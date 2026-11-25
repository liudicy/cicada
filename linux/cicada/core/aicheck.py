"""What the last look at the AI service found, step by step (AICheck.swift, plus the ports' 听对方):
can this computer reach it, does it take the key, does the text model answer, does the hear model
take audio. A failed step stops the ones after it, so the settings can say exactly where it broke
and offer the one thing that fixes it.

Most of the time the answer comes from real requests (hearing, notes, translation): every call
reports back here, so a meeting keeps the steps current without an extra request. A check runs
only when the service, a model or the key changes, at launch, on 重新检查, and when the network
changes while the service was unreachable. Stdlib only: the Mac runs these tests too."""
from __future__ import annotations

import copy
import time
from dataclasses import dataclass

from .jsonfmt import arr, obj, parse_object, string
from .strings import L, LF

STEPS = ("reach", "key", "text", "hear")

UNREACHABLE, BAD_ADDRESS, INVALID_KEY, MGMT_KEY, NO_CREDIT, NO_MODEL, NO_JSON, DEAF, BUSY, SERVER_ERROR = (
    "unreachable", "badAddress", "invalidKey", "mgmtKey", "noCredit", "noModel", "noJSON", "deaf", "busy", "serverError")
REASONS = (UNREACHABLE, BAD_ADDRESS, INVALID_KEY, MGMT_KEY, NO_CREDIT, NO_MODEL, NO_JSON, DEAF, BUSY, SERVER_ERROR)

RUNNING, OK, BUSY_STATE, FAIL, SKIPPED, UNTESTED = "running", "ok", "busy", "fail", "skipped", "untested"

# Below this many dollars left, OpenRouter's balance is worth a word.
LOW_BALANCE = 0.5
TOP_UP = "https://openrouter.ai/settings/credits"
# A custom service whose sentence takes this long often misses the 6 s a translation is given and
# falls back to Google (AICheck.Speed.slowAfter).
SLOW_AFTER = 3.0


@dataclass(frozen=True)
class Speed:
    """A custom service: how long one real sentence took, and whether the model thought first."""
    seconds: float
    thinks: bool

    @property
    def slow(self) -> bool:
        return self.thinks or self.seconds >= SLOW_AFTER


@dataclass(frozen=True)
class State:
    kind: str = UNTESTED
    seconds: float | None = None   # ok: how long the request that proved it took (None: proved by another step's)
    reason: str | None = None      # fail
    code: int | None = None        # fail: the HTTP status, when there was one


class AICheck:
    """The steps in order, when the newest result came in, whether it came from a real request
    (`passive`), the proxy hint after `unreachable`, and OpenRouter's balance. Replaced whole, never
    changed in place once shown: engine threads and the UI read it at the same time."""

    def __init__(self):
        self.steps = {s: State() for s in STEPS}
        self.at: float | None = None
        self.passive = False
        # proxy.hint: ("system",) a proxy is in use; ("dead", "host:port") it doesn't answer; ("pac",)
        # GNOME's is automatic; ("app", port) a proxy app listens but no proxy is set; ("none",).
        self.proxy: tuple | None = None
        self.balance: float | None = None
        # A custom service: the real sentence the check translated (Speed).
        self.translate: Speed | None = None
        # A custom service whose notes go to another model or server: how that one answered (a State:
        # running, ok or fail). None while notes use the translation model (then the steps say it
        # all). A notes failure doesn't stop translation: `failure` and `passed` stay about it.
        self.notes: State | None = None

    def copy(self) -> "AICheck":
        return copy.deepcopy(self)

    def __getitem__(self, step: str) -> State:
        return self.steps[step]

    def __setitem__(self, step: str, state: State) -> None:
        self.steps[step] = state

    @property
    def failure(self):
        """(step, reason, code) of the first step that failed, else None."""
        for s in STEPS:
            st = self.steps[s]
            if st.kind == FAIL:
                return s, st.reason, st.code
        return None

    @property
    def reason(self) -> str | None:
        f = self.failure
        return f[1] if f else None

    @property
    def running(self) -> bool:
        return any(st.kind == RUNNING for st in self.steps.values()) or (self.notes is not None and self.notes.kind == RUNNING)

    @property
    def notes_failed(self) -> bool:
        """Translation works but the notes' own model or server doesn't (a busy one fixes itself)."""
        return self.notes is not None and self.notes.kind == FAIL and self.notes.reason != BUSY

    @property
    def busy(self) -> bool:
        return any(st.kind == BUSY_STATE for st in self.steps.values())

    @property
    def passed(self) -> bool:
        """Every step passed (busy counts; a step nothing has tested yet does not block)."""
        return self.at is not None and self.failure is None and not self.running

    @property
    def slow(self) -> bool:
        """Text works but every sentence is slow (a thinking model): translations will fall back.
        The hear model is a job of its own here: one that isn't set yet or can't hear doesn't hide it."""
        f = self.failure
        return (f is None or f[0] == "hear") and self.translate is not None and self.translate.slow

    @property
    def low_balance(self) -> bool:
        return self.balance is not None and self.balance < LOW_BALANCE

    @property
    def needs_user(self) -> bool:
        """Something only the user can fix (a busy service, or one that errs, fixes itself)."""
        f = self.failure
        if f is None:
            return self.low_balance
        return f[1] not in (BUSY, SERVER_ERROR)

    @property
    def down(self) -> bool:
        """Nothing AI works: the service can't be reached, or won't take the key. A hear model at an
        address of its own that can't be reached leaves the text model working."""
        f = self.failure
        return f is not None and f[0] != "hear" and f[1] in (UNREACHABLE, BAD_ADDRESS, INVALID_KEY, MGMT_KEY, NO_CREDIT)

    def fail(self, step: str, reason: str, code: int | None = None, reached: bool = True) -> None:
        """`step` failed and the ones after it were never reached. `reached`: a reply came back, so
        the steps before it passed (False when nothing was sent, like a management key)."""
        after = False
        for s in STEPS:
            if s == step:
                self.steps[s] = State(FAIL, reason=reason, code=code)
                after = True
            elif after:
                self.steps[s] = State(SKIPPED)
            elif reached and self.steps[s].kind != OK:
                self.steps[s] = State(OK)
        if reason != UNREACHABLE:
            self.proxy = None

    def pass_up_to(self, step: str, seconds: float | None) -> None:
        """One request proved every step up to `step` (a chat proves the address, the key and the
        model). Clears what failed before; skipped steps after it are open again."""
        after = False
        for s in STEPS:
            if after:
                if self.steps[s].kind == SKIPPED:
                    self.steps[s] = State(UNTESTED)
            elif s == step:
                self.steps[s] = State(OK, seconds)
                after = True
            elif self.steps[s].kind != OK:
                self.steps[s] = State(OK)
        self.proxy = None

    # Words

    def message(self, service: str, host: str, text_model: str, hear_model: str) -> str | None:
        """Why the failed step failed, in one sentence."""
        f = self.failure
        if f is None:
            return LF("%@ 现在很忙，key 没问题。开会时会自动重试。", service) if self.busy else None
        reason, code = f[1], f[2]
        return {
            UNREACHABLE: lambda: LF("这台电脑访问不到 %@。", host),
            BAD_ADDRESS: lambda: L("地址要用 https；这台电脑和局域网里的服务可以用 http。"),
            INVALID_KEY: lambda: LF("%@ 说这个 key 无效，可能没复制全，或已删除。", service),
            MGMT_KEY: lambda: L("这是 ZenMux 的管理 key，不能用来调用模型。请粘贴 sk-payg 开头的 key。"),
            NO_CREDIT: lambda: LF("%@ 账户余额不足。", service),
            NO_MODEL: lambda: LF("%@ 上找不到 %@ 这个模型。", service, text_model),
            NO_JSON: lambda: L("这个服务不支持 JSON，纪要写不了；翻译照常。"),
            DEAF: lambda: LF("%@ 听不了声音。", hear_model or service),  # no hear model yet: the service
            BUSY: lambda: LF("%@ 现在很忙，key 没问题。开会时会自动重试。", service),
            SERVER_ERROR: lambda: LF("%@ 暂时出错（HTTP %lld），稍后再试。", service, code or 0),
        }[reason]()

    def slow_line(self, google_off: bool = False) -> str | None:
        """Why translations are slow, and what to do (a custom service). Linux falls back to Google
        too (Translator.translate, 6 s), so the Mac's words hold; with 语音和文字只发给你的服务
        (`google_off`) a sentence over 6 s is given up on instead (AICheck.slowLine(googleOff:))."""
        if not self.slow:
            return None
        secs = "%.1f" % self.translate.seconds
        if google_off:
            if self.translate.thinks:
                return LF("这个模型先思考再回答，翻一句要 %@ 秒，超过 6 秒这句就不等它了。在服务端关掉思考，或换一个不思考的模型。", secs)
            return LF("翻一句要 %@ 秒，超过 6 秒这句就不等它了。换一个更小的模型会快一些。", secs)
        if self.translate.thinks:
            return LF("这个模型先思考再回答，翻一句要 %@ 秒，超过 6 秒会改用 Google。在服务端关掉思考，或换一个不思考的模型。", secs)
        return LF("翻一句要 %@ 秒，超过 6 秒会改用 Google。换一个更小的模型会快一些。", secs)

    def notes_line(self, host: str, model: str, shared_key: bool) -> str | None:
        """The notes' own model or server's problem, in one sentence. `shared_key`: notes use the
        translation key, so a refused key wants one of their own."""
        n = self.notes
        if n is None or n.kind != FAIL:
            return None
        reason = n.reason
        if reason in (INVALID_KEY, MGMT_KEY):
            return LF("%@ 不认上面的 key，给它单独填一个。", host) if shared_key else LF("%@ 说这个 key 无效，可能没复制全，或已删除。", host)
        if reason == SERVER_ERROR:
            return LF("%@ 暂时出错（HTTP %lld），稍后再试。", host, n.code or 0)
        return {
            UNREACHABLE: lambda: LF("这台电脑访问不到 %@。", host),
            BAD_ADDRESS: lambda: L("地址要用 https；这台电脑和局域网里的服务可以用 http。"),
            NO_CREDIT: lambda: LF("%@ 账户余额不足。", host),
            NO_MODEL: lambda: LF("%@ 上找不到 %@ 这个模型。", host, model),
            NO_JSON: lambda: L("这个模型没按要求返回 JSON，写不了纪要。换一个通用模型。"),
        }.get(reason, lambda: None)()

    def proxy_line(self, service: str, host: str) -> str | None:
        """Under "can't reach": what this computer's proxy looks like, and what to do."""
        from .providers import is_nearby
        # A server on this computer or the local network: a proxy has nothing to do with it.
        if self.reason != UNREACHABLE or self.proxy is None or is_nearby(host):
            return None
        if self.proxy[0] == "system":
            return LF("开了代理也连不上：换一个节点，或检查代理软件是否放过 %@。", host)
        if self.proxy[0] == "dead":
            # Linux: the proxy requests go through (the environment's or GNOME's) doesn't answer.
            return LF("代理 %@ 没有回应。打开代理软件，或在 设置 › 网络 › 网络代理 里改正。", self.proxy[1])
        if self.proxy[0] == "pac":
            # GNOME's "automatic" needs a PAC file evaluated, which the app can't: requests go direct.
            return L("系统代理设成了“自动”，知了用不了。在 设置 › 网络 › 网络代理 里改成“手动”。")
        if self.proxy[0] == "app":
            # As text: a number would be grouped ("7,890") on the Mac, which keys it this way.
            return LF("代理软件在运行（端口 %@），但没开系统代理。在代理软件里打开“系统代理”。", str(self.proxy[1]))
        return LF("这台电脑没开代理。在国内通常要开代理才能用 %@。", service)

    def balance_line(self, service: str) -> str | None:
        """"OpenRouter 余额快用完了（还剩 $0.40）" when it is."""
        if not self.low_balance:
            return None
        return LF("%@ 余额快用完了（还剩 $%@）", service, "%.2f" % max(0.0, self.balance))

    def summary(self) -> str:
        """Debug and logs: "reach=ok key=fail(invalidKey) text=skipped hear=skipped"."""
        out = ["%s=%s" % (s, _state(self.steps[s])) for s in STEPS]
        if self.proxy is not None:
            out.append("proxy=" + ":".join(str(p) for p in self.proxy))
        if self.balance is not None:
            out.append("balance=%.2f" % self.balance)
        if self.passive:
            out.append("passive")
        if self.translate is not None:
            out.append("translate=%.1fs%s" % (self.translate.seconds, " thinks" if self.translate.thinks else ""))
        if self.notes is not None:
            out.append("notes=" + _state(self.notes))
        return " ".join(out)


def _state(st: State) -> str:
    if st.kind == OK:
        return "ok" if st.seconds is None else "ok(%.1fs)" % st.seconds
    if st.kind == FAIL:
        return "fail(%s%s)" % (st.reason, "" if st.code is None else " %d" % st.code)
    return st.kind


def title(step: str, host: str) -> str:
    return {"reach": lambda: LF("连上 %@", host), "key": lambda: L("key 可以用"),
            "text": lambda: L("纪要和翻译"), "hear": lambda: L("听对方")}[step]()


def classify(e: LingError, at: str, audio: bool = False):
    """(step, reason, code) a failed request stops at, or None when it says nothing about the
    service. `at` is the step the request was proving; `audio`: it carried audio for the hear model."""
    from .ling import LingError  # here: ling.py imports this module
    k = e.kind
    if k in (LingError.NETWORK, LingError.TIMEOUT):
        return "reach", UNREACHABLE, None
    if k == LingError.INVALID_KEY:
        return "key", INVALID_KEY, None
    if k == LingError.RATE_LIMITED:
        return at, BUSY, None
    if k != LingError.HTTP:
        return None  # no key, a search essay, an unreadable reply
    code = e.status
    if code == 402:
        return "key", NO_CREDIT, code
    if audio and code in (400, 404, 415, 422):
        return "hear", DEAF, code
    if code in (400, 404):
        return ("key", SERVER_ERROR, code) if at == "key" else ("text", NO_MODEL, code)
    return at, SERVER_ERROR, code


def owner(key: str):
    """(service id, management) the prefix of a key says it belongs to: `sk-or-` OpenRouter,
    `sk-payg` ZenMux, `sk-mgmt` ZenMux's management key (it can't call models). None: can't tell."""
    k = (key or "").strip()
    if k.startswith("sk-or-"):
        return "openrouter", False
    if k.startswith("sk-payg"):
        return "zenmux", False
    if k.startswith("sk-mgmt"):
        return "zenmux", True
    return None


def listed(data) -> tuple:
    """(every model id, the ids that take audio in) from a `/models` reply, as listed: unlike the
    menus' catalog, recommended models are not added, so one the service dropped shows. Either is
    None when the reply can't tell (no list; no model that declares its input modalities)."""
    root = parse_object(data) if isinstance(data, str) else data
    ids, hear, declared = set(), set(), False
    for m in arr((root or {}).get("data")):
        m = obj(m) or {}
        mid = string(m.get("id"))
        if not mid:
            continue
        ids.add(mid)
        ins = m.get("input_modalities")
        if ins is None:
            ins = (obj(m.get("architecture")) or {}).get("input_modalities")
        if isinstance(ins, list):
            declared = True
            if "audio" in ins:
                hear.add(mid)
    return (ids or None), (hear if declared and ids else None)


def balance(key_info, credits) -> float | None:
    """OpenRouter: dollars left from `/key` (`limit_remaining`, null without a key limit) and
    `/credits` (bought minus used); the smaller one is what the next meeting can spend."""
    k = (obj((obj(key_info) or {}).get("data")) or {}).get("limit_remaining")
    k = float(k) if isinstance(k, (int, float)) and not isinstance(k, bool) else None
    d = obj((obj(credits) or {}).get("data")) or {}
    total, used = d.get("total_credits"), d.get("total_usage")
    c = float(total) - float(used) if all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in (total, used)) else None
    have = [v for v in (k, c) if v is not None]
    return min(have) if have else None


def simulated(reason: str) -> AICheck:
    """A made-up result for `reason` (debug screenshots of every state)."""
    r = AICheck()
    if reason == BUSY:
        r.pass_up_to("hear", 1.4)
        r["text"] = State(OK, 1.2)
        r["hear"] = State(BUSY_STATE)
    elif reason in (UNREACHABLE, BAD_ADDRESS):
        r.fail("reach", reason, reached=False)
    elif reason in (INVALID_KEY, NO_CREDIT):
        r.fail("key", reason, 402 if reason == NO_CREDIT else None)
    elif reason == MGMT_KEY:
        r.fail("key", reason, reached=False)
    elif reason in (NO_MODEL, NO_JSON):
        r.fail("text", reason, 404)
    elif reason == DEAF:
        r.pass_up_to("text", 1.2)
        r.fail("hear", reason, 400)
    elif reason == SERVER_ERROR:
        r.fail("text", reason, 503)
    else:  # lowBalance: everything passed
        r.pass_up_to("hear", 1.4)
        r["text"] = State(OK, 1.2)
    return r


def relative(at: float, now: float | None = None) -> str:
    """"12 分钟前开会时用过", from when a meeting last proved the service."""
    ago = max(0, int((now if now is not None else time.time()) - at))
    if ago < 60:
        return L("刚刚开会时用过")
    if ago < 3600:
        return LF("%lld 分钟前开会时用过", ago // 60)
    if ago < 86400:
        return LF("%lld 小时前开会时用过", ago // 3600)
    return LF("%lld 天前开会时用过", ago // 86400)


def help_url(language: str) -> str:
    """The website's proxy help, in the UI language."""
    prefix = next(("/" + p for p in ("en", "ja", "ko") if (language or "").startswith(p)), "")
    return "https://cicada.indaloop.app%s/start/#proxy" % prefix
