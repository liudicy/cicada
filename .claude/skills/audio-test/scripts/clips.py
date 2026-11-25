#!/usr/bin/env python3
"""Writes the room test's clips into a folder (16 kHz mono WAV, 52 s each, on one timeline):

  mac.wav    five English sentences (Samantha) at 0, 10, 20, 30, 40 s: the online side, from the speakers
  table.wav  six Chinese sentences (Tingting) for the ESP32 speaker: three in the gaps (6, 25, 47 s),
             three over the Mac's speech (11, 31, 41 s)
  music.wav  chords and a beat, no words: what the Mac plays instead of mac.wav in the music round

For 同声传译 (speak-round.sh):
  me1.wav … me3.wav  what "I" say, one sentence each (Tingting), for the ESP32 while the talk key is held
  meeting.wav        the online side talking without a break (Samantha, the five sentences twice), from
                     the speakers while I talk: its echo must not be what gets interpreted

Different languages on the two sides, so every line in the record says where it came from.
Usage: clips.py <folder>"""
import array, math, os, random, subprocess, sys, wave

MAC = ["Revenue grew twelve percent compared to last quarter, mostly from enterprise.",
       "The mobile team shipped offline mode two weeks ago, and crashes dropped by half.",
       "We still have three open roles in engineering and one in design.",
       "Customers keep asking for better export options before summer.",
       "The offsite budget needs approval by Friday, so send comments soon."]
TABLE = ["我同意这个数字。", "等一下，企业版具体涨了多少？", "设计那个岗位很急。", "好的，没问题。", "导出功能我们下周排期。", "周四之前我会回复。"]
TABLE_AT = [6, 11, 25, 31, 41, 47]
ME = ["我们下周三之前可以把测试做完。", "价格方面我需要先和财务确认一下。", "这个问题我会后发邮件给大家。"]
RATE, LENGTH = 16000, 52


def say(voice, text, out):
    aiff = out + ".aiff"
    subprocess.run(["say", "-v", voice, "-o", aiff, text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@%d" % RATE, "-c", "1", aiff, out], check=True)
    os.remove(aiff)
    w = wave.open(out)
    return array.array("h", w.readframes(w.getnframes()))


def write(path, pieces):
    buf = array.array("h", [0] * (RATE * LENGTH))
    for samples, at in pieces:
        start = int(at * RATE)
        buf[start:start + len(samples)] = samples
    with wave.open(path, "w") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(buf.tobytes())


def music():
    out, chords = array.array("h"), [(220, 277, 330), (196, 247, 294), (174, 220, 262), (196, 247, 294)]
    for i in range(RATE * LENGTH):
        t = i / RATE
        v = sum(math.sin(2 * math.pi * f * t) for f in chords[int(t / 2) % 4]) * 0.18 * (0.7 + 0.3 * math.sin(math.pi * t))
        beat = t % 0.5
        if beat < 0.08:
            v += 0.35 * math.sin(2 * math.pi * 60 * t) * (1 - beat / 0.08)
        if 0.25 < beat < 0.28:
            v += 0.15 * (random.random() * 2 - 1)
        out.append(int(max(-1, min(1, v)) * 30000))
    return out


if __name__ == "__main__":
    folder = sys.argv[1]
    os.makedirs(folder, exist_ok=True)
    tmp = os.path.join(folder, "piece.wav")
    write(os.path.join(folder, "mac.wav"), [(say("Samantha", s, tmp), i * 10) for i, s in enumerate(MAC)])
    write(os.path.join(folder, "table.wav"), [(say("Tingting", s, tmp), at) for s, at in zip(TABLE, TABLE_AT)])
    write(os.path.join(folder, "music.wav"), [(music(), 0)])
    for i, sentence in enumerate(ME, 1):
        say("Tingting", sentence, os.path.join(folder, "me%d.wav" % i))
    talk, at = [], 0.0
    for sentence in MAC * 2:
        samples = say("Samantha", sentence, tmp)
        talk.append((samples, at))
        at += len(samples) / RATE + 0.3
    write(os.path.join(folder, "meeting.wav"), talk)
    os.remove(tmp)
    print("clips in", folder)
