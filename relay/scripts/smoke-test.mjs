// End-to-end check of the relay, playing browsers and fake Macs.
//   node scripts/smoke-test.mjs [baseUrl]
import { createHash, randomBytes } from "node:crypto";

const BASE = process.argv[2] || "http://127.0.0.1:8787";
let failures = 0;
const check = (name, cond, extra = "") => {
  console.log(`${cond ? "ok  " : "FAIL"} ${name}${!cond && extra ? " — " + extra : ""}`);
  if (!cond) failures++;
};

/** A browser with its own cookie jar. */
function browser() {
  let cookie = "";
  return async function call(path, { method = "GET", body, headers = {} } = {}) {
    const res = await fetch(BASE + path, {
      method,
      headers: { ...(body ? { "Content-Type": "application/json" } : {}), ...(cookie ? { Cookie: cookie } : {}), ...headers },
      body: body ? JSON.stringify(body) : undefined,
    });
    const sc = res.headers.get("set-cookie");
    if (sc && sc.startsWith("ns_session=")) cookie = sc.includes("Max-Age=0") ? "" : sc.split(";")[0];
    let data = {};
    try { data = await res.json(); } catch {}
    return { status: res.status, data };
  };
}

/** A fake Mac: pairs via `browserCall`, then connects over WebSocket and answers commands. */
async function pairMac(browserCall, name) {
  const anon = browser();
  const token = randomBytes(32).toString("base64url");
  const tokenHash = createHash("sha256").update(token).digest("hex");
  const start = await anon("/api/pair/start", { method: "POST", body: { name, tokenHash } });
  if (!start.data.code) throw new Error("pair/start failed: " + start.status + " " + JSON.stringify(start.data));
  const claim = await browserCall("/api/claim", { method: "POST", body: { code: start.data.code.toLowerCase().replace("-", " ") } });
  const poll = await anon("/api/pair/poll", { method: "POST", body: { pairId: start.data.pairId, token } });
  return { start, claim, poll, token, deviceId: poll.data.deviceId };
}

function connect(deviceId, token) {
  const ws = new WebSocket(BASE.replace(/^http/, "ws") + "/api/device/connect", {
    headers: { Authorization: `Bearer ${token}`, "X-Device-Id": deviceId },
  });
  ws.inbox = [];
  ws.waiters = [];
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    ws.inbox.push(msg);
    if (msg.type === "command") {
      ws.send(JSON.stringify({ type: "result", id: msg.id, ok: msg.cmd !== "pauseApp", error: msg.cmd === "pauseApp" ? "nope" : undefined, data: { echo: msg.cmd } }));
    }
    ws.waiters = ws.waiters.filter((w) => !w(msg));
  };
  ws.next = (type) => new Promise((r) => ws.waiters.push((m) => (m.type === type ? (r(m), true) : false)));
  return ws;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const phone = browser();
check("dashboard page served", (await fetch(BASE + "/")).status === 200);
check("no session → no devices", (await phone("/api/devices")).data.devices?.length === 0);
check("old password login is gone", (await phone("/api/login", { method: "POST", body: { password: "x" } })).status !== 200);
check("bad code rejected", (await phone("/api/claim", { method: "POST", body: { code: "AAAA-AAAA" } })).status === 404);
check("cross-origin claim rejected",
  (await phone("/api/claim", { method: "POST", body: { code: "AAAA-AAAA" }, headers: { Origin: "https://evil.example" } })).status === 403);

// Pair Mac A from the phone.
const A = await pairMac(phone, "Mac A");
check("pair code format", /^[A-Z2-9]{4}-[A-Z2-9]{4}$/.test(A.start.data.code), JSON.stringify(A.start.data));
check("claim signs the phone in", A.claim.status === 200 && A.claim.data.device?.id === A.deviceId, JSON.stringify(A.claim.data));
check("Mac learns its device id", A.poll.data.status === "claimed");
check("code is single use", (await phone("/api/claim", { method: "POST", body: { code: A.start.data.code } })).status === 404);

const bad = connect(A.deviceId, "y".repeat(43));
check("wrong device token closed with 4401", (await new Promise((r) => { bad.onclose = (e) => r(e.code); })) === 4401);

const wsA = connect(A.deviceId, A.token);
await new Promise((r, j) => { wsA.onopen = r; wsA.onerror = j; });
wsA.send(JSON.stringify({ type: "state", state: { battery: { present: true, percent: 77 } } }));
await sleep(400);

const st = await phone(`/api/devices/${A.deviceId}/state`);
check("phone sees state + online", st.data.online === true && st.data.state?.battery?.percent === 77, JSON.stringify(st.data));
const ok = await phone(`/api/devices/${A.deviceId}/command`, { method: "POST", body: { cmd: "setLidMode", args: { enabled: true } } });
check("command round-trips to the Mac", ok.status === 200 && ok.data.data?.echo === "setLidMode", JSON.stringify(ok.data));
const macErr = await phone(`/api/devices/${A.deviceId}/command`, { method: "POST", body: { cmd: "pauseApp", args: { pid: 123 } } });
check("Mac-side error is reported", macErr.status === 502 && macErr.data.error === "nope");
for (const [cmd, args] of [["shell", { cmd: "ls" }], ["pauseApp", { pid: "1; rm" }], ["launchApp", { bundleId: "../x" }], ["setLidMode", {}], ["quitApp", { pid: 5, extra: 1 }]]) {
  const r = await phone(`/api/devices/${A.deviceId}/command`, { method: "POST", body: { cmd, args } });
  check(`rejects ${cmd} ${JSON.stringify(args)}`, r.status === 400);
}
check("Mac only received the 2 valid commands", wsA.inbox.filter((m) => m.type === "command").length === 2);

// A stranger pairs their own fake Mac; that must not give access to Mac A.
const stranger = browser();
const S = await pairMac(stranger, "Stranger Mac");
check("stranger can pair their own Mac", S.claim.status === 200);
check("stranger cannot read Mac A", (await stranger(`/api/devices/${A.deviceId}/state`)).status === 401);
check("stranger cannot command Mac A",
  (await stranger(`/api/devices/${A.deviceId}/command`, { method: "POST", body: { cmd: "refresh", args: {} } })).status === 401);
check("stranger's list excludes Mac A", !(await stranger("/api/devices")).data.devices.some((d) => d.id === A.deviceId));
check("phone's list excludes stranger's Mac", !(await phone("/api/devices")).data.devices.some((d) => d.id === S.deviceId));

// Paired Mac shows a code for a second browser (laptop).
const laptop = browser();
wsA.send(JSON.stringify({ type: "requestBrowserCode" }));
const bc = await wsA.next("browserCode");
check("Mac gets a browser code", /^[A-Z2-9]{4}-[A-Z2-9]{4}$/.test(bc.code ?? ""), JSON.stringify(bc));
const lc = await laptop("/api/claim", { method: "POST", body: { code: bc.code } });
check("laptop signs in with it", lc.status === 200 && lc.data.device?.id === A.deviceId);
check("laptop can read Mac A", (await laptop(`/api/devices/${A.deviceId}/state`)).status === 200);
check("browser code is single use", (await stranger("/api/claim", { method: "POST", body: { code: bc.code } })).status === 404);

// "Sign out all browsers" on the Mac.
wsA.send(JSON.stringify({ type: "revokeBrowsers" }));
await wsA.next("browsersRevoked");
check("phone signed out after revoke", (await phone(`/api/devices/${A.deviceId}/state`)).status === 401);
check("laptop signed out after revoke", (await laptop(`/api/devices/${A.deviceId}/state`)).status === 401);
check("Mac still connected after revoke", wsA.readyState === 1);

// Fresh code → back in → remove the Mac.
wsA.send(JSON.stringify({ type: "requestBrowserCode" }));
const bc2 = await wsA.next("browserCode");
check("phone signs back in with a new code", (await phone("/api/claim", { method: "POST", body: { code: bc2.code } })).status === 200);
const closed = new Promise((r) => { wsA.onclose = (e) => r(e.code); });
check("remove Mac A", (await phone(`/api/devices/${A.deviceId}`, { method: "DELETE" })).status === 200);
check("Mac socket closed with 4401 on removal", (await closed) === 4401);
check("removed Mac gone from list", (await phone("/api/devices")).data.devices.length === 0);

// Clean up the stranger's fake Mac.
check("stranger removes their Mac", (await stranger(`/api/devices/${S.deviceId}`, { method: "DELETE" })).status === 200);
check("sign out", (await phone("/api/logout", { method: "POST" })).status === 200);

console.log(`\n${failures ? failures + " FAILED" : "all passed"}`);
process.exit(failures ? 1 : 0);
