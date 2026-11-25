#!/usr/bin/env bash
# One-time setup of the share service in Cloudflare (after `wrangler login`): the D1 database,
# the R2 bucket, and the secrets. Writes the new database id into server/wrangler.jsonc; commit it.
#   ZENMUX_CICADA_API_KEY=… scripts/share-setup.sh
# Then scripts/deploy-site.sh deploys the site and the service together.
set -euo pipefail
cd "$(dirname "$0")/../server"

: "${ZENMUX_CICADA_API_KEY:?set ZENMUX_CICADA_API_KEY (the ZenMux key for Jev)}"

if grep -q '"database_id": "00000000-0000-0000-0000-000000000000"' wrangler.jsonc; then
  id=$(wrangler d1 create cicada-share 2>&1 | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
  [ -n "$id" ] || { echo "could not create the D1 database" >&2; exit 1; }
  sed -i '' "s/00000000-0000-0000-0000-000000000000/$id/" wrangler.jsonc
  echo "D1 cicada-share: $id (now in server/wrangler.jsonc)"
fi
wrangler r2 bucket create cicada-share 2>/dev/null || echo "R2 bucket cicada-share already exists"
printf '%s' "$ZENMUX_CICADA_API_KEY" | wrangler secret put ZENMUX_API_KEY
# Salts the daily hash of visitors' addresses used for rate limits; never needs to be known.
head -c 32 /dev/urandom | base64 | tr -d '\n' | wrangler secret put IP_SALT
echo "Done. Deploy with scripts/deploy-site.sh"
