"""When a meeting is over (MeetingEnd.swift), so one nobody ended doesn't run on for hours and pull the
next video or meeting into its notes.

Two signals, as on the Mac. The main one: a meeting app (Zoom, 腾讯会议…) that was reading a
microphone during this meeting lets go of it, which is what hanging up looks like from outside; a
short grace covers switching devices. The fallback, for meetings in a browser or in the room: nothing
was recognised for a while ("nothing recognised" counts lines, not sound, so background music doesn't
keep a meeting alive). While a meeting app is still in a call, silence doesn't count. Pure: the
controller ticks it with the clock and `calls()`."""
from __future__ import annotations

import os
import re
import subprocess

PROMPT, END, OFF = "prompt", "end", "off"


class Config:
    def __init__(self, follow_apps: bool = True, silence: str = PROMPT, silence_after: float = 600,
                 countdown: float = 60, app_grace: float = 30):
        self.follow_apps = follow_apps
        self.silence = silence
        self.silence_after = silence_after
        self.countdown = countdown      # how long the 没人说话 prompt waits before ending
        self.app_grace = app_grace      # after a hang-up: a device switch drops the mic for a moment


class Reason:
    """Why the meeting ends: `app` hung up (its name), `silence`, or `nobody` spoke at all (nothing to
    keep, so it just stops, without a countdown)."""

    def __init__(self, kind: str, name: str = ""):
        self.kind = kind
        self.name = name

    def __eq__(self, other):
        return isinstance(other, Reason) and (self.kind, self.name) == (other.kind, other.name)

    def __repr__(self):
        return "%s(%s)" % (self.kind, self.name) if self.name else self.kind


class Pending:
    def __init__(self, reason: Reason, deadline: float):
        self.reason = reason
        self.deadline = deadline

    def __eq__(self, other):
        return isinstance(other, Pending) and (self.reason, self.deadline) == (other.reason, other.deadline)


class MeetingEndWatch:
    def __init__(self, config: Config, start: float):
        self.config = config
        self.pending: Pending | None = None
        self.last_speech = start
        self.in_call: dict = {}  # meeting apps seen in a call during this meeting (id → name)

    def heard(self, now: float) -> None:
        """Words were recognised (theirs or mine): a silence countdown stops. A hang-up doesn't: the
        next video would talk over it."""
        self.last_speech = now
        if self.pending is not None and self.pending.reason.kind == "silence":
            self.pending = None

    def keep_going(self, now: float) -> None:
        """继续记录: forget the hang-up and start counting silence again."""
        self.pending = None
        self.last_speech = now
        self.in_call = {}

    def tick(self, now: float, calls: dict, said: bool) -> Reason | None:
        """`calls`: meeting apps reading a microphone now. `said`: the meeting has lines. One without
        keeps listening for the silence time, then stops quietly. Returns why it ends now, if it does."""
        c = self.config
        in_a_call = c.follow_apps and bool(calls)
        if not said:
            self.in_call = dict(calls) if c.follow_apps else {}
            self.pending = None
            if c.silence != OFF and not in_a_call and now - self.last_speech >= c.silence_after:
                return Reason("nobody")
            return None
        app_pending = self.pending is not None and self.pending.reason.kind == "app"
        if c.follow_apps:
            self.in_call.update(calls)
            hung_up = bool(self.in_call) and all(k not in calls for k in self.in_call)
            if app_pending and not hung_up:
                self.pending = None  # rejoined
            if hung_up and (self.pending is None or self.pending.reason.kind == "silence"):
                name = self.in_call[sorted(self.in_call)[0]]
                self.pending = Pending(Reason("app", name), now + c.app_grace)
        elif app_pending:
            self.pending = None
        if self.pending is None and c.silence != OFF and not in_a_call and now - self.last_speech >= c.silence_after:
            if c.silence == END:
                return Reason("silence")
            self.pending = Pending(Reason("silence"), now + c.countdown)
        if (c.silence == OFF or in_a_call) and self.pending is not None and self.pending.reason.kind == "silence":
            self.pending = None
        if self.pending is not None and now >= self.pending.deadline:
            p, self.pending = self.pending, None
            return p.reason
        return None


# Dedicated meeting apps on Linux, by the program that opens the microphone (lower case) → the name
# shown. Browsers aren't here, as on the Mac: a browser holding a mic isn't necessarily a meeting.
MEETING_APPS = {
    "zoom": "Zoom", "zoomwebinar": "Zoom",
    "wemeetapp": "腾讯会议", "wemeet": "腾讯会议",
    "feishu": "飞书", "bytedance-feishu": "飞书", "lark": "Lark",
    "dingtalk": "钉钉", "com.alibabainc.dingtalk": "钉钉",
    "teams": "Teams", "teams-for-linux": "Teams", "teams-insiders": "Teams",
    "webex": "Webex", "ciscocollabhost": "Webex",
    "skypeforlinux": "Skype", "discord": "Discord",
}

_PROP = re.compile(r'^\s+([a-z0-9_.\-]+) = "(.*)"\s*$')


def parse_source_outputs(text: str, own_pid: int | None = None) -> dict:
    """`pactl list source-outputs` (LC_ALL=C) → the meeting apps reading a microphone: {program: name}.
    A stream recording a speaker's monitor (stream.capture.sink, as Cicada's own capture does) isn't
    a microphone, and Cicada's own streams never count."""
    out = {}
    for block in re.split(r"^Source Output #\d+\s*$", text, flags=re.M)[1:]:
        props = {}
        for line in block.splitlines():
            m = _PROP.match(line)
            if m:
                props[m.group(1)] = m.group(2)
        if props.get("stream.capture.sink") == "true":
            continue
        if own_pid is not None and props.get("application.process.id") == str(own_pid):
            continue
        for key in ("application.process.binary", "application.id", "application.name"):
            v = props.get(key, "").lower()
            program = os.path.basename(v).split(" ")[0] if v else ""
            if program in MEETING_APPS:
                out[program] = MEETING_APPS[program]
                break
    # One app opening two streams is one call; Zoom's two names are one app.
    names = {}
    for program, name in sorted(out.items()):
        names.setdefault(name, program)
    return {program: name for name, program in names.items()}


def calls() -> dict:
    """The meeting apps reading a microphone now, from the sound server (PipeWire or PulseAudio)."""
    try:
        r = subprocess.run(["pactl", "list", "source-outputs"], capture_output=True, text=True, timeout=3,
                           env={**os.environ, "LC_ALL": "C"})
    except (OSError, subprocess.SubprocessError):
        return {}
    return parse_source_outputs(r.stdout, os.getpid()) if r.returncode == 0 else {}
