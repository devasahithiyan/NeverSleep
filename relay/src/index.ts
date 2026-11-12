import { validateCommand } from "./commands";
import { Env, Grant, clearSessionCookie, err, json, makeSession, readJson, readSession, sha256Hex } from "./util";

export { Hub } from "./hub";
export { Device } from "./device";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const HEX64 = /^[0-9a-f]{64}$/;
const CODE = /^[A-Z2-9]{4}-[A-Z2-9]{4}$/;

function hub(env: Env) {
  return env.HUB.get(env.HUB.idFromName("global"));
}
function device(env: Env, id: string) {
  return env.DEVICE.get(env.DEVICE.idFromName(id));
}

function isLocal(url: URL) {
  return url.hostname === "localhost" || url.hostname === "127.0.0.1";
}

/** Browser POST/DELETEs must come from our own origin (on top of SameSite=Strict cookies). */
function sameOrigin(req: Request, url: URL) {
  const origin = req.headers.get("Origin");
  return origin === null || origin === url.origin;
}

async function limited(env: Env, key: string, max: number, windowSec: number): Promise<Response | null> {
  const r = await hub(env).limit(key, max, windowSec);
  return r.ok ? null : json({ error: "Too many attempts. Try again later." }, 429, { "Retry-After": String(r.retryAfter) });
}

/** Grants from the cookie that still point at an existing device with a current epoch. */
async function validGrants(req: Request, env: Env): Promise<Grant[]> {
  const grants = await readSession(req, env);
  const out: Grant[] = [];
  for (const g of grants) {
    if (!UUID.test(g.id) || !(await hub(env).getDevice(g.id))) continue;
    if ((await device(env, g.id).getEpoch()) === g.epoch) out.push(g);
  }
  return out;
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);

    // TLS only (wrangler dev on localhost is the one exception).
    if (url.protocol !== "https:" && !isLocal(url)) {
      url.protocol = "https:";
      return Response.redirect(url.toString(), 301);
    }
    if (!url.pathname.startsWith("/api/")) return env.ASSETS.fetch(req);
    if (!env.SESSION_SECRET || env.SESSION_SECRET.length < 32) {
      return err(500, "Relay is not configured: set SESSION_SECRET (32+ chars).");
    }
    if ((req.method === "POST" || req.method === "DELETE") && !sameOrigin(req, url)) return err(403, "bad origin");

    const ip = req.headers.get("CF-Connecting-IP") ?? "local";
    const path = url.pathname;

    // ---------- Mac-facing (device token or pairing proof) ----------

    if (path === "/api/device/connect") {
      const id = req.headers.get("X-Device-Id") ?? "";
      if (!UUID.test(id)) return err(400, "bad device id");
      const rl = await limited(env, `connect:${ip}`, 30, 60);
      if (rl) return rl;
      if (!(await hub(env).getDevice(id))) {
        // Unknown/removed device: answer with a 4401 close so the Mac unpairs itself.
        const pair = new WebSocketPair();
        const [client, server] = Object.values(pair);
        server.accept();
        server.close(4401, "unknown device");
        return new Response(null, { status: 101, webSocket: client });
      }
      return device(env, id).fetch(req);
    }

    if (path === "/api/pair/start" && req.method === "POST") {
      const rl = await limited(env, `pairstart:${ip}`, 10, 600);
      if (rl) return rl;
      const body = await readJson(req);
      const name = typeof body?.name === "string" ? body.name.replace(/[\u0000-\u001f]/g, "").slice(0, 64) : "";
      const tokenHash = body?.tokenHash;
      if (!name || typeof tokenHash !== "string" || !HEX64.test(tokenHash)) return err(400, "bad request");
      try {
        return json(await hub(env).startPairing(name, tokenHash));
      } catch {
        return err(429, "Too many pending pairings");
      }
    }

    if (path === "/api/pair/poll" && req.method === "POST") {
      const rl = await limited(env, `pairpoll:${ip}`, 60, 60);
      if (rl) return rl;
      const body = await readJson(req);
      const pairId = body?.pairId, token = body?.token;
      if (typeof pairId !== "string" || !UUID.test(pairId) || typeof token !== "string" || token.length > 128) {
        return err(400, "bad request");
      }
      const r = await hub(env).poll(pairId, await sha256Hex(token));
      return r ? json(r) : err(404, "Pairing expired or unknown");
    }

    // ---------- Browser sign-in: a one-time code shown on the Mac ----------

    if (path === "/api/claim" && req.method === "POST") {
      // 8 symbols from 31 ≈ 8.5e11 codes, live for 10 min; 10 guesses per 5 min per IP.
      const rl = await limited(env, `claim:${ip}`, 10, 300);
      if (rl) return rl;
      const body = await readJson(req, 1024);
      const raw = typeof body?.code === "string" ? body.code.trim().toUpperCase().replace(/[\s-]+/g, "") : "";
      const code = raw.length === 8 ? `${raw.slice(0, 4)}-${raw.slice(4)}` : raw;
      if (!CODE.test(code)) return err(400, "The code looks like ABCD-EFGH");
      const r = await hub(env).claim(code);
      if (!r) return err(404, "Unknown or expired code. Get a new one from the Mac.");
      if (r.newTokenHash) await device(env, r.device.id).init(r.device.id, r.device.name, r.newTokenHash);
      const epoch = await device(env, r.device.id).getEpoch();
      const grants = (await validGrants(req, env)).filter((g) => g.id !== r.device.id);
      grants.push({ id: r.device.id, epoch });
      return json({ device: r.device }, 200, { "Set-Cookie": await makeSession(env, grants) });
    }

    if (path === "/api/logout" && req.method === "POST") {
      return json({ ok: true }, 200, { "Set-Cookie": clearSessionCookie() });
    }

    // ---------- Signed-in browser ----------

    const grants = await validGrants(req, env);
    const allowed = new Set(grants.map((g) => g.id));

    if (path === "/api/devices" && req.method === "GET") {
      const out = await Promise.all(
        grants.map(async (g) => {
          const d = await hub(env).getDevice(g.id);
          const s = await device(env, g.id).getStatus();
          return { id: g.id, name: d?.name ?? s.name, createdAt: d?.createdAt, online: s.online, lastSeen: s.lastSeen };
        }),
      );
      return json({ devices: out });
    }

    const m = path.match(/^\/api\/devices\/([0-9a-f-]{36})(\/state|\/command)?$/);
    if (m && UUID.test(m[1])) {
      const id = m[1];
      if (!allowed.has(id)) return err(401, "This browser is not signed in to that Mac");
      if (!m[2] && req.method === "DELETE") {
        await device(env, id).destroy();
        await hub(env).removeDevice(id);
        return json({ ok: true });
      }
      if (m[2] === "/state" && req.method === "GET") {
        return json(await device(env, id).getStatus());
      }
      if (m[2] === "/command" && req.method === "POST") {
        const body = await readJson(req, 64 * 1024);
        const v = validateCommand(body?.cmd, body?.args);
        if (typeof v === "string") return err(400, v);
        const r = (await device(env, id).command(v.cmd, v.args)) as { ok: boolean; error?: string; data?: unknown };
        return json(r, r.ok ? 200 : 502);
      }
    }

    return err(404, "Not found");
  },
} satisfies ExportedHandler<Env>;
