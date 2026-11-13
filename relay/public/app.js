"use strict";

const $ = (id) => document.getElementById(id);
const state = {
  devices: [],
  deviceId: null,
  status: null,
  installed: null,       // [{bundleId, name}] fetched from the Mac on demand
  allowDraft: null,      // Set of bundle ids being edited, or null if not dirty
  pollTimer: null,
};

// ---------- helpers ----------

async function api(path, opts = {}) {
  const res = await fetch(path, {
    method: opts.method || "GET",
    headers: opts.body ? { "Content-Type": "application/json" } : {},
    body: opts.body ? JSON.stringify(opts.body) : undefined,
    credentials: "same-origin",
  });
  let data = {};
  try { data = await res.json(); } catch {}
  if (res.status === 401) { showSignIn(); throw new Error(data.error || "Not signed in"); }
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

let toastTimer;
function toast(msg) {
  const t = $("toast");
  t.textContent = msg;
  t.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove("show"), 2800);
}

function el(tag, attrs = {}, ...children) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") e.className = v;
    else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else if (v === true) e.setAttribute(k, "");
    else if (v !== false && v != null) e.setAttribute(k, v);
  }
  for (const c of children.flat()) if (c != null) e.append(c instanceof Node ? c : document.createTextNode(String(c)));
  return e;
}

function ago(ms) {
  if (!ms) return "never";
  const s = Math.round((Date.now() - ms) / 1000);
  if (s < 10) return "just now";
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  return new Date(ms).toLocaleString();
}

function show(view) {
  for (const v of ["signInView", "deviceView"]) $(v).hidden = v !== view;
  const loggedIn = view !== "signInView";
  $("logoutBtn").hidden = !loggedIn;
  $("devicePicker").hidden = !loggedIn || state.devices.length < 2;
}

function showSignIn() {
  stopPolling();
  state.devices = [];
  state.deviceId = null;
  show("signInView");
}

async function command(cmd, args = {}, okMsg) {
  try {
    const r = await api(`/api/devices/${state.deviceId}/command`, { method: "POST", body: { cmd, args } });
    if (okMsg) toast(okMsg);
    setTimeout(refreshState, 600);
    return r.data;
  } catch (e) {
    toast(e.message);
    throw e;
  }
}

// ---------- boot / sign out ----------

async function boot() {
  try {
    await loadDevices();
  } catch {
    showSignIn();
  }
}

$("logoutBtn").addEventListener("click", async () => {
  if (!confirm("Sign this browser out? You will need a new code from the Mac to sign back in.")) return;
  await api("/api/logout", { method: "POST" }).catch(() => {});
  showSignIn();
});

// ---------- devices + pairing ----------

async function loadDevices(selectId) {
  const { devices } = await api("/api/devices");
  state.devices = devices;
  if (!devices.length) return showSignIn();
  const saved = selectId || state.deviceId || localStorageGet("deviceId");
  state.deviceId = devices.some((d) => d.id === saved) ? saved : devices[0].id;
  const picker = $("devicePicker");
  picker.replaceChildren(...devices.map((d) => el("option", { value: d.id, selected: d.id === state.deviceId }, d.name)));
  show("deviceView");
  state.installed = null;
  state.allowDraft = null;
  startPolling();
}

function localStorageGet(k) { try { return localStorage.getItem(`ns:${k}`); } catch { return null; } }
function localStorageSet(k, v) { try { localStorage.setItem(`ns:${k}`, v); } catch {} }

$("devicePicker").addEventListener("change", (e) => {
  localStorageSet("deviceId", e.target.value);
  loadDevices(e.target.value);
});

async function pair(form) {
  const errEl = form.parentElement.querySelector(".pair-error");
  errEl.textContent = "";
  const code = form.code.value;
  try {
    const { device } = await api("/api/claim", { method: "POST", body: { code } });
    form.reset();
    toast(`Signed in to ${device.name}`);
    localStorageSet("deviceId", device.id);
    await loadDevices(device.id);
  } catch (e) {
    errEl.textContent = e.message;
  }
}
for (const f of [$("pairForm"), $("codeForm")]) {
  f.addEventListener("submit", (ev) => { ev.preventDefault(); pair(f); });
}

$("removeDevice").addEventListener("click", async () => {
  const d = state.devices.find((x) => x.id === state.deviceId);
  if (!confirm(`Remove ${d ? d.name : "this Mac"}? It is unpaired and every browser loses access. Pair it again from the Mac to undo.`)) return;
  try {
    await api(`/api/devices/${state.deviceId}`, { method: "DELETE" });
    toast("Removed");
    state.deviceId = null;
    await loadDevices();
  } catch (e) { toast(e.message); }
});

// ---------- polling ----------

function startPolling() {
  stopPolling();
  refreshState();
  state.pollTimer = setInterval(() => { if (!document.hidden) refreshState(); }, 4000);
}
function stopPolling() { clearInterval(state.pollTimer); state.pollTimer = null; }
document.addEventListener("visibilitychange", () => { if (!document.hidden && state.pollTimer) refreshState(); });

async function refreshState() {
  if (!state.deviceId) return;
  try {
    state.status = await api(`/api/devices/${state.deviceId}/state`);
    render();
  } catch {}
}

// ---------- rendering ----------

function render() {
  const st = state.status || {};
  const s = st.state || {};
  const online = !!st.online;

  $("onlineDot").classList.toggle("on", online);
  $("onlineText").textContent = online ? `${st.name} is online` : `${st.name} is offline`;
  $("lastSeen").textContent = `· last seen ${ago(st.lastSeen)}`;

  // Battery
  const b = s.battery || {};
  if (b.present && b.percent != null) {
    $("batteryPct").textContent = `${b.percent}%`;
    $("batteryBar").style.width = `${b.percent}%`;
    const parts = [b.charging ? "Charging" : b.pluggedIn ? "Plugged in" : "On battery"];
    if (!b.pluggedIn && b.timeToEmptyMin) parts.push(`${Math.floor(b.timeToEmptyMin / 60)}h ${b.timeToEmptyMin % 60}m left`);
    if (b.charging && b.timeToFullMin) parts.push(`full in ${Math.floor(b.timeToFullMin / 60)}h ${b.timeToFullMin % 60}m`);
    $("batteryDetail").textContent = parts.join(" · ");
  } else {
    $("batteryPct").textContent = s.battery ? "No battery" : "–";
    $("batteryBar").style.width = "0";
    $("batteryDetail").textContent = "";
  }
  $("thermal").textContent = s.thermal ? `Thermal state: ${s.thermal}` : "";

  // Lid
  const lm = s.lidMode || {};
  const lid = s.lid || {};
  const toggle = $("lidModeToggle");
  if (document.activeElement !== toggle) toggle.checked = !!lm.enabled;
  toggle.disabled = !online;
  $("lidState").textContent = lid.closed == null ? "–" : lid.closed ? (lid.simulated ? "closed (simulated)" : "closed") : "open";
  $("phase").textContent = { off: "Off", armed: "Armed", active: "Active (apps paused)", cutoff: "Cut off" }[lm.phase] || "–";
  $("phaseReason").textContent = lm.reason ? `— ${lm.reason}` : lm.pausedCount ? `— ${lm.pausedCount} paused` : "";
  $("lidError").textContent = lm.error || "";
  $("helperWarn").hidden = s.helper !== "notEnabled";

  renderApps(s, online);
  renderAllow(s);
  renderActivity(s);
}

function renderApps(s, online) {
  const apps = (s.apps || []).slice().sort((a, b) => a.name.localeCompare(b.name));
  $("appCount").textContent = apps.length ? `${apps.length}` : "";
  const items = apps.map((a) => {
    const tags = [];
    if (a.paused) tags.push(el("span", { class: "tag paused" }, a.pausedBy === "manual" ? "paused" : "paused (lid)"));
    if (a.allowed) tags.push(el("span", { class: "tag allowed" }, "allowed"));
    if (a.protected) tags.push(el("span", { class: "tag" }, "system"));
    if (a.keptBecause) tags.push(el("span", { class: "tag allowed" }, a.keptBecause));
    const actions = [];
    if (!a.protected) {
      actions.push(a.paused
        ? el("button", { class: "small", disabled: !online, onclick: () => command("resumeApp", { pid: a.pid }, `Resumed ${a.name}`) }, "Resume")
        : el("button", { class: "small", disabled: !online, onclick: () => command("pauseApp", { pid: a.pid }, `Paused ${a.name}`) }, "Pause"));
      actions.push(el("button", { class: "small", disabled: !online, onclick: () => command("quitApp", { pid: a.pid }, `Asked ${a.name} to quit`) }, "Quit"));
      actions.push(el("button", {
        class: "small danger", disabled: !online,
        onclick: () => confirm(`Force quit ${a.name}? Unsaved work will be lost.`) && command("forceQuitApp", { pid: a.pid }, `Force quit ${a.name}`),
      }, "Force quit"));
    }
    return el("li", {},
      el("div", { class: "app-name" }, a.name, ...tags, el("small", {}, a.bundleId || `pid ${a.pid}`)),
      el("div", { class: "actions" }, actions));
  });
  $("appList").replaceChildren(...(items.length ? items : [el("li", { class: "muted" }, online ? "No apps" : "Waiting for the Mac…")]));
}

function renderActivity(s) {
  const events = (s.events || []).slice().reverse();
  const fmt = (t) => new Date(t).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
  $("activityList").replaceChildren(...(events.length
    ? events.map((e) => el("li", {},
        el("time", {}, fmt(e.t)),
        el("span", { class: "k" }, e.kind),
        el("span", { class: e.kind === "error" || e.kind === "safety" ? "bad" : "" }, e.msg)))
    : [el("li", { class: "muted" }, "No activity yet")]));
}

// ---------- installed apps (launch + allow-list) ----------

async function ensureInstalled() {
  if (state.installed || !state.status?.online) return state.installed;
  try {
    const data = await command("listInstalledApps");
    state.installed = (data && data.apps) || [];
  } catch {}
  return state.installed;
}

function renderLaunch() {
  const q = $("launchSearch").value.trim().toLowerCase();
  const list = state.installed || [];
  const running = new Set((state.status?.state?.apps || []).map((a) => a.bundleId));
  const hits = q ? list.filter((a) => a.name.toLowerCase().includes(q) || a.bundleId.toLowerCase().includes(q)).slice(0, 40) : [];
  $("launchList").replaceChildren(...hits.map((a) =>
    el("li", {},
      el("div", { class: "app-name" }, a.name, running.has(a.bundleId) ? el("span", { class: "tag allowed" }, "running") : null,
        el("small", {}, a.bundleId)),
      el("div", { class: "actions" },
        el("button", { class: "small", onclick: () => command("launchApp", { bundleId: a.bundleId }, `Opening ${a.name}`) }, "Open")))));
  if (q && !state.installed) $("launchList").replaceChildren(el("li", { class: "muted" }, "Loading apps from the Mac…"));
}

$("launchSearch").addEventListener("focus", async () => { await ensureInstalled(); renderLaunch(); });
$("launchSearch").addEventListener("input", renderLaunch);

function renderAllow(s) {
  const current = new Set(s.allowList || []);
  const draft = state.allowDraft || current;
  const q = $("allowSearch").value.trim().toLowerCase();
  const byId = new Map();
  for (const a of state.installed || []) byId.set(a.bundleId, a.name);
  for (const a of s.apps || []) if (a.bundleId && !a.protected) byId.set(a.bundleId, a.name);
  for (const id of draft) if (!byId.has(id)) byId.set(id, id);
  const rows = [...byId.entries()]
    .filter(([id, name]) => !q || name.toLowerCase().includes(q) || id.toLowerCase().includes(q))
    .sort((a, b) => (draft.has(b[0]) - draft.has(a[0])) || a[1].localeCompare(b[1]));
  if (document.activeElement && $("allowList").contains(document.activeElement)) return; // don't re-render under the finger
  $("allowList").replaceChildren(...rows.map(([id, name]) =>
    el("li", {},
      el("label", { class: "allow-row" },
        el("input", { type: "checkbox", checked: draft.has(id), onchange: (e) => {
          const next = new Set(state.allowDraft || current);
          e.target.checked ? next.add(id) : next.delete(id);
          state.allowDraft = next;
          $("saveAllow").disabled = false;
        } }),
        el("div", { class: "app-name" }, name, el("small", {}, id))))));
}

$("allowSearch").addEventListener("focus", async () => { await ensureInstalled(); renderAllow(state.status?.state || {}); });
$("allowSearch").addEventListener("input", () => renderAllow(state.status?.state || {}));

$("saveAllow").addEventListener("click", async () => {
  if (!state.allowDraft) return;
  try {
    await command("setAllowList", { bundleIds: [...state.allowDraft] }, "Allow-list saved");
    state.allowDraft = null;
    $("saveAllow").disabled = true;
  } catch {}
});

$("lidModeToggle").addEventListener("change", async (e) => {
  const on = e.target.checked;
  try { await command("setLidMode", { enabled: on }, on ? "Lid mode on" : "Lid mode off"); }
  catch { e.target.checked = !on; }
  e.target.blur();
});

setInterval(() => { if (state.status) $("lastSeen").textContent = `· last seen ${ago(state.status.lastSeen)}`; }, 5000);

boot();
