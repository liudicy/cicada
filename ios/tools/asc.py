#!/usr/bin/env python3
"""App Store Connect API for iOS signing, without Xcode's account sign-in and without third-party
packages: the JWT is signed with openssl (ES256), requests go through urllib.

Credentials come from the environment (never from the repo):
  ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the .p8, e.g. ~/.cicada-signing/AuthKey_<id>.p8)

  ios/tools/asc.py get <path>                  e.g. /v1/bundleIds?filter[identifier]=com.indaloop.cicada
  ios/tools/asc.py post <path> <json>
  ios/tools/asc.py delete <path>
Prints the JSON reply. ios/tools/provision.py builds on it.
"""
import base64, json, os, subprocess, sys, tempfile, time, urllib.error, urllib.request

BASE = "https://api.appstoreconnect.apple.com"


def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    """openssl's ECDSA signature is DER (SEQUENCE of two INTEGERs); a JWT wants r || s, 32 bytes each."""
    def read_int(buf, i):
        assert buf[i] == 0x02
        n = buf[i + 1]
        v = buf[i + 2:i + 2 + n]
        return v.lstrip(b"\x00").rjust(32, b"\x00"), i + 2 + n
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    r, i = read_int(der, i)
    s, _ = read_int(der, i)
    return r + s


def token() -> str:
    key_id, issuer, path = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], os.path.expanduser(os.environ["ASC_KEY_PATH"])
    now = int(time.time())
    head = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    body = b64url(json.dumps({"iss": issuer, "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"}).encode())
    signing = f"{head}.{body}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", path], input=signing, capture_output=True, check=True).stdout
    return f"{head}.{body}.{b64url(der_to_raw(der))}"


def call(method: str, path: str, data=None):
    req = urllib.request.Request(BASE + path, method=method,
                                 data=json.dumps(data).encode() if data is not None else None,
                                 headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"raw": raw.decode(errors="replace")}


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    method, path = sys.argv[1].upper(), sys.argv[2]
    data = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    status, reply = call(method, path, data)
    print(json.dumps({"status": status, **reply} if isinstance(reply, dict) else {"status": status, "data": reply}, ensure_ascii=False, indent=1))
    sys.exit(0 if status < 400 else 1)
