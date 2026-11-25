#!/bin/bash
# The Mac release signing material lives in ~/.cicada-signing (0700, never in the repo):
#   developer_id.key / .cer / .p12   Developer ID Application: Indaloop LLC (QB8TQGXTXC), expires
#                                    2027-12-16; p12.password is the .p12's random password
#   AuthKey_KGZAJRYTXC.p8            App Store Connect API key "Cicada Notary" (Developer) for notarytool
#   DeveloperIDG2CA.cer              the intermediate (http://certs.apple.com/devidg2.der)
# The certificate and key are also in the login Keychain, and the notary key as the notarytool
# profile cicada-notary, so a local `SIGN_IDENTITY=… NOTARY_PROFILE=cicada-notary scripts/package.sh`
# works. Back the folder up: losing the key means a new certificate. A new certificate from the same
# team keeps everyone's permissions (the designated requirement is the bundle id alone).
# This checks the identity and puts the five Mac secrets in the repo for the release workflow.
set -euo pipefail
cd "$(dirname "$0")/.."
dir="${CICADA_SIGNING:-$HOME/.cicada-signing}"
# The notary key, not the iOS one (AuthKey_P6XXXAA736.p8, App Manager) kept in the same folder.
key_id="${NOTARY_KEY_ID:-KGZAJRYTXC}"
p8="$dir/AuthKey_$key_id.p8"
issuer="${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID: the Issuer ID on App Store Connect › Users and Access › Integrations}"

security find-identity -v -p codesigning | grep "Developer ID Application" ||
  { echo "no Developer ID Application identity in the keychain" >&2; exit 1; }
openssl x509 -inform DER -in "$dir/developer_id.cer" -noout -subject -enddate

base64 -i "$dir/developer_id.p12" | gh secret set MAC_CERT_P12_BASE64
gh secret set MAC_CERT_PASSWORD < "$dir/p12.password"
base64 -i "$p8" | gh secret set NOTARY_KEY_P8_BASE64
printf %s "$key_id" | gh secret set NOTARY_KEY_ID
printf %s "$issuer" | gh secret set NOTARY_ISSUER_ID
echo "set MAC_CERT_P12_BASE64 MAC_CERT_PASSWORD NOTARY_KEY_P8_BASE64 NOTARY_KEY_ID NOTARY_ISSUER_ID"
