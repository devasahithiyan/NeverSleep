import { DurableObject } from "cloudflare:workers";
import { Env, rateLimit } from "./util";

export interface DeviceInfo {
  id: string;
  name: string;
  createdAt: number;
}

/**
 * A one-time code shown on the Mac. Typing it into a browser signs that browser in to that Mac.
 *  - kind "pair":    an unpaired Mac. Claiming it also creates the device (the Mac polls for it).
 *  - kind "browser": an already-paired Mac asked for a code over its authenticated WebSocket.
 */
interface CodeRecord {
  pairId: string;
  kind: "pair" | "browser";
  code: string;
  name: string;
  expiresAt: number;
  tokenHash?: string;        // pair only
  deviceId?: string;         // browser: target device; pair: set once claimed
  claimed?: boolean;
}

// No 0/O/1/I/L so codes are easy to read off a menu bar.
const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const CODE_TTL_MS = 10 * 60 * 1000;

function makeCode(): string {
  // Rejection sampling keeps the distribution uniform (31 symbols, 8 chars ≈ 2^39.6).
  let s = "";
  while (s.length < 8) {
    for (const b of crypto.getRandomValues(new Uint8Array(16))) {
      if (b < 248 && s.length < 8) s += CODE_ALPHABET[b % 31];
    }
  }
  return `${s.slice(0, 4)}-${s.slice(4)}`;
}

/** Singleton: rate limits, one-time codes and the device registry. */
export class Hub extends DurableObject<Env> {
  async limit(key: string, max: number, windowSec: number) {
    return rateLimit(this.ctx.storage, key, max, windowSec);
  }

  async getDevice(id: string): Promise<DeviceInfo | undefined> {
    return this.ctx.storage.get<DeviceInfo>(`dev:${id}`);
  }

  async removeDevice(id: string): Promise<boolean> {
    return this.ctx.storage.delete(`dev:${id}`);
  }

  private async newCode(rec: Omit<CodeRecord, "code" | "pairId" | "expiresAt">) {
    await this.sweep();
    const pending = await this.ctx.storage.list({ prefix: "pair:" });
    if (pending.size > 50) throw new Error("too many pending codes");
    let code = makeCode();
    while (await this.ctx.storage.get(`code:${code}`)) code = makeCode();
    const full: CodeRecord = { ...rec, code, pairId: crypto.randomUUID(), expiresAt: Date.now() + CODE_TTL_MS };
    await this.ctx.storage.put({ [`pair:${full.pairId}`]: full, [`code:${code}`]: full.pairId });
    return full;
  }

  async startPairing(name: string, tokenHash: string): Promise<{ pairId: string; code: string; expiresAt: number }> {
    const r = await this.newCode({ kind: "pair", name, tokenHash });
    return { pairId: r.pairId, code: r.code, expiresAt: r.expiresAt };
  }

  async browserCode(deviceId: string): Promise<{ code: string; expiresAt: number }> {
    const dev = await this.getDevice(deviceId);
    if (!dev) throw new Error("unknown device");
    const r = await this.newCode({ kind: "browser", name: dev.name, deviceId });
    return { code: r.code, expiresAt: r.expiresAt };
  }

  /**
   * Browser typed a code. Returns the device it unlocks; for a "pair" code also the token hash
   * the new Device object must be initialised with.
   */
  async claim(code: string): Promise<{ device: DeviceInfo; newTokenHash?: string } | null> {
    await this.sweep();
    const pairId = await this.ctx.storage.get<string>(`code:${code}`);
    if (!pairId) return null;
    await this.ctx.storage.delete(`code:${code}`); // single use, even if something below fails
    const p = await this.ctx.storage.get<CodeRecord>(`pair:${pairId}`);
    if (!p || p.claimed || p.expiresAt < Date.now()) return null;

    if (p.kind === "browser") {
      await this.ctx.storage.delete(`pair:${pairId}`);
      const dev = p.deviceId ? await this.getDevice(p.deviceId) : undefined;
      return dev ? { device: dev } : null;
    }
    const device: DeviceInfo = { id: crypto.randomUUID(), name: p.name, createdAt: Date.now() };
    p.claimed = true;
    p.deviceId = device.id;
    await this.ctx.storage.put({ [`pair:${pairId}`]: p, [`dev:${device.id}`]: device });
    return { device, newTokenHash: p.tokenHash };
  }

  /** Polled by an unpaired Mac. It proves possession of the token whose hash it registered. */
  async poll(pairId: string, tokenHash: string): Promise<{ status: "pending" | "claimed"; deviceId?: string } | null> {
    const p = await this.ctx.storage.get<CodeRecord>(`pair:${pairId}`);
    if (!p || p.kind !== "pair" || p.tokenHash !== tokenHash) return null;
    if (p.claimed && p.deviceId) {
      await this.ctx.storage.delete(`pair:${pairId}`);
      return { status: "claimed", deviceId: p.deviceId };
    }
    if (p.expiresAt < Date.now()) return null;
    return { status: "pending" };
  }

  private async sweep() {
    const now = Date.now();
    const all = await this.ctx.storage.list<CodeRecord>({ prefix: "pair:" });
    const dead: string[] = [];
    for (const [k, p] of all) {
      // Keep claimed pair records a little longer so the Mac's next poll can pick them up.
      if (p.expiresAt + (p.claimed ? CODE_TTL_MS : 0) < now) dead.push(k, `code:${p.code}`);
    }
    if (dead.length) await this.ctx.storage.delete(dead.slice(0, 128));
    const rl = await this.ctx.storage.list<{ reset: number }>({ prefix: "rl:" });
    const oldRl = [...rl].filter(([, v]) => v.reset < now).map(([k]) => k);
    if (oldRl.length) await this.ctx.storage.delete(oldRl.slice(0, 128));
  }
}
