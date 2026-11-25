"""Something only the user can fix, said beyond the settings (the Mac's AIServiceStrip.blocking and
its menu bar dot). Plain GNOME has no top bar icon and the notes window may be put away while you
meet, so on Linux it is also a desktop notification: once a meeting for a failure that stays until
you change something, and once for a service that has been unreachable for 2 minutes (shorter is
usually the network catching its breath). Never while the notes window shows it already. Stdlib
only: the Mac runs these tests too."""
from __future__ import annotations

from . import aicheck
from .strings import L, LF

# Stay until the key, the account, a model or the address changes: not the network, a busy service
# or one that errs. DEAF is the ports' own: the service hears for us, so nothing goes on without it.
BLOCKING = (aicheck.INVALID_KEY, aicheck.MGMT_KEY, aicheck.NO_CREDIT, aicheck.NO_MODEL,
            aicheck.BAD_ADDRESS, aicheck.NO_JSON, aicheck.DEAF)
# Only the notes and the full translations stop; the subtitles go on (the hear model is fine).
NOTES_ONLY = (aicheck.NO_MODEL, aicheck.NO_JSON)
UNREACHABLE_AFTER = 120.0


def blocking(reason: str | None) -> bool:
    return reason in BLOCKING


def stops_hearing(reason: str | None) -> bool:
    return blocking(reason) and reason not in NOTES_ONLY


def title(reason: str | None, service: str, text_model: str, hear_model: str) -> str | None:
    """The Mac's words for a blocking failure (AIServiceStrip.blocking), plus 听不了声音; None otherwise."""
    if not blocking(reason):
        return None
    return {aicheck.INVALID_KEY: lambda: LF("%@ 的 key 用不了", service),
            aicheck.MGMT_KEY: lambda: LF("%@ 的 key 用不了", service),
            aicheck.NO_CREDIT: lambda: LF("%@ 账户余额不足。", service),
            aicheck.NO_MODEL: lambda: LF("%@ 上找不到 %@ 这个模型。", service, text_model),
            aicheck.DEAF: lambda: LF("%@ 听不了声音。", hear_model or service)}.get(reason, lambda: L("AI 服务的设置要改一下"))()


class Notices:
    """When to notify, per meeting: `start` at 开始听, `tick` every second and on each change."""

    def __init__(self, wait: float = UNREACHABLE_AFTER):
        self.wait = wait
        self.sent: set = set()
        self.since: float | None = None  # unreachable, while listening, since then

    def start(self) -> None:
        self.sent = set()
        self.since = None

    def tick(self, now: float, listening: bool, reason: str | None, shown: bool) -> str | None:
        """"blocking" or "unreachable" when a notification is due now (counted as sent), else None.
        `shown`: the notes window is up and says it."""
        if reason == aicheck.UNREACHABLE and listening:
            if self.since is None:
                self.since = now
        else:
            self.since = None
        if not listening or shown:
            return None
        if blocking(reason):
            kind = "blocking"
        elif self.since is not None and now - self.since >= self.wait:
            kind = "unreachable"
        else:
            return None
        if kind in self.sent:
            return None
        self.sent.add(kind)
        return kind
