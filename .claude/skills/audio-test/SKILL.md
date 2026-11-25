---
name: audio-test
description: Test Cicada with real sound on the Mac — a scripted meeting from the speakers, a person in the room played by an ESP32 speaker next to the mic, the talk key held from the shell — and score each round against a pass line. Use after any change to the room mic (打开麦克风, EchoGate, EchoMatch), 同声传译 (the talk key, its mic, echo cancellation, the virtual mic), voice activity or recognition from a mic; or for "实测", "测回声", "测同声传译", "混合会议实测", "抢话测试".
---

# Audio test

Real sound through real speakers and mics, on the Mac (the reference). The Windows and Linux VMs have no speakers or mic: their rounds are UI and state only (`cicadactl mic on`, `roomechosim`). One file per feature under `references/`: read the one for what changed.

| Feature | Reference | Script |
|---|---|---|
| 打开麦克风: echo, people at the table, music, headphones | `references/room.md` | `scripts/room-round.sh` |
| 同声传译: what I say, with the meeting playing | `references/speak.md` | `scripts/speak-round.sh` |

## The cast

- **The online side:** clips from the MacBook speakers (`afplay`), English, Samantha.
- **A person in the room** (someone at the table, or me holding the talk key): an M5Stack StopWatch's speaker about 10 cm from the MacBook Pro's mics, which sit under the left speaker grille near the hinge (by Esc), facing it, not on the right grille. `~/workshop/15.experiment/m5-stopwatch/tablevoice/tv.py play <wav> [--at <utc>]` (START/END on stdout, blocks until END). Chinese, Tingting, so every record line says which side it came from. At 30 cm it reaches only −22 dB and half the lines are lost to level alone; its volume is already the ceiling.
- **What the meeting app hears:** BlackHole 2ch, the virtual mic. `lsctl speakOut:<file.m4a>` keeps a copy of each voice sent.
- **The talk key:** `lsctl talkDown` / `talkUp`, with the real mic.

The ESP32 belongs to the `esp32-stopwatch-meeting-mic-test` session: message it before using the port (one `tv.py` at a time) and when done. Flashing it is that session's user's call.

Scripts: `clips.py` writes every clip into `$WORK` (default `$TMPDIR/cicada-room-test`), `audio.swift` sets the output device and an input's level (`audio list`), the round scripts build both on first use, drive the dev build with `tools/lsctl`, and score from the meeting record and `/tmp/livesubs-dev-debug.log`.

## Before the first round

- `ListAgents`: tell the sessions on this repo you hold the dev build, the speakers and the mic, and ask who used it last; nobody else rebuilds or drives `build/Cicada.app` until you say so. Build it yourself and check the panel's `main @ <commit>` line is yours.
- Nothing else makes sound: quit the release Cicada (`osascript -e 'quit app id "com.wquguru.cicada"'`; if it hangs, `kill -TERM`), shut simulators (`xcrun simctl shutdown all`). `pmset -g assertions | grep -i audio` lists who plays or records. Ask before closing what the user may be using.
- `audio list`: output the MacBook speakers, the MacBook mic's level about 0.5. **AirPods take the output when they connect** and the clips then play in the user's ears: the scripts force the output every round; ask the user before playing out loud.
- The terminal has no microphone permission: `ffmpeg -f avfoundation` records zeros. Judge the mic through the app only.
- 同声传译 needs a working AI service (`lsctl aiState`); the dev build's service is the user's setting: switch it only for the test and put it back.

## Designing a new scenario

Write it down as a conversation before scripting it: who says what, when, from where (speakers, ESP32, nobody), and which key is held. Give each side its own language, one sentence per row with its time. Then the pass line: what must appear in which part of the record (`speaker` "me" or "them", `via` "room"), what must not (the other side's language), and a number for each. Run a round twice before believing a single bad cell: the ESP32 is quiet and rounds vary. Add the scenario and its numbers to the feature's reference.

## After

`lsctl mic:off`, `stop`, `speakOff` if you turned it on, `roomEcho:off`, `roomGate:on`, `speakVP:on` (the default), `speakMic:` (the user's), `roomMicSilent:off`, the AI service back; output and volume back to what the user had; tell the ESP32 session and the repo's sessions you're done. Put the numbers in the commit message.
