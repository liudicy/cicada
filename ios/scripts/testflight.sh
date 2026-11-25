#!/usr/bin/env bash
# Builds the release app for the App Store, packs it as an .ipa and uploads it to App Store Connect,
# where it shows up in TestFlight after processing (10–30 min).
#   ios/scripts/testflight.sh            build, pack and upload
#   ios/scripts/testflight.sh --no-upload
# Signing: ~/.cicada-signing/ios-appstore.env (ios/tools/provision.py appstore > that file).
# Upload: ASC_KEY_ID and ASC_ISSUER_ID, with the key's .p8 in ~/.cicada-signing (altool looks there
# through API_PRIVATE_KEYS_DIR). The app's record must exist in App Store Connect first.
set -euo pipefail
cd "$(dirname "$0")/../.."
ENV=~/.cicada-signing/ios-appstore.env
[[ -f $ENV ]] || { echo "no $ENV: ios/tools/provision.py appstore > $ENV"; exit 1; }
# shellcheck disable=SC1090
source "$ENV"
RELEASE=1 DEVICE=1 ios/scripts/build.sh
OUT=ios/build/testflight
rm -rf "$OUT" && mkdir -p "$OUT/Payload"
cp -R ios/build/device/Cicada.app "$OUT/Payload/"
(cd "$OUT" && zip -qry Cicada.ipa Payload)
echo "Packed $OUT/Cicada.ipa"
[[ "${1:-}" == --no-upload ]] && exit 0
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}"
API_PRIVATE_KEYS_DIR=~/.cicada-signing xcrun altool --validate-app -f "$OUT/Cicada.ipa" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
API_PRIVATE_KEYS_DIR=~/.cicada-signing xcrun altool --upload-app -f "$OUT/Cicada.ipa" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
