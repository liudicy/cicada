# 打开麦克风: the room mic

What cb7762c was measured with. `scripts/room-round.sh <label> [mac|music|none] [volume]`, env `OUT` (`BlackHole` = headphones: nothing reaches the room), `ECHO` (`roomEcho`, default off), `GATE`, `TABLE`. About 75 s a round.

## The conversation (clips.py, one 52 s timeline)

| Time | From | Says |
|---|---|---|
| 0, 10, 20, 30, 40 s | speakers (online) | five English sentences, about 4 s each (`mac.wav`) |
| 6, 25, 47 s | ESP32 (table) | 我同意这个数字。 / 设计那个岗位很急。 / 周四之前我会回复。 — in the online side's gaps |
| 11, 31, 41 s | ESP32 (table) | 等一下，企业版具体涨了多少？ / 好的，没问题。 / 导出功能我们下周排期。 — over the online side |

`music` plays `music.wav` (chords and a beat, no words) instead of the online side; `none` plays nothing.

## Reading a round

```
== speakers56: mac=5 room=3 echo_dropped=0 english_room=0 table: 空100% 抢0% 空75% 抢0% 抢20% 空100%
   echo=true [during=7.8s p80=0.0943 quiet=4.8s floor=0.0043]
```

`english_room` is online speech that got into the room's lines (echo). `空` a table sentence in a gap, `抢` one over the online side, with the share of its characters found. `echo=` is EchoGate's measurement: MacBook speakers about ×20 at 56 %, ×6 at 25 %, AirPods and BlackHole about ×1.

## Pass line (2026-11-06, MacBook Pro 14)

| Round | Command | Pass |
|---|---|---|
| Speakers 25 / 56 / 100 % | `room-round.sh s25 mac 25` … | `english_room` 0; gaps ≥ 75 % |
| Music | `room-round.sh music music 56` | table ≥ 60 % (gaps and over) |
| Headphones | `OUT=BlackHole room-round.sh hp mac 56` | `echo=false`; over ≥ 90 % |
| Then speakers again | `room-round.sh s56b mac 56` | `english_room` 0 (the measurement starts over) |
| Table alone | `room-round.sh alone none` | 6/6 |

Lines over the online side are lost on speakers by design (the gate). With macOS echo cancellation (`ECHO=on`) echo was 0 too but gaps fell to 0–25 %: why its processing is off for the room.

2026-11-10, `ECHO=bypass` (the default: the unit with processing off, gated like the plain mic, so the talk key can turn processing on): s25 / s56 ×4 / s100 `english_room` 0, gaps 88–100 % but one 38 %; headphones `echo=false`, over 100/100/100 %. The plain mic (`ECHO=off`) the same hour: gaps 12–100 %, `english_room` 2 in two of four rounds, and 0 % on every sentence while 同声传译's unit was made (it starves the plain mic).

Also: `lsctl roomMicSilent:on` then `mic:on` shows 麦克风没声音 after about 10 s (log `room mic: silent since it started`, then `still silent`); `roomEchoSim:<on|off|real>` fixes the measurement for UI work.
