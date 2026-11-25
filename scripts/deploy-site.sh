#!/usr/bin/env bash
# Builds the website and deploys it with the share service: one Worker, "cicada-site"
# (server/wrangler.jsonc), serving cicada.indaloop.app. The site is its static assets; /s/* and
# /api/* run server/src. The custom domain is attached to the Worker in Cloudflare, so the config
# declares no routes and a deploy leaves it alone. Needs `wrangler login` once, and
# scripts/share-setup.sh once (the database, the bucket and the ZenMux key).
set -euo pipefail
cd "$(dirname "$0")/.."

python3 scripts/site.py
if grep -q '"database_id": "00000000-0000-0000-0000-000000000000"' server/wrangler.jsonc; then
  echo "server/wrangler.jsonc has no database_id yet: run scripts/share-setup.sh first." >&2
  exit 1
fi
(cd server && wrangler d1 migrations apply cicada-share --remote && wrangler deploy)
curl -fsS -o /dev/null "https://cicada.indaloop.app/?deployed=$(date +%s)" && echo "Live: https://cicada.indaloop.app/"
curl -fsS "https://cicada.indaloop.app/api/v1/config" && echo
