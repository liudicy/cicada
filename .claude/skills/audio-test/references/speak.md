# 同声传译: what I say into the meeting

What 279d045, 08f316b and 7106021 were measured with. `scripts/speak-round.sh <label> [quiet|meeting|silent] [volume]`, env `VP` (`speakVP`, default on as in the app), `MIC` (打开麦克风 during the round), `SPEAKMIC` (the talk key's mic, default the MacBook's), `OUT`. Three presses, about 50 s a round. It needs a working AI service (`lsctl aiState`; Ling speaks with Ming).

## The conversation

| Press | Key held for | ESP32 (me, 10 cm from the mic) | Speakers |
|---|---|---|---|
| 1 | about 4 s | 我们下周三之前可以把测试做完。 | `quiet`: nothing; `meeting`: `meeting.wav`, English without a break, through all three presses |
| 2 | about 4 s | 价格方面我需要先和财务确认一下。 | same |
| 3 | about 4 s | 这个问题我会后发邮件给大家。 | same |

`silent` holds the key the same way with nobody speaking (and the meeting playing, or at volume 0 for a quiet room). `MIC=on` adds the room mic: my sentences must not show up as room lines, since the room mic hears silence while I hold the key and while the translation is read out.

## Reading a round

```
== meeting: presses=3 sent=3 failed=0 me_lines=3 mine_heard: 86% 100% 100% english_in_mine=0 voiced=3 skipped_silent=0 in_room_lines: 0% 0% 0%
   release→text 2.97s, text→translation 0.00s
   voice: 8 chunks to BlackHole 2ch, first audio 4.12s after release
   me| 我们下周三之前可以把这个任务做完。  =>  We can finish this task by next Wednesday.
```

`mine_heard` is how much of each of my sentences is in what was sent; `english_in_mine` the meeting's words in it (its echo, interpreted as me). `voiced` counts the voices that reached BlackHole (`spoke … chunks`); `skipped_silent` the presses PressSpeech found nobody speaking in. Ming answers recognition and translation together: `text→translation` is 0 and `release→text` is the whole call.

## Pass line (2026-11-06, MacBook Pro 14, speakers at 56 %)

| Round | Command | Pass |
|---|---|---|
| Quiet | `speak-round.sh quiet quiet 56` | sent 3; mine ≥ 90 %; voiced 3 |
| Meeting playing | `speak-round.sh meeting meeting 56` | mine ≥ 80 %; `english_in_mine` 0 and no meeting content in the `me|` lines |
| Silent, meeting playing | `speak-round.sh sm silent 56` | sent 0 |
| Silent, quiet room | `speak-round.sh sq silent 0` | sent 0 (see below) |
| Room mic on, quiet | `MIC=on speak-round.sh mq quiet 56` | as quiet; `in_room_lines` 0 % |
| Room mic on, meeting playing | `MIC=on speak-round.sh mm meeting 56` (and at 100) | as meeting playing (log `voice mic: processing on` / `off` per press) |
| Room mic on, silent, meeting playing | `MIC=on speak-round.sh msm silent 100` | sent 0 |

2026-11-10: the room mic is heard through the echo-cancelling unit with processing off (`roomEcho:bypass`, the default) and a press turns it on. Room mic on, meeting playing went from 0/3 (the plain mic, `played through 100 % … (echo)`) to 3/3 at 100/100/100 % in seven rounds at 56 and 100 %; silent presses 0 sent. `roomEcho:off` brings back the plain mic and the old drop. Run `lsctl source:auto` first if the dev build listens to a fixed language: the room is recognized in it, and the table's Chinese scores 0 %.

Two rounds right after room rounds had every press at 0.0 s (unit setting changed while running; fixed by stop, set, start) and once more without a cause in the log; the log line `voice mic: N renders since the last change` says whether the unit kept running.

What it found: with the plain mic (`VP=off`) the meeting's English came back from the speakers and Ming interpreted it as me — my sentences 50/27/23 %, the meeting sent back into itself, and a silent press sent the meeting back 3 of 3 times. Through echo cancellation: 86–100 %, none of the meeting. A silent press in a quiet room came back as 嗯 → "Hmm." until PressSpeech and the filler check.

## 不用按键 (hands-free)

`lsctl handsFree:on`; the unit runs the whole time with Apple's advanced ducking at max (`VoiceMic.advancedDucking`), `HandsFreeDetector` cuts sentences, and each goes through the press pipeline. Debug: `handsFreeDump:<path>` writes the echo-cancelled stream as raw 16 kHz float32; the log has `hands-free: voice began / sentence of / only … of voice / … chars, too short / the meeting's own words`.

| Round | What plays | Pass |
|---|---|---|
| Quiet | ESP32 says one sentence, nothing on the speakers | ≥ 90 % |
| Meeting 56 % | meeting from the speakers, ESP32 talks over it | ≥ 70 %, none of the meeting's words |
| Two sentences | the same, 2 s apart | both sent |
| Meeting only, 100 % | nobody talks, 5 rounds | 0 sent |

2026-11-11 (MacBook Pro 14, ESP32 10 cm from the mic, the sentence `我同意这个数字。设计那个岗位很急，周四之前我会回复。`, scored on the `me` lines). Rounds were run before the echo check, the three-unit minimum and listening-only were added, except where marked:

- Quiet: 23/23 ×3.
- Meeting 56 %: 20, 20, 18, 16, 18/23; with the final filters 20, 16, 16. The first word or two is lost: the unit takes the voice away for ~0.5 s before the ducking holds.
- Two sentences 2 s apart: 4 of 4 sent (one only after the round's record had ended: room noise held the sentence open to the 20 s cut).
- Meeting 100 % with the ESP32: nothing detected (too quiet there; the iPhone was louder).
- Meeting only, 100 %: before the echo check 2 of 15 sentences heard were the meeting's own words ("营收增长；四名工程师；下半年"); after it, none in 5 rounds. The check itself hasn't been seen firing on a reproduced leak yet.
- The other sends in those rounds ("妈妈，我饿了。", "云南是不是雨季？", "喂。", "咳咳。") were people in the room: a minute of the idle stream with nothing playing ran at −7 to −15 dB and the on-device recognizer heard Chinese speech in it.

Unit ducking, measured on the stream (share of 200 ms frames of the ESP32's sentence over −45 dB): min 12/27 at 56 %, 3/27 at 100 %; advanced max 23 and 15; plain max 25 and 23, but that ducks the meeting ~25 dB for as long as the unit runs, Cicada's capture too (−65 against −40 dB). Advanced max dips Cicada's capture to −66 dB only while someone speaks near the mic.

To do, in a quiet room: meeting only for 5 minutes at 56 % and 100 %; the rounds above again on the final build with each sentence matched to its START/END; the talk-key rounds with hands-free off and on, and `MIC=on`; `voiced` against sent.

## Open

- **Hands-free hears everyone near the Mac as me**, and each loud stretch costs a Ming call. While it runs the unit's processing is on, so other apps hear the built-in mic muted (#24); it runs only while a meeting is listened to, when the meeting hears the virtual mic. Not measured: a real voice, typing, music.

- **Sounds that aren't speech.** In a quiet room a silent press with typing nearby went out as "The sound of typing on a computer keyboard." (Ming described the sound). The on-device recognizer can't vote it down: it heard 0 characters of a real sentence too.
- **Voice output stalls.** Now and then a sentence's voice to BlackHole stops until the next one's stall check rebuilds the output (`voice output stalled … rebuilt`): seen with echo cancellation on and off, once a sentence going out 8 s late. Count `voiced` against `sent`.
- **The ports** have no echo cancellation on the talk key: Windows (b155b46) and Linux drop a press the computer played through for more than half, so talking over the other side isn't sent there. Their silent-press and filler checks are unit-tested and, on Windows, checked in the VM with `cicadactl speak silence.wav` / `me-zh.wav`; real echo needs a real PC.
- **Not measured yet:** a real voice; AirPods as the talk mic (only that it no longer crashes); Windows and Linux (no audio in the VMs).
