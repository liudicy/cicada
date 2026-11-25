// Small helpers shared by the routes. No dependencies: Web Crypto and the Workers runtime only.

const enc = new TextEncoder();

export function b64url(bytes) {
  let s = "";
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Decodes base64url (or plain base64); null when it isn't. */
export function unb64(text) {
  if (typeof text !== "string" || !/^[A-Za-z0-9_\-+/]*={0,2}$/.test(text)) return null;
  try {
    const s = atob(text.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(text.length / 4) * 4, "="));
    return Uint8Array.from(s, (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

export function hex(bytes) {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256(data) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", typeof data === "string" ? enc.encode(data) : data));
}

export function random(n) {
  return crypto.getRandomValues(new Uint8Array(n));
}

/** Equal in time that doesn't depend on where the bytes differ. */
export function same(a, b) {
  a = new Uint8Array(a);
  b = new Uint8Array(b);
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}

export function now() {
  return Math.floor(Date.now() / 1000);
}

/**
 * What a rate limit counts as one visitor: an IPv4 address, or an IPv6 /64. One home or phone
 * usually gets a whole /64, so counting single IPv6 addresses would let anyone step past every
 * per-address limit by picking another address from their own block.
 */
export function ipGroup(ip) {
  if (!ip || !ip.includes(":")) return ip || "local";
  const [head, tail = ""] = ip.toLowerCase().split("::");
  const a = head ? head.split(":") : [], b = tail ? tail.split(":") : [];
  const groups = ip.includes("::") ? [...a, ...Array(Math.max(0, 8 - a.length - b.length)).fill("0"), ...b] : a;
  return groups.slice(0, 4).map((g) => g.replace(/^0+(?=.)/, "")).join(":") + "::/64";
}

/** The visitor's address (group), hashed with a salt that changes every day: enough to rate-limit, not to track. */
export async function ipKey(request, env) {
  const ip = ipGroup(request.headers.get("CF-Connecting-IP"));
  const day = new Date().toISOString().slice(0, 10);
  return hex((await sha256(`${env.IP_SALT || "cicada"}|${day}|${ip}`)).slice(0, 12));
}

const SECURITY = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "X-Robots-Tag": "noindex, nofollow",
};

export function json(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...SECURITY, ...headers },
  });
}

/** Every error is a fixed code (the apps word it in their own language) and maybe when to retry. */
export function fail(status, code, extra = {}) {
  const headers = extra.retryAfter ? { "Retry-After": String(extra.retryAfter) } : {};
  return json({ code, ...extra }, status, headers);
}

export { SECURITY };
