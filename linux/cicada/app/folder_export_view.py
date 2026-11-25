"""存到文件夹 on screen (the Mac's FolderExportViews.swift): 设置 › 会后存一份's card, the 存到哪里 dialog
and the record's line under its title. The work is core/folder_export.py's.

Linux has no privacy prompt (the .deb isn't sandboxed): a folder Cicada can't write is its
permissions, so the Mac's 去系统设置 and "macOS 可能会问…" have no counterpart here."""
from __future__ import annotations

import os

from gi.repository import Gio, GLib, Gtk, Pango

from ..core import folder_export as fx
from ..core import session_store
from ..core.strings import L, LF
from . import ui


def open_folder(path: str) -> None:
    """Never creates it: under a drive that isn't mounted that would be a stray folder."""
    if not os.path.isdir(path):
        return
    try:
        Gio.AppInfo.launch_default_for_uri(Gio.File.new_for_path(path).get_uri(), None)
    except GLib.Error:
        pass


def documents_dir() -> str:
    """GLib's XDG documents folder; unset, it answers the home folder: then xdg-user-dir, ~/Documents."""
    d = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DOCUMENTS)
    if d and os.path.normpath(d) != os.path.normpath(os.path.expanduser("~")):
        return d
    return fx.documents_dir()


class FolderExportCard:
    """设置 › 会后存一份. Rebuilt from a state key (as WordList is), so the window's show_all never brings
    back a row that shouldn't show."""

    def __init__(self, app, group, window):
        self.app = app
        self.window = window
        self.box = ui.vbox(8)
        self._key = None
        self.widget = group(L("会后存一份"), self.box)
        self.refresh()
        # Opened again: a vault opened in Obsidian since may now hold the folder.
        window.connect("show", lambda *_: (setattr(self, "_vault_for", None), self.refresh()))

    def refresh(self) -> None:
        ex = self.app.folder_export
        folder = ex.folder
        idx = ex.index
        unwritten = len(ex.unwritten()) if ex.on else 0
        key = (ex.on, folder, ex.checking, ex.problem, ex.problem_message, len(idx.pending), unwritten,
               idx.lastFile, idx.lastAt, bool(folder) and os.path.isdir(folder), self._vault(folder))
        if key == self._key:
            return
        self._key = key
        ui.clear(self.box)
        sw = Gtk.Switch()
        sw.set_valign(Gtk.Align.CENTER)
        sw.set_active(ex.on)
        sw.connect("notify::active", self._toggled)  # after set_active: only the user's clicks
        rows = [ui.prow(L("存到文件夹"), sw, L("纪要和文字记录存成 Markdown；文件夹同步到哪，内容就到哪"))]
        if ex.on and folder:
            short = fx.short_path(folder)
            if ex.checking:
                spin = Gtk.Spinner()
                spin.start()
                rows.append(ui.panel(ui.pad(ui.hbox(8, spin, ui.text(LF("正在确认能写入 %@…", short), 12, "secondary", wrap=False)), 12, 14), "prow"))
            elif ex.problem is not None:
                rows.append(ui.panel(ui.pad(self._problem(ex, short), 8, 10), "prow"))
            controls = ui.hbox(8)
            if key[-1]:
                tag = ui.text(L("Obsidian 库"), 11, "", wrap=False, ellipsize=False)
                ui.pad(tag, 1, 6)  # a margin: GTK 3 ignores CSS padding on an EventBox
                t = ui.panel(tag, "foldertag")
                t.set_valign(Gtk.Align.CENTER)
                controls.pack_start(t, False, False, 0)
            opener = ui.soft_button(L("打开"), lambda: open_folder(folder))
            opener.set_sensitive(key[-2])  # nothing to open while the folder is gone
            controls.pack_start(opener, False, False, 0)
            controls.pack_start(ui.soft_button(L("更改…"), self._choose), False, False, 0)
            sub = ui.text(short, 11, "tertiary", wrap=False)
            sub.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
            sub.set_tooltip_text(folder)
            rows.append(ui.prow(L("位置"), controls, subtitle_widget=sub))
            if unwritten > 0:
                rows.append(ui.prow(L("以前的会议"), ui.soft_button(L("也存一份"), ex.write_all), LF("还有 %lld 场没存", unwritten)))
        self.box.pack_start(ui.boxed(rows), False, False, 0)
        if ex.on and idx.lastFile and idx.lastAt:
            when = session_store._local_date(idx.lastAt, L("M月d日 HH:mm"))
            last = ui.text(LF("上次存于 %@ · %@", when, idx.lastFile), 12, "tertiary", wrap=False)
            last.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
            self.box.pack_start(ui.pad(last, 0, 0, 0, 4), False, False, 0)
        self.box.show_all()

    def _vault(self, folder):
        """Obsidian 库 or not, read once per folder: refresh runs on every change, meetings included."""
        if not folder:
            return None
        if getattr(self, "_vault_for", None) != folder:
            self._vault_for, self._vault_is = folder, fx.vault_of(folder)
        return self._vault_is

    def _problem(self, ex, short: str) -> Gtk.Widget:
        waiting = len(ex.index.pending)
        if ex.problem == fx.DENIED:
            title = LF("没有权限写入 %@", short)
            # Linux asks no one: the folder's own permissions are what to change.
            detail = LF("%lld 场会议没存上，允许后自动补存", waiting) if waiting else L("改一下这个文件夹的权限，或换个文件夹")
        elif ex.problem == fx.MISSING:
            title, detail = LF("找不到 %@", short), L("接上或换个文件夹后自动补存")
        else:
            title, detail = L("没存上"), ex.problem_message
        box = ui.vbox(2, ui.text(title, 13, "ink", bold=True, width_chars=50), ui.text(detail, 12, "secondary", width_chars=50))
        return ui.panel(ui.pad(box, 10, 12), "folderproblem", "denied" if ex.problem == fx.DENIED else "")

    def _toggled(self, sw, _p) -> None:
        ex = self.app.folder_export
        if not sw.get_active():
            ex.turn_off()
        elif ex.folder:
            ex.choose(ex.folder)
        else:
            # Not inside the switch's own signal: the dialog's refresh replaces the switch.
            GLib.idle_add(lambda: self._choose() and False)

    def _choose(self) -> None:
        picked = choose_folder(self.window, self.app.folder_export.folder)
        if picked:
            self.app.folder_export.choose(picked)
        else:
            self._key = None  # the switch flipped on for a dialog that was cancelled: back off
            self.refresh()


def choose_folder(parent, current: str | None) -> str | None:
    """存到哪里: an Obsidian vault first (a new Cicada folder in it), then Documents › Cicada, or any
    folder through the system's folder dialog."""
    options = [(LF("Obsidian 库「%@」", os.path.basename(v)), L("在库里新建 Cicada 文件夹"), os.path.join(v, "Cicada"))
               for v in fx.all_vaults()[:3]]
    docs = documents_dir()
    options.append((os.path.basename(docs) + " › Cicada", None, os.path.join(docs, "Cicada")))
    options.append((L("其他文件夹…"), None, None))
    d = Gtk.Dialog(transient_for=parent, modal=True)
    d.set_title(L("存到哪里"))
    d.set_resizable(False)
    # The app's flat bar with only ×, not Yaru's dark one repeating the heading (the Mac's is a sheet).
    bar = Gtk.HeaderBar()
    bar.set_show_close_button(True)
    bar.set_decoration_layout(":close")
    bar.set_custom_title(Gtk.Box())  # the heading below says it once
    ui.classes(bar, "cicada")
    d.set_titlebar(bar)
    ui.classes(d, "sheet")
    area = d.get_content_area()
    ui.classes(area, "sheet")
    body = ui.vbox(14, ui.text(L("存到哪里"), 15, "heading", bold=True, wrap=False))
    ui.pad(body, 0, 20, 20, 20)  # the bar above is the top margin
    body.set_size_request(380, -1)
    picks = ui.vbox(8)
    body.pack_start(picks, False, False, 0)
    state = {"pick": 0}
    buttons = []

    def draw():
        for i, (b, title, mark) in enumerate(buttons):
            on = i == state["pick"]
            ui.classes(b, "picked") if on else b.get_style_context().remove_class("picked")
            mark.set_from_icon_name("radio-checked-symbolic" if on else "radio-symbolic", Gtk.IconSize.BUTTON)
            title.cicada_format = (13, title.cicada_format[1], on)
            ui.retext(title, options[i][0])
    for i, (title, detail, _path) in enumerate(options):
        b = Gtk.Button()
        b.set_can_focus(False)
        ui.classes(b, "folderoption")
        mark = ui.icon("radio-symbolic", 13)
        mark.set_valign(Gtk.Align.START)
        t = ui.text(title, 13, "ink", wrap=False)
        col = ui.vbox(2, t)
        if detail:
            col.pack_start(ui.text(detail, 12, "secondary", wrap=False), False, False, 0)
        row = ui.hbox(10, mark, col)
        b.add(ui.pad(row, 10, 12))
        b.connect("clicked", lambda _b, i=i: (state.update(pick=i), draw()))
        buttons.append((b, t, mark))
        picks.pack_start(b, False, False, 0)
    draw()
    actions = ui.hbox(8)
    actions.set_halign(Gtk.Align.END)
    actions.pack_start(ui.soft_button(L("取消"), lambda: d.response(Gtk.ResponseType.CANCEL)), False, False, 0)
    actions.pack_start(ui.soft_button(L("存到这里"), lambda: d.response(Gtk.ResponseType.OK), dark=True), False, False, 0)
    body.pack_start(actions, False, False, 0)
    area.add(body)
    d.show_all()
    ok = d.run() == Gtk.ResponseType.OK
    d.destroy()
    if not ok:
        return None
    path = options[state["pick"]][2]
    if path:
        return path
    chooser = Gtk.FileChooserDialog(title=L("会后把纪要和文字记录存成 Markdown 到这里"), transient_for=parent,
                                    action=Gtk.FileChooserAction.SELECT_FOLDER)
    chooser.add_buttons(L("取消"), Gtk.ResponseType.CANCEL, L("存到这里"), Gtk.ResponseType.ACCEPT)
    chooser.set_create_folders(True)
    start = current if current and os.path.isdir(current) else docs if os.path.isdir(docs) else os.path.expanduser("~")
    chooser.set_current_folder(start)
    path = chooser.get_filename() if chooser.run() == Gtk.ResponseType.ACCEPT else None
    chooser.destroy()
    return path


def line_key(app, s):
    """What the record's line says, so it is rebuilt only when that changes."""
    ex = app.folder_export
    if not (ex.on and ex.folder and ex.ready(s)):
        return None
    pending = ex.is_pending(s.id)
    return (ex.folder, ex.file(s.id), pending, pending and ex.problem is not None)


def record_line(app, s, show_in_folder):
    """Under the record's title: where its file is, or why it isn't there yet. None: nothing to say."""
    key = line_key(app, s)
    if key is None:
        return None
    folder, path, pending, problem = key
    short = fx.short_path(folder)
    row = ui.hbox(4)

    def link(label, action):
        b = Gtk.Button()
        b.add(ui.text(label, 12, "link", wrap=False, ellipsize=False))
        b.set_relief(Gtk.ReliefStyle.NONE)
        ui.classes(b, "timelink")
        b.connect("clicked", lambda *_: action())
        return b

    def folder_icon():
        i = ui.icon("folder-symbolic", 11)
        ui.classes(i, "tertiary")
        return i
    if path and not pending:
        row.pack_start(folder_icon(), False, False, 0)
        row.pack_start(ui.text(LF("已存到 %@ ·", short), 12, "tertiary", wrap=False, ellipsize=False), False, False, 0)
        row.pack_start(link(L("在文件夹中显示"), lambda: show_in_folder(path)), False, False, 0)
    elif pending and problem:
        row.pack_start(ui.text(L("没存到文件夹 ·"), 12, "tertiary", wrap=False, ellipsize=False), False, False, 0)
        row.pack_start(link(L("去设置"), lambda: app.show_settings(general=True)), False, False, 0)
    elif pending:
        row.pack_start(folder_icon(), False, False, 0)
        row.pack_start(ui.text(LF("整理好后存到 %@", short), 12, "tertiary", wrap=False, ellipsize=False), False, False, 0)
    else:
        return None
    return row
