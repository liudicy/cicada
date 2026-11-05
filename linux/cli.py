#!/usr/bin/env python3
"""cicada-cli: the Linux engines without the desktop (runs on the Mac too).

  cli.py listen <file.wav> [--target zh-CN] [--speed 1|0] [--notes] [--log]
      Plays the file into ListenEngine as if the speakers were playing it, prints each line as it is
      recorded, then the record's folder. --notes waits for the final notes and prints them.
  cli.py hear <file.wav> [--target zh-CN]   one file to Ming, raw reply printed
  cli.py speak <file.wav> [--from zh-CN] [--to en] [--out out.wav]
      同声传译 on a recording: each sentence interpreted, voiced by Ming, written to --out (24 kHz)
  cli.py segments <file.wav>                where the segmenter cuts
  cli.py roundtrip <session.json>… [--diff] reads and writes records, says if a byte changed

Records go to CICADA_HOME (default: a temp folder). The key comes from CICADA_KEY_FILE, else this
app's own key file, else the Mac app's; it is never printed."""
from __future__ import annotations

import os
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from cicada.core import strings  # noqa: E402
from cicada.core.audio import PcmAudioSource, Wav  # noqa: E402
from cicada.core.ling import AUDIO_MODEL, TRANSLATE, AIKey, LingClient  # noqa: E402
from cicada.core.listen import ListenEngine  # noqa: E402
from cicada.core.models import Session  # noqa: E402
from cicada.core.notes import NotesEngine  # noqa: E402
from cicada.core.segmenter import Segmenter  # noqa: E402
from cicada.core.session_store import SessionStore  # noqa: E402
from cicada.core.settings import AppSettings  # noqa: E402
from cicada.core.support import Log, Paths, clock  # noqa: E402
from cicada.core.translator import Translator, hear_instruction, hear_prompt, parse_heard  # noqa: E402


def key_file() -> str | None:
    env = os.environ.get("CICADA_KEY_FILE")
    if env:
        return env
    for p in (os.path.expanduser("~/.config/cicada/ling-api-key"),
              os.path.expanduser("~/Library/Application Support/LiveSubs Dev/ling-api-key"),
              os.path.expanduser("~/Library/Application Support/LiveSubs/ling-api-key")):
        if os.path.isfile(p):
            return p
    return None


def main(args: list) -> int:
    if not args:
        print(__doc__)
        return 2

    def opt(name, fallback):
        return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else fallback
    strings.load(opt("--ui", "zh-Hans"), [os.path.join(HERE, "..", "Resources"), os.path.join(HERE, "strings")])
    cmd = args[0]
    if cmd == "segments":
        pcm = Wav.read_file(args[1])
        got = []
        seg = Segmenter()
        seg.on_segment = got.append
        for i in range(0, len(pcm), 1600):
            seg.feed(pcm[i:i + 1600])
        seg.flush()
        for s in got:
            print("%3d %7.2fs %5.2fs" % (s.index, s.start, s.seconds))
        print("%d segments, %.1fs of speech" % (len(got), sum(s.seconds for s in got)))
        return 0
    if cmd == "roundtrip":
        changed = 0
        for path in [a for a in args[1:] if not a.startswith("--")]:
            with open(path, encoding="utf-8") as f:
                original = f.read()
            s = Session.read(original)
            written = s.write() if s else None
            same = written == original
            changed += 0 if same else 1
            print("%s %s (%d lines%s)" % ("same   " if same else "CHANGED", path, len(s.lines) if s else 0,
                                          ", notes" if s and s.notes else ""))
            if not same and "--diff" in args and written is not None:
                a, b = original.split("\n"), written.split("\n")
                at = next((i for i in range(len(a)) if i >= len(b) or a[i] != b[i]), len(a))
                print("  first difference at line %d:\n  mac:   %s\n  linux: %s" % (at + 1, a[at] if at < len(a) else None,
                                                                                  b[at] if at < len(b) else None))
        return 0 if changed == 0 else 1
    if cmd == "hear":
        ling = LingClient(AIKey(key_file()))
        target = opt("--target", "zh-CN")
        r = ling.chat(hear_prompt(target, None, []), hear_instruction(target), TRANSLATE, max_tokens=800, timeout=20.0,
                      model=AUDIO_MODEL, audio=Wav.bytes(Wav.read_file(args[1])))
        print(r)
        print("->", parse_heard(r, target, None))
        return 0
    if cmd == "speak":
        import struct
        from array import array as _array
        from cicada.core.speak import SpeakEngine
        Log.echo = "--log" in args
        key = AIKey(key_file())
        ling = LingClient(key)
        settings = AppSettings(target=opt("--from", "zh-CN"), speakTo=opt("--to", "en"))
        out = bytearray()

        class Collect:
            def write(self, pcm):
                out.extend(pcm)

            def drain(self):
                pass

            def close(self):
                out.extend(bytes(24000 // 2 * 2))  # half a second between sentences
        eng = SpeakEngine(ling, Translator(ling), settings, player=Collect)
        eng.on_change(lambda: eng.last and eng.stage == "speaking" and print("  %s\n  → %s" % eng.last, flush=True))
        done = threading.Event()
        src = PcmAudioSource(args[1], 0)
        src.on_ended = lambda why: done.set()
        eng.start(src)
        done.wait()
        time.sleep(1)
        while not eng._work.empty() or eng.stage not in ("hearing", "idle"):
            time.sleep(0.2)
        eng.stop()
        path = opt("--out", "speak-out.wav")
        pcm = _array("h")
        pcm.frombytes(bytes(out))
        with open(path, "wb") as f:
            f.write(Wav.bytes(pcm, rate=24000))
        print("%d sentences spoken, %.1f s of voice in %s" % (eng.spoken, len(pcm) / 24000, path))
        return 0
    if cmd == "listen":
        Log.echo = "--log" in args
        if not os.environ.get("CICADA_HOME"):
            Paths.home_override = tempfile.mkdtemp(prefix="cicada-cli-")
        key = AIKey(key_file())
        if key.read() is None:
            print("no Ling key (set CICADA_KEY_FILE)")
            return 2
        settings = AppSettings(target=opt("--target", "zh-CN"))
        ling = LingClient(key)
        store = SessionStore()
        notes = NotesEngine(ling, store)
        engine = ListenEngine(ling, Translator(ling), store, notes, settings)
        shown = {}
        lock = threading.Lock()
        started = time.monotonic()

        def changed():
            sid = engine.session_id
            if sid is None:
                return
            with lock:
                for l in store.lines(sid):
                    text = "%s\n%s→ %s" % (l.src, " " * 17, l.dst or "…")
                    if shown.get(l.id) == text:
                        continue
                    tag = "upd" if l.id in shown else "new"
                    shown[l.id] = text
                    print("[%5.1f] %s %s %-5s %s" % (time.monotonic() - started, tag, clock(l.t), l.srcLang, text), flush=True)
        engine.on_change(changed)
        ended = threading.Event()
        src = PcmAudioSource(args[1], float(opt("--speed", "1")))
        src.on_ended = lambda why: ended.set()
        engine.start(src, "file")
        ended.wait()
        time.sleep(1.5)
        engine.stop()
        sid = engine.session_id
        if "--notes" in args:
            for _ in range(120):
                s = store.get(sid)
                if s and s.notes and s.notes.final:
                    break
                time.sleep(1)
        store.flush()
        s = store.get(sid)
        print("\n%d lines in %s" % (len(s.lines) if s else 0, os.path.join(Paths.sessions(), sid)))
        if s and s.notes:
            n = s.notes
            print("notes%s: %s\n  %s" % (" (final)" if n.final else "", n.title, n.summary))
            for t in n.topics:
                print("  %s %s: %s" % (clock(t.start), t.title, " / ".join(t.points)))
            for t in n.todos:
                print("  [ ] %s (%s)" % (t.text, t.owner))
        return 0
    print("unknown command", cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
