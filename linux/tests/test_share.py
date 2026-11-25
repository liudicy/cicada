"""分享…: the share document is a contract with the server (server/src/doc.js) and the Mac, so the
same record must give the same bytes (Tests/fixtures/share); plus the password, the Ed25519
signatures (RFC 8032) and the client against a fake server (never the real one: production limits
how many devices an address may register)."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
REPO = os.path.dirname(os.path.dirname(HERE))
FIXTURES = os.path.join(REPO, "Tests", "fixtures", "share")

from cicada.core import ed25519, share, strings  # noqa: E402
from cicada.core.models import Session, TranscriptLine  # noqa: E402
from cicada.core.support import Paths  # noqa: E402


def session() -> Session:
    with open(os.path.join(FIXTURES, "session.json"), encoding="utf-8") as f:
        return Session.read(f.read())


class ShareDocTests(unittest.TestCase):
    def setUp(self):
        # Other suites switch the UI language; the document's speaker words follow it.
        strings.load("zh-Hans", [os.path.join(REPO, "Resources")])

    def test_fixture_bytes(self):
        with open(os.path.join(FIXTURES, "share-doc.json"), encoding="utf-8") as f:
            want = f.read().strip()
        self.assertEqual(want, share.encode(share.doc(session(), "full", False)).decode("utf-8"))

    def test_nothing_private_leaves(self):
        text = share.encode(share.doc(session(), "full", False)).decode("utf-8")
        for secret in ["/Users/someone", "Emma", "Kenji", "Emmer", "Sure, Emma", "hasAudio", "room", "voice"]:
            self.assertNotIn(secret, text)

    def test_names_when_asked(self):
        d = share.doc(session(), "full", True)
        self.assertEqual("Emma", d["notes"]["todos"][0]["owner"])
        self.assertEqual("Emma", d["notes"]["terms"][0]["name"])
        self.assertNotIn("owner", d["notes"]["conclusions"][0])

    def test_notes_only_and_removed(self):
        s = session()
        self.assertEqual([], share.doc(s, "notes", False)["lines"])
        d = share.doc(s, "full", False, removed={3}, drop_notes=True)
        self.assertEqual(3, len(d["lines"]))
        self.assertNotIn("notes", d)
        self.assertEqual(2, d["hidden"])

    def test_speaker_numbers_without_names(self):
        s = session()
        # Two voices with five substantive lines each get numbers; their names stay out.
        s.lines = [TranscriptLine(id="v%d" % i, t=float(i), speaker="them", src="this is line number %d" % i,
                                  dst="第 %d 句话" % i, srcLang="en", dstLang="zh", voice=3 if i % 2 == 0 else 7)
                   for i in range(10)]
        self.assertEqual({"说话人 1", "说话人 2"}, {l["who"] for l in share.doc(s, "full", False)["lines"]})
        self.assertEqual({"Emma", "Kenji"}, {l["who"] for l in share.doc(s, "full", True)["lines"]})

    def test_rounding_and_numbers(self):
        s = session()
        s.lines[0].t = 0.25  # half away from zero, as Swift rounds: 0.3, not Python's 0.2
        s.lines[1].dst = s.lines[1].src
        d = share.doc(s, "full", False)
        self.assertEqual(0.3, d["lines"][0]["t"])
        self.assertNotIn("dst", d["lines"][1])
        self.assertIn(b'"t":605,', share.encode(share.doc(session(), "full", False)))

    def test_languages_by_most_lines(self):
        self.assertEqual(["en", "zh"], share.languages(session().lines))
        self.assertEqual([], share.languages([]))

    def test_password(self):
        salt = bytes([1] * 16)
        # Same as the browser's crypto.subtle PBKDF2-SHA256, 32 bytes (server/test/api.test.mjs).
        v = share.verifier("ruby-41-lake", salt, 1000)
        self.assertEqual("eab69fcd00a0517794c156495dd76ad1fbfb036ea03df3d59a68a33519009c81", v.hex())
        self.assertNotEqual(v, share.verifier("ruby-41-laka", salt, 1000))
        self.assertEqual(3, len(share.make_password().split("-")))

    def test_blocked_hits_map_back(self):
        # The server counts lines of what was sent; the app maps them back to the record.
        hits = [{"part": "lines", "from": 2, "to": 3, "questions": ["credential"]}, {"part": "notes", "questions": []}]
        self.assertEqual({4, 5}, share.record_lines(hits, [0, 1, 4, 5, 6]))

    def test_messages(self):
        self.assertEqual("密码或密钥", share.category("credential"))
        self.assertEqual("分享得太频繁了，请稍后再试。", share.message("too_many_shares"))
        self.assertEqual("服务器出了问题，请稍后再试。", share.message("whatever"))

    def test_clipboard_message(self):
        # One message, three lines, in the UI's language; days left round up, a year reads as a year.
        now = 1_000_000.0
        r = share.ShareRecord("a", "https://x/s/a", "t", now + 6.5 * 86400, "notes", "ruby-41-lake", now)
        self.assertEqual("「周会」会议记录\nhttps://x/s/a\n密码：ruby-41-lake（7 天内有效）", share.clipboard_text(r, "周会", now))
        r.password, r.expiresAt = None, now + 365 * 86400
        self.assertEqual("「周会」会议记录\nhttps://x/s/a\n1 年内有效", share.clipboard_text(r, "周会", now))
        self.assertEqual("无密码 · 7 天有效 · 不显示名字", share.summary(False, 7, False))
        try:
            strings.load("en", [os.path.join(REPO, "Resources")])
            r.password, r.expiresAt = "ruby-41-lake", now + 30 * 86400
            self.assertEqual("Meeting record: Standup\nhttps://x/s/a\nPassword: ruby-41-lake (valid for 30 days)",
                             share.clipboard_text(r, "Standup", now))
            self.assertEqual("Password · Open 1 year · Names shown", share.summary(True, 365, True))
        finally:
            strings.load("zh-Hans", [os.path.join(REPO, "Resources")])


class Ed25519Tests(unittest.TestCase):
    # RFC 8032 §7.1, tests 1–3: secret key, public key, message, signature.
    VECTORS = [
        ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
         "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
         "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
        ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
         "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
         "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
        ("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
         "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025", "af82",
         "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"),
    ]

    def test_rfc8032_vectors(self):
        for sk, pk, msg, sig in self.VECTORS:
            seed, m = bytes.fromhex(sk), bytes.fromhex(msg)
            self.assertEqual(pk, ed25519.public_key(seed).hex())
            self.assertEqual(sig, ed25519.sign(seed, m).hex())
            self.assertTrue(ed25519.verify(bytes.fromhex(pk), m, bytes.fromhex(sig)))
            self.assertFalse(ed25519.verify(bytes.fromhex(pk), m + b"x", bytes.fromhex(sig)))


class FakeServer:
    """server/src's contract in miniature: registration with proof of work, signed requests."""

    def __init__(self):
        self.keys = {}
        self.calls = []
        self.forget = False
        self.reply = None

    def __call__(self, method, url, body, headers):
        path = url.split("cicada.test", 1)[1]
        self.calls.append((method, path, headers))
        if path == "/api/v1/devices":
            o = json.loads(body)
            pub, nonce = share.unb64(o["key"]), share.unb64(o["pow"])
            d = hashlib.sha256(pub + nonce).digest()
            assert d[0] == 0 and d[1] == 0 and d[2] < 16, "bad proof"
            assert o["platform"] == "linux"
            dev = hashlib.sha256(pub).digest()[:16].hex()
            self.keys[dev] = pub
            return 201, json.dumps({"device": dev}).encode()
        assert headers["X-Cicada-Client"].startswith("linux/")
        dev = headers.get("X-Cicada-Device")
        if self.forget:
            self.forget = False
            self.keys.clear()
        if dev not in self.keys:
            return 401, b'{"code":"unknown_device"}'
        msg = "%s\n%s\n%s\n%s\n%s" % (method, path, headers["X-Cicada-Time"], headers["X-Cicada-Nonce"],
                                      hashlib.sha256(body or b"").hexdigest())
        if not ed25519.verify(self.keys[dev], msg.encode(), share.unb64(headers["X-Cicada-Signature"])):
            return 401, b'{"code":"bad_signature"}'
        if self.reply is not None:
            return self.reply
        if method == "POST":
            return 201, json.dumps({"id": "A" * 22, "url": "https://cicada.test/s/" + "A" * 22, "token": "tok",
                                    "expiresAt": 1900000000}).encode()
        if method == "DELETE":
            return 204, b""
        return 200, b'{"shares":[]}'


class ShareClientTests(unittest.TestCase):
    def setUp(self):
        strings.load("zh-Hans", [os.path.join(REPO, "Resources")])
        self.dir = tempfile.mkdtemp()
        Paths.home_override = self.dir
        self.server = FakeServer()
        self.client = share.ShareClient(transport=self.server, base="https://cicada.test", version="1.5.1")

    def tearDown(self):
        Paths.home_override = None
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_registers_once_signs_and_keeps_secrets_private(self):
        s = session()
        out = self.client.share(s, share.Options(scope="full", password="ruby-41-lake"))
        self.assertEqual("shared", out.kind)
        out = self.client.share(s, share.Options(scope="notes"))
        self.assertEqual(1, sum(1 for c in self.server.calls if c[1] == "/api/v1/devices"))
        for f in (share.ShareClient.device_file(), os.path.join(share.ShareStore.folder(), s.id + ".json")):
            self.assertEqual(0o600, stat.S_IMODE(os.stat(f).st_mode))
        self.assertEqual(0o700, stat.S_IMODE(os.stat(share.ShareStore.folder()).st_mode))
        r = share.ShareStore.read(s.id)
        self.assertEqual(("A" * 22, "tok", 1900000000), (r.id, r.token, r.expiresAt))
        post = [c for c in self.server.calls if c[0] == "POST" and c[1] == "/api/v1/shares"][0]
        self.assertTrue(post[2]["Idempotency-Key"].startswith(s.id + "-"))

    def test_registers_again_when_forgotten(self):
        self.client.share(session(), share.Options())
        self.server.forget = True
        self.assertEqual("shared", self.client.share(session(), share.Options()).kind)
        self.assertEqual(2, sum(1 for c in self.server.calls if c[1] == "/api/v1/devices"))

    def test_blocked_and_failed(self):
        s = session()
        self.server.reply = (422, b'{"code":"blocked","hits":[{"part":"lines","from":1,"to":1,"questions":["credential"]}]}')
        out = self.client.share(s, share.Options(scope="full"))
        self.assertEqual("blocked", out.kind)
        self.assertEqual({1}, share.record_lines(out.hits, out.kept))
        self.assertIsNone(share.ShareStore.read(s.id))
        self.server.reply = (429, b'{"code":"rate_limited","retryAfter":30}')
        out = self.client.share(s, share.Options())
        self.assertEqual(("failed", "rate_limited", 30), (out.kind, out.code, out.retry_after))

    def test_revoke_forgets(self):
        s = session()
        r = self.client.share(s, share.Options()).record
        self.assertTrue(self.client.revoke(r, s.id))
        self.assertIsNone(share.ShareStore.read(s.id))
        delete = [c for c in self.server.calls if c[0] == "DELETE"][0]
        self.assertEqual("Bearer tok", delete[2]["Authorization"])

    def test_network_failure(self):
        def down(*_):
            raise share.Failure("network")
        c = share.ShareClient(transport=down, base="https://cicada.test")
        self.assertEqual("network", c.share(session(), share.Options()).code)


if __name__ == "__main__":
    unittest.main()
