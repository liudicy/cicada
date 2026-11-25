"""The AI service's check, step by step (AICheckView.swift): the settings and the onboarding show the
same list. Every step that ran shows its result; the one that failed says why in one line and
offers the one thing that fixes it. Also the words the tray, the checklist and 开始听 use."""
from __future__ import annotations

from gi.repository import Gtk

from ..core import aicheck
from ..core.providers import is_nearby
from ..core import strings
from ..core.strings import L, LF
from . import ui

ICONS = {aicheck.OK: ("object-select-symbolic", "ok"), aicheck.FAIL: ("window-close-symbolic", "fail"),
         aicheck.BUSY_STATE: ("dialog-warning-symbolic", "busy"), aicheck.RUNNING: ("content-loading-symbolic", "running"),
         aicheck.SKIPPED: ("list-remove-symbolic", "off"), aicheck.UNTESTED: ("list-remove-symbolic", "off")}


def recommended(app, kind: str) -> str | None:
    """The service's first recommended text or hear model, when it isn't the one in use."""
    c = app.ling.config()
    models = c.provider.text_models if kind == "text" else c.provider.hear_models
    current = c.text_model if kind == "text" else c.hear_model
    first = models[0].id if models else None
    return first if first and first != current else None


def top_up_url(provider) -> str:
    return aicheck.TOP_UP if provider.id == "openrouter" else (provider.site or aicheck.TOP_UP)


def actions(app, change_key, recheck_in_step: bool = True) -> list:
    """(title, run) for the failed step: one primary fix, at most one other."""
    from .settings_window import open_uri
    ling = app.ling
    f = ling.check_result.failure
    if f is None:
        return []
    p = ling.provider
    reason = f[1]
    recheck = [(L("重新检查"), app.recheck)] if recheck_in_step else []
    if reason == aicheck.UNREACHABLE:
        # A proxy has nothing to do with a server on this computer or the local network.
        if is_nearby(ling.service_host):
            return recheck
        return [(L("怎么设置代理"), lambda: open_uri(aicheck.help_url(strings.language)))] + recheck
    if reason in (aicheck.INVALID_KEY, aicheck.MGMT_KEY):
        out = [(L("更换 key"), change_key)]
        if p.site:
            out.append((LF("打开 %@", p.name), lambda: open_uri(p.site)))
        return out
    if reason == aicheck.NO_CREDIT:
        return [(L("去充值"), lambda: open_uri(top_up_url(p)))] + recheck
    if reason in (aicheck.NO_MODEL, aicheck.DEAF):
        kind = "text" if reason == aicheck.NO_MODEL else "hear"
        rec = recommended(app, kind)
        if rec is None:
            return [(L("重新检查"), app.recheck)]
        return [(LF("换成推荐的 %@", rec), lambda: app.use_recommended(kind))]
    if reason == aicheck.SERVER_ERROR:
        return [(L("重新检查"), app.recheck)]
    return []


def steps_widget(app, change_key, recheck_in_step: bool = True, width_chars: int = 46) -> Gtk.Widget:
    """The step list: a disc, the step's name and seconds; under the failed one, why, the proxy hint
    and its buttons (the first dark)."""
    ling = app.ling
    r = ling.check_result
    c = ling.config()
    host = ling.service_host
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    for i, step in enumerate(aicheck.STEPS):
        st = r[step]
        if i:
            sep = ui.panel(Gtk.Box(), "hair")
            sep.set_size_request(-1, 1)
            sep.set_margin_start(30)
            box.pack_start(sep, False, False, 0)
        icon_name, tone = ICONS[st.kind]
        img = ui.icon(icon_name, 11)
        img.set_halign(Gtk.Align.CENTER)
        img.set_valign(Gtk.Align.CENTER)
        disc = ui.panel(img, "stepdisc", tone)
        disc.set_size_request(20, 20)
        disc.set_valign(Gtk.Align.START)
        quiet = st.kind in (aicheck.SKIPPED, aicheck.UNTESTED)
        texts = ui.vbox(4, ui.text(aicheck.title(step, host), 13, "tertiary" if quiet else "ink", wrap=False))
        if st.kind == aicheck.OK and step in ("text", "hear"):
            texts.pack_start(ui.text(c.text_model if step == "text" else c.hear_model, 11, "tertiary", wrap=False), False, False, 0)
        if st.kind == aicheck.UNTESTED and r.passed:
            texts.pack_start(ui.text(L("开会用过一次后确认"), 11, "tertiary", wrap=False), False, False, 0)
        if st.kind in (aicheck.FAIL, aicheck.BUSY_STATE) and (st.kind == aicheck.BUSY_STATE or r.failure[0] == step):
            why = ling.message()
            if why:
                w = ui.text(why, 12, "stepwhy", width_chars=width_chars)
                if st.kind == aicheck.BUSY_STATE:
                    ui.classes(w, "busy")
                texts.pack_start(w, False, False, 0)
            line = r.proxy_line(ling.service_label, host)
            if line:
                texts.pack_start(ui.panel(ui.pad(ui.text(line, 12, "", width_chars=width_chars), 7, 10), "proxybox"), False, False, 0)
            acts = actions(app, change_key, recheck_in_step) if st.kind == aicheck.FAIL else []
            if acts:
                row = ui.hbox(8)
                for j, (title, run) in enumerate(acts):
                    row.pack_start(ui.button(title, run, "darkbtn" if j == 0 else "outline"), False, False, 0)
                texts.pack_start(ui.gap(row, 2), False, False, 0)
        row = ui.hbox(10, disc)
        row.pack_start(texts, True, True, 0)
        if st.kind == aicheck.OK and st.seconds is not None:
            secs = ui.text(LF("%@ 秒", "%.1f" % st.seconds), 11, "tertiary", wrap=False, ellipsize=False)
            secs.set_valign(Gtk.Align.START)
            row.pack_end(secs, False, False, 0)
        box.pack_start(ui.pad(row, 8, 0), False, False, 0)
    return box


def show_steps(r) -> bool:
    """The list shows while something is wrong or being checked; all passed folds into one line."""
    return r.running or r.failure is not None or r.busy or (r.at is not None and not r.passed)


def passed_line(app) -> str | None:
    """All passed, in one line: "文字 1.8 秒 · 听 2.1 秒", or "12 分钟前开会时用过" when the newest
    evidence came from a meeting."""
    r = app.ling.check_result
    if not r.passed or r.busy:
        return None
    if r.passive and r.at is not None:
        return aicheck.relative(r.at)
    parts = []
    text, hear = r["text"], r["hear"]
    if text.kind == aicheck.OK and text.seconds is not None:
        parts.append(LF("文字 %@ 秒", "%.1f" % text.seconds))
    if hear.kind == aicheck.OK and hear.seconds is not None:
        parts.append(LF("听 %@ 秒", "%.1f" % hear.seconds))
    return " · ".join(parts) or None


def strip_words(app):
    """(title, detail) for the tray's first item and the checklist: only failures the user must fix
    (AIServiceStrip.swift). On Linux the service hears too, so nothing goes on without it."""
    ling = app.ling
    r = ling.check_result
    if not ling.has_key or not r.needs_user:
        return None
    name = ling.service_label
    f = r.failure
    if f is None:
        return r.balance_line(name), L("用完后纪要会停下")
    c = ling.config()
    from ..core import problem
    title = LF("连不上 %@", name) if f[1] == aicheck.UNREACHABLE else \
        problem.title(f[1], name, c.text_model, c.hear_model) or L("AI 服务的设置要改一下")
    return title, ling.message() or ""


def blocking(app) -> str | None:
    """What stops Cicada until the user changes something (AIServiceStrip.blocking): the tray's dot
    and the notification. Not the network, a busy service or one that errs."""
    from ..core import problem
    ling = app.ling
    if not ling.has_key:
        return None
    c = ling.config()
    return problem.title(ling.check_result.reason, ling.service_label, c.text_model, c.hear_model)


def blocking_detail(app) -> str:
    """The line under blocking(): why, unless that only says the title again (余额不足, 听不了声音,
    找不到模型), then where it's fixed."""
    why = app.ling.message() or ""
    return why if why and why != blocking(app) else L("在 设置 › AI 服务 里换一个")


def key_hint(app, key: str):
    """A pasted key that belongs elsewhere: (what it is, the service it fits or None), else None.
    A management key can't call models; another service's key goes there with one click."""
    owner = aicheck.owner(key)
    if owner is None:
        return None
    service, management = owner
    if management:
        return L("这是 ZenMux 的管理 key，不能用来调用模型。请粘贴 sk-payg 开头的 key。"), None
    if service != app.settings.aiProvider:
        from ..core.providers import named
        return LF("这是 %@ 的 key。", named(service).name), service
    return None
