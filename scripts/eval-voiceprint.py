# Scores voiceprint models and the clustering behind 说话人识别 on AMI meetings, so a model or
# threshold change is a measured decision. Developer-only, like convert-voiceprint.py.
#
# Lines are cut the way the app hears a meeting: one timeline from the Mix-Headset audio, where the
# person holding the floor owns overlapped speech (a "yeah" under someone else's sentence is part of
# that sentence, as SpeechAnalyzer writes it), cut at pauses and every 10 s. A line's truth is whoever
# talks most in it; a line nobody clearly owns is ambiguous and scores neither way. Each line gets the
# app's fbank, a voiceprint, and ~1.5 s window voiceprints when long enough, all cached per model.
# Scored per line, as the user sees it:
#   shown    lines that get a speaker number
#   right    lines whose number is that speaker's (one number per person, Hungarian matching,
#            so splitting one person in two or merging two people both count as wrong)
#   wrong    lines shown with someone else's number
#   count    meetings whose number of speakers shown equals the people who said 5+ lines
# The sweep picks thresholds on dev by right - 2 × wrong (a wrong name costs more than none), then
# scores test once.
#
# Needs Python 3.11 with onnxruntime "numpy<2" soundfile scipy, the WeSpeaker ONNX files, and
#   git clone https://github.com/pyannote/AMI-diarization-setup
#   amicorpus/<meeting>/audio/<meeting>.Mix-Headset.wav for the dev and test meetings
# usage: python3 scripts/eval-voiceprint.py --ami AMI-diarization-setup --wav wavdir --cache cachedir \
#            --model resnet34=voxceleb_resnet34_LM.onnx [--model campp=voxceleb_CAM++_LM.onnx:cpu] [--jobs 4] [--no-windows]
import argparse, os, time
import numpy as np

# MARK: the app's fbank (SpeakerID.swift `Fbank`, `Voiceprints.embed`)

BINS, FRAME, SHIFT, NFFT, SR = 80, 400, 160, 512, 16000
MIN_SECONDS, MAX_SECONDS = 0.5, 20.0
WINDOW = (0.5 - 0.5 * np.cos(2 * np.pi * np.arange(FRAME) / (FRAME - 1))) ** 0.85

def _mel_banks():
    mel = lambda f: 1127 * np.log(1 + f / 700)
    lo, hi = mel(20), mel(8000)
    delta = (hi - lo) / (BINS + 1)
    x = mel(np.arange(NFFT // 2) * SR / NFFT)
    w = np.zeros((BINS, NFFT // 2 + 1))
    for m in range(BINS):
        left = lo + m * delta
        center, right = left + delta, left + 2 * delta
        w[m, : NFFT // 2] = np.maximum(np.minimum((x - left) / (center - left), (right - x) / (right - center)), 0)
    return w

MELS = _mel_banks()

def fbank(samples):
    """Frames × 80 log-mel, as `Fbank.compute` does for 16 kHz mono samples in -1...1."""
    if len(samples) < FRAME:
        return np.zeros((0, BINS), np.float32)
    n = 1 + (len(samples) - FRAME) // SHIFT
    idx = np.arange(FRAME)[None, :] + SHIFT * np.arange(n)[:, None]
    f = samples.astype(np.float64)[idx] * 32768
    f -= f.mean(1, keepdims=True)
    f[:, 1:] -= 0.97 * f[:, :-1].copy()
    f[:, 0] -= 0.97 * f[:, 0]
    f *= WINDOW
    power = np.abs(np.fft.rfft(f, NFFT)) ** 2
    return np.log(np.maximum(power @ MELS.T, np.finfo(np.float32).eps)).astype(np.float32)

def check_fbank():
    """The reference values SpeakerTests.fbankMatchesKaldi checks the Swift fbank against."""
    t = np.arange(16000) / 16000
    x = 0.3 * np.sin(2 * np.pi * 220 * t) + 0.1 * np.sin(2 * np.pi * 1234 * t) \
        + 0.05 * (((np.arange(16000) * 7919) % 1000) / 1000 - 0.5)
    f = fbank(x)
    assert f.shape == (98, 80), f.shape
    for frame, vals in ((0, [14.668, 16.6069, 12.7853, 20.1031]), (97, [13.7549, 16.6393, 14.6429, 20.1246])):
        assert np.abs(f[frame, [0, 10, 40, 79]] - vals).max() < 0.01, frame
    assert abs(f.mean() - 16.1517) < 0.01, f.mean()

class Model:
    def __init__(self, path, threads, gpu=False):
        import onnxruntime as ort
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = threads
        providers = ["CPUExecutionProvider"]
        if gpu:   # FP16 on the GPU, as the app runs it; fixed shapes only, or it recompiles every call
            providers.insert(0, ("CoreMLExecutionProvider", {"ModelFormat": "MLProgram", "MLComputeUnits": "CPUAndGPU"}))
        self.sess = ort.InferenceSession(path, opts, providers=providers)
        self.seconds = 0.0

    @staticmethod
    def feats(samples):
        """Mean-normalised fbank for a line, or None when too short (as `Voiceprints.embed`)."""
        if len(samples) < MIN_SECONDS * SR:
            return None
        f = fbank(samples[: int(MAX_SECONDS * SR)])
        return f - f.mean(0, keepdims=True) if len(f) >= 50 else None

    def run(self, batch):
        start = time.perf_counter()
        v = self.sess.run(None, {"feats": batch})[0].astype(np.float32)
        self.seconds += time.perf_counter() - start
        n = np.linalg.norm(v, axis=1, keepdims=True)
        return v / np.maximum(n, 1e-12)

    def embed(self, samples):
        """A unit-length voiceprint, or None when the line is too short."""
        f = self.feats(samples)
        return None if f is None else self.run(f[None])[0]

    def embed_all(self, clips, batch=32):
        """Voiceprints of equal-length clips, in fixed-size batches."""
        fs = [self.feats(c) for c in clips]
        out = []
        for i in range(0, len(fs), batch):
            chunk = fs[i: i + batch]
            pad = batch - len(chunk)
            x = np.stack(chunk + [np.zeros_like(chunk[0])] * pad)
            out += list(self.run(x)[: len(chunk)])
        return out

# Window voiceprints: lines this long also get one per WIN_SECONDS window, WIN_HOP apart.
WIN_FROM, WIN_SECONDS, WIN_HOP = 3.0, 1.5, 0.75

def windows(samples):
    n, w, h = len(samples), int(WIN_SECONDS * SR), int(WIN_HOP * SR)
    if n < WIN_FROM * SR:
        return []
    starts = list(range(0, n - w + 1, h))
    if starts[-1] + w < n:
        starts.append(n - w)
    return [samples[s: s + w] for s in starts]

# MARK: AMI lines

LINE_SECONDS, PAUSE = 10.0, 0.3

_splits = {}
def split_of(ami, meeting):
    if not _splits:
        for s in ("train", "dev", "test"):
            for m in open(os.path.join(ami, "lists", s + ".meetings.txt")).read().split():
                _splits[m] = s
    return _splits[meeting]

def lines(ami, meeting):
    """(start, seconds, truth or None) per line, in time order; see the header."""
    turns = []
    with open(os.path.join(ami, "only_words", "rttms", split_of(ami, meeting), meeting + ".rttm")) as f:
        for line in f:
            p = line.split()
            turns.append((float(p[3]), float(p[3]) + float(p[4]), p[7]))
    people = sorted({t[2] for t in turns})
    frames = int(max(t[1] for t in turns) * 100) + 1
    active = np.zeros((len(people), frames), bool)
    holder, since = np.full(frames, -1), np.full(frames, np.inf)
    for s, e, p in sorted(turns):
        a, b = int(s * 100), int(e * 100)
        i = people.index(p)
        active[i, a:b] = True
        take = since[a:b] > s
        holder[a:b][take], since[a:b][take] = i, s
    # Runs of one floor holder, joined across pauses shorter than PAUSE.
    edges = np.flatnonzero(np.diff(holder)) + 1
    runs = []
    for a, b in zip(np.r_[0, edges], np.r_[edges, frames]):
        h = holder[a]
        if h < 0:
            continue
        if runs and runs[-1][0] == h and a - runs[-1][2] <= PAUSE * 100:
            runs[-1][2] = b
        else:
            runs.append([h, a, b])
    out = []
    for _, a, b in runs:
        pieces = int(np.ceil((b - a) / (LINE_SECONDS * 100)))
        for k in range(pieces):
            s, e = a + (b - a) * k // pieces, a + (b - a) * (k + 1) // pieces
            if (e - s) / 100 < MIN_SECONDS:
                continue
            talk = np.sort(active[:, s:e].sum(1))
            top = int(active[:, s:e].sum(1).argmax())
            clear = talk[-1] >= 0.5 * (e - s) and talk[-1] >= 1.5 * talk[-2]
            out.append((s / 100, (e - s) / 100, people[top] if clear else None))
    return out

def cache_path(cache, name, meeting):
    return os.path.join(cache, f"{name}.{meeting}.lines.npz")

def compute(job):
    """Voiceprints of one meeting's lines into the cache (a worker process); returns model seconds."""
    name, path, ami, wav, cache, meeting, threads, gpu = job
    import soundfile as sf
    model, win_model = Model(path, threads), Model(path, threads, gpu)
    audio, sr = sf.read(os.path.join(wav, meeting + ".Mix-Headset.wav"), dtype="float32")
    assert sr == SR and audio.ndim == 1, (sr, audio.shape)
    clips = [audio[int(s * SR): int((s + d) * SR)] for s, d, _ in lines(ami, meeting)]
    embs = [model.embed(c) for c in clips]
    # --no-windows: whole lines only, for models too slow to embed every window (live+vote needs them)
    per_line = [[] if os.environ.get("EVAL_NO_WINDOWS") else windows(c) for c in clips]
    flat = win_model.embed_all([w for ws in per_line for w in ws])
    wins, k = [], 0
    for ws in per_line:
        wins.append(flat[k: k + len(ws)])
        k += len(ws)
    np.savez(cache_path(cache, name, meeting), embs=np.array(embs, dtype=object), wins=np.array(wins, dtype=object))
    return model.seconds + win_model.seconds

class Meeting:
    def __init__(self, name, ami, cache, meeting):
        self.id = meeting
        ls = lines(ami, meeting)
        d = np.load(cache_path(cache, name, meeting), allow_pickle=True)
        self.embs, self.wins = list(d["embs"]), list(d["wins"])
        assert len(self.embs) == len(ls)
        self.seconds = [x[1] for x in ls]
        self.truth = [x[2] for x in ls]

# MARK: clustering, live (`VoiceClusterer`) and after the meeting

NEW_SECONDS, SHOWN_AFTER = 2.0, 5
# `SpeakerLabels.substantive` wants three words; these lines carry no text, so a second stands in.
SUBSTANTIVE_SECONDS = 1.0

def _best(v, sums, norms):
    if not sums:
        return -1, -1.0
    sims = np.stack(sums) @ v / np.maximum(norms, 1e-7)
    i = int(sims.argmax())
    return i, float(sims[i])

def live(m, join, start_new, margin=0.0, vote=False):
    """The app's online clustering. margin: a line moves its voice only when this much surer than
    `join`. vote: a long line goes by its windows' majority, and moves its voice by the agreeing ones."""
    sums, out = [], []
    for v, ws, s in zip(m.embs, m.wins, m.seconds):
        if v is None:
            out.append(None)
            continue
        n = np.array([np.linalg.norm(x) for x in sums])
        if vote and len(ws) >= 3 and sums:
            picks = [_best(w, sums, n) for w in ws]
            agree = {}
            for (i, sim), w in zip(picks, ws):
                if sim >= join:
                    agree.setdefault(i, []).append((sim, w))
            winner = max(agree, key=lambda i: len(agree[i]), default=None)
            if winner is not None and len(agree[winner]) * 2 > len(ws):
                if np.mean([sim for sim, _ in agree[winner]]) >= join + margin:
                    vec = np.mean([w for _, w in agree[winner]], 0)
                    sums[winner] = sums[winner] + vec / np.linalg.norm(vec)
                out.append(winner)
            elif s >= NEW_SECONDS and sum(sim < start_new for _, sim in picks) * 2 > len(ws):
                sums.append(v.copy())
                out.append(len(sums) - 1)
            else:
                out.append(None)
            continue
        best, sim = _best(v, sums, n)
        if best >= 0 and sim >= join:
            if sim >= join + margin:
                sums[best] = sums[best] + v
            out.append(best)
        elif s >= NEW_SECONDS and (not sums or sim < start_new):
            sums.append(v.copy())
            out.append(len(sums) - 1)
        else:
            out.append(None)
    return out

def after(m, threshold, clean=False):
    """Whole-meeting agglomerative clustering (average linkage, cosine) of the lines' voiceprints;
    clean: a long line by the mean of its windows rather than its whole-line voiceprint."""
    from scipy.cluster.hierarchy import fcluster, linkage
    idx = [i for i, v in enumerate(m.embs) if v is not None]
    vecs = []
    for i in idx:
        v = np.mean(m.wins[i], 0) if clean and len(m.wins[i]) >= 3 else m.embs[i]
        vecs.append(v / np.linalg.norm(v))
    out = [None] * len(m.embs)
    if len(idx) < 2:
        return out
    labels = fcluster(linkage(np.stack(vecs), "average", metric="cosine"), 1 - threshold, "distance")
    for i, l in zip(idx, labels):
        out[i] = int(l)
    return out

# MARK: scoring (`SpeakerLabels`)

def shown_numbers(voices, seconds):
    """Voice → number for the voices on show, as `SpeakerLabels.voiceNumbers`."""
    count, reached = {}, {}
    for i, (v, s) in enumerate(zip(voices, seconds)):
        if v is None or s < SUBSTANTIVE_SECONDS:
            continue
        count[v] = count.get(v, 0) + 1
        if count[v] == SHOWN_AFTER:
            reached[v] = i
    shown = sorted(reached, key=reached.get)
    return {v: n + 1 for n, v in enumerate(shown)} if len(shown) >= 2 else {}

def score(m, voices):
    from scipy.optimize import linear_sum_assignment
    numbers = shown_numbers(voices, m.seconds)
    pairs = [(numbers[v], t) for v, t in zip(voices, m.truth) if v in numbers and t is not None]
    right = 0
    if pairs:
        nums, people = sorted({n for n, _ in pairs}), sorted({t for _, t in pairs})
        c = np.zeros((len(nums), len(people)))
        for n, t in pairs:
            c[nums.index(n), people.index(t)] += 1
        r, k = linear_sum_assignment(-c)
        right = int(c[r, k].sum())
    said = {}
    for t, s in zip(m.truth, m.seconds):
        if t is not None and s >= SUBSTANTIVE_SECONDS:
            said[t] = said.get(t, 0) + 1
    people = sum(n >= SHOWN_AFTER for n in said.values())
    return dict(lines=sum(t is not None for t in m.truth),
                shown=sum(v in numbers for v, t in zip(voices, m.truth) if t is not None),
                right=right, wrong=len(pairs) - right, count=int(len(set(numbers.values())) == people), meetings=1)

def total(rows):
    s = {k: sum(r[k] for r in rows) for k in rows[0]}
    s["value"] = (s["right"] - 2 * s["wrong"]) / s["lines"]
    return s

def fmt(s):
    return (f"shown {100 * s['shown'] / s['lines']:5.1f}%  right {100 * s['right'] / s['lines']:5.1f}%  "
            f"wrong {100 * s['wrong'] / s['lines']:4.1f}% (of shown {100 * s['wrong'] / max(s['shown'], 1):4.1f}%)  "
            f"count {s['count']}/{s['meetings']}  value {100 * s['value']:5.1f}")

def eer(ms):
    """Same vs different speaker within a meeting, unambiguous lines of 2 s and more."""
    tg, ng = [], []
    for m in ms:
        keep = [i for i, (v, s, t) in enumerate(zip(m.embs, m.seconds, m.truth)) if v is not None and s >= 2 and t]
        e = np.stack([m.embs[i] for i in keep])
        lab = np.array([m.truth[i] for i in keep])
        iu = np.triu_indices(len(keep), 1)
        sim, same = (e @ e.T)[iu], lab[iu[0]] == lab[iu[1]]
        tg.append(sim[same])
        ng.append(sim[~same])
    t, n = np.sort(np.concatenate(tg)), np.sort(np.concatenate(ng))
    return min(max(np.searchsorted(t, th) / len(t), 1 - np.searchsorted(n, th) / len(n)) for th in np.linspace(-0.2, 1, 1201))

GRID = [round(x, 2) for x in np.arange(0.2, 0.751, 0.05)]
METHODS = {
    # name: (clustering, parameter grid); "app" is today's VoiceClusterer at its own thresholds.
    "app": (lambda m, p: live(m, 0.5, 0.5), [()]),
    "live": (lambda m, p: live(m, *p), [(j, n) for j in GRID for n in GRID if n <= j]),
    "live+margin": (lambda m, p: live(m, *p), [(j, n, g) for j in GRID for n in GRID if n <= j for g in (0.05, 0.1, 0.15, 0.2)]),
    "live+vote": (lambda m, p: live(m, *p, vote=True), [(j, n, g) for j in GRID for n in GRID if n <= j for g in (0.0, 0.1, 0.2)]),
    "after": (lambda m, p: after(m, *p), [(round(t, 3),) for t in np.arange(0.1, 0.71, 0.025)]),
    "after+clean": (lambda m, p: after(m, *p, clean=True), [(round(t, 3),) for t in np.arange(0.1, 0.71, 0.025)]),
}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ami", required=True)
    ap.add_argument("--wav", required=True)
    ap.add_argument("--cache", required=True)
    ap.add_argument("--model", action="append", required=True, help="name=path.onnx, or name=path.onnx:cpu to keep its windows off the GPU")
    ap.add_argument("--methods", default=",".join(METHODS), help="comma-separated: " + ", ".join(METHODS))
    ap.add_argument("--no-windows", action="store_true", help="skip the windows; live+vote and after+clean then use whole lines")
    ap.add_argument("--jobs", type=int, default=4, help="meetings embedded at once; one is quickest when the GPU does the windows")
    a = ap.parse_args()
    if a.no_windows:
        os.environ["EVAL_NO_WINDOWS"] = "1"   # read by the worker processes
    check_fbank()
    os.makedirs(a.cache, exist_ok=True)
    sets = {s: open(os.path.join(a.ami, "lists", s + ".meetings.txt")).read().split() for s in ("dev", "test")}
    print(f"dev {len(sets['dev'])} meetings, test {len(sets['test'])} meetings", flush=True)
    for spec in a.model:
        name, path = spec.split("=", 1)
        gpu = not path.endswith(":cpu")
        path = path.removesuffix(":cpu")
        todo = [m for ms in sets.values() for m in ms if not os.path.exists(cache_path(a.cache, name, m))]
        model_s = 0.0
        if todo:
            from concurrent.futures import ProcessPoolExecutor
            with ProcessPoolExecutor(a.jobs) as pool:
                model_s = sum(pool.map(compute, [(name, path, a.ami, a.wav, a.cache, m, max(2, os.cpu_count() // a.jobs), gpu) for m in todo]))
        data = {s: [Meeting(name, a.ami, a.cache, m) for m in ms] for s, ms in sets.items()}
        print(f"\n== {name}  ({os.path.basename(path)}{', %.0f s embedding' % model_s if todo else ''})")
        print(f"EER dev {100 * eer(data['dev']):.2f}%  test {100 * eer(data['test']):.2f}%")
        for method in a.methods.split(","):
            fn, grid = METHODS[method]
            run = lambda ms, p: total([score(m, fn(m, p)) for m in ms])
            best = max(grid, key=lambda p: run(data["dev"], p)["value"]) if len(grid) > 1 else grid[0]
            label = method + (" " + "/".join(f"{x:.3g}" for x in best) if best else "")
            print(f"{label:28} dev  {fmt(run(data['dev'], best))}")
            print(f"{'':28} test {fmt(run(data['test'], best))}", flush=True)

if __name__ == "__main__":
    main()
