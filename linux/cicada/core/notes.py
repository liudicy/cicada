"""Keeps the live meeting's notes up to date: every ~45 s with new speech, one Ling call sends the
current notes plus the new lines and gets the whole notes back as JSON; a final pass rewrites them
over the whole transcript when the meeting ends. A failed or odd reply never replaces good notes.
The prompt and parsing are the Mac's (Notes.swift, via the Windows and Android ports), so every
platform writes the same notes."""
from __future__ import annotations

import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from . import jsonfmt, speakers
from .jsonfmt import arr, num, obj
from .ling import NOTES, LingError
from .models import Fishbone, FishboneBranch, MeetingNotes, NoteItem, NoteTerm, NoteTopic, now
from .support import Log, clock, written_in

INTERVAL = 45.0
IDLE, UPDATING, NO_KEY, INVALID_KEY, RATE_LIMITED, FAILED = "idle", "updating", "noKey", "invalidKey", "rateLimited", "failed"


class NotesEngine:
    def __init__(self, ling, store):
        self.ling = ling
        self.store = store
        self.voices = lambda: False  # 说话人识别 on: lines go as 说话人N or the name given (set by the app)
        self._gate = threading.RLock()
        self._work = ThreadPoolExecutor(max_workers=1, thread_name_prefix="NotesWork")
        self._ticker = None
        self._session_id = None
        self._in_flight = False
        self._pending_final = None
        self._pending_fresh = None
        self._last_attempt = 0.0
        self._listeners = []
        self.notes = MeetingNotes()
        self.status = IDLE
        self.shown_id = None  # the session the notes belong to (stays set after the meeting ends)
        self.language = lambda sid: "Simplified Chinese"  # a meeting's notes language (English name), from 纪要语言
        self.working_id = None  # the record being written now, for a "正在整理纪要…" next to it

    def on_change(self, listener) -> None:
        self._listeners.append(listener)

    def _changed(self) -> None:
        for l in list(self._listeners):
            l()

    def glossary(self) -> list:
        """Names for the translation glossary: "江充 (note; misheard as 江松, 江冲)"."""
        out = []
        for t in self.notes.terms[:30]:
            out.append("%s (%s)" % (t.name, t.note) if not t.heard else "%s (%s; misheard as %s)" % (t.name, t.note, ", ".join(t.heard)))
        return out

    def begin(self, sid: str) -> None:
        with self._gate:
            self._session_id = sid
            self.shown_id = sid
            s = self.store.get(sid)
            self.notes = (s.notes if s else None) or MeetingNotes()
            self.status = IDLE if self.ling.has_key else NO_KEY
            self._last_attempt = time.time()
            self._stop_ticker()
            stop = threading.Event()

            def loop():
                while not stop.wait(5.0):
                    self._tick()
            self._ticker = stop
            threading.Thread(target=loop, name="Notes", daemon=True).start()
        self._changed()

    def _stop_ticker(self) -> None:
        if self._ticker is not None:
            self._ticker.set()
            self._ticker = None

    def finish(self) -> None:
        """The meeting ended: one last pass over the whole transcript. Blocks until it's written."""
        with self._gate:
            self._stop_ticker()
            sid = self._session_id
            self._session_id = None
        if sid is not None:
            self._update(sid, final=True)

    def show(self, sid: str) -> None:
        with self._gate:
            self.shown_id = sid
            s = self.store.get(sid)
            self.notes = (s.notes if s else None) or MeetingNotes()
        self._changed()

    def rewrite(self) -> None:
        """The live meeting's notes again from its first line (纪要语言 changed): the Mac's rewrite."""
        with self._gate:
            sid = self._session_id
        if sid is not None:
            self._work.submit(self._update, sid, False, True)

    def generate(self, sid: str) -> None:
        """Notes for a finished meeting that has none (runs in the background)."""
        self._work.submit(self._update, sid, True)

    def _tick(self) -> None:
        with self._gate:
            if self.status == NO_KEY and self.ling.usable:
                self.status = IDLE
            sid = self._session_id
            if sid is None or self._in_flight:
                return
            s = self.store.get(sid)
            if s is None or len(s.lines) <= self.notes.covered:
                return
            since = time.time() - self._last_attempt
            # First notes as soon as there is something to say, then every 45 s.
            due = (len(s.lines) >= 3 or since > 20) if self.notes.is_empty else since >= INTERVAL
            if not due:
                return
        self._work.submit(self._update, sid, False)

    def _update(self, sid: str, final: bool, fresh: bool = False) -> None:
        with self._gate:
            if self._in_flight:
                if final:
                    self._pending_final = sid
                elif fresh:
                    self._pending_fresh = sid  # after the round in the old language
                return
            session = self.store.get(sid)
            if session is None or not session.lines:
                return
            if not self.ling.has_key:
                self.status = NO_KEY
                self._changed()
                return
            self._in_flight = True
            self.working_id = sid
            self._last_attempt = time.time()
            self.status = UPDATING
            base = MeetingNotes() if final or fresh else (self.notes if sid == self.shown_id else (session.notes or MeetingNotes()))
        self._changed()
        try:
            lines = self.store.lines(sid)
            frm = 0 if final else min(base.covered, len(lines))
            lang = self.language(sid)
            shown = speakers.names(session) if self.voices() else {}
            p = prompt(base, lines, frm, lang, final, shown, self.voices())
            nxt = None
            for attempt in range(1, 3 if final else 2):
                raw = self.ling.chat(p, "Update the notes. Write them in %s." % lang, NOTES, json=True, max_tokens=6000, timeout=90.0)
                parsed = parse(raw, [l.t for l in lines], lines[0].t if lines else 0.0)
                if parsed is None:
                    break
                if written(parsed, lang):
                    nxt = parsed
                    break
                Log.d("notes: %s reply not in %s (attempt %d), dropped" % ("final" if final else "live", lang, attempt))
            if nxt is None:
                Log.d("notes: no usable reply, kept the previous notes")
                self.status = FAILED
                return
            carry_times(base, nxt)
            nxt.title = nxt.title or base.title or (session.notes.title if session.notes else None)
            nxt.covered = len(lines)
            nxt.updatedAt = now()
            nxt.final = final
            with self._gate:
                if sid == self.shown_id:
                    self.notes = nxt
            self.store.set_notes(sid, nxt)
            self.status = IDLE
            Log.d("notes: %s update %d new lines -> %d topics, %d terms" % (
                "final" if final else "live", len(lines) - frm, len(nxt.topics), len(nxt.terms)))
        except LingError as e:
            self.status = {LingError.INVALID_KEY: INVALID_KEY, LingError.RATE_LIMITED: RATE_LIMITED,
                           LingError.NO_KEY: NO_KEY}.get(e.kind, FAILED)
            Log.d("notes: update failed %s" % e)
        except Exception as e:  # noqa: BLE001
            self.status = FAILED
            Log.d("notes: update failed %s" % type(e).__name__)
        finally:
            with self._gate:
                self._in_flight = False
                self.working_id = None
                queued, again = self._pending_final, self._pending_fresh
                self._pending_final = self._pending_fresh = None
            self._changed()
            if queued is not None:
                self._update(queued, final=True)
            elif again is not None:
                self._update(again, final=False, fresh=True)


def _min(a, b):
    return b if a is None else a if b is None else min(a, b)


def carry_times(old: MeetingNotes, nxt: MeetingNotes) -> None:
    """The model echoes points it already had without evidence: keep the times they had, and a point
    keeps the time it was first heard."""
    known = {}
    for t in old.topics:
        for i, p in enumerate(t.points):
            pt = t.point_time(i)
            if pt is not None:
                known.setdefault(p, pt)
    for t in nxt.topics:
        times = [_min(t.point_time(i), known.get(p)) for i, p in enumerate(t.points)]
        t.pointTimes = times if any(x is not None for x in times) else None
    items = {}
    for i in old.conclusions + old.todos:
        if i.t is not None:
            items.setdefault(i.text, i.t)
    for i in nxt.conclusions + nxt.todos:
        i.t = _min(i.t, items.get(i.text))


def written(notes: MeetingNotes, language: str) -> bool:
    return written_in(notes.summary + "".join(t.title for t in notes.topics), language)


# Prompt (Notes.swift › prompt, word for word)

def prompt(notes: MeetingNotes, lines: list, frm: int, language: str, final: bool, names: dict | None = None,
           voices: bool = False) -> str:
    nums = speakers.numbers(lines) if voices else {}
    names = names or {}

    def line(i):
        l = lines[i]
        # A named voice goes as its name: notes then say "George" rather than "说话人2".
        who = "你" if l.speaker == "me" else (
            (names.get(nums[l.id]) or "说话人%d" % nums[l.id]) if l.id in nums else ("对方" if not nums else "未识别"))
        return "[L%d %s %s] %s" % (i + 1, clock(l.t), who, l.src)
    current = "{}" if notes.is_empty else _compact_json(notes)
    context = max(0, frm - 2)
    p = ("You keep notes for a meeting %s.\n" % ("that has just ended. Rewrite them from the whole transcript" if final
                                               else "that is still going on. Update them with the new lines") +
         "Write the notes in %s. Return JSON only.\n" % language)
    if not final:
        p += "Current notes (JSON):\n%s\n\n" % current
    if context < frm:
        p += "Already covered (context only):\n" + "\n".join(line(i) for i in range(context, frm)) + "\n\n"
    p += ("%s (id, mm:ss, speaker 对方=the other side / 你=me / a name or 说话人N=one person on the other side, told apart by voice and possibly wrong / 未识别=someone on the other side not identified, text). Speech recognition makes mistakes, often in names: correct them from context, and write a public figure's name as the news spells it.\n"
          % ("Transcript" if final else "New lines"))
    p += "\n".join(line(i) for i in range(frm, len(lines)))
    if final and lines:
        span = lines[-1].t - lines[0].t
        most = max(1, min(8, int(span / 180) + 1))
        p += "\n\nThis meeting ran %s: use at most %d topic%s." % (clock(span), most, "" if most == 1 else "s")
    elif not final and notes.topics and lines and lines[-1].t - notes.topics[-1].start < 120:
        topic = notes.topics[-1]
        p += ("\n\nThe current topic \"%s\" started at %s, under 2 minutes ago: do not start a new topic in this update; add the new lines to it."
              % (topic.title, clock(topic.start)))
    elif not final and not notes.topics:
        p += "\n\nThese are the first lines: make one topic."
    p += ("\n\nReturn the full notes as one JSON object with exactly these keys:\n"
          "{\"title\": \"the meeting's name: what it is about, a few words\",\n"
          " \"summary\": \"2-3 sentences on the whole meeting so far\",\n"
          " \"topics\": [{\"start\": seconds, \"title\": \"short title\", \"summary\": \"one sentence\", \"points\": [{\"text\": \"key point\", \"evidence\": [\"L4\"]}], \"evidence\": [\"L3\"],\n"
          "             \"fishbone\": null or {\"question\": \"the problem or question\", \"branches\": [{\"label\": \"2-6 words\", \"detail\": \"one short line\", \"t\": seconds, \"evidence\": [\"L5\"]}]}}],\n"
          " \"conclusions\": [{\"text\": \"...\", \"evidence\": [\"L7\", \"L8\"]}],\n"
          " \"todos\": [{\"text\": \"...\", \"owner\": %s, \"evidence\": [\"L9\"]}],\n"
          " \"terms\": [{\"name\": \"correct spelling\", \"note\": \"who or what, a few words\", \"heard\": [\"how it was misrecognised\"]}]}\n"
          "Rules (be brief: these notes are read at a glance during the meeting):\n"
          "- title: a name for the whole meeting, like a calendar entry (at most 12 Chinese characters or 6 words; no date, no quotes, not \"会议\" alone). Keep the current title unless the meeting's subject has clearly changed.\n"
          "- summary: at most 3 short sentences.\n"
          "- Topics in time order, at most 8 in total. A topic is a stretch of the meeting, usually 3-10 minutes, not a single remark: start a new one only when the subject clearly changes and the current topic started at least 2 minutes before the newest line%s. Otherwise add to the current one, and merge small neighbouring topics. Keep earlier topics as they are unless new lines correct them. The last topic is the one being discussed now.\n"
          "- At most 4 points per topic, each one short phrase. Merge rather than repeat.\n"
          "- At most 5 conclusions and only real to-dos (often none).\n"
          "- Add a fishbone only to a topic that discusses causes, reasons or factors (3-5 branches); otherwise null.\n"
          "- Every topic, point, branch, conclusion and to-do needs evidence: the ids of the lines that say it. Never state anything the transcript does not say.\n"
          "- terms: at most 10 in total, replacing less useful ones rather than adding: first names the transcript misspells (heard), then the people, places and jargon a reader would not know. Leave out what everyone knows (a famous company, index or politician) unless it was misheard. name is the correct spelling in the transcript's language (no translation in brackets); heard lists only the wrong forms the transcript used; note is a few words.\n"
          "- Write the meeting title and every summary, title, point, branch, conclusion and to-do in %s, even when the transcript is in another language. Only term names keep the transcript's spelling.\n"
          "- Write about what was said, never about the transcript or recognition quality.\n"
          "- Use empty arrays when there is nothing. No markdown, no text outside the JSON."
          % ('"对方" or "你" or null' if not nums else
             'the person\'s label from the transcript (a name like "George", or "说话人2"), "你", or null when unclear',
             "" if final else "; add at most one new topic per update", language))
    return p


def _compact_json(n: MeetingNotes) -> str:
    """The current notes as sent back to the model (no bookkeeping fields). Insertion order, like the
    Kotlin LinkedHashMap; jsonfmt sorts keys, which the model doesn't mind."""
    o = {}
    if n.title is not None:
        o["title"] = n.title
    o["summary"] = n.summary
    o["topics"] = [{"start": t.start, "title": t.title, "summary": t.summary, "points": list(t.points),
                    "fishbone": t.fishbone.to_json() if t.fishbone else None} for t in n.topics]
    o["conclusions"] = [c.text for c in n.conclusions]
    o["todos"] = [t.text for t in n.todos]
    o["terms"] = [t.to_json() for t in n.terms]
    return jsonfmt.write(o, pretty=False)


# Parse

def parse(raw: str, times: list, started_at: float) -> MeetingNotes | None:
    """Lenient: missing keys become empty, evidence ids are checked against the transcript."""
    a = raw.find("{")
    b = raw.rfind("}")
    if a < 0 or b <= a:
        return None
    root = jsonfmt.parse_object(raw[a:b + 1])
    if root is None:
        return None

    def s(v):
        return v.strip() if isinstance(v, str) else ""

    def line_numbers(v):
        out = set()
        for i in arr(v):
            m = re.search(r"\d+", s(i))
            if m:
                n = int(m.group())
                if 1 <= n <= len(times):
                    out.add(n)
        return out

    def time_of(v):
        ns = line_numbers(v)
        return times[min(ns) - 1] if ns else None

    def objects(v):
        return [x for x in arr(v) if isinstance(x, dict)]

    n = MeetingNotes(summary=s(root.get("summary")))
    title = s(root.get("title")).strip("\"“”「」《》")
    n.title = title or None
    for t in objects(root.get("topics")):
        topic_title = s(t.get("title"))
        if not topic_title:
            continue
        fish = None
        f = obj(t.get("fishbone"))
        if f is not None:
            branches = [FishboneBranch(label=s(br.get("label")), detail=s(br.get("detail")), t=num(br.get("t")),
                                       support=len(line_numbers(br.get("evidence")))) for br in objects(f.get("branches"))]
            branches = [x for x in branches if x.label]
            if len(branches) >= 2:
                fish = Fishbone(s(f.get("question")), branches)
        points, point_times = [], []
        for p in arr(t.get("points")):
            po = obj(p)
            text = s(po.get("text")) if po is not None else s(p)
            if not text:
                continue
            points.append(text)
            point_times.append(time_of(po.get("evidence")) if po is not None else None)
        start = num(t.get("start"))
        n.topics.append(NoteTopic(start=started_at if start is None else start, title=topic_title, summary=s(t.get("summary")),
                                  points=points, pointTimes=point_times if any(x is not None for x in point_times) else None,
                                  fishbone=fish))

    def items(key):
        out = [NoteItem(text=s(i.get("text")), owner=s(i.get("owner")) or None, support=len(line_numbers(i.get("evidence"))),
                        t=time_of(i.get("evidence"))) for i in objects(root.get(key))]
        return [i for i in out if i.text]
    n.conclusions = items("conclusions")
    n.todos = items("todos")
    terms = []
    for t in objects(root.get("terms")):
        name = s(t.get("name"))
        if name:
            terms.append(NoteTerm(name=name, note=s(t.get("note")), heard=[s(h) for h in arr(t.get("heard")) if s(h) and s(h) != name]))
    # The model keeps every term it ever had: bound the glossary, keeping the misheard ones.
    n.terms = NoteTerm.ordered(terms)[:20] if len(terms) > 20 else terms
    return None if n.is_empty else n
