// Who is asking, without accounts. Each app install makes an Ed25519 key pair and registers the
// public key once, paying a small proof of work so that minting many devices costs time. Every
// write after that is signed: method, path, time, a one-off nonce and the body's hash, so a request
// can be neither altered nor replayed. A device identity is not trusted for anything but rate limits
// and owning its shares (anyone can make a new one); changing a share also needs its manage token.
import { b64url, unb64, hex, sha256, now, fail, ipKey } from "./util.js";
import { gate, limit } from "./gate.js";

export const POW_BITS = 20;
const SKEW = 300;

function leadingZeroBits(bytes) {
  let n = 0;
  for (const b of bytes) {
    if (b === 0) { n += 8; continue; }
    n += Math.clz32(b) - 24;
    break;
  }
  return n;
}

export async function deviceId(pubkey) {
  return hex((await sha256(pubkey)).slice(0, 16));
}

/** POST /api/v1/devices {key, pow, platform, version} → {device} */
export async function register(request, env) {
  const ip = await ipKey(request, env);
  // A household or office shares one address, hence a few a day rather than one; tests raise it.
  const wait = await limit(env, "devices:" + ip, Number(env.DEVICES_PER_IP_DAY || 5), 86400);
  if (wait) return fail(429, "rate_limited", { retryAfter: wait });
  const body = await request.json().catch(() => null);
  const key = unb64(body?.key), nonce = unb64(body?.pow);
  if (!key || key.length !== 32 || !nonce || nonce.length > 16) return fail(400, "bad_request");
  const work = new Uint8Array(key.length + nonce.length);
  work.set(key);
  work.set(nonce, key.length);
  if (leadingZeroBits(await sha256(work)) < POW_BITS) return fail(400, "bad_proof");
  try {
    await crypto.subtle.importKey("raw", key, { name: "Ed25519" }, false, ["verify"]);
  } catch {
    return fail(400, "bad_request");
  }
  const id = await deviceId(key);
  await env.DB.prepare(
    "INSERT INTO devices (id, pubkey, platform, app_version, created_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET app_version = excluded.app_version"
  ).bind(id, key, String(body.platform || "").slice(0, 20), String(body.version || "").slice(0, 20), now()).run();
  return { device: id };
}

/**
 * Checks a signed request. Returns { device, body } (the raw body text, already verified), or a
 * Response to send back. Headers: X-Cicada-Device, -Time, -Nonce, -Signature over
 * "METHOD\nPATH\nTIME\nNONCE\nsha256hex(body)".
 */
export async function signed(request, env) {
  const h = (k) => request.headers.get("X-Cicada-" + k) || "";
  const id = h("Device"), time = Number(h("Time")), nonce = h("Nonce"), sig = unb64(h("Signature"));
  if (!/^[0-9a-f]{32}$/.test(id) || !Number.isInteger(time) || !/^[A-Za-z0-9_-]{16,64}$/.test(nonce) || !sig || sig.length !== 64)
    return fail(401, "unsigned");
  if (Math.abs(now() - time) > SKEW) return fail(401, "clock");
  const row = await env.DB.prepare("SELECT pubkey, banned_at FROM devices WHERE id = ?").bind(id).first();
  if (!row) return fail(401, "unknown_device");
  if (row.banned_at) return fail(403, "banned");
  const text = request.method === "GET" || request.method === "HEAD" ? "" : await request.text();
  const url = new URL(request.url);
  const message = `${request.method}\n${url.pathname}${url.search}\n${time}\n${nonce}\n${hex(await sha256(text))}`;
  const key = await crypto.subtle.importKey("raw", new Uint8Array(row.pubkey), { name: "Ed25519" }, false, ["verify"]);
  if (!(await crypto.subtle.verify({ name: "Ed25519" }, key, sig, new TextEncoder().encode(message))))
    return fail(401, "bad_signature");
  if (!(await gate(env, "nonce:" + id).fresh(nonce, SKEW * 2))) return fail(401, "replayed");
  return { device: id, body: text };
}

export { b64url };
