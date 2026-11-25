"""设置 › 词表 (the Mac's WordListSettings.swift): the switches for 改正听错的词, and the word list itself
(core/vocabulary.py): each word, what it has been heard as, where it came from and how often it fixed
a line. Everything is edited in place; changes count from the next sentence on."""
from __future__ import annotations

from gi.repository import Gdk, GLib, Gtk

from ..core import vocabulary as vocab
from ..core.strings import L, LF
from . import ui


class WordList:
    def __init__(self, app, group):
        self.app = app
        self.group = group  # SettingsWindow._group
        self.query = ""
        self.deleted = None  # (term, index): shown in its place with 撤销 for a few seconds
        self._deleted_at = 0
        self.editing = None  # the word whose spelling is being changed
        self.conflict = None  # (word, heard, owner): a heard form typed that another word has
        self.typing = {}  # word → text typed into its 加一个容易听错的词 (kept through a refresh)
        self._key = None
        self.box = ui.vbox(14)
        self.refresh()

    @property
    def widget(self) -> Gtk.Widget:
        return self.group(L("词表"), self.box)

    def refresh(self) -> None:
        app = self.app
        terms = app.vocabulary.snapshot()
        ling = app.ling
        key = (tuple((t.word, tuple(t.heard), t.source, t.fixes) for t in terms), self.query, ling.usable,
               app.settings.fixMisheard, app.settings.askNames, self.deleted and self.deleted[0].word, self.editing,
               self.conflict, ling.provider.name)
        if key == self._key:
            return
        self._key = key
        ui.clear(self.box)
        self.box.pack_start(self._switches(), False, False, 0)
        self.box.pack_start(self._head(terms), False, False, 0)
        if not terms and self.deleted is None:
            self.box.pack_start(ui.text(L("还没有词。把常用的人名、产品名贴进来，会中就照这些写法改"), 12, "tertiary", width_chars=60),
                                False, False, 0)
        else:
            rows = []
            if self.deleted is not None:
                d = self.deleted[0]
                row = ui.hbox(10)
                lab = Gtk.Label()
                lab.set_markup('<span size="%d">%s <b>%s</b></span>' % (13 * 768, ui.esc(L("已删除")), ui.esc(d.word)))
                ui.classes(lab, "secondary")
                row.pack_start(lab, False, False, 0)
                row.pack_end(ui.classes(ui.link(L("撤销"), self._undo_delete), "fixlink"), False, False, 0)
                rows.append(ui.panel(ui.pad(row, 6, 14), "prow"))
            rows += [self._row(t) for t in self._shown(terms)]
            self.box.pack_start(ui.boxed(rows), False, False, 0)
        self.box.pack_start(ui.text(LF("最多 %lld 个，满了优先用最近的。只存在这台电脑上", vocab.LIMIT), 11, "tertiary", width_chars=60),
                            False, False, 0)
        self.box.show_all()

    # The switches

    def _switches(self) -> Gtk.Widget:
        app, s = self.app, self.app.settings
        ling = app.ling
        if ling.usable:
            fix = Gtk.Switch()
            fix.set_active(s.fixMisheard)
            fix.connect("notify::active", lambda w, _p: self._set("fixMisheard", w.get_active()))
            first = ui.prow(L("会中改正听错的词"), fix, LF("走 %@，只发文字", ling.provider.name))
        else:
            go = ui.link(L("去设置"), lambda: app.show_settings(ai=True))
            ui.classes(go, "fixlink")
            first = ui.prow(L("会中改正听错的词"), go, L("接上 AI 服务后才会改"))
        ask = Gtk.Switch()
        ask.set_active(s.askNames)
        ask.set_sensitive(s.fixMisheard and ling.usable)
        ask.connect("notify::active", lambda w, _p: self._set("askNames", w.get_active()))
        return ui.boxed([first, ui.prow(L("没见过的名字和专称先问我"), ask, L("关掉就只改词表里的词和同音错字"))])

    def _set(self, name: str, on: bool) -> None:
        setattr(self.app.settings, name, on)
        self.app.settings.save()
        GLib.idle_add(lambda: self.refresh() and False)

    # The list

    def _head(self, terms) -> Gtk.Widget:
        head = ui.hbox(10)
        head.pack_start(ui.text(L("词"), 13, "secondary", bold=True, wrap=False, ellipsize=False), False, False, 0)
        if terms:
            head.pack_start(ui.text(str(len(terms)), 12, "tertiary", wrap=False, ellipsize=False), False, False, 0)
        head.pack_end(ui.soft_button(L("粘贴导入…"), self._import, dark=True), False, False, 0)
        if len(terms) > 12:
            search = Gtk.SearchEntry()
            search.set_placeholder_text(L("搜索词表"))
            search.set_text(self.query)
            search.set_size_request(160, -1)

            def typed(e):
                self.query = e.get_text()
                GLib.idle_add(lambda: self.refresh() and False)
            search.connect("search-changed", typed)
            head.pack_end(search, False, False, 0)
        return ui.gap(head, 4)

    def _shown(self, terms) -> list:
        """Most recently useful first, then the rest newest first."""
        from datetime import datetime, timezone
        oldest = datetime.min.replace(tzinfo=timezone.utc)
        ordered = sorted(reversed(terms), key=lambda t: t.used or oldest, reverse=True)
        q = vocab.key(self.query)
        if not q:
            return ordered
        return [t for t in ordered if q in vocab.key(t.word) or any(q in vocab.key(h) for h in t.heard)]

    def _row(self, t) -> Gtk.Widget:
        voc = self.app.vocabulary
        row = ui.hbox(12)
        if self.editing == t.word:
            entry = Gtk.Entry()
            entry.set_text(t.word)
            entry.set_size_request(140, -1)

            def done(*_):
                if self.editing == t.word:
                    self.editing = None
                    voc.rename(t.word, entry.get_text())
                    GLib.idle_add(lambda: self.refresh() and False)
                return False

            def key(_w, event):
                if event.keyval == Gdk.KEY_Escape:
                    self.editing = None
                    GLib.idle_add(lambda: self.refresh() and False)
                    return True
                return False
            entry.connect("activate", done)
            entry.connect("focus-out-event", done)
            entry.connect("key-press-event", key)
            GLib.idle_add(lambda: entry.grab_focus() and False)
            row.pack_start(entry, False, False, 0)
        else:
            b = Gtk.Button()
            lab = ui.text(t.word, 13, "ink", bold=True, wrap=False)
            lab.set_size_request(140, -1)
            b.add(lab)
            ui.classes(b, "quietbtn")
            b.set_tooltip_text(L("点一下改写法"))
            b.connect("clicked", lambda *_: self._edit(t.word))
            row.pack_start(b, False, False, 0)
        forms = ui.Wrap(4)
        for h in t.heard:
            chip = ui.hbox(3, ui.text(h, 11, "secondary", wrap=False, ellipsize=False))
            x = ui.icon_button("window-close-symbolic", L("删掉这个听错的词"),
                               lambda h=h: voc.forget(h, t.word), px=8)
            x.set_size_request(16, 16)
            chip.pack_start(x, False, False, 0)
            forms.add(ui.panel(ui.pad(chip, 1, 2, 1, 6), "heardchip"))
        add = Gtk.Entry()
        add.set_placeholder_text(L("加一个容易听错的词"))
        add.set_width_chars(18)
        add.set_text(self.typing.get(t.word, ""))
        add.connect("changed", lambda e: self.typing.__setitem__(t.word, e.get_text()))
        add.connect("activate", lambda e: self._add_heard(t, e.get_text()))
        forms.add(add)
        row.pack_start(forms, True, True, 0)
        live = t.source == "live"
        row.pack_start(ui.text(L("会中确认") if live else L("你加的"), 11, "accent" if live else "tertiary", wrap=False, ellipsize=False),
                       False, False, 0)
        row.pack_start(ui.text(LF("改过 %lld 次", t.fixes) if t.fixes else L("还没用上"), 11, "tertiary", wrap=False, ellipsize=False),
                       False, False, 0)
        row.pack_start(ui.icon_button("user-trash-symbolic", L("从词表里删掉"), lambda: self._remove(t), px=12), False, False, 0)
        out = ui.vbox(6, row)
        if self.conflict is not None and self.conflict[0] == t.word:
            _w, heard, owner = self.conflict
            c = ui.hbox(10)
            c.pack_start(ui.text(LF("“%@”已经记在 %@ 下", heard, owner), 12, "ink", width_chars=30), True, True, 0)

            def move():
                voc.forget(heard, owner)
                voc.confirm(heard, t.word, t.source)
                self.conflict = None

            def both():
                voc.confirm(heard, t.word, t.source)
                self.conflict = None
            c.pack_end(ui.soft_button(L("两个都留"), both), False, False, 0)
            c.pack_end(ui.soft_button(LF("改给 %@", t.word), move, dark=True), False, False, 0)
            out.pack_start(c, False, False, 0)
        return ui.panel(ui.pad(out, 6, 14), "prow")

    def _edit(self, word) -> None:
        self.editing = word
        self.refresh()

    def _add_heard(self, t, text: str) -> None:
        h = text.strip()
        self.typing.pop(t.word, None)
        if not h or len(h) > 40:
            self.refresh()
            return
        owners = self.app.vocabulary.owners(h, t.word)
        if owners:
            self.conflict = (t.word, h, owners[0])
            self.refresh()
        else:
            self.app.vocabulary.confirm(h, t.word, t.source)

    def _remove(self, t) -> None:
        terms = self.app.vocabulary.snapshot()
        index = next((i for i, x in enumerate(terms) if x.word == t.word), 0)
        self.app.vocabulary.remove(t.word)
        self.deleted = (t, index)
        self._deleted_at += 1
        at = self._deleted_at

        def expire():
            if self._deleted_at == at:
                self.deleted = None
                self.refresh()
            return False
        GLib.timeout_add_seconds(8, expire)
        self.refresh()

    def _undo_delete(self) -> None:
        if self.deleted is not None:
            term, index = self.deleted
            self.deleted = None
            self.app.vocabulary.insert(term, index)
            self.refresh()

    # 粘贴导入

    def _import(self) -> None:
        """Many words at once, one per line, heard forms after "=". The counts follow what is pasted,
        and the button says how many go in."""
        voc = self.app.vocabulary
        top = self.box.get_toplevel()
        d = Gtk.Dialog(transient_for=top if isinstance(top, Gtk.Window) else None, modal=True)
        d.set_title(L("粘贴导入"))
        d.set_default_size(420, -1)
        area = d.get_content_area()
        body = ui.vbox(12)
        ui.pad(body, 20)
        body.pack_start(ui.text(L("粘贴导入"), 15, "heading", bold=True, wrap=False), False, False, 0)
        body.pack_start(ui.text(L("一行一个。常被听错的词，写在 = 后面"), 12, "secondary"), False, False, 0)
        view = Gtk.TextView()
        view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        view.set_left_margin(6)
        view.set_top_margin(4)
        sc = Gtk.ScrolledWindow()
        sc.set_size_request(-1, 180)
        sc.add(view)
        body.pack_start(ui.panel(sc, "boxed"), False, False, 0)
        hint = ui.text("Uniswap V3 · Morpho = 莫拉、莫法 · 巡检", 11, "tertiary", wrap=False)
        body.pack_start(hint, False, False, 0)
        counts = ui.text("", 12, "secondary")
        skipped = ui.text("", 11, "accent")
        body.pack_start(counts, False, False, 0)
        body.pack_start(skipped, False, False, 0)
        buttons = ui.hbox(8)
        cancel = ui.soft_button(L("取消"), lambda: d.destroy())
        go = ui.soft_button(LF("导入 %lld 个", 0), lambda: None, dark=True)
        buttons.pack_end(go, False, False, 0)
        buttons.pack_end(cancel, False, False, 0)
        body.pack_start(buttons, False, False, 0)
        area.pack_start(body, True, True, 0)
        buf = view.get_buffer()
        state = {"done": False}

        def text():
            return buf.get_text(buf.get_start_iter(), buf.get_end_iter(), False)

        def changed(*_):
            if state["done"]:
                return
            p = voc.preview(text())
            ui.retext(counts, LF("新增 %lld · 补充听成 %lld · 跳过 %lld", p.added, p.updated, len(p.skipped)) if text().strip() else "")
            go.set_label(LF("导入 %lld 个", p.added + p.updated))
            go.set_sensitive(p.added + p.updated > 0)
        buf.connect("changed", changed)

        def run_import(*_):
            r = voc.import_text(text())
            state["done"] = True
            buf.set_text("")
            ui.retext(counts, LF("新增 %lld · 补充听成 %lld · 跳过 %lld", r.added, r.updated, len(r.skipped)))
            ui.retext(skipped, LF("第 %@ 行没加进去：超过 40 个字", "、".join(str(n) for n in r.skipped)) if r.skipped else "")
            go.hide()
            cancel.set_label(L("完成"))
        go.connect("clicked", run_import)
        changed()
        d.show_all()
        view.grab_focus()
        self.dialog = d
        self.dialog_view = view
