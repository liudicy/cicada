#!/bin/bash
# Makes the release signing key, once ever: ~/.cicada-android/release.jks (PKCS12, RSA 4096, 30
# years), its random password in the login Keychain (cicada-android-release). Every release must be
# signed with this same key, or phones can't update to it: back up the file and the password.
# --github also puts both in the repo's Actions secrets, for the release workflow.
set -euo pipefail
ks="${CICADA_KEYSTORE:-$HOME/.cicada-android/release.jks}"
keytool="$HOME/.cicada-android/jdk/Contents/Home/bin/keytool"
if [ -e "$ks" ]; then
  echo "$ks already exists: never replace it (installed copies could no longer update)" >&2
else
  pw=$(openssl rand -hex 24)
  mkdir -p "$(dirname "$ks")"
  "$keytool" -genkeypair -keystore "$ks" -storetype PKCS12 -alias cicada -keyalg RSA -keysize 4096 \
    -validity 10950 -dname "CN=Cicada, O=wquguru" -storepass "$pw" -keypass "$pw" >/dev/null
  chmod 600 "$ks"
  security add-generic-password -a "$USER" -s cicada-android-release -w "$pw" -U
  echo "made $ks; the password is in the Keychain (security find-generic-password -s cicada-android-release -w)"
fi
pw=$(security find-generic-password -s cicada-android-release -w)
"$keytool" -list -v -keystore "$ks" -storepass "$pw" -alias cicada | grep -E "Owner|SHA256:"
if [ "${1:-}" = --github ]; then
  base64 -i "$ks" | gh secret set ANDROID_KEYSTORE_BASE64
  printf %s "$pw" | gh secret set ANDROID_KEYSTORE_PASSWORD
  echo "set ANDROID_KEYSTORE_BASE64 and ANDROID_KEYSTORE_PASSWORD"
fi
echo "back up $ks and its password somewhere safe (a password manager): losing either means a new app id"
