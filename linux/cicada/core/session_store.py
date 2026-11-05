"""The meeting records: one folder per meeting under Sessions/<yyyyMMdd-HHmmss>/ with session.json,
as on the Mac. Saves are debounced by 1.5 s; a meeting with no lines is removed when it ends.
Thread-safe; listeners fire on whichever thread made the change."""
from __future__ import annotations

import os
import shutil
import threading
from datetime import datetime, timezone

from . import speakers, strings
from .models import Session, now
from .support import Log, Paths, clock


class SessionStore:
    def __init__(self):
        self._gate = threading.RLock()
        self._sessions: dict = {}
        self._dirty: set = set()
        self._timer = None
        self._listeners = []
        self._word_listeners = []
        self.live: str | None = None  # the meeting being listened to (the Mac's liveID)
        self._load()

    def on_change(self, listener) -> None:
        self._listeners.append(listener)

    def on_words(self, listener) -> None:
        """`listener(sid)` the moment recognised words land in a record: a new line (theirs or mine)
        or a half sentence that grew. What 结束会议 counts as someone speaking (MeetingEndWatch.heard)."""
        self._word_listeners.append(listener)

    def _words(self, sid: str) -> None:
        for l in list(getattr(self, "_word_listeners", [])):
            l(sid)

    def _fire(self, sid: str) -> None:
        for l in list(self._listeners):
            l(sid)

    def _folder(self, sid: str) -> str:
        return os.path.join(Paths.sessions(), sid)

    def _load(self) -> None:
        root = Paths.sessions()
        if not os.path.isdir(root):
            return
        for name in os.listdir(root):
            path = os.path.join(root, name, "session.json")
            if not os.path.isfile(path):
                continue
            try:
                with open(path, encoding="utf-8") as f:
                    s = Session.read(f.read())
                if s is not None:
                    self._sessions[s.id] = s
            except (OSError, ValueError) as e:
                Log.d("store: skipped %s: %s" % (name, type(e).__name__))

    def all(self) -> list:
        """Newest first."""
        with self._gate:
            return sorted(self._sessions.values(), key=lambda s: s.startedAt, reverse=True)

    def get(self, sid: str) -> Session | None:
        with self._gate:
            return self._sessions.get(sid)

    def lines(self, sid: str) -> list:
        """A copy of a record's lines, safe to read while listening adds to them."""
        with self._gate:
            s = self._sessions.get(sid)
            return [l.copy() for l in s.lines] if s else []

    def begin(self, at: datetime | None = None) -> Session:
        at = (at or now()).replace(microsecond=0)
        local = at.astimezone()
        sid = local.strftime("%Y%m%d-%H%M%S")
        s = Session(id=sid, title=default_title(at), startedAt=at)
        with self._gate:
            self._sessions[sid] = s
            self.live = sid
        return s

    def append(self, sid: str, line) -> None:
        self._mutate(sid, lambda s: s.lines.append(line))
        self._words(sid)

    def replace(self, sid: str, line) -> None:
        grew = []

        def change(s):
            for i, l in enumerate(s.lines):
                if l.id == line.id:
                    # Whose line it is stays as stored: a joined half sentence keeps the earlier
                    # line's voice, and the user's 这句是谁说的 isn't undone by a retranslation.
                    line.voice = l.voice
                    if len(line.src) > len(l.src):
                        grew.append(True)  # a half sentence joined: new words, not a retranslation
                    s.lines[i] = line
                    return
        self._mutate(sid, change)
        if grew:
            self._words(sid)

    # Voices (说话人识别, SessionStore.swift)

    def set_line_voices(self, sid: str, ids: set, voice: int) -> None:
        """The user says a line (or a paragraph of them) was someone else's: those lines take that voice."""
        def change(s):
            for l in s.lines:
                if l.id in ids and l.speaker == "them":
                    l.voice = voice
        self._mutate(sid, change)

    def voice_snapshot(self, sid: str):
        """Who said what, taken before a speaker edit so 撤销 can put it back."""
        with self._gate:
            s = self._sessions.get(sid)
            if s is None:
                return None
            return ({l.id: l.voice for l in s.lines}, dict(s.voiceNames) if s.voiceNames is not None else None,
                    dict(s.voiceGuesses) if s.voiceGuesses is not None else None)

    def restore(self, sid: str, snap) -> None:
        voices, vnames, guesses = snap

        def change(s):
            for l in s.lines:
                if l.id in voices:  # lines heard since keep the voice they were given
                    l.voice = voices[l.id]
            s.voiceNames, s.voiceGuesses = vnames, guesses
        self._mutate(sid, change)

    def set_voice_name(self, sid: str, voice: int, name) -> None:
        """The user names a voice. None drops their name (Ling's guess shows again); "" keeps 说话人 N."""
        def change(s):
            vn = dict(s.voiceNames or {})
            if name is None:
                vn.pop(str(voice), None)
            else:
                vn[str(voice)] = name.strip()
            s.voiceNames = vn or None
        self._mutate(sid, change)

    def set_voice_guesses(self, sid: str, guesses: dict, refuted: dict | None = None) -> None:
        """Ling's latest guesses; earlier ones stay for voices it no longer mentions, unless it now named
        them without evidence (refuted, voice → name): then that earlier name goes too."""
        refuted = refuted or {}
        if not guesses and not refuted:
            return

        def change(s):
            allg = dict(s.voiceGuesses or {})
            for v, name in refuted.items():
                if v not in guesses and allg.get(str(v)) is not None and allg[str(v)].name == name:
                    del allg[str(v)]
            for v, g in guesses.items():
                allg[str(v)] = g
            s.voiceGuesses = allg or None
        self._mutate(sid, change)

    def merge_voice(self, sid: str, frm: int, into: int) -> None:
        """The user said two voices are the same person: `frm`'s lines become `into`'s."""
        if frm == into:
            return

        def change(s):
            for l in s.lines:
                if l.voice == frm:
                    l.voice = into
            if s.voiceNames is not None and str(frm) in s.voiceNames:
                vn = dict(s.voiceNames)
                moved = vn.pop(str(frm))
                # A turned-down guess ("") stays with the voice it was about; a real name moves over.
                if str(into) not in vn and moved:
                    vn[str(into)] = moved
                s.voiceNames = vn or None
            if s.voiceGuesses is not None and str(frm) in s.voiceGuesses:
                vg = dict(s.voiceGuesses)
                moved = vg.pop(str(frm))
                if str(into) not in vg:
                    vg[str(into)] = moved
                s.voiceGuesses = vg or None
        self._mutate(sid, change)

    def set_notes(self, sid: str, notes) -> None:
        self._mutate(sid, lambda s: setattr(s, "notes", notes))

    def rename(self, sid: str, title: str) -> None:
        """As on the Mac: the shown title unchanged is no rename (the notes may still name it later),
        and an empty one goes back to the automatic title (恢复自动标题)."""
        t = title.strip()
        with self._gate:
            s = self._sessions.get(sid)
            if s is None or t == display_title(s):
                return

        def change(s):
            if t:
                s.title, s.renamed = t, True
            else:
                s.title, s.renamed = default_title(s.startedAt), False
        self._mutate(sid, change)

    def end(self, sid: str, ended_at=None) -> None:
        """The meeting ended (at `ended_at` when it ended by itself a while ago): kept if anything was
        said, removed otherwise."""
        with self._gate:
            s = self._sessions.get(sid)
            if self.live == sid:
                self.live = None
            if s is None:
                return
            s.endedAt = max(ended_at, s.startedAt) if ended_at is not None else now()
            empty = not s.lines
        if empty:
            self.delete(sid)
        else:
            self._mark_dirty(sid)
            self.flush()
            self._fire(sid)

    def delete(self, sid: str) -> None:
        """Never the live meeting (`live` is its id): listening would go on into a record that's gone."""
        with self._gate:
            if sid == self.live:
                Log.d("store: not deleting the live meeting %s" % sid)
                return
            self._sessions.pop(sid, None)
            self._dirty.discard(sid)
        shutil.rmtree(self._folder(sid), ignore_errors=True)
        self._fire(sid)

    def import_session(self, s: Session) -> None:
        """A record from elsewhere (a Mac's session.json): added as it is, saved now."""
        with self._gate:
            self._sessions[s.id] = s
        self._mark_dirty(s.id)
        self.flush()
        self._fire(s.id)

    def _mutate(self, sid: str, change) -> None:
        with self._gate:
            s = self._sessions.get(sid)
            if s is None:
                return
            change(s)
        self._mark_dirty(sid)
        self._fire(sid)

    def _mark_dirty(self, sid: str) -> None:
        with self._gate:
            self._dirty.add(sid)
            if self._timer:
                self._timer.cancel()
            self._timer = threading.Timer(1.5, self.flush)
            self._timer.daemon = True
            self._timer.start()

    def flush(self) -> None:
        """Writes every changed record now."""
        with self._gate:
            writes = [(sid, self._sessions[sid].write()) for sid in self._dirty if sid in self._sessions]
            self._dirty.clear()
        for sid, text in writes:
            try:
                folder = self._folder(sid)
                os.makedirs(folder, exist_ok=True)
                tmp = os.path.join(folder, "session.json.tmp")
                with open(tmp, "w", encoding="utf-8") as f:
                    f.write(text)
                os.replace(tmp, os.path.join(folder, "session.json"))
            except OSError as e:
                Log.d("store: save failed %s" % type(e).__name__)


def default_title(at: datetime) -> str:
    """The stored default title is always Chinese ("会议 11月1日 14:30"), as on the Mac; the UI shows
    display_title instead."""
    l = at.astimezone()
    return "会议 %d月%d日 %02d:%02d" % (l.month, l.day, l.hour, l.minute)


def _local_date(at: datetime, pattern: str) -> str:
    """The Mac's date patterns the strings tables carry ("M月d日 HH:mm", "MMM d", "yyyy年M月d日")."""
    l = at.astimezone()
    months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    out = []
    i = 0
    while i < len(pattern):
        c = pattern[i]
        j = i
        while j < len(pattern) and pattern[j] == c:
            j += 1
        run = j - i
        if c == "'":
            k = pattern.find("'", i + 1)
            out.append(pattern[i + 1:k if k > 0 else len(pattern)])
            i = (k + 1) if k > 0 else len(pattern)
            continue
        if c == "y":
            out.append(str(l.year))
        elif c == "M":
            out.append(months[l.month - 1] if run >= 3 else ("%02d" % l.month if run == 2 else str(l.month)))
        elif c == "d":
            out.append("%02d" % l.day if run == 2 else str(l.day))
        elif c == "H":
            out.append("%02d" % l.hour if run == 2 else str(l.hour))
        elif c == "m":
            out.append("%02d" % l.minute)
        else:
            out.append(pattern[i:j])
        i = j
    return "".join(out)


def display_title(s: Session) -> str:
    """The user's own title, else the date and the name the notes gave the meeting, else the default
    title in the UI language (Session.displayTitle)."""
    renamed = s.renamed if s.renamed is not None else not s.title.startswith("会议 ")
    if renamed:
        return s.title
    name = s.notes.title if s.notes else None
    if not name:
        # An imported file is known by its name until the notes give it one.
        if s.sourceFile:
            return os.path.splitext(s.sourceFile)[0]
        return strings.L("会议") + " " + _local_date(s.startedAt, strings.L("M月d日 HH:mm"))
    this_year = s.startedAt.astimezone().year == datetime.now().year
    return _local_date(s.startedAt, strings.L("M月d日" if this_year else "yyyy年M月d日")) + " " + name


# The Mac's dateText(_, "yMMMdHHmm"), as its DateFormatter writes it in each UI language.
_DATE_TIME = {"zh-Hans": "y年M月d日 HH:mm", "en": "MMM d, y 'at' HH:mm", "ja": "y年M月d日 H:mm", "ko": "y년 M월 d일 HH:mm"}


def header(s: Session) -> str:
    """"2026年11月4日 12:30 · 24 分钟" (TranscriptExport.header)."""
    mins = int(s.duration // 60)
    when = _local_date(s.startedAt, _DATE_TIME.get(strings.language, _DATE_TIME["zh-Hans"]))
    return when + " · " + (strings.L("不到 1 分钟") if mins < 1 else strings.LF("%lld 分钟", mins))


def notes_markdown(n) -> str:
    """The notes as Markdown, empty when there are none (TranscriptExport.notesMarkdown)."""
    L = strings.L
    if n is None or n.is_empty:
        return ""
    b = ["## %s\n\n%s\n\n" % (L("纪要"), n.summary)]
    for t in n.topics:
        b.append("### %s %s\n\n" % (clock(t.start), t.title))
        if t.summary:
            b.append(t.summary + "\n\n")
        for p in t.points:
            b.append("- %s\n" % p)
        if t.fishbone is not None:
            b.append("\n**%s**\n\n" % t.fishbone.question)
            for br in t.fishbone.branches:
                b.append("- %s：%s\n" % (br.label, br.detail))
        b.append("\n")
    if n.conclusions:
        b.append("### %s\n\n" % L("结论") + "".join("- %s\n" % c.text for c in n.conclusions) + "\n")
    if n.todos:
        b.append("### %s\n\n" % L("待办") + "".join("- [ ] %s%s\n" % (t.text, "（%s）" % t.owner if t.owner else "") for t in n.todos) + "\n")
    if n.terms:
        b.append("### %s\n\n" % L("人名和术语") + "".join("- **%s** %s\n" % (t.name, t.note) for t in n.terms) + "\n")
    return "".join(b)


def markdown(s: Session, voices: bool = False) -> str:
    """The record as Markdown, the Mac's export line for line (TranscriptExport.markdown): title, date
    · length, the notes, then each line as **[mm:ss] who** with the translation quoted under it."""
    nums = speakers.numbers(s.lines) if voices else {}
    shown = speakers.names(s) if nums else {}
    out = ["# %s\n\n%s\n\n" % (display_title(s), header(s))]
    # Names given since Ling wrote "说话人 6" show in the notes too, as in the window.
    notes = notes_markdown(speakers.named(s.notes, shown))
    if notes:
        out.append(notes + "## %s\n\n" % strings.L("文字记录"))
    for l in s.lines:
        # An imported file has no "other side" to name.
        who = (" " + speakers.speaker_name(l, nums, shown)) if s.sourceFile is None else ""
        out.append("**[%s]%s**  \n%s\n" % (clock(l.t), who, l.src))
        if l.dst and l.dst != l.src:
            out.append("> %s\n" % l.dst)
        out.append("\n")
    return "".join(out)
