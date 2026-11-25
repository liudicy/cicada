#!/usr/bin/env bash
# Takes a shared meeting down by hand (there is no admin page): the link answers 410 at once and
# the document is deleted from R2. With --device it also bans the device that made it, so that
# Mac can't share again.
#   scripts/share-revoke.sh <share id> [--device]
set -euo pipefail
cd "$(dirname "$0")/../server"
id="${1:?share id (the part after /s/)}"
[[ "$id" =~ ^[A-Za-z0-9_-]{22}$ ]] || { echo "not a share id: $id" >&2; exit 1; }
now=$(date +%s)
wrangler d1 execute cicada-share --remote --command \
  "UPDATE shares SET revoked_at = $now, revoked_by = 'admin' WHERE id = '$id' AND revoked_at IS NULL"
wrangler r2 object delete "cicada-share/shares/$id.json" --remote
wrangler d1 execute cicada-share --remote --command "UPDATE shares SET purged_at = $now WHERE id = '$id'"
if [ "${2:-}" = "--device" ]; then
  wrangler d1 execute cicada-share --remote --command \
    "UPDATE devices SET banned_at = $now WHERE id = (SELECT device_id FROM shares WHERE id = '$id')"
fi
echo "Revoked $id"
