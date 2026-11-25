// Creating, revoking and reading shares. D1 holds who owns what and its state; R2 holds the
// document; the Gate objects count views and wrong passwords.
import { b64url, unb64, sha256, same, random, now, json, fail, ipKey } from "./util.js";
import { gate, limit } from "./gate.js";
import { signed } from "./auth.js";
import { clean } from "./doc.js";
import { review, ReviewUnavailable } from "./review.js";

const MAX_BODY = 2 * 1024 * 1024;
const DAYS = [7, 30, 365];
const ACTIVE_PER_DEVICE = 200;
const REVIEW_CHARS_PER_DAY = 400_000;

async function tokenHash(token) {
  return sha256(unb64(token) || new Uint8Array());
}

/** POST /api/v1/shares, signed. → 201 {id, url, token, expiresAt} | 422 blocked {hits} */
export async function create(request, env) {
  if (env.SHARING !== "on") return fail(503, "sharing_off");
  const who = await signed(request, env);
  if (who instanceof Response) return who;
  const ip = await ipKey(request, env);
  for (const [key, max, window] of [["create:" + who.device, 20, 3600], ["create-ip:" + ip, 100, 86400]]) {
    const wait = await limit(env, key, max, window);
    if (wait) return fail(429, "rate_limited", { retryAfter: wait });
  }
  if (who.body.length > MAX_BODY) return fail(413, "too_large");
  let body;
  try { body = JSON.parse(who.body); } catch { return fail(400, "bad_request"); }
  const scope = body.scope === "full" ? "full" : "notes";
  const days = DAYS.includes(body.days) ? body.days : 7;
  const doc = clean(body.doc);
  if (!doc) return fail(400, "bad_document");
  if (scope === "notes") doc.lines = [];
  if (!doc.notes && doc.lines.length === 0) return fail(400, "bad_document");

  let pw = null;
  if (body.password) {
    const salt = unb64(body.password.salt), hash = unb64(body.password.hash), iter = body.password.iter;
    if (!salt || salt.length < 16 || !hash || hash.length !== 32 || !Number.isInteger(iter) || iter < 100_000 || iter > 2_000_000)
      return fail(400, "bad_password");
    pw = { salt, hash, iter };
  }

  const active = await env.DB.prepare("SELECT COUNT(*) AS n FROM shares WHERE device_id = ? AND revoked_at IS NULL AND expires_at > ?")
    .bind(who.device, now()).first();
  if (active.n >= ACTIVE_PER_DEVICE) return fail(429, "too_many_shares");

  // A retried request (the network dropped the answer) gets the same link back, with a new token
  // because only the old token's hash was kept.
  const idem = (request.headers.get("Idempotency-Key") || "").slice(0, 80) || null;
  if (idem) {
    const old = await env.DB.prepare("SELECT id, expires_at FROM shares WHERE device_id = ? AND idem_key = ? AND revoked_at IS NULL")
      .bind(who.device, idem).first();
    if (old) {
      const token = random(32);
      await env.DB.prepare("UPDATE shares SET token_hash = ? WHERE id = ?").bind(await sha256(token), old.id).run();
      return json({ id: old.id, url: link(request, old.id), token: b64url(token), expiresAt: old.expires_at }, 200);
    }
  }

  const characters = JSON.stringify(doc).length;
  const wait = await limit(env, "review:" + who.device, REVIEW_CHARS_PER_DAY, 86400, characters);
  if (wait) return fail(429, "rate_limited", { retryAfter: wait });
  // The whole site's review budget a day (Jev is paid per token): past it, sharing waits rather
  // than skipping the review. Many devices from many addresses can't run up the bill past this.
  const budget = Number(env.REVIEW_CHARS_PER_DAY_ALL || 50_000_000);
  if (await limit(env, "review-all", budget, 86400, characters)) {
    console.error("review: daily budget used up", budget);
    return fail(503, "review_unavailable", { retryAfter: 3600 });
  }
  let result;
  try {
    result = await review(env, doc);
  } catch (e) {
    if (e instanceof ReviewUnavailable) return fail(503, "review_unavailable", { retryAfter: 60 });
    throw e;
  }
  if (result.blocked) return fail(422, "blocked", { hits: result.hits });

  const id = b64url(random(16)), token = random(32), created = now();
  const expires = created + days * 86400;
  const text = JSON.stringify(doc);
  await env.BUCKET.put(`shares/${id}.json`, text, { httpMetadata: { contentType: "application/json" } });
  const desc = body.summaryInPreview && doc.notes?.summary ? [...doc.notes.summary].slice(0, 80).join("") : null;
  await env.DB.prepare(
    `INSERT INTO shares (id, device_id, token_hash, idem_key, mode, scope, title, og_desc, langs, duration, size,
       pw_salt, pw_iter, pw_hash, check_max, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).bind(id, who.device, await sha256(token), idem, pw ? "password" : "open", scope, doc.title, desc, doc.langs.join(","),
    doc.duration, text.length, pw?.salt ?? null, pw?.iter ?? null, pw?.hash ?? null, JSON.stringify(result.max), created, expires).run();
  return json({ id, url: link(request, id), token: b64url(token), expiresAt: expires }, 201);
}

function link(request, id) {
  return new URL(request.url).origin + "/s/" + id;
}

async function revokeRow(env, id, by) {
  await env.DB.prepare("UPDATE shares SET revoked_at = ?, revoked_by = ? WHERE id = ? AND revoked_at IS NULL").bind(now(), by, id).run();
  await env.BUCKET.delete(`shares/${id}.json`);
  await env.DB.prepare("UPDATE shares SET purged_at = ? WHERE id = ?").bind(now(), id).run();
  await gate(env, "share:" + id).clear();
}

/** DELETE /api/v1/shares/:id, signed, with the manage token as Bearer. Unknown and not-yours look alike. */
export async function revoke(request, env, id) {
  const who = await signed(request, env);
  if (who instanceof Response) return who;
  const token = (request.headers.get("Authorization") || "").replace(/^Bearer /, "");
  const row = await env.DB.prepare("SELECT token_hash, device_id, revoked_at FROM shares WHERE id = ?").bind(id).first();
  const hash = await tokenHash(token);
  if (!row || row.device_id !== who.device || !same(row.token_hash, hash)) return fail(404, "not_found");
  if (!row.revoked_at) await revokeRow(env, id, "owner");
  return new Response(null, { status: 204 });
}

/** DELETE /api/v1/shares, signed: every share this device made (取消全部, or a lost token). */
export async function revokeAll(request, env) {
  const who = await signed(request, env);
  if (who instanceof Response) return who;
  const { results } = await env.DB.prepare("SELECT id FROM shares WHERE device_id = ? AND revoked_at IS NULL").bind(who.device).all();
  for (const r of results) await revokeRow(env, r.id, "owner");
  return json({ revoked: results.length });
}

/** GET /api/v1/shares?ids=a,b, signed → this device's shares among them, with views. */
export async function stats(request, env) {
  const who = await signed(request, env);
  if (who instanceof Response) return who;
  const ids = (new URL(request.url).searchParams.get("ids") || "").split(",").filter(Boolean).slice(0, 200);
  if (!ids.length) return json({ shares: [] });
  const { results } = await env.DB.prepare(
    `SELECT id, expires_at, revoked_at FROM shares WHERE device_id = ? AND id IN (${ids.map(() => "?").join(",")})`
  ).bind(who.device, ...ids).all();
  const t = now();
  const shares = await Promise.all(results.map(async (r) => {
    const live = !r.revoked_at && r.expires_at > t;
    const s = live ? await gate(env, "share:" + r.id).stats() : { views: 0, wrongPasswords: 0, locked: false };
    return { id: r.id, expiresAt: r.expires_at, state: r.revoked_at ? "revoked" : live ? "live" : "expired", ...s };
  }));
  return json({ shares });
}

/** The row a visitor may see, or why not. */
export async function visible(env, id) {
  if (!/^[A-Za-z0-9_-]{22}$/.test(id)) return { status: 404, code: "not_found" };
  const row = await env.DB.prepare("SELECT * FROM shares WHERE id = ?").bind(id).first();
  if (!row) return { status: 404, code: "not_found" };
  if (row.revoked_at && row.revoked_by !== "expired") return { status: 410, code: "revoked" };
  if (row.revoked_at || row.expires_at <= now()) return { status: 410, code: "expired" };
  return { row };
}

const BOTS = /bot|crawl|spider|preview|facebookexternalhit|slackbot|whatsapp|telegram|discord|skype|wechat|micromessenger.*(?:crawler)/i;

async function document(env, request, row) {
  const obj = await env.BUCKET.get(`shares/${row.id}.json`);
  if (!obj) return fail(410, "expired");
  const views = BOTS.test(request.headers.get("User-Agent") || "") ? null : await gate(env, "share:" + row.id).view();
  return new Response(obj.body, {
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "private, no-store", "X-Robots-Tag": "noindex", ...(views ? { "X-Views": String(views) } : {}) },
  });
}

/** GET /api/v1/s/:id → the document, or {locked, salt, iter} for a password share. */
export async function read(request, env, id) {
  const wait = await limit(env, "read:" + (await ipKey(request, env)), 120, 60);
  if (wait) return fail(429, "rate_limited", { retryAfter: wait });
  const v = await visible(env, id);
  if (!v.row) return fail(v.status, v.code);
  if (v.row.mode === "password") {
    const g = await gate(env, "share:" + id).stats();
    if (g.locked) return fail(423, "locked");
    return json({ locked: true, salt: b64url(v.row.pw_salt), iter: v.row.pw_iter });
  }
  return document(env, request, v.row);
}

/** POST /api/v1/s/:id/open {verifier}: the browser's PBKDF2 of the password; the server keeps only its hash. */
export async function open(request, env, id) {
  const ip = await ipKey(request, env);
  const wait = await limit(env, "open:" + ip, 10, 900);
  if (wait) return fail(429, "rate_limited", { retryAfter: wait });
  const v = await visible(env, id);
  if (!v.row) return fail(v.status, v.code);
  if (v.row.mode !== "password") return document(env, request, v.row);
  const g = gate(env, "share:" + id);
  const may = await g.mayTry();
  if (may.locked) return fail(423, "locked");
  if (!may.ok) return fail(429, "rate_limited", { retryAfter: may.retryAfter });
  const body = await request.json().catch(() => null);
  const verifier = unb64(body?.verifier);
  if (!verifier || verifier.length !== 32) return fail(400, "bad_request");
  const right = same(await sha256(verifier), v.row.pw_hash);
  await g.tried(right);
  if (!right) return fail(403, "wrong_password");
  return document(env, request, v.row);
}

/** Daily: delete what expired, and finish any revoke that stopped half way. */
export async function purge(env) {
  const { results } = await env.DB.prepare(
    "SELECT id, revoked_at FROM shares WHERE purged_at IS NULL AND (expires_at <= ? OR revoked_at IS NOT NULL) LIMIT 500"
  ).bind(now()).all();
  for (const r of results) {
    if (!r.revoked_at) await env.DB.prepare("UPDATE shares SET revoked_at = ?, revoked_by = 'expired' WHERE id = ?").bind(now(), r.id).run();
    await env.BUCKET.delete(`shares/${r.id}.json`);
    await env.DB.prepare("UPDATE shares SET purged_at = ? WHERE id = ?").bind(now(), r.id).run();
    await gate(env, "share:" + r.id).clear();
  }
  return results.length;
}
