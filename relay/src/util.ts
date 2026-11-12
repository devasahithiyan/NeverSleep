export interface Env {
  HUB: DurableObjectNamespace<import("./hub").Hub>;
  DEVICE: DurableObjectNamespace<import("./device").Device>;
  ASSETS: Fetcher;
  SESSION_SECRET: string;
}

export const SECURITY_HEADERS: Record<string, string> = {
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
};

export function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...SECURITY_HEADERS, ...extra },
  });
}

export function err(status: number, message: string): Response {
  return json({ error: message }, status);
}

const enc = new TextEncoder();

export async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", enc.encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
    "verify",
  ]);
}

function b64url(buf: ArrayBuffer | Uint8Array): string {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromB64url(s: string): Uint8Array {
  const pad = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
  const bin = atob(pad);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

export function randomToken(bytes = 32): string {
  return b64url(crypto.getRandomValues(new Uint8Array(bytes)));
}

// ---------- Session cookie ----------
// There is no password. A browser is signed in by typing a one-time code shown on the Mac.
// The cookie lists which Macs this browser may control, each with the Mac's "browser epoch";
// "Sign out all browsers" on the Mac bumps the epoch, which invalidates every older grant.
// Format: "<expiresMs>.<b64url(JSON grants)>.<hmac>"

export interface Grant {
  id: string;
  epoch: number;
}

export const COOKIE = "ns_session";
const SESSION_MS = 180 * 24 * 3600 * 1000;
const MAX_GRANTS = 10;

export async function makeSession(env: Env, grants: Grant[]): Promise<string> {
  const payload = b64url(enc.encode(JSON.stringify(grants.slice(-MAX_GRANTS))));
  const body = `${Date.now() + SESSION_MS}.${payload}`;
  const sig = await crypto.subtle.sign("HMAC", await hmacKey(env.SESSION_SECRET), enc.encode(body));
  return `${COOKIE}=${body}.${b64url(sig)}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${SESSION_MS / 1000}`;
}

export function clearSessionCookie(): string {
  return `${COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0`;
}

/** Grants from a valid, unexpired, correctly signed cookie (not yet checked against epochs). */
export async function readSession(req: Request, env: Env): Promise<Grant[]> {
  const cookie = req.headers.get("Cookie") ?? "";
  const m = cookie.match(new RegExp(`(?:^|;\\s*)${COOKIE}=([^;]+)`));
  if (!m) return [];
  const parts = m[1].split(".");
  if (parts.length !== 3) return [];
  const [exp, payload, sig] = parts;
  if (!/^\d+$/.test(exp) || Number(exp) < Date.now()) return [];
  try {
    const ok = await crypto.subtle.verify(
      "HMAC",
      await hmacKey(env.SESSION_SECRET),
      fromB64url(sig),
      enc.encode(`${exp}.${payload}`),
    );
    if (!ok) return [];
    const grants = JSON.parse(new TextDecoder().decode(fromB64url(payload)));
    if (!Array.isArray(grants)) return [];
    return grants.filter((g) => g && typeof g.id === "string" && Number.isInteger(g.epoch)).slice(0, MAX_GRANTS);
  } catch {
    return [];
  }
}

/** Fixed-window rate limiter backed by Durable Object storage. */
export async function rateLimit(
  storage: DurableObjectStorage,
  key: string,
  limit: number,
  windowSec: number,
): Promise<{ ok: boolean; retryAfter: number }> {
  const now = Date.now();
  const k = `rl:${key}`;
  const cur = (await storage.get<{ n: number; reset: number }>(k)) ?? { n: 0, reset: now + windowSec * 1000 };
  if (cur.reset <= now) {
    cur.n = 0;
    cur.reset = now + windowSec * 1000;
  }
  cur.n++;
  await storage.put(k, cur);
  return { ok: cur.n <= limit, retryAfter: Math.ceil((cur.reset - now) / 1000) };
}

export async function readJson(req: Request, maxBytes = 16 * 1024): Promise<Record<string, unknown> | null> {
  const ct = req.headers.get("Content-Type") ?? "";
  if (!ct.toLowerCase().startsWith("application/json")) return null;
  const text = await req.text();
  if (text.length > maxBytes) return null;
  try {
    const v = JSON.parse(text);
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}
