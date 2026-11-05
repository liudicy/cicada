"""The dev build's control socket ($XDG_RUNTIME_DIR/cicada-dev.sock, this user only), the Linux
counterpart of tools/lsctl and the Windows named pipe; scripts/cicadactl talks to it. One command
per connection, one JSON line back. Never in release builds.

  state | start | stop | feed <wav> | sample | view notes|subtitles | show records|notes|settings|onboarding
  target <code> | key-reload | windows | select <record id> | append <record id> <n> (a growing meeting)
  speak-enable on|off | speak on|off (同声传译) | quit
  calls <program=name,…>|none|real (meeting apps in a call) | endtimes <silence> <countdown> <grace>|off | endkeep
  notes-tab notes|transcript | notes-search <text> | notes-wide on|off | onboarding-step <n> | settings-scroll <0-1>
  pill (the records window capsule's widget sizes)"""
from __future__ import annotations

import os
import socket
import threading

from gi.repository import GLib

from ..core import jsonfmt
from ..core.support import Log, Paths


def path() -> str:
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "cicada-dev.sock")


def start(app) -> None:
    p = path()
    try:
        os.unlink(p)
    except OSError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    old = os.umask(0o077)
    try:
        server.bind(p)
    finally:
        os.umask(old)
    server.listen(4)
    threading.Thread(target=_serve, args=(app, server), name="Debug", daemon=True).start()
    Log.d("debug: listening on %s" % p)


def _serve(app, server) -> None:
    while True:
        conn, _ = server.accept()
        with conn:
            try:
                data = b""
                while not data.endswith(b"\n"):
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                reply = _on_main(app, data.decode().strip())
            except Exception as e:  # noqa: BLE001 - report, don't kill the server
                reply = {"ok": False, "error": "%s: %s" % (type(e).__name__, e)}
            conn.sendall((jsonfmt.write(reply, pretty=False) + "\n").encode())


def _on_main(app, line: str) -> dict:
    done = threading.Event()
    box = {}

    def run():
        try:
            box["r"] = command(app, line)
        except Exception as e:  # noqa: BLE001
            box["r"] = {"ok": False, "error": "%s: %s" % (type(e).__name__, e)}
        done.set()
        return False
    GLib.idle_add(run)
    done.wait(10)
    return box.get("r", {"ok": False, "error": "timeout"})


def _window(w) -> dict | None:
    if w is None:
        return None
    x, y = w.get_position()
    width, height = w.get_size()
    gdk = w.get_window()
    return {"visible": w.get_visible(), "x": x, "y": y, "w": width, "h": height, "title": w.get_title(),
            "xid": gdk.get_xid() if gdk is not None and hasattr(gdk, "get_xid") else None,
            "acceptFocus": w.get_accept_focus(), "active": w.is_active()}


def _speakers(app, s) -> dict:
    from ..core import speakers
    out = {"on": app.settings.speakerVoices, "available": app.voices_available, "model": app.speakers._model is not None}
    if s is not None:
        vnums = speakers.voice_numbers(s.lines)
        out.update({"voices": sorted({l.voice for l in s.lines if l.voice is not None}),
                    "shown": {str(v): n for v, n in vnums.items()}, "names": {str(k): v for k, v in speakers.names(s).items()},
                    "tagged": sum(1 for l in s.lines if l.voice is not None), "lines": len(s.lines),
                    "byVoice": [[l.id, l.voice, l.src[:40]] for l in s.lines]})
    return out


def updates_notified():
    from ..core import updates
    return updates.notified()


def command(app, line: str) -> dict:
    parts = line.split(" ", 1)
    cmd, arg = parts[0], (parts[1] if len(parts) > 1 else "")
    listen = app.listen
    if cmd == "state":
        sid = listen.session_id
        s = app.store.get(sid) if sid else None
        last = s.lines[-1] if s and s.lines else None
        n = app.notes.notes
        return {"ok": True, "listening": listen.listening, "session": sid, "source": listen.source_kind,
                "lines": len(s.lines) if s else 0, "last": {"src": last.src, "dst": last.dst, "lang": last.srcLang} if last else None,
                "pending": listen.pending, "problem": listen.problem, "problemKind": listen.problem_kind, "heardSeconds": round(listen.heard_seconds, 1),
                "peak": round(listen.peak, 4), "notes": {"title": n.title, "topics": len(n.topics), "status": app.notes.status, "final": n.final},
                "key": app.ling.key_state, "view": app.settings.view, "target": app.settings.target_code,
                "ui": __import__("cicada.core.strings", fromlist=["language"]).language, "records": len(app.store.all()),
                "tray": app.tray is not None, "home": Paths.data(),
                "speak": {"enabled": app.settings.speakEnabled, "room": app.room.on, "active": app.speak.active, "stage": app.speak.stage,
                          "spoken": app.speak.spoken, "problem": app.speak.problem, "to": app.speak.target,
                          "last": list(app.speak.last) if app.speak.last else None},
                "speakers": _speakers(app, s),
                "ending": {"title": app.ending_title(app.ending), "left": app.ending_left(app.ending),
                           "reason": repr(app.ending.reason)} if app.ending else None,
                "autoEnded": app.auto_ended, "fakeCalls": app.fake_calls,
                "endTimes": list(app.end_times) if app.end_times else None,
                "inCall": dict(app.end_watch.in_call) if app.end_watch else None}
    if cmd == "start":
        app.toggle_listening() if not listen.listening else None
        return {"ok": True}
    if cmd == "stop":
        app.stop_listening()
        return {"ok": True}
    if cmd == "updatecheck":  # the Mac's updateCheck: check the feed now (CICADA_UPDATE_FEED in a dev build)
        app.updates.check_now()
        return {"ok": True}
    if cmd == "updatestate":
        u = app.updates
        return {"update": u.update.version if u.update else None, "notified": updates_notified(),
                "afterMeeting": u.after_meeting, "failure": u.failure}
    if cmd == "feed":
        if not os.path.isfile(arg):
            return {"ok": False, "error": "no such file"}
        app.feed(arg)
        return {"ok": True}
    if cmd == "sample":
        app.play_sample()
        return {"ok": True}
    if cmd == "view":
        app.set_view(arg)
        return {"ok": True, "view": app.settings.view}
    if cmd == "show":
        {"records": app.show_records, "notes": app.show_notes, "settings": app.show_settings,
         "onboarding": app.show_onboarding}[arg]()
        return {"ok": True}
    if cmd == "target":
        app.settings.target = arg
        app.settings.save()
        return {"ok": True, "target": app.settings.target_code}
    if cmd == "key-reload":
        app.key.reload()
        app.ling.key_changed()
        threading.Thread(target=app.ling.check, daemon=True).start()
        return {"ok": True}
    if cmd == "windows":
        return {"ok": True, "notes": _window(app.notes_window), "records": _window(app.records_window),
                "settings": _window(app.settings_window), "onboarding": _window(app.onboarding)}
    if cmd == "pill":
        # The records window's capsule as a tree of allocations (checking it against the Mac's sizes).
        def tree(w, depth=0):
            a = w.get_allocation()
            ctx = w.get_style_context()
            out = ["%s%s %dx%d+%d+%d %s" % ("  " * depth, type(w).__name__, a.width, a.height, a.x, a.y,
                                            ".".join(ctx.list_classes()))]
            if hasattr(w, "get_children") and depth < 8:
                for c in w.get_children():
                    out += tree(c, depth + 1)
            return out
        return {"ok": True, "tree": tree(app.records_window.listen_box)} if app.records_window else {"ok": False}
    if cmd == "speakers":
        # speakers on|off; speakers <session id>: the voices of a record
        if arg in ("on", "off"):
            app.set_speaker_voices(arg == "on")
            return {"ok": True, "on": app.settings.speakerVoices}
        return {"ok": True, **_speakers(app, app.store.get(arg))}
    if cmd == "speak-enable":
        return {"ok": app.set_speak_enabled(arg == "on"), "enabled": app.settings.speakEnabled, "realMic": app.room.real_mic}
    if cmd == "speak":
        if (arg == "on") != app.speak.active:
            app.toggle_speaking()
        return {"ok": True, "speaking": app.speak.active}
    if cmd == "select":
        app.show_records()
        app.records_window.selected = arg
        app.records_window.fill()
        return {"ok": True}
    if cmd == "append":
        # A meeting growing line by line, as while listening: `append <id> <n>`.
        from ..core.models import TranscriptLine
        sid, n = arg.split()
        s = app.store.get(sid)
        if s is None:
            return {"ok": False, "error": "no such record"}
        base = len(s.lines)

        def add(i=[0]):
            k = base + i[0]
            app.store.append(sid, TranscriptLine(id="h%d-%d" % (k + 1, k + 1), t=k * 4.2, src="Appended line %d." % (k + 1),
                                                 dst="追加的第 %d 句。" % (k + 1), srcLang="en", dstLang="zh-CN"))
            i[0] += 1
            return i[0] < int(n)
        GLib.timeout_add(300, add)
        return {"ok": True}
    if cmd == "calls":
        if arg == "real":
            app.fake_calls = None
        elif arg in ("", "none"):
            app.fake_calls = {}
        else:
            app.fake_calls = dict(p.split("=", 1) for p in arg.split(","))
        return {"ok": True, "fakeCalls": app.fake_calls}
    if cmd == "realcalls":
        from ..core import meeting_end
        return {"ok": True, "calls": meeting_end.calls()}
    if cmd == "endtimes":
        app.end_times = None if arg in ("", "off") else tuple(float(x) for x in arg.split())
        return {"ok": True, "endTimes": app.end_times}
    if cmd == "endkeep":
        app.keep_recording()
        return {"ok": True}
    if cmd in ("notes-tab", "notes-search", "notes-wide"):
        app.show_notes()
        w = app.notes_window
        if cmd == "notes-tab":
            w.set_tab(arg)
        elif cmd == "notes-search":
            w.set_tab("transcript")
            w.search.set_text(arg)
        else:
            w.set_wide(arg == "on")
        return {"ok": True, "tab": w.tab, "wide": w.wide, "matches": len(w.matches), "match": w.match_index}
    if cmd == "rename":
        # `rename <id> <title>`; no title is 恢复自动标题.
        sid, _, title = arg.partition(" ")
        app.store.rename(sid, title)
        s = app.store.get(sid)
        from ..core import session_store
        return {"ok": s is not None, "title": s.title if s else None, "renamed": s.renamed if s else None,
                "shown": session_store.display_title(s) if s else None}
    if cmd == "delete":
        app.store.delete(arg)
        return {"ok": True, "exists": app.store.get(arg) is not None, "live": app.store.live}
    if cmd == "notes-end":
        # The notes window's 结束: `ask`, then `keep` (继续记录) or `end` (结束会议).
        app.show_notes()
        w = app.notes_window
        {"ask": w._ask_end, "keep": lambda: w._end_answer(False), "end": lambda: w._end_answer(True)}[arg]()
        return {"ok": True, "asking": getattr(w, "confirm_end", False), "listening": listen.listening}
    if cmd == "notes-status":
        # How the notes window shows a state the network won't give on demand: `failed`, `invalidKey`…
        app.notes.status = arg
        app.changed()
        return {"ok": True, "status": app.notes.status}
    if cmd == "settings-scroll":
        app.show_settings()
        adj = app.settings_window.get_child().get_vadjustment()
        adj.set_value(float(arg) * (adj.get_upper() - adj.get_page_size()))
        return {"ok": True}
    if cmd == "onboarding-step":
        app.show_onboarding()
        app.onboarding.go(int(arg))
        return {"ok": True, "step": app.onboarding.step if app.onboarding is not None else "done"}
    if cmd == "quit":
        app.quit()
        return {"ok": True}
    return {"ok": False, "error": "unknown command " + cmd}
