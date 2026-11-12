import { DurableObject } from "cloudflare:workers";
import { Env, rateLimit, sha256Hex } from "./util";

interface Pending {
  resolve: (v: { ok: boolean; error?: string; data?: unknown }) => void;
  timer: ReturnType<typeof setTimeout>;
}

const MAX_MAC_MESSAGE = 512 * 1024;
const COMMAND_TIMEOUT_MS = 15_000;
const STALE_MS = 90_000; // Mac sends state at least every 30 s

/**
 * One instance per paired Mac. Holds the Mac's outbound WebSocket (Hibernation API, so an
 * idle connection costs nothing), the last state snapshot, and forwards dashboard commands.
 */
export class Device extends DurableObject<Env> {
  private pending = new Map<string, Pending>();

  async init(id: string, name: string, tokenHash: string) {
    await this.ctx.storage.put({ id, name, tokenHash, createdAt: Date.now(), epoch: 1 });
  }

  /** Browser grants carry this number; bumping it signs every browser out. */
  async getEpoch(): Promise<number> {
    return (await this.ctx.storage.get<number>("epoch")) ?? 1;
  }

  async destroy() {
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.send(JSON.stringify({ type: "revoked" }));
        ws.close(4401, "revoked");
      } catch {}
    }
    await this.ctx.storage.deleteAll();
  }

  /** WebSocket upgrade from the Mac. Auth: Bearer token, compared by SHA-256 hash. */
  async fetch(req: Request): Promise<Response> {
    if (req.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("expected websocket", { status: 426 });
    const stored = await this.ctx.storage.get<string>("tokenHash");
    const auth = req.headers.get("Authorization") ?? "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    const ok = !!stored && token.length >= 32 && token.length <= 128 && (await sha256Hex(token)) === stored;

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    if (!ok) {
      // Accept then close with 4401 so the Mac can tell "revoked" apart from a network error.
      server.accept();
      server.close(4401, "unauthorized");
      return new Response(null, { status: 101, webSocket: client });
    }
    // One live connection per device: newest wins.
    for (const old of this.ctx.getWebSockets()) {
      try {
        old.close(4000, "replaced");
      } catch {}
    }
    this.ctx.acceptWebSocket(server);
    await this.ctx.storage.put({ lastSeen: Date.now(), online: true });
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer) {
    if (typeof message !== "string" || message.length > MAX_MAC_MESSAGE) {
      ws.close(1009, "message too big");
      return;
    }
    const rl = await rateLimit(this.ctx.storage, "mac", 240, 60);
    if (!rl.ok) {
      ws.close(4429, "rate limited");
      return;
    }
    let msg: any;
    try {
      msg = JSON.parse(message);
    } catch {
      return;
    }
    if (!msg || typeof msg !== "object") return;
    const now = Date.now();
    if (msg.type === "state" && msg.state && typeof msg.state === "object" && !Array.isArray(msg.state)) {
      await this.ctx.storage.put({ state: msg.state, lastSeen: now, online: true });
    } else if (msg.type === "requestBrowserCode") {
      // The Mac asks for a one-time code to sign a browser in to it.
      const lim = await rateLimit(this.ctx.storage, "browserCode", 10, 600);
      const id = await this.ctx.storage.get<string>("id");
      if (!lim.ok || !id) {
        ws.send(JSON.stringify({ type: "browserCode", error: "Too many codes requested. Try again later." }));
        return;
      }
      try {
        const r = await this.env.HUB.get(this.env.HUB.idFromName("global")).browserCode(id);
        ws.send(JSON.stringify({ type: "browserCode", code: r.code, expiresAt: r.expiresAt }));
      } catch {
        ws.send(JSON.stringify({ type: "browserCode", error: "Could not create a code" }));
      }
    } else if (msg.type === "revokeBrowsers") {
      await this.ctx.storage.put("epoch", (await this.getEpoch()) + 1);
      ws.send(JSON.stringify({ type: "browsersRevoked" }));
    } else if (msg.type === "result" && typeof msg.id === "string") {
      const p = this.pending.get(msg.id);
      if (p) {
        clearTimeout(p.timer);
        this.pending.delete(msg.id);
        p.resolve({
          ok: msg.ok === true,
          error: typeof msg.error === "string" ? msg.error.slice(0, 300) : undefined,
          data: msg.data,
        });
      }
      await this.ctx.storage.put("lastSeen", now);
    }
  }

  async webSocketClose(ws: WebSocket) {
    if (this.ctx.getWebSockets().filter((w) => w !== ws).length === 0) {
      await this.ctx.storage.put({ online: false, lastSeen: Date.now() });
    }
  }

  async webSocketError(ws: WebSocket) {
    await this.webSocketClose(ws);
  }

  async getStatus() {
    const s = await this.ctx.storage.get(["name", "state", "lastSeen", "createdAt"]);
    const lastSeen = (s.get("lastSeen") as number | undefined) ?? null;
    const socketOpen = this.ctx.getWebSockets().length > 0;
    return {
      name: s.get("name") ?? "Mac",
      online: socketOpen && lastSeen !== null && Date.now() - lastSeen < STALE_MS,
      lastSeen,
      state: s.get("state") ?? null,
    };
  }

  async command(cmd: string, args: Record<string, unknown>): Promise<{ ok: boolean; error?: string; data?: unknown }> {
    const rl = await rateLimit(this.ctx.storage, "cmd", 60, 60);
    if (!rl.ok) return { ok: false, error: `rate limited, retry in ${rl.retryAfter}s` };
    const ws = this.ctx.getWebSockets()[0];
    if (!ws) return { ok: false, error: "Mac is offline" };
    const id = crypto.randomUUID();
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        resolve({ ok: false, error: "Mac did not answer in time" });
      }, COMMAND_TIMEOUT_MS);
      this.pending.set(id, { resolve, timer });
      try {
        ws.send(JSON.stringify({ type: "command", id, cmd, args }));
      } catch {
        clearTimeout(timer);
        this.pending.delete(id);
        resolve({ ok: false, error: "Mac is offline" });
      }
    });
  }
}
