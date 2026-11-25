#!/usr/bin/env python3
"""Makes what a signed iOS build needs, through the App Store Connect API (ios/tools/asc.py):
the App IDs, the connected devices, a certificate whose private key is on this Mac, and the two
provisioning profiles (the app and the CicadaLive extension). Prints the variables
ios/scripts/build.sh signs with. Safe to run again: it reuses what is there.

  ios/tools/provision.py development        Apple Development, the dev bundle ids, this Mac's devices
  ios/tools/provision.py appstore           Apple Distribution, the release bundle ids (TestFlight)

Needs ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH for a key that may manage Certificates,
Identifiers & Profiles (Admin, or App Manager with that access). Keys and certificates live in
~/.cicada-signing (0700); the certificate goes into the login keychain, usable by codesign only.
"""
import base64, json, os, re, subprocess, sys, urllib.parse
sys.path.insert(0, os.path.dirname(__file__))
from asc import call

HOME = os.path.expanduser("~/.cicada-signing")
KIND = sys.argv[1] if len(sys.argv) > 1 else "development"
DEV = KIND == "development"
APP_ID = "com.indaloop.cicada.dev" if DEV else "com.indaloop.cicada"
IDS = {APP_ID: "Cicada Dev" if DEV else "Cicada", APP_ID + ".live": "Cicada Dev Live" if DEV else "Cicada Live"}
CERT_TYPE = "DEVELOPMENT" if DEV else "DISTRIBUTION"
PROFILE_TYPE = "IOS_APP_DEVELOPMENT" if DEV else "IOS_APP_STORE"


def ok(status, reply, what):
    if status >= 400:
        sys.exit(f"{what} failed ({status}): {json.dumps(reply.get('errors', reply), ensure_ascii=False)}")
    return reply


def run(*cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def bundle_id(identifier, name):
    _, r = call("GET", f"/v1/bundleIds?filter[identifier]={identifier}&fields[bundleIds]=identifier,platform")
    found = [b for b in r.get("data", []) if b["attributes"]["identifier"] == identifier]
    if found:
        return found[0]["id"]
    r = ok(*call("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
        "identifier": identifier, "name": name, "platform": "IOS"}}}), f"register {identifier}")
    print(f"registered App ID {identifier}", file=sys.stderr)
    return r["data"]["id"]


def devices():
    """Physical devices this Mac is paired with, registered if they aren't yet."""
    out = run("xcrun", "devicectl", "list", "devices")
    udids = {m.group(2): m.group(1).strip() for m in re.finditer(r"^(\S.*?)\s{2,}.*?([0-9A-F]{8}-[0-9A-F]{16}) \(UDID\)", out, re.M)}
    _, r = call("GET", "/v1/devices?limit=200&fields[devices]=udid,name,status")
    known = {d["attributes"]["udid"]: d["id"] for d in r.get("data", [])}
    ids = []
    for udid, name in udids.items():
        if udid not in known:
            r2 = ok(*call("POST", "/v1/devices", {"data": {"type": "devices", "attributes": {
                "name": name, "udid": udid, "platform": "IOS"}}}), f"register device {name}")
            known[udid] = r2["data"]["id"]
            print(f"registered device {name} {udid}", file=sys.stderr)
        ids.append(known[udid])
    if not ids:
        sys.exit("no iPhone or iPad connected (xcrun devicectl list devices)")
    return ids


def certificate():
    """A certificate of this kind whose private key is in ~/.cicada-signing; made if there is none."""
    key, cer = f"{HOME}/ios-{KIND}.key", f"{HOME}/ios-{KIND}.cer"
    _, r = call("GET", f"/v1/certificates?filter[certificateType]={CERT_TYPE}&fields[certificates]=certificateContent,serialNumber,expirationDate")
    if os.path.exists(key) and os.path.exists(cer):
        mine = run("openssl", "x509", "-inform", "der", "-in", cer, "-noout", "-serial").split("=")[1].strip().upper()
        for c in r.get("data", []):
            if c["attributes"]["serialNumber"].upper().lstrip("0") == mine.lstrip("0"):
                into_keychain(key, cer)
                return c["id"], cer
    os.makedirs(HOME, mode=0o700, exist_ok=True)
    run("openssl", "genrsa", "-out", key, "2048")
    os.chmod(key, 0o600)
    csr = run("openssl", "req", "-new", "-key", key, "-subj", f"/CN=Cicada iOS {KIND}/O=Indaloop LLC")
    r = ok(*call("POST", "/v1/certificates", {"data": {"type": "certificates", "attributes": {
        "certificateType": CERT_TYPE, "csrContent": csr}}}), f"create {CERT_TYPE} certificate")
    with open(cer, "wb") as f:
        f.write(base64.b64decode(r["data"]["attributes"]["certificateContent"]))
    print(f"created {CERT_TYPE} certificate {r['data']['id']}", file=sys.stderr)
    into_keychain(key, cer)
    return r["data"]["id"], cer


def sha1(cer):
    return run("openssl", "x509", "-inform", "der", "-in", cer, "-noout", "-fingerprint", "-sha1").split("=")[1].replace(":", "").strip()


def into_keychain(key, cer):
    """The certificate and its key in the login keychain, the key usable by codesign without a prompt."""
    # The intermediate it is issued by (WWDR G3), shipped inside Xcode; without it the identity
    # isn't valid and codesign can't use it.
    # Imported every time; the keychain refuses a duplicate, which is fine.
    subprocess.run(["security", "import", "/Applications/Xcode.app/Contents/SharedFrameworks/DVTFoundation.framework/Versions/A/Resources/AppleWWDRCA-2030.cer",
                    "-k", os.path.expanduser("~/Library/Keychains/login.keychain-db")], capture_output=True)
    if sha1(cer) in run("security", "find-identity", "-v", "-p", "codesigning"):
        return
    p12, password = f"{HOME}/ios-{KIND}.p12", base64.b64encode(os.urandom(18)).decode()
    pem = run("openssl", "x509", "-inform", "der", "-in", cer)
    # OpenSSL 3 writes a cipher the keychain can't read unless told -legacy; macOS's LibreSSL
    # writes the old one already and doesn't know the flag.
    legacy = ["-legacy"] if run("openssl", "version").startswith("OpenSSL 3") else []
    run("openssl", "pkcs12", "-export", *legacy, "-inkey", key, "-out", p12, "-passout", f"pass:{password}", input=pem)
    try:
        run("security", "import", p12, "-k", os.path.expanduser("~/Library/Keychains/login.keychain-db"),
            "-P", password, "-T", "/usr/bin/codesign")
    finally:
        os.remove(p12)
    print("added it to the login keychain", file=sys.stderr)


def profile(identifier, bundle, cert, device_ids):
    name = f"Cicada {KIND} {identifier}"
    _, r = call("GET", f"/v1/profiles?filter[name]={urllib.parse.quote(name)}&fields[profiles]=name,profileState")
    for p in r.get("data", []):   # remade each time, so it always holds today's devices and certificate
        call("DELETE", f"/v1/profiles/{p['id']}")
    rel = {"bundleId": {"data": {"type": "bundleIds", "id": bundle}},
           "certificates": {"data": [{"type": "certificates", "id": cert}]}}
    if DEV:
        rel["devices"] = {"data": [{"type": "devices", "id": d} for d in device_ids]}
    r = ok(*call("POST", "/v1/profiles", {"data": {"type": "profiles", "attributes": {
        "name": name, "profileType": PROFILE_TYPE}, "relationships": rel}}), f"profile {name}")
    os.makedirs(f"{HOME}/profiles", mode=0o700, exist_ok=True)
    path = f"{HOME}/profiles/{identifier}.{KIND}.mobileprovision"
    with open(path, "wb") as f:
        f.write(base64.b64decode(r["data"]["attributes"]["profileContent"]))
    return path


bundles = {i: bundle_id(i, n) for i, n in IDS.items()}
device_ids = devices() if DEV else []
cert, cer = certificate()
fingerprint = sha1(cer)
paths = {i: profile(i, b, cert, device_ids) for i, b in bundles.items()}
print(f"export SIGN_IDENTITY={fingerprint}")
print(f"export PROFILE='{paths[APP_ID]}'")
print(f"export PROFILE_LIVE='{paths[APP_ID + '.live']}'")
