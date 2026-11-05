"""The meeting record, field for field the Mac app's `session.json` (SessionStore.swift, Notes.swift),
so a record moves between the platforms unchanged. Each type maps to and from a JSON object;
jsonfmt.write sorts the keys and leaves out nulls, as the Mac's encoder does."""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone

from .jsonfmt import arr, boolean, integer, num, obj, string
from . import jsonfmt


def iso_write(at: datetime) -> str:
    """Whole seconds, UTC, "Z": what Swift's `.iso8601` writes (and expects back)."""
    return at.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_read(text: str | None) -> datetime | None:
    if not text:
        return None
    try:
        return datetime.strptime(text.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S%z")
    except ValueError:
        try:
            return datetime.fromisoformat(text.replace("Z", "+00:00"))
        except ValueError:
            return None


def now() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


@dataclass
class TranscriptLine:
    id: str = ""  # "h<n>-<segment>" for heard lines, "m<n>" for the user's own
    t: float = 0.0  # seconds from the start of the session
    speaker: str = "them"  # "them" (heard) or "me" (the Mac's microphone)
    src: str = ""
    dst: str | None = None
    srcLang: str = ""
    dstLang: str = ""
    voice: int | None = None  # experimental voice id on the Mac; Linux doesn't tell voices apart

    def copy(self) -> "TranscriptLine":
        return TranscriptLine(self.id, self.t, self.speaker, self.src, self.dst, self.srcLang, self.dstLang, self.voice)

    def to_json(self) -> dict:
        return {"id": self.id, "t": self.t, "speaker": self.speaker, "src": self.src, "dst": self.dst,
                "srcLang": self.srcLang, "dstLang": self.dstLang, "voice": self.voice}

    @staticmethod
    def from_json(o: dict) -> "TranscriptLine":
        return TranscriptLine(id=string(o.get("id")) or "", t=_num(o.get("t"), 0.0), speaker=string(o.get("speaker")) or "them",
                              src=string(o.get("src")) or "", dst=string(o.get("dst")), srcLang=string(o.get("srcLang")) or "",
                              dstLang=string(o.get("dstLang")) or "", voice=integer(o.get("voice")))


def _num(v, fallback):
    """Keeps an int an int, so "start" : 0 writes back as 0."""
    n = num(v)
    return fallback if n is None else n


@dataclass
class VoiceGuess:
    name: str = ""
    evidence: str = ""

    def to_json(self) -> dict:
        return {"name": self.name, "evidence": self.evidence}

    @staticmethod
    def from_json(o: dict) -> "VoiceGuess":
        return VoiceGuess(string(o.get("name")) or "", string(o.get("evidence")) or "")


@dataclass
class NoteItem:
    text: str = ""
    owner: str | None = None
    support: int = 0
    t: float | None = None  # when it was said (first evidence line)

    def to_json(self) -> dict:
        return {"text": self.text, "owner": self.owner, "support": self.support, "t": self.t}

    @staticmethod
    def from_json(o: dict) -> "NoteItem":
        return NoteItem(string(o.get("text")) or "", string(o.get("owner")), integer(o.get("support")) or 0, num(o.get("t")))


@dataclass
class NoteTerm:
    """A name or term as the notes settled on it, and how speech recognition heard it."""
    name: str = ""
    note: str = ""
    heard: list = field(default_factory=list)

    def to_json(self) -> dict:
        return {"name": self.name, "note": self.note, "heard": list(self.heard)}

    @staticmethod
    def from_json(o: dict) -> "NoteTerm":
        return NoteTerm(string(o.get("name")) or "", string(o.get("note")) or "",
                        [x for x in arr(o.get("heard")) if isinstance(x, str)])

    @staticmethod
    def ordered(terms: list) -> list:
        """Corrected spellings first: what a reader can't work out alone."""
        return [t for t in terms if t.heard] + [t for t in terms if not t.heard]


@dataclass
class FishboneBranch:
    label: str = ""
    detail: str = ""
    t: float | None = None
    support: int = 0  # how many transcript lines back this branch; 0 is shown as weak

    def to_json(self) -> dict:
        return {"label": self.label, "detail": self.detail, "t": self.t, "support": self.support}

    @staticmethod
    def from_json(o: dict) -> "FishboneBranch":
        return FishboneBranch(string(o.get("label")) or "", string(o.get("detail")) or "", num(o.get("t")), integer(o.get("support")) or 0)


@dataclass
class Fishbone:
    question: str = ""
    branches: list = field(default_factory=list)

    def to_json(self) -> dict:
        return {"question": self.question, "branches": [b.to_json() for b in self.branches]}

    @staticmethod
    def from_json(o: dict) -> "Fishbone":
        return Fishbone(string(o.get("question")) or "", [FishboneBranch.from_json(b) for b in arr(o.get("branches")) if isinstance(b, dict)])


@dataclass
class NoteTopic:
    start: float = 0.0
    title: str = ""
    summary: str = ""
    points: list = field(default_factory=list)
    pointTimes: list | None = None  # when each point was said, parallel to points
    fishbone: Fishbone | None = None

    def point_time(self, i: int) -> float | None:
        return self.pointTimes[i] if self.pointTimes is not None and i < len(self.pointTimes) else None

    def to_json(self) -> dict:
        # pointTimes keeps its nulls: Swift writes [12.4, null].
        return {"start": self.start, "title": self.title, "summary": self.summary, "points": list(self.points),
                "pointTimes": self.pointTimes, "fishbone": self.fishbone.to_json() if self.fishbone else None}

    @staticmethod
    def from_json(o: dict) -> "NoteTopic":
        pt = o.get("pointTimes")
        return NoteTopic(start=_num(o.get("start"), 0.0), title=string(o.get("title")) or "", summary=string(o.get("summary")) or "",
                         points=[p for p in arr(o.get("points")) if isinstance(p, str)],
                         pointTimes=[num(x) for x in pt] if isinstance(pt, list) else None,
                         fishbone=Fishbone.from_json(o["fishbone"]) if isinstance(o.get("fishbone"), dict) else None)


@dataclass
class MeetingNotes:
    """Written by Ling while the meeting runs, rewritten over the whole transcript when it ends."""
    title: str | None = None
    summary: str = ""
    topics: list = field(default_factory=list)
    conclusions: list = field(default_factory=list)
    todos: list = field(default_factory=list)
    terms: list = field(default_factory=list)
    covered: int = 0  # how many transcript lines these notes cover
    final: bool = False
    updatedAt: datetime | None = None

    @property
    def is_empty(self) -> bool:
        return not self.summary and not self.topics

    def to_json(self) -> dict:
        return {"title": self.title, "summary": self.summary, "topics": [t.to_json() for t in self.topics],
                "conclusions": [c.to_json() for c in self.conclusions], "todos": [t.to_json() for t in self.todos],
                "terms": [t.to_json() for t in self.terms], "covered": self.covered, "final": self.final,
                "updatedAt": iso_write(self.updatedAt) if self.updatedAt else None}

    @staticmethod
    def from_json(o: dict) -> "MeetingNotes":
        def objs(key):
            return [x for x in arr(o.get(key)) if isinstance(x, dict)]
        return MeetingNotes(title=string(o.get("title")), summary=string(o.get("summary")) or "",
                            topics=[NoteTopic.from_json(t) for t in objs("topics")],
                            conclusions=[NoteItem.from_json(c) for c in objs("conclusions")],
                            todos=[NoteItem.from_json(c) for c in objs("todos")],
                            terms=[NoteTerm.from_json(c) for c in objs("terms")],
                            covered=integer(o.get("covered")) or 0, final=boolean(o.get("final")) or False,
                            updatedAt=iso_read(string(o.get("updatedAt"))))


@dataclass
class Session:
    id: str = ""
    title: str = ""
    startedAt: datetime = field(default_factory=now)
    endedAt: datetime | None = None
    lines: list = field(default_factory=list)
    hasAudio: bool = False
    notes: MeetingNotes | None = None
    renamed: bool | None = None
    voiceNames: dict | None = None
    voiceGuesses: dict | None = None
    # An imported recording (the Mac's 导入录音): its file name, where it was, and true until
    # transcribing it finished. Linux doesn't import yet; the fields are kept so a record survives.
    sourceFile: str | None = None
    sourcePath: str | None = None
    importing: bool | None = None
    # Heard through the microphone in the room (the Mac's 会议室) for some or all of it.
    room: bool | None = None
    # Keys this version doesn't know (a newer Mac's), written back as they came so a record survives.
    extra: dict = field(default_factory=dict)

    KEYS = ("id", "title", "startedAt", "endedAt", "lines", "hasAudio", "notes", "renamed", "voiceNames",
            "voiceGuesses", "sourceFile", "sourcePath", "importing", "room")

    @property
    def duration(self) -> float:
        """Until it ended; a record that never got an end (the app quit mid-meeting) runs to its last
        line rather than to now. The live meeting shows its own clock."""
        if self.endedAt is not None:
            return (self.endedAt - self.startedAt).total_seconds()
        return self.lines[-1].t if self.lines else 0.0

    def to_json(self) -> dict:
        return {**self.extra, "id": self.id, "title": self.title, "startedAt": iso_write(self.startedAt),
                "endedAt": iso_write(self.endedAt) if self.endedAt else None, "lines": [l.to_json() for l in self.lines],
                "hasAudio": self.hasAudio, "notes": self.notes.to_json() if self.notes else None, "renamed": self.renamed,
                "voiceNames": self.voiceNames,
                "voiceGuesses": {k: v.to_json() for k, v in self.voiceGuesses.items()} if self.voiceGuesses is not None else None,
                "sourceFile": self.sourceFile, "sourcePath": self.sourcePath, "importing": self.importing,
                "room": self.room}

    @staticmethod
    def from_json(o: dict) -> "Session":
        vn = obj(o.get("voiceNames"))
        vg = obj(o.get("voiceGuesses"))
        return Session(id=string(o.get("id")) or "", title=string(o.get("title")) or "",
                       startedAt=iso_read(string(o.get("startedAt"))) or datetime.fromtimestamp(0, timezone.utc),
                       endedAt=iso_read(string(o.get("endedAt"))),
                       lines=[TranscriptLine.from_json(l) for l in arr(o.get("lines")) if isinstance(l, dict)],
                       hasAudio=boolean(o.get("hasAudio")) or False,
                       notes=MeetingNotes.from_json(o["notes"]) if isinstance(o.get("notes"), dict) else None,
                       renamed=boolean(o.get("renamed")),
                       voiceNames={k: (string(v) or "") for k, v in vn.items()} if vn is not None else None,
                       voiceGuesses={k: VoiceGuess.from_json(obj(v) or {}) for k, v in vg.items()} if vg is not None else None,
                       sourceFile=string(o.get("sourceFile")), sourcePath=string(o.get("sourcePath")),
                       importing=boolean(o.get("importing")), room=boolean(o.get("room")),
                       extra={k: v for k, v in o.items() if k not in Session.KEYS})

    @staticmethod
    def read(text: str) -> "Session | None":
        o = jsonfmt.parse_object(text)
        return Session.from_json(o) if o is not None else None

    def write(self) -> str:
        return jsonfmt.write(self.to_json())
