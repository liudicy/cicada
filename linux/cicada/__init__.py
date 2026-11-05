"""Cicada (知了) for Linux. `core` is the UI-free engine (stdlib only, runs and is tested on the
Mac too); `app` is the GTK desktop app."""

from pathlib import Path as _Path


def _version() -> str:
    # One version for every platform: VERSION at the repo root, copied next to cicada/ in a build.
    here = _Path(__file__).resolve().parent.parent
    for p in (here / "VERSION", here.parent / "VERSION"):
        try:
            return p.read_text(encoding="utf-8").strip()
        except OSError:
            pass
    return "0"


VERSION = _version()
