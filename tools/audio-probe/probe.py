"""Can a model on an aggregator hear meetings the way Ming does for the ports?

Sends each clip through the ports' listening request (the Linux prompt, instruction and parser, word
for word) to Ming on Ling and to audio models on ZenMux, and reports per model: latency, whether the
reply parsed, the language it reported, how far the original is from the known text, and the
translation. Keys are read from the dev app's 0600 files and never printed.

    python3 -I tools/audio-probe/probe.py <clips folder> [--runs 2] [--models a,b] > report.md
"""
import argparse
import base64
import json
import os
import re
import statistics
import sys
import time
import urllib.error
import urllib.request
import wave
from array import array

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "linux"))
from cicada.core import translator  # noqa: E402
from cicada.core.segmenter import Segmenter  # noqa: E402

SUPPORT = os.path.expanduser("~/Library/Application Support/LiveSubs Dev")
LING = ("ling", "https://api.ant-ling.com/v1/", "Ming-3.0-audio-flash")
ZENMUX = "https://zenmux.ai/api/v1/"
CANDIDATES = [
    "google/gemini-3.5-flash-lite", "google/gemini-3.1-flash-lite", "google/gemini-3.8-flash",
    "qwen/qwen3.8-omni-flash", "xiaomi/mimo-v2.6-flash", "bytedance/doubao-seed-2.0-mini",
]


def key(name):
    path = os.path.join(SUPPORT, "ling-api-key" if name == "ling" else "ai-key-" + name)
    return open(path).read().strip()


def wav_bytes(samples: array) -> bytes:
    import io
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        w.writeframes(samples.tobytes())
    return buf.getvalue()


def clips(folder):
    """(name, wav, expected text or None, spoken language or None)."""
    out = []
    for f in sorted(os.listdir(folder)):
        if f.endswith(".wav") and f != "sample.wav":
            name = f[:-4]
            text = open(os.path.join(folder, name + ".txt")).read().strip()
            lang = None if name.startswith("none") else "zh-CN" if name.startswith(("zh", "mix")) else name.split("-")[0]
            out.append((name, open(os.path.join(folder, f), "rb").read(), text, lang))
    # The sample meeting, cut the way the ports cut it (no known text: compare the models).
    path = os.path.join(folder, "sample.pcm")
    if not os.path.exists(path):
        return out
    # afconvert writes WAVE_FORMAT_EXTENSIBLE, which `wave` won't read: take the data chunk itself.
    raw = open(path, "rb").read()
    at = 12
    while raw[at:at + 4] != b"data":
        at += 8 + int.from_bytes(raw[at + 4:at + 8], "little")
    samples = array("h", raw[at + 8:at + 8 + int.from_bytes(raw[at + 4:at + 8], "little")])
    seg = Segmenter()
    got = []
    seg.on_segment = got.append
    seg.feed(samples); seg.flush()
    for s in got:
        out.append(("sample-%d" % s.index, wav_bytes(s.samples), None, None))
    return out


def ask(model, wav, target, hint):
    """One listening request. Returns (ms, reply text or None, error or None)."""
    if model == LING[2]:
        base, k = LING[1], key("ling")
        audio = {"type": "audio_url", "audio_url": {"url": "data:audio/wav;base64," + base64.b64encode(wav).decode()}}
        extra = {"thinking": {"type": "disabled"}}
    else:
        base, k = ZENMUX, key("zenmux")
        data = base64.b64encode(wav).decode()
        # Qwen's omni models take the audio as a data URL inside input_audio (DashScope's form).
        if model.startswith("qwen/"):
            data = "data:audio/wav;base64," + data
        audio = {"type": "input_audio", "input_audio": {"data": data, "format": "wav"}}
        extra = {"reasoning": {"enabled": False}}
    seconds = (len(wav) - 44) / 32000.0
    body = {"model": model, "stream": False, "temperature": 0.2, "max_tokens": translator.hear_tokens(seconds),
            "messages": [{"role": "system", "content": translator.hear_prompt(target, hint, [])},
                         {"role": "user", "content": [audio, {"type": "text", "text": translator.hear_instruction(target)}]}]}
    body.update(extra)
    req = urllib.request.Request(base + "chat/completions", json.dumps(body).encode(), {
        "Authorization": "Bearer " + k, "Content-Type": "application/json", "User-Agent": "Cicada-probe"})
    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            root = json.load(r)
        ms = (time.monotonic() - started) * 1000
        msg = root["choices"][0]["message"]
        usage = root.get("usage") or {}
        reasoning = (usage.get("completion_tokens_details") or {}).get("reasoning_tokens")
        if reasoning:
            print("  %s reasoned %s tokens" % (model, reasoning), file=sys.stderr)
        return ms, msg.get("content") or "", None
    except urllib.error.HTTPError as e:
        return (time.monotonic() - started) * 1000, None, "http%d %s" % (e.code, e.read()[:160].decode("utf-8", "replace"))
    except Exception as e:  # noqa: BLE001
        return (time.monotonic() - started) * 1000, None, type(e).__name__


def distance(a, b):
    """Character error rate of `a` against `b`, punctuation and case ignored (words for English)."""
    def norm(s):
        s = re.sub(r"[^\w]+", " ", s.lower()).strip()
        return s.split() if re.search(r"[a-z]", s) and not re.search(r"[぀-鿿가-힯]", s) else list(s.replace(" ", ""))
    x, y = norm(a), norm(b)
    if not y:
        return 0.0 if not x else 1.0
    prev = list(range(len(y) + 1))
    for i, cx in enumerate(x, 1):
        cur = [i]
        for j, cy in enumerate(y, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (cx != cy)))
        prev = cur
    return prev[-1] / len(y)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder")
    ap.add_argument("--runs", type=int, default=2)
    ap.add_argument("--models", default=",".join([LING[2]] + CANDIDATES))
    a = ap.parse_args()
    models = a.models.split(",")
    items = clips(a.folder)
    results = {m: [] for m in models}
    for name, wav, text, lang in items:
        target = "en" if (lang or "").startswith("zh") else "zh-CN"
        for m in models:
            for run in range(a.runs):
                ms, reply, err = ask(m, wav, target, None)
                heard = translator.parse_heard(reply, target, None, (len(wav) - 44) / 32000.0) if reply is not None else None
                row = {"clip": name, "run": run, "ms": round(ms), "err": err, "reply": reply,
                       "lang": heard.lang if heard else None, "original": heard.original if heard else None,
                       "translation": heard.translation if heard else None,
                       "cer": None if text is None or not text or heard is None else round(distance(heard.original, text), 3),
                       "expected": text, "spoken": lang}
                results[m].append(row)
                print("%-34s %-9s %5d ms %s" % (m, name, ms, err or (heard.original[:40] if heard else "(dropped)")), file=sys.stderr)
                if m == LING[2]:
                    time.sleep(0.6)  # Ling allows ~2 requests a second
    json.dump(results, open(os.path.join(a.folder, "..", "results.json"), "w"), ensure_ascii=False, indent=1)
    report(results)


def report(results):
    print("| model | median ms | p90 ms | errors | speech heard | language right | mean CER | no-speech dropped |")
    print("|---|---|---|---|---|---|---|---|")
    for m, rows in results.items():
        ok = [r for r in rows if not r["err"]]
        ms = sorted(r["ms"] for r in ok) or [0]
        speech = [r for r in ok if r["spoken"]]
        heard = [r for r in speech if r["original"]]
        lang_ok = [r for r in heard if r["lang"].split("-")[0] == r["spoken"].split("-")[0]]
        cers = [r["cer"] for r in heard if r["cer"] is not None]
        none = [r for r in ok if r["clip"].startswith("none")]
        print("| %s | %d | %d | %d/%d | %d/%d | %d/%d | %s | %d/%d |" % (
            m, statistics.median(ms), ms[min(len(ms) - 1, int(len(ms) * 0.9))], len(rows) - len(ok), len(rows),
            len(heard), len(speech), len(lang_ok), len(heard), "%.3f" % statistics.mean(cers) if cers else "-",
            sum(1 for r in none if not r["original"]), len(none)))


if __name__ == "__main__":
    main()
