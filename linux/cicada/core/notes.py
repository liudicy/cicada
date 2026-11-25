"""Keeps the live meeting's notes up to date: every ~45 s with new speech, one Ling call sends the
current notes plus the new lines and gets the notes back as JSON, rewriting only the last topics; a
final pass rewrites them over the whole transcript when the meeting ends (a long meeting in parts,
merged). A failed or odd reply never replaces good notes.
The prompt and parsing are the Mac's (Notes.swift, via the Windows and Android ports), so every
platform writes the same notes."""
from __future__ import annotations

import math
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace

from . import jsonfmt, speakers
from .jsonfmt import arr, num, obj
from .ling import CHECKING, INVALID, NOTES, LingError
from .models import Fishbone, FishboneBranch, MeetingNotes, NoteItem, NoteTerm, NoteTopic, now
from .support import Log, clock, written_in

INTERVAL = 45.0
IDLE, UPDATING, NO_KEY, INVALID_KEY, RATE_LIMITED, FAILED = "idle", "updating", "noKey", "invalidKey", "rateLimited", "failed"
# The notes' own request couldn't reach the service (network, proxy, timeout); another request
# failing, such as naming speakers, never sets it.
UNREACHABLE = "unreachable"


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
        # Final passes asked for and not over yet (queued in a pool, running or waiting their turn),
        # and the call when one is over, notes written or not (存到文件夹 waits for it).
        self._finals: list = []
        self.final_done = None

    def settling(self, sid: str) -> bool:
        """The meeting's final pass is still to come, running or waiting: also while the meeting is
        still this engine's own, before listening's pool gets to finish()."""
        with self._gate:
            return sid == self._session_id or sid in self._finals

    def _final_over(self, sid: str) -> None:
        with self._gate:
            if sid in self._finals:
                self._finals.remove(sid)
            done = sid not in self._finals
        if done and self.final_done is not None:
            self.final_done(sid)

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
            self._sync_key()
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
                self._finals.append(sid)
        if sid is not None:
            self._update(sid, final=True)

    def show(self, sid: str) -> None:
        with self._gate:
            self.shown_id = sid
            s = self.store.get(sid)
            self.notes = (s.notes if s else None) or MeetingNotes()
            # A round that failed belongs to the meeting it ran for, not to the record opened now.
            if self._session_id is None and self.status in (FAILED, UNREACHABLE, RATE_LIMITED):
                self.status = IDLE
        self._changed()

    def rewrite(self) -> None:
        """The live meeting's notes again from its first line (纪要语言 changed): the Mac's rewrite."""
        with self._gate:
            sid = self._session_id
        if sid is not None:
            self._work.submit(self._update, sid, False, True)

    def generate(self, sid: str) -> None:
        """Notes for a finished meeting that has none (runs in the background)."""
        with self._gate:
            self._finals.append(sid)
        self._work.submit(self._update, sid, True)

    def _sync_key(self) -> None:
        """The status follows the key, as on the Mac (`NotesEngine.tick`)."""
        ling = self.ling
        # A key was added or replaced since the last failure.
        if self.status in (NO_KEY, INVALID_KEY) and ling.usable and ling.key_state != CHECKING:
            self.status = IDLE
        if self.status == IDLE and not ling.has_key:
            self.status = NO_KEY
        # A key that was just checked and refused says so, rather than asking for a key again.
        if self.status in (NO_KEY, IDLE) and ling.has_key and ling.key_state == INVALID:
            self.status = INVALID_KEY

    def _tick(self) -> None:
        with self._gate:
            # The service answers again (the check after a network change, or any other request): the
            # banner goes now, not after the next round, which runs on its usual 45 s.
            recovered = self.status == UNREACHABLE and self.ling.check_result.reason != "unreachable"
            if recovered:
                self.status = IDLE
        if recovered:
            self._changed()
        with self._gate:
            self._sync_key()
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
        over = None  # a final pass that ends here without running
        start = False
        with self._gate:
            if self._in_flight:
                if final:
                    # One waiting slot: the pass it held won't run, so that one is over.
                    over, self._pending_final = self._pending_final, sid
                elif fresh:
                    self._pending_fresh = sid  # after the round in the old language
            else:
                session = self.store.get(sid)
                if session is None or not session.lines:
                    over = sid if final else None
                elif not self.ling.has_key:
                    self.status = NO_KEY
                    over = sid if final else None
                    self._changed()
                else:
                    start = True
                    self._in_flight = True
                    self.working_id = sid
                    self._last_attempt = time.time()
                    self.status = UPDATING
                    base = MeetingNotes() if final or fresh else (self.notes if sid == self.shown_id else (session.notes or MeetingNotes()))
        if over is not None:
            self._final_over(over)
        if not start:
            return
        self._changed()
        try:
            lines = self.store.lines(sid)
            frm = 0 if final else min(base.covered, len(lines))
            lang = self.language(sid)
            voices = self.voices()
            shown = speakers.names(session) if voices else {}
            started_at = lines[0].t if lines else 0.0
            # A live update returns only the last topics: when it rewrote them all, its reply grew with
            # the meeting until, about an hour in, it was cut off at max_tokens or fell into a loop and
            # the notes stopped updating. The final pass still rewrites everything once.
            frozen = 0 if final or fresh else max(0, len(base.topics) - EDITABLE_TOPICS)
            p = prompt(base, lines, frm, lang, final, shown, voices, frozen)
            nxt = self._long_final(lines, shown, voices, lang, started_at) if final else None
            for attempt in range(1, 3 if final else 2):
                if nxt is not None:
                    break
                raw = self.ling.chat(p, "Update the notes. Write them in %s." % lang, NOTES, json=True, max_tokens=6000, timeout=90.0,
                                     patient=final)
                parsed = parse(raw, [l.t for l in lines], started_at)
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
            if not final and not fresh:
                nxt.topics = merge(base.topics, frozen, nxt.topics)
            if not fresh:
                prior = self.notes if sid == self.shown_id else session.notes
                nxt.terms = NoteTerm.keeping_order(prior.terms if prior else [], nxt.terms)
            nxt.terms = heard_as_said(nxt.terms, lines)
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
                           LingError.NO_KEY: NO_KEY, LingError.NETWORK: UNREACHABLE,
                           LingError.TIMEOUT: UNREACHABLE}.get(e.kind, FAILED)
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
            if final:
                self._final_over(sid)
            if queued is not None:
                self._update(queued, final=True)
            elif again is not None:
                self._update(again, final=False, fresh=True)

    def _long_final(self, lines: list, names: dict, voices: bool, lang: str, started_at: float) -> MeetingNotes | None:
        """A long meeting's final pass: each part noted on its own, all at once, then merged into one.
        None when a step fails: the caller then makes one pass over the whole transcript, as before."""
        ranges = parts(lines)
        if len(ranges) <= 1:
            return None
        started = time.time()
        times = [l.t for l in lines]

        def ask(i):
            r = ranges[i]
            p = prompt(MeetingNotes(), lines[:r.stop], r.start, lang, True, names, voices, part=(i + 1, len(ranges)))
            try:
                return self.ling.chat(p, "Write the notes for this part. Write them in %s." % lang, NOTES, json=True,
                                      max_tokens=6000, timeout=90.0)
            except Exception:  # noqa: BLE001
                return None
        with ThreadPoolExecutor(max_workers=len(ranges), thread_name_prefix="NotesPart") as pool:
            replies = list(pool.map(ask, range(len(ranges))))
        notes, topics = [], []
        for i, raw in enumerate(replies):
            parsed = parse(raw, times, started_at) if raw else None
            root = jsonfmt.parse_object(raw[raw.find("{"):raw.rfind("}") + 1]) if parsed is not None and parsed.topics else None
            if root is None:
                Log.d("notes: final part %d/%d failed, one pass instead" % (i + 1, len(ranges)))
                return None
            # Without its topics: given them, the merge wrote them all back out and was cut off.
            root.pop("topics", None)
            notes.append(jsonfmt.write(root, pretty=False))
            topics += thinned(parsed.topics, part_topics(len(ranges)), lines[ranges[i].stop - 1].t)
        p = merge_prompt(notes, lines, lang, voices and bool(speakers.numbers(lines)))
        for attempt in (1, 2):
            try:
                raw = self.ling.chat(p, "Merge the notes. Write them in %s." % lang, NOTES, json=True, max_tokens=6000, timeout=90.0)
            except Exception:  # noqa: BLE001
                break
            merged = parse(raw, times, started_at)
            if merged is None:
                break
            merged.topics = topics
            if written(merged, lang):
                Log.d("notes: final in %d parts -> %d topics in %d s" % (len(ranges), len(topics), time.time() - started))
                return merged
            Log.d("notes: merged reply not in %s (attempt %d), dropped" % (lang, attempt))
        Log.d("notes: merging %d parts failed, one pass instead" % len(ranges))
        return None


def _min(a, b):
    return b if a is None else a if b is None else min(a, b)


# The most topics the final notes have (the prompt says so too; the model doesn't always listen).
MAX_TOPICS = 8
# Live notes once stopped at 8 topics and poured the rest of the meeting into the last one, whose
# summary grew into a wall of "最新…又…补充…": past this, the two shortest neighbouring settled
# topics are joined instead, so the newest can start.
LIVE_MAX_TOPICS = 12
# How many of the last topics a live update may rewrite; earlier ones stay as they are.
EDITABLE_TOPICS = 2
# A topic summary longer than this is a log the model kept appending to, not one sentence.
TOPIC_SUMMARY_LIMIT = 160


def heard_as_said(terms: list, lines: list) -> list:
    """Terms keep only the heard forms the recognizer really wrote (`src`). The notes read lines with
    fixes in, so a wrong fix came back as a heard form ("X平台 heard as platform"), went to the
    translator and the next fix's request as a known mishearing, and was proposed again."""
    srcs = [l.src.casefold() for l in lines]
    return [replace(t, heard=[h for h in t.heard if any(h.casefold() in s for s in srcs)]) for t in terms]


def shortened(summary: str) -> str:
    """A runaway topic summary cut back to its first sentence (or to the limit, with "…")."""
    if len(summary) <= TOPIC_SUMMARY_LIMIT:
        return summary
    head = summary[:TOPIC_SUMMARY_LIMIT]
    m = re.search(r"[。！？；.!?;]", head[10:])
    return head[:10 + m.end()] if m else head.rstrip() + "…"


def merge(old: list, frozen: int, returned: list) -> list:
    """A live reply's topics after the `frozen` ones it was told to leave alone: with some frozen, at
    most the editable ones plus one new, from the end (the model sometimes echoes the whole list),
    never a copy of a frozen one, each summary kept to one sentence; and no more than
    LIVE_MAX_TOPICS in all (past that, settled neighbours are joined). A reply with no topics of its
    own keeps the ones it had."""
    kept = list(old[:frozen])
    fixed = {t.title for t in kept}
    own = [t for t in returned if t.title not in fixed]
    tail = own if not kept else own[-(len(old) - len(kept) + 1):]
    if not tail:
        return old
    tail = [replace(t, summary=shortened(t.summary)) for t in tail]
    tail = capped(tail, LIVE_MAX_TOPICS - min(len(kept), 1))
    while len(kept) + len(tail) > LIVE_MAX_TOPICS and len(kept) >= 2:
        # The pair spanning the least time, its end being the next topic's start.
        ends = [t.start for t in kept[1:]] + [tail[0].start]
        i = min(range(len(kept) - 1), key=lambda j: ends[j + 1] - kept[j].start)
        kept[i] = joined(kept[i], kept[i + 1])
        del kept[i + 1]
    return capped(kept + tail, LIVE_MAX_TOPICS)


def joined(a: NoteTopic, b: NoteTopic) -> NoteTopic:
    """Two neighbouring topics as one: both titles and summaries, and up to the 4 points the prompt
    allows, taken evenly from each."""
    from_a = min(len(a.points), max(2, 4 - len(b.points)))
    from_b = min(len(b.points), 4 - from_a)
    times = [a.point_time(i) for i in range(from_a)] + [b.point_time(i) for i in range(from_b)]
    gap = "" if not a.summary or a.summary[-1] in "。！？；" else " "
    return NoteTopic(start=a.start, title="%s / %s" % (a.title, b.title), summary=a.summary + gap + b.summary,
                     points=a.points[:from_a] + b.points[:from_b], fishbone=a.fishbone or b.fishbone,
                     pointTimes=times if any(x is not None for x in times) else None)


def capped(topics: list, count: int) -> list:
    """At most `count` topics (at least one): the points of any after that go into the last kept."""
    topics = list(topics)
    while len(topics) > max(1, count):
        extra = topics.pop()
        last = topics.pop()
        times = [last.point_time(i) for i in range(len(last.points))] + [extra.point_time(i) for i in range(len(extra.points))]
        topics.append(replace(last, points=last.points + extra.points,
                              pointTimes=times if any(x is not None for x in times) else None))
    return topics


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
        # A topic starts no later than its first point (the reply dates it from the lines it cites now).
        first = min((x for x in times if x is not None), default=None)
        if first is not None and first < t.start:
            t.start = first
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
           voices: bool = False, frozen: int = 0, part: tuple | None = None) -> str:
    """`frozen`: the first topics, settled, sent as a list and not returned. `part`: in a long
    meeting's final pass, which part `frm:len(lines)` is (1-based index, count)."""
    nums = speakers.numbers(lines) if voices else {}
    names = names or {}

    def line(i):
        l = lines[i]
        # A named voice goes as its name: notes then say "George" rather than "说话人2".
        who = "你" if l.speaker == "me" else (
            (names.get(nums[l.id]) or "说话人%d" % nums[l.id]) if l.id in nums else ("对方" if not nums else "未识别"))
        return "[L%d %s %s] %s" % (i + 1, clock(l.t), who, l.shown)
    current = "{}" if notes.is_empty else _compact_json(notes, frozen)
    context = max(0, frm - 2)
    if part is not None:
        task = ("that has just ended. It was long, so it is noted in parts: write the notes for part %d of %d only, from the lines below"
                % part)
    else:
        task = "that has just ended. Rewrite them from the whole transcript" if final else "that is still going on. Update them with the new lines"
    p = "You keep notes for a meeting %s.\nWrite the notes in %s. Return JSON only.\n" % (task, language)
    if not final:
        if frozen > 0:
            p += ("Earlier topics (settled: kept as they are, do not return them):\n" +
                  "\n".join("- %s %s: %s" % (clock(t.start), t.title, t.summary) for t in notes.topics[:frozen]) + "\n\n")
        p += "Current notes (JSON%s):\n%s\n\n" % (", latest topics only" if frozen > 0 else "", current)
    if context < frm:
        p += "Already covered (context only):\n" + "\n".join(line(i) for i in range(context, frm)) + "\n\n"
    p += ("%s (id, mm:ss, speaker 对方=the other side / 你=me / a name or 说话人N=one person on the other side, told apart by voice and possibly wrong / 未识别=someone on the other side not identified, text). Speech recognition makes mistakes, often in names: correct them from context, and write a public figure's name as the news spells it.\n"
          % ("Transcript" if final else "New lines"))
    p += "\n".join(line(i) for i in range(frm, len(lines)))
    # The model splits too eagerly when only told how long a topic should be: say plainly whether
    # this update may start one.
    if final and frm < len(lines):
        span = lines[-1].t - lines[frm].t
        most = max(1, min(part_topics(part[1]) if part else MAX_TOPICS, int(span / 180) + 1))
        p += "\n\nThis %s ran %s: use at most %d topic%s." % ("meeting" if part is None else "part", clock(span), most, "" if most == 1 else "s")
    elif not final and notes.topics and lines and lines[-1].t - notes.topics[-1].start < 120:
        topic = notes.topics[-1]
        p += ("\n\nThe current topic \"%s\" started at %s, under 2 minutes ago: do not start a new topic in this update; add the new lines to it."
              % (topic.title, clock(topic.start)))
    elif not final and not notes.topics:
        p += "\n\nThese are the first lines: make one topic."
    return p + "\n\n" + _format(language, bool(nums), final, frozen)


def _format(language: str, voices: bool, final: bool, frozen: int) -> str:
    """The reply's JSON shape and the rules for its contents."""
    return ("Return the full notes as one JSON object with exactly these keys:\n"
            "{\"title\": \"the meeting's name: what it is about, a few words\",\n"
            " \"summary\": \"2-3 sentences on the whole meeting so far\",\n"
            " \"topics\": [{\"start\": seconds, \"title\": \"short title\", \"summary\": \"one sentence on the whole topic\", \"points\": [{\"text\": \"key point\", \"evidence\": [\"L4\"]}], \"evidence\": [\"L3\"],\n"
            "             \"fishbone\": null or {\"question\": \"the problem or question\", \"branches\": [{\"label\": \"2-6 words\", \"detail\": \"one short line\", \"t\": seconds, \"evidence\": [\"L5\"]}]}}],\n"
            " \"conclusions\": [{\"text\": \"...\", \"evidence\": [\"L7\", \"L8\"]}],\n"
            " \"todos\": [{\"text\": \"...\", \"owner\": %s, \"evidence\": [\"L9\"]}],\n"
            " \"terms\": [{\"name\": \"correct spelling\", \"note\": \"who or what, a few words\", \"heard\": [\"how it was misrecognised\"]}]}\n"
            "Rules (be brief: these notes are read at a glance during the meeting):\n"
            "- title: a name for the whole meeting, like a calendar entry (at most 12 Chinese characters or 6 words; no date, no quotes, not \"会议\" alone). Keep the current title unless the meeting's subject has clearly changed.\n"
            "- summary: at most 3 short sentences.\n"
            "- Topics in time order, %s. A topic is a stretch of the meeting, usually 3-10 minutes, not a single remark: start a new one only when the subject clearly changes and the current topic started at least 2 minutes before the newest line%s. Otherwise add to the current one, and merge small neighbouring topics. Keep earlier topics as they are unless new lines correct them. The last topic is the one being discussed now.\n"
            "- A topic's summary is one sentence on the whole topic, at most 40 Chinese characters or 25 words: as the topic grows, rewrite it; never append to it or narrate what came next (\"最新\", \"又\", \"补充\", \"then\", \"later\").\n"
            "- At most 4 points per topic, each one short phrase. Merge rather than repeat.\n"
            "- At most 5 conclusions and only real to-dos (often none).\n"
            "- Add a fishbone only to a topic that discusses causes, reasons or factors (3-5 branches); otherwise null.\n"
            "- Every topic, point, branch, conclusion and to-do needs evidence: the ids of the lines that say it. Never state anything the transcript does not say.\n"
            "- terms: at most 10 in total, replacing less useful ones rather than adding: first names the transcript misspells (heard), then the people, places and jargon a reader would not know. Leave out what everyone knows (a famous company, index or politician) unless it was misheard. name is the correct spelling in the transcript's language (no translation in brackets); heard lists only the wrong forms the transcript used, and only of that same thing: a name said again and again in one spelling that context doesn't tie to a known one (\"我们 twoty\", \"our platform\") is a thing of its own, its own term with that spelling, not a mishearing of a similar name; note is a few words.\n"
            "- Write the meeting title and every summary, title, point, branch, conclusion and to-do in %s, even when the transcript is in another language. Only term names keep the transcript's spelling.\n"
            "- Write about what was said, never about the transcript or recognition quality.\n"
            "- Use empty arrays when there is nothing. No markdown, no text outside the JSON."
            % ('"对方" or "你" or null' if not voices else
               'the person\'s label from the transcript (a name like "George", or "说话人2"), "你", or null when unclear',
               "returning only the topics in the current notes and at most one new one after them" if frozen > 0
               else "at most %d in total" % MAX_TOPICS,
               "" if final else "; add at most one new topic per update", language))


# Long meetings

# How a long meeting's final pass is split: over SPLIT_MINUTES, into equal parts by time of at most
# PART_MINUTES. One pass covered a 91-minute meeting but only the first hour of a 4-hour one.
SPLIT_MINUTES = 100.0
PART_MINUTES = 60.0


def parts(lines: list) -> list:
    """The final pass's parts as ranges of line indices."""
    if not lines:
        return []
    first, last = lines[0].t, lines[-1].t
    minutes = (last - first) / 60
    if minutes <= SPLIT_MINUTES:
        return [range(0, len(lines))]
    count = math.ceil(minutes / PART_MINUTES)
    length = (last - first) / count
    bounds = [0]
    for k in range(1, count):
        at = first + length * k
        i = next((j for j, l in enumerate(lines) if l.t >= at), None)
        if i is not None and i > bounds[-1]:
            bounds.append(i)
    bounds.append(len(lines))
    return [range(a, b) for a, b in zip(bounds, bounds[1:])]


def part_topics(n: int) -> int:
    """Each part's share of the topics: the merge keeps them as they are, so every part has some."""
    return max(2, MAX_TOPICS // max(1, n))


def thinned(topics: list, count: int, end: float) -> list:
    """At most `count` of a part's `topics`, neighbours joined: a part's reply often has more topics
    than asked. Keeping the first ones lost the end of the part, and keeping some spread from first to
    last kept a topic's "（续）" stub at the part's end and dropped the topic itself. The same subject
    twice is joined first, under the first one's title; then the pair spanning the least time (to the
    next topic's start, or `end` for the last), as live notes do."""
    topics = list(topics)
    while len(topics) > max(1, count):
        pairs = range(len(topics) - 1)
        same = next((i for i in pairs if subject(topics[i].title) == subject(topics[i + 1].title)), None)
        # min() keeps the first of equal spans, as the Mac does.
        i = same if same is not None else min(
            pairs, key=lambda j: (topics[j + 2].start if j + 2 < len(topics) else end) - topics[j].start)
        one = joined(topics[i], topics[i + 1])
        if same is not None:
            one = replace(one, title=topics[i].title, summary=topics[i].summary)
        topics[i:i + 2] = [one]
    return topics


def subject(title: str) -> str:
    """A topic title without a trailing bracket ("预算评审（续）", "Budget (cont.)"): what it is about."""
    t = title.strip()
    if not t or t[-1] not in "）)":
        return t
    open_at = max(t.rfind("（"), t.rfind("("))
    return t[:open_at].strip() if open_at > 0 else t


def merge_prompt(parts: list, lines: list, language: str, voices: bool) -> str:
    """The whole meeting's title, summary, conclusions, to-dos and terms from its parts' notes (the
    replies as they came, with their evidence line ids). Asked to merge topics too, the model kept the
    first parts' and dropped the rest, so topics are joined in code."""
    p = ("You keep notes for a meeting that has just ended. It was long, so each part was noted on its own; below are those notes, in time order (JSON; evidence ids are transcript lines, L1 the first). Merge them into the notes for the whole meeting.\n"
         "Write the notes in %s. Return JSON only.\n\n" % language)
    for i, part in enumerate(parts):
        p += "Part %d of %d:\n%s\n\n" % (i + 1, len(parts), part)
    if lines:
        p += ("This meeting ran %s. Return \"topics\": []: the parts' topics are kept as they are. Name and summarise the whole meeting, every part of it; keep each conclusion, to-do and term once, with the evidence ids it had (joined when you merge two).\n\n"
              % clock(lines[-1].t - lines[0].t))
    return p + _format(language, voices, True, 0)


def _compact_json(n: MeetingNotes, frm: int = 0) -> str:
    """The current notes as sent back to the model (no bookkeeping fields), topics from `frm` (earlier
    ones go as a list of titles). Insertion order, like the Kotlin LinkedHashMap; jsonfmt sorts keys,
    which the model doesn't mind."""
    o = {}
    if n.title is not None:
        o["title"] = n.title
    o["summary"] = n.summary
    o["topics"] = [{"start": t.start, "title": t.title, "summary": t.summary, "points": list(t.points),
                    "fishbone": t.fishbone.to_json() if t.fishbone else None} for t in n.topics[frm:]]
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
            # A branch's time from its lines, as a point's: the model's own "t" came back past the end.
            branches = [FishboneBranch(label=s(br.get("label")), detail=s(br.get("detail")),
                                       t=time_of(br.get("evidence")) if line_numbers(br.get("evidence")) else num(br.get("t")),
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
        # When it was first said, from its lines: the model's own start drifts by tens of minutes in a
        # long meeting (a topic said at 51-85 min came back as starting at 23).
        said = [x for x in [time_of(t.get("evidence"))] + point_times if x is not None]
        start = min(said) if said else num(t.get("start"))
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
