// cicada.indaloop.app: the static website (assets) plus the share service. wrangler.jsonc runs this
// only for /s/* and /api/*; everything else is served straight from the assets.
import { json, fail } from "./util.js";
import { register } from "./auth.js";
import { create, revoke, revokeAll, stats, read, open, purge } from "./shares.js";
import { page } from "./page.js";
export { Gate } from "./gate.js";

/** Older apps are told to update (426) rather than half work with a newer server. */
function tooOld(request, env) {
  const m = /^[a-z]+\/(\d+)\.(\d+)\.(\d+)/.exec(request.headers.get("X-Cicada-Client") || "");
  if (!m) return false;
  const have = m.slice(1).map(Number), need = (env.MIN_CLIENT || "0.0.0").split(".").map(Number);
  for (let i = 0; i < 3; i++) if (have[i] !== need[i]) return have[i] < need[i];
  return false;
}

async function api(request, env, path) {
  const m = request.method;
  // The apps only; no browser page but the share page (same origin) calls the API, so no CORS.
  if (path === "/api/v1/config" && m === "GET") return json({ sharing: env.SHARING === "on", minClient: env.MIN_CLIENT || "0.0.0" });
  if (tooOld(request, env)) return fail(426, "update_required");
  if (path === "/api/v1/devices" && m === "POST") {
    const r = await register(request, env);
    return r instanceof Response ? r : json(r, 201);
  }
  if (path === "/api/v1/shares") {
    if (m === "POST") return create(request, env);
    if (m === "GET") return stats(request, env);
    if (m === "DELETE") return revokeAll(request, env);
  }
  let x = /^\/api\/v1\/shares\/([A-Za-z0-9_-]{22})$/.exec(path);
  if (x && m === "DELETE") return revoke(request, env, x[1]);
  x = /^\/api\/v1\/s\/([A-Za-z0-9_-]{1,64})(\/open)?$/.exec(path);
  if (x && !x[2] && m === "GET") return read(request, env, x[1]);
  if (x && x[2] && m === "POST") return open(request, env, x[1]);
  return fail(404, "not_found");
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      if (url.pathname.startsWith("/api/")) {
        const len = Number(request.headers.get("Content-Length") || 0);
        if (len > 2.5 * 1024 * 1024) return fail(413, "too_large");
        return await api(request, env, url.pathname);
      }
      const s = /^\/s\/([A-Za-z0-9_-]{1,64})\/?$/.exec(url.pathname);
      if (s && request.method === "GET") return await page(request, env, s[1]);
      return env.ASSETS.fetch(request);
    } catch (e) {
      // Never log a request body or token: only what failed.
      console.error("share error", url.pathname.replace(/\/s\/[^/]+/, "/s/:id"), e?.message);
      return fail(500, "server_error");
    }
  },

  async scheduled(_event, env) {
    console.log("purged", await purge(env));
  },
};
