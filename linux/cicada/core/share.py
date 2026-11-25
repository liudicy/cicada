"""A meeting shared as a link on cicada.indaloop.app: the Mac's ShareProjection.swift and
ShareClient.swift. Three parts:

- `doc`: the share document (v1), made from a record. Only whitelisted fields leave the computer:
  never the record's file paths, Ling's guesses at names with the lines they came from, or its own
  bookkeeping. Speakers are 说话人 N unless the user chose to show names. Same bytes as the Mac
  (Tests/fixtures/share); the server (server/src/doc.js) reads exactly these fields.
- `ShareStore`: what this computer keeps about each link (Shares/<record id>.json, 0600 in a 0700
  folder): the manage token and password live only there, never in the record, exports or logs.
- `ShareClient`: no accounts. This computer is an Ed25519 key made on first use (share-device.json,
  0600), registered once with a small proof of work; every write is signed (method, path, time,
  nonce, body hash), as server/src/auth.js checks. Not an AI call, so not LingClient: the review
  runs on the server."""
from __future__ import annotations

import base64
import hashlib
import json
import math
import os
import secrets
import time
import urllib.error
import urllib.request

from . import ed25519, proxy, speakers
from .models import iso_write
from .strings import L, LF
from .support import Log, Paths

BASE = "https://cicada.indaloop.app"
ITERATIONS = 210_000
DAYS = (7, 30, 365)

# The document


def _round(t: float) -> float:
    """One decimal, half away from zero (Swift's .rounded(), not Python's banker's round)."""
    x = t * 10
    r = math.floor(abs(x) + 0.5)
    return math.copysign(r, x) / 10


def _base(code: str) -> str:
    return (code.split("-")[0] if code else "").lower()


def languages(lines) -> list:
    """The meeting's usual direction ("en" → "zh"), by the most lines; ties go to the earliest."""
    count, first = {}, {}
    for i, l in enumerate(lines):
        if l.dst is None:
            continue
        key = _base(l.srcLang) + ">" + _base(l.dstLang)
        count[key] = count.get(key, 0) + 1
        first.setdefault(key, i)
    if not count:
        return []
    top = max(count, key=lambda k: (count[k], -first[k]))
    return top.split(">")


def kept_lines(s, scope: str, removed=()) -> list:
    """The record's line indices that go out, in order: what the server's line numbers count."""
    if scope != "full":
        return []
    return [i for i, l in enumerate(s.lines) if i not in removed and l.src]


def doc(s, scope: str, names: bool, removed=frozenset(), drop_notes: bool = False) -> dict:
    """`removed`: indices into the record's lines the user took out; `drop_notes` leaves the notes out."""
    from .session_store import display_title
    nums = speakers.numbers(s.lines)
    name_map = speakers.names(s) if names else {}

    def who(l) -> str:
        if l.speaker == "me":
            return L("分享者")
        n = nums.get(l.id)
        if n is None:
            return L("对方")
        return speakers.label(n, name_map) if names else LF("说话人 %lld", n)

    lines = []
    for i in kept_lines(s, scope, removed):
        l = s.lines[i]
        line = {"t": _round(l.t), "who": who(l), "src": l.src}
        if l.dst and l.dst != l.src:
            line["dst"] = l.dst
        lines.append(line)
    notes = None
    has_notes = s.notes is not None and not s.notes.is_empty
    if not drop_notes and has_notes:
        n = speakers.named(s.notes, name_map) if names else s.notes

        def item(i, owner: bool) -> dict:
            o = {"text": i.text}
            if owner and i.owner is not None:
                o["owner"] = i.owner
            if i.t is not None:
                o["t"] = _round(i.t)
            return o
        notes = {"summary": n.summary,
                 "topics": [{"start": _round(t.start), "title": t.title, "summary": t.summary, "points": list(t.points)}
                            for t in n.topics],
                 "conclusions": [item(c, False) for c in n.conclusions],
                 "todos": [item(t, names) for t in n.todos],
                 "terms": [{"name": t.name, "note": t.note} for t in n.terms] if names else []}
    hidden = (len(removed) if scope == "full" else 0) + (1 if drop_notes and has_notes else 0)
    out = {"v": 1, "title": display_title(s), "startedAt": iso_write(s.startedAt),
           "duration": int(_round_whole(s.duration)), "langs": languages(s.lines), "lines": lines, "hidden": hidden}
    if notes is not None:
        out["notes"] = notes
    return out


def _round_whole(x: float) -> float:
    return math.copysign(math.floor(abs(x) + 0.5), x)


def _plain(v):
    """Whole doubles as integers (605, not 605.0), as Swift's encoder writes them."""
    if isinstance(v, float) and v == int(v) and abs(v) < 1e15:
        return int(v)
    if isinstance(v, dict):
        return {k: _plain(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_plain(x) for x in v]
    return v


def encode(d: dict) -> bytes:
    """Compact, sorted keys, slashes and non-ASCII as they are: the Mac's [.sortedKeys, .withoutEscapingSlashes]."""
    return json.dumps(_plain(d), sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


# Review hits


def record_lines(hits: list, kept: list) -> set:
    """The record's line indices behind the review's hits ({part, from, to, questions}), given which
    record lines were sent (`kept`)."""
    out = set()
    for h in hits:
        if h.get("part") != "lines":
            continue
        a, b = h.get("from"), h.get("to")
        if not isinstance(a, int) or not isinstance(b, int) or a > b:
            continue
        for i in range(a, b + 1):
            if 0 <= i < len(kept):
                out.add(kept[i])
    return out


CATEGORIES = {"credential": "密码或密钥", "confidential": "未公开的公司信息", "crossborder": "不宜跨境传输的信息",
              "personal": "个人身份信息", "harmful": "违法或危险内容"}


def category(q: str) -> str:
    return L(CATEGORIES[q]) if q in CATEGORIES else q


def message(code: str) -> str:
    """What a failed share says, by the server's code (ShareSheet.message)."""
    if code in ("rate_limited", "too_many_shares"):
        return L("分享得太频繁了，请稍后再试。")
    return L({"review_unavailable": "敏感内容检查暂时不可用，没有检查就不会分享。请稍后再试。",
              "sharing_off": "分享功能暂时关闭了。", "update_required": "请先更新知了。",
              "too_large": "这场会议太长，可以只分享纪要。", "bad_document": "这场会议没有可分享的内容。",
              "network": "连不上 cicada.indaloop.app，请检查网络。"}.get(code, "服务器出了问题，请稍后再试。"))


def summary(password: bool, days: int, names: bool) -> str:
    """The settings already chosen, in one line (无密码 · 7 天有效 · 不显示名字); 更改 opens them."""
    return " · ".join((L("密码保护") if password else L("无密码"),
                       L("1 年有效") if days == 365 else LF("%lld 天有效", days),
                       L("显示名字") if names else L("不显示名字")))


def clipboard_text(r: "ShareRecord", title: str, now: float | None = None) -> str:
    """What 复制 puts on the clipboard, in the UI's language (ShareSheet.clipboardText): the title,
    the link on a line of its own (chat apps then make it a link), the password and how long it
    stays open."""
    left = r.days_left(now)
    valid = L("1 年内有效") if left >= 365 else LF("%lld 天内有效", left)
    last = LF("密码：%@（%@）", r.password, valid) if r.password else valid
    return "\n".join((LF("「%@」会议记录", title), r.url, last))


# Passwords

_WORDS = ("amber apple arrow aspen basil beach birch bloom brook cedar cherry cloud coral comet dawn delta dune ember fern "
          "field flint frost grove harbor hazel honey iris island jade lake lark lemon lily linen maple meadow mint moss "
          "olive orbit pearl pine plum pond quartz rain reed river ruby sage sand shell silk sky slate snow spruce stone "
          "storm sun tide tulip velvet willow wind").split()


def verifier(password: str, salt: bytes, iterations: int = ITERATIONS) -> bytes:
    """PBKDF2-SHA256, 32 bytes: what the browser derives from the password (site/share.js). The
    server keeps only its hash, so the password itself never leaves either side."""
    return hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations, 32)


def make_password() -> str:
    """"ruby-41-lake": easy to read out and type; the server limits how many can be tried."""
    return "%s-%d-%s" % (secrets.choice(_WORDS), 10 + secrets.randbelow(90), secrets.choice(_WORDS))


def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def unb64(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


# Local storage


def write_secret(path: str, data: bytes) -> bool:
    """A file only this user can read, created 0600 from the start in a 0700 folder."""
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(path, 0o600)
        return True
    except OSError as e:
        Log.d("share: could not write %s (%s)" % (os.path.basename(path), type(e).__name__))
        return False


class ShareRecord:
    """A link this computer made: `expiresAt` and `createdAt` are Unix seconds."""

    def __init__(self, id: str, url: str, token: str, expiresAt: float, scope: str, password: str | None, createdAt: float):
        self.id, self.url, self.token, self.expiresAt = id, url, token, expiresAt
        self.scope, self.password, self.createdAt = scope, password, createdAt

    def to_json(self) -> dict:
        o = {"id": self.id, "url": self.url, "token": self.token, "expiresAt": iso_write(_utc(self.expiresAt)),
             "scope": self.scope, "createdAt": iso_write(_utc(self.createdAt))}
        if self.password is not None:
            o["password"] = self.password
        return o

    @staticmethod
    def from_json(o: dict) -> "ShareRecord | None":
        from .models import iso_read
        try:
            exp, made = iso_read(o["expiresAt"]), iso_read(o.get("createdAt"))
            return ShareRecord(o["id"], o["url"], o["token"], exp.timestamp(), o.get("scope") or "notes",
                               o.get("password"), made.timestamp() if made else exp.timestamp())
        except (KeyError, TypeError, AttributeError):
            return None

    def days_left(self, now: float | None = None) -> int:
        # The server sets the expiry by its own clock: an hour's slack keeps a fresh 7-day link at 7.
        return max(1, math.ceil((self.expiresAt - (time.time() if now is None else now) - 3600) / 86400))


def _utc(t: float):
    from datetime import datetime, timezone
    return datetime.fromtimestamp(t, timezone.utc)


class ShareStore:
    """Shares/<record id>.json, 0600 in a 0700 folder, beside the records' folder."""

    @staticmethod
    def folder() -> str:
        return os.path.join(Paths.data(), "Shares")

    @classmethod
    def _path(cls, sid: str) -> str:
        return os.path.join(cls.folder(), os.path.basename(sid) + ".json")

    @classmethod
    def read(cls, sid: str) -> ShareRecord | None:
        try:
            with open(cls._path(sid), encoding="utf-8") as f:
                o = json.load(f)
        except (OSError, ValueError):
            return None
        return ShareRecord.from_json(o) if isinstance(o, dict) else None

    @classmethod
    def save(cls, r: ShareRecord, sid: str) -> None:
        write_secret(cls._path(sid), json.dumps(r.to_json(), sort_keys=True, ensure_ascii=False).encode("utf-8"))

    @classmethod
    def remove(cls, sid: str) -> None:
        try:
            os.remove(cls._path(sid))
        except OSError:
            pass

    @classmethod
    def all(cls) -> dict:
        out = {}
        try:
            names = os.listdir(cls.folder())
        except OSError:
            return out
        for n in names:
            if n.endswith(".json"):
                r = cls.read(n[:-5])
                if r is not None:
                    out[n[:-5]] = r
        return out


# The client


def proof_of_work(pub: bytes) -> bytes:
    """20 leading zero bits of sha256(public key ‖ 8-byte big-endian nonce): about a million
    hashes, a few seconds in Python. Run it off the main loop."""
    head = hashlib.sha256(pub)
    n = 0
    while True:
        nonce = n.to_bytes(8, "big")
        h = head.copy()
        h.update(nonce)
        d = h.digest()
        if d[0] == 0 and d[1] == 0 and d[2] < 16:
            return nonce
        n += 1


class Failure(Exception):
    def __init__(self, code: str, retry_after: int | None = None):
        super().__init__(code)
        self.code, self.retry_after = code, retry_after


class Outcome:
    """"shared" (record), "blocked" (hits, kept: the record lines sent) or "failed" (code)."""

    def __init__(self, kind: str, record: ShareRecord | None = None, hits=None, kept=None, code: str | None = None,
                 retry_after: int | None = None):
        self.kind, self.record, self.hits, self.kept, self.code, self.retry_after = kind, record, hits or [], kept or [], code, retry_after


def _version() -> str:
    try:
        from .. import VERSION
        return VERSION
    except ImportError:
        return "0.0.0"


def http(method: str, url: str, body: bytes | None, headers: dict, timeout: float = 90) -> tuple:
    """(status, body bytes) through this computer's proxy; a refused status is an answer, not an error."""
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with proxy.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        try:
            return e.code, e.read()
        except OSError:
            return e.code, b""
    except (OSError, ValueError) as e:
        raise Failure("network") from e


def _code(data: bytes) -> str | None:
    try:
        o = json.loads(data.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    return o.get("code") if isinstance(o, dict) else None


class Options:
    def __init__(self, scope: str = "notes", days: int = 7, names: bool = False, password: str | None = None,
                 summary_in_preview: bool = False, removed=None, drop_notes: bool = False):
        self.scope, self.days, self.names, self.password = scope, days, names, password
        self.summary_in_preview, self.removed, self.drop_notes = summary_in_preview, set(removed or ()), drop_notes


class ShareClient:
    """Blocking calls: run them on a worker thread. `transport(method, url, body, headers)` →
    (status, bytes); tests pass a fake. CICADA_SHARE_SERVER points a dev build at a local Worker."""

    def __init__(self, transport=http, base: str | None = None, platform: str = "linux", version: str | None = None):
        self.transport = transport
        self.base = (base or os.environ.get("CICADA_SHARE_SERVER") or BASE).rstrip("/")
        self.platform = platform
        self.version = version or _version()

    @staticmethod
    def device_file() -> str:
        return os.path.join(Paths.data(), "share-device.json")

    def _load(self) -> tuple:
        try:
            with open(self.device_file(), encoding="utf-8") as f:
                o = json.load(f)
            seed = base64.b64decode(o["key"])
            if len(seed) == 32:
                return seed, o
        except (OSError, ValueError, KeyError, TypeError):
            pass
        seed = secrets.token_bytes(32)
        o = {"key": base64.b64encode(seed).decode()}
        self._save(o)
        return seed, o

    def _save(self, o: dict) -> None:
        write_secret(self.device_file(), json.dumps(o, sort_keys=True).encode())

    def device(self, force: bool = False) -> tuple:
        """(private key seed, device id), registering this computer with the server first if needed."""
        seed, o = self._load()
        if not force and o.get("device") and o.get("server") == self.base:
            return seed, o["device"]
        pub = ed25519.public_key(seed)
        nonce = proof_of_work(pub)
        body = json.dumps({"key": b64url(pub), "pow": b64url(nonce), "platform": self.platform,
                           "version": self.version}).encode()
        status, data = self._send("POST", "/api/v1/devices", body, {}, None)
        try:
            device = json.loads(data.decode())["device"] if status == 201 else None
        except (ValueError, KeyError, TypeError, UnicodeDecodeError):
            device = None
        if not isinstance(device, str):
            Log.d("share: register failed %d %s" % (status, _code(data) or "?"))
            raise Failure(_code(data) or "register_failed")
        o["device"], o["server"] = device, self.base
        self._save(o)
        Log.d("share: registered this computer")
        return seed, device

    def _send(self, method: str, path: str, body: bytes | None, headers: dict, signer) -> tuple:
        h = {"Content-Type": "application/json", "X-Cicada-Client": "%s/%s" % (self.platform, self.version),
             "User-Agent": "Cicada-Linux", **headers}
        if signer is not None:
            seed, device = signer
            t = str(int(time.time()))
            nonce = b64url(secrets.token_bytes(16))
            digest = hashlib.sha256(body or b"").hexdigest()
            msg = "%s\n%s\n%s\n%s\n%s" % (method, path, t, nonce, digest)
            h.update({"X-Cicada-Device": device, "X-Cicada-Time": t, "X-Cicada-Nonce": nonce,
                      "X-Cicada-Signature": b64url(ed25519.sign(seed, msg.encode("utf-8")))})
        return self.transport(method, self.base + path, body, h)

    def signed(self, method: str, path: str, body: bytes | None = None, headers: dict | None = None) -> tuple:
        """A signed call; registers again once if the server no longer knows this computer."""
        signer = self.device()
        status, data = self._send(method, path, body, headers or {}, signer)
        if status == 401 and _code(data) == "unknown_device":
            signer = self.device(force=True)
            status, data = self._send(method, path, body, headers or {}, signer)
        return status, data

    def share(self, s, o: Options) -> Outcome:
        d = doc(s, o.scope, o.names, o.removed, o.drop_notes)
        kept = kept_lines(s, o.scope, o.removed)
        body = {"doc": d, "scope": o.scope, "days": o.days, "summaryInPreview": o.summary_in_preview}
        if o.password:
            salt = secrets.token_bytes(16)
            v = verifier(o.password, salt)
            body["password"] = {"salt": b64url(salt), "iter": ITERATIONS, "hash": b64url(hashlib.sha256(v).digest())}
        data = json.dumps(_plain(body), ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        # The same meeting, content and settings sent again (the answer was lost) gets the same link
        # back; any other setting makes a new share.
        settings = "%s|%d|%s|%s|%s" % (o.scope, o.days, _b(o.names), o.password or "", _b(o.summary_in_preview))
        idem = s.id + "-" + hashlib.sha256(encode(d) + settings.encode("utf-8")).digest()[:8].hex()
        try:
            status, out = self.signed("POST", "/api/v1/shares", data, {"Idempotency-Key": idem})
        except Failure as f:
            return Outcome("failed", code=f.code, retry_after=f.retry_after)
        try:
            obj = json.loads(out.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            obj = {}
        if not isinstance(obj, dict):
            obj = {}
        if status in (200, 201):
            try:
                r = ShareRecord(obj["id"], obj["url"], obj["token"], float(obj["expiresAt"]), o.scope, o.password, time.time())
            except (KeyError, TypeError, ValueError):
                return Outcome("failed", code="server_error")
            old = ShareStore.read(s.id)
            if old is not None and old.id != r.id:
                self.revoke(old, None)
            ShareStore.save(r, s.id)
            Log.d("share: %s shared (%s, %d days%s)" % (s.id, o.scope, o.days, ", password" if o.password else ""))
            return Outcome("shared", record=r)
        if status == 422:
            hits = [h for h in obj.get("hits") or [] if isinstance(h, dict)]
            Log.d("share: %s blocked %s" % (s.id, "; ".join(
                "%s%s %s" % (h.get("part"), " %s-%s" % (h.get("from"), h.get("to")) if h.get("from") is not None else "",
                             ",".join(h.get("questions") or [])) for h in hits)))
            return Outcome("blocked", hits=hits, kept=kept)
        Log.d("share: %s failed %d %s" % (s.id, status, obj.get("code") or "?"))
        return Outcome("failed", code=obj.get("code") or "server_error",
                       retry_after=obj.get("retryAfter") if isinstance(obj.get("retryAfter"), int) else None)

    def revoke(self, r: ShareRecord, sid: str | None) -> bool:
        """Turns the link off on the server and forgets it here. `sid` None: the record is being replaced."""
        try:
            status, data = self.signed("DELETE", "/api/v1/shares/" + r.id, None, {"Authorization": "Bearer " + r.token})
        except Failure:
            return False
        # 404: already gone (or never ours); either way nothing to keep.
        ok = status in (204, 404)
        if not ok:
            Log.d("share: revoke failed %d %s" % (status, _code(data) or "?"))
        if ok and sid:
            ShareStore.remove(sid)
        return ok

    def stats(self, ids: list) -> dict:
        """id → {id, expiresAt, state, views} for this computer's links among `ids`."""
        if not ids:
            return {}
        try:
            status, data = self.signed("GET", "/api/v1/shares?ids=" + ",".join(ids))
            if status != 200:
                return {}
            return {x["id"]: x for x in json.loads(data.decode("utf-8")).get("shares", []) if isinstance(x, dict)}
        except (Failure, ValueError, KeyError, AttributeError, UnicodeDecodeError):
            return {}


def _b(v: bool) -> str:
    return "true" if v else "false"
