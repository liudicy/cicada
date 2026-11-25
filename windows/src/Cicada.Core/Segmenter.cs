namespace Cicada;

/// A stretch of speech to send to Ming: where it starts (seconds since listening began) and its
/// 16 kHz mono samples.
public sealed record Segment(int Index, double Start, short[] Samples)
{
    public double Seconds => Samples.Length / (double)Segmenter.Rate;
}

/// Cuts the system audio into stretches of speech by loudness alone: a pause of 0.6 s ends one,
/// and one that runs to 8 s is cut at its quietest moment in the last 2 s, so a word is split as
/// rarely as possible (Ming has no word timings to put it back together). Not thread-safe: fed
/// from the audio queue only.
public sealed class Segmenter
{
    public const int Rate = 16000;
    const int Frame = 480;                       // 30 ms
    const int Step10 = 160;                      // 10 ms: a key click is judged in these, as the Mac's VoiceActivity does
    const int Onset = 3;                         // steps of sound before it counts as speech
    public static double Threshold = 0.01;       // the Mac AudioRouter's gate (about -40 dBFS)
    public static double Pause = 0.6, MaxLength = 8.0, MinSpeech = 0.25;
    public static double MinWord = 0.2;          // a word on its own (IsWord): this much over gate / 4
    public static double Steady = 2.0;           // frames' 90th / 10th percentile below this: not speech…
    public static double Dips = 2.5;             // …unless the median is this far over the 10th, quiet ones held at gate / 8
    public static double Short = 2.0;            // a sound up to this long, with real quiet (gate / 4) on both sides…
    public static double Swell = Math.Pow(10, 10 / 20.0); // …that swells and fades by 10 dB is a word: see IsWord
    public static double Fade = Math.Pow(10, 30 / 20.0);  // its rise and fade reach this far under its loudest step (or gate / 4 if lower)
    public static double Voiced = 0.15;          // a word's full frames crossing zero under this often (per sample) have voice in them: see IsVoiced
    public static double Above = 0.25;           // under this share of its loud frames' energy over 100 Hz: rumble, not speech
    const double PreRoll = 0.15, Tail = 0.15, CutWindow = 2.0;
    // A first-order high-pass at 100 Hz, for how much of a sound is above it (IsRumble).
    static readonly double HighPass = 1.0 / (1.0 + 2.0 * Math.PI * 100.0 / Rate);

    readonly List<short> pending = [];           // samples not yet a whole frame
    readonly List<short> current = [];           // the open segment
    readonly List<double> levels = [];           // per frame of `current`
    readonly List<double> highs = [];            // per frame of `current`: its level over 100 Hz
    readonly List<bool> speech = [];             // per frame of `current`: whether it held speech (IsSpeech)
    double hx, hy;                               // the high-pass's last input and output, carried from frame to frame
    readonly Queue<(short[] frame, double level, double high)> before = new(); // recent quiet frames, for the pre-roll
    readonly Queue<double> idle = new();         // levels of the last 0.6 s of quiet frames
    double? lead;                                // the quietest of those when the open segment began
    long consumed;                               // samples seen, for timestamps
    double currentStart;
    int quietFrames, loudFrames, index;
    int sounding;                                // 10 ms steps of sound in a row so far
    bool carried;                                // the sound that made the last frame speech began in the frame before
    /// 会议室: a microphone's line follows the room's noise (VoiceGate); null keeps the fixed one.
    /// Swapped when 听哪里 changes mid-meeting (read once per frame on the audio thread).
    public VoiceGate? Gate { get => gate; set => gate = value; }
    volatile VoiceGate? gate;
    double line = Threshold;

    public Segmenter(VoiceGate? gate = null) { this.gate = gate; }

    /// The level that counts as speech right now.
    public double Line => line;

    public event Action<Segment>? Emitted;

    public void Feed(ReadOnlySpan<short> samples)
    {
        foreach (var s in samples) pending.Add(s);
        int whole = pending.Count / Frame * Frame;
        for (int i = 0; i < whole; i += Frame)
        {
            var frame = pending.GetRange(i, Frame).ToArray();
            Step(frame);
        }
        pending.RemoveRange(0, whole);
    }

    /// Ends the open segment (listening stopped).
    public void Flush()
    {
        if (current.Count > 0) Close(current.Count - quietFrames * Frame + (int)(Tail * Rate));
    }

    static double Rms(short[] frame)
    {
        double sum = 0;
        foreach (var s in frame) sum += (double)s * s;
        return Math.Sqrt(sum / frame.Length) / 32768;
    }

    /// Whether the frame holds speech: sound that has lasted 30 ms, judged in 10 ms steps against the
    /// line, so a lone key click (a few ms) neither opens a segment nor breaks the pause that ends one
    /// (VoiceActivity.swift's onset); the pre-roll then reaches back to where that sound began. A
    /// room's gate learns its noise per frame and takes whole ones, as the Mac's does per block: a
    /// voiced 30 ms frame has lasted the onset already.
    bool IsSpeech(short[] frame, double level, VoiceGate? g)
    {
        if (g is not null)
        {
            bool on = g.Voiced(level, Frame / (double)Rate);
            sounding = on ? sounding + Frame / Step10 : 0;
            carried = false;
            return on;
        }
        bool said = false, early = sounding > 0;
        for (int i = 0; i < frame.Length; i += Step10)
        {
            int end = Math.Min(frame.Length, i + Step10);
            double sum = 0;
            for (int k = i; k < end; k++) sum += (double)frame[k] * frame[k];
            if (Math.Sqrt(sum / (end - i)) / 32768 >= line)
            {
                if (++sounding >= Onset && !said) { said = true; carried = early; }
            }
            else { sounding = 0; early = false; }
        }
        return said;
    }

    void Step(short[] frame)
    {
        double level = Rms(frame);
        double high = High(frame);
        var g = gate;
        line = g?.Threshold ?? Threshold;
        bool loud = IsSpeech(frame, level, g);
        double now = consumed / (double)Rate;
        consumed += frame.Length;

        if (current.Count == 0)
        {
            if (!loud)
            {
                idle.Enqueue(level);
                while (idle.Count > (int)(Pause * Rate / Frame)) idle.Dequeue();
                before.Enqueue((frame, level, high));
                while (before.Count > PreRoll * Rate / Frame + 1) before.Dequeue();
                return;
            }
            // One frame more when the sound began in the last quiet one.
            while (before.Count > PreRoll * Rate / Frame + (carried ? 1 : 0)) before.Dequeue();
            currentStart = now - before.Count * Frame / (double)Rate;
            lead = idle.Count > 0 ? idle.Min() : null;
            idle.Clear();
            foreach (var (f, l, h) in before) { current.AddRange(f); levels.Add(l); highs.Add(h); speech.Add(false); }
            before.Clear();
            quietFrames = 0; loudFrames = 0;
        }

        current.AddRange(frame);
        levels.Add(level);
        highs.Add(high);
        speech.Add(loud);
        if (loud) { quietFrames = 0; loudFrames++; } else quietFrames++;

        if (quietFrames * Frame >= Pause * Rate)
        {
            Close(current.Count - quietFrames * Frame + (int)(Tail * Rate));
        }
        else if (current.Count >= MaxLength * Rate)
        {
            // The quietest frame in the last 2 s; the rest starts the next segment.
            int from = Math.Max(1, levels.Count - (int)(CutWindow * Rate / Frame));
            int cut = from;
            for (int i = from; i < levels.Count; i++) if (levels[i] < levels[cut]) cut = i;
            Close(cut * Frame);
        }
    }

    /// Steady sound just over the gate (a fan, hum, hiss) isn't speech: its frames barely vary
    /// (90th / 10th percentile about 1.1; speech, even over such a floor, 3 and up). Given one, Ming
    /// writes a stock sentence in the hint's language ("I'm going to show you a couple of things").
    /// Speech buried under steady noise goes too; system audio rarely carries it. Every frame from
    /// the first loud one to the last counts, the quiet ones held at the gate: counting only the
    /// loud ones dropped quiet speech (under about -30 dBFS), whose dips fall below the gate.
    /// A voice so quiet that its loudest frames barely clear the gate (about -38 dBFS: 6 of 6 lines
    /// lost in testing) still pauses between syllables, its quietest tenth of frames far under its
    /// median (8 dB and more); noise near the gate stays within about 6 dB of its median. So a flat
    /// top is steady only when it has no such dips, measured with quiet frames held at gate / 8.
    /// Very low rumble (brown noise with almost nothing over 20 Hz) can look like that and gets
    /// through more often than before (about 1 in 3 segments, was 1 in 5); what Ming makes of it
    /// still meets the hear filter (Translator.IsNoise).
    internal static bool IsSteady(IEnumerable<double> frameLevels, double? gate = null)
    {
        var all = frameLevels.ToList();
        var threshold = gate ?? Threshold;
        int first = all.FindIndex(l => l >= threshold), last = all.FindLastIndex(l => l >= threshold);
        if (first < 0 || last <= first) return false;
        var body = all.GetRange(first, last - first + 1);
        var top = body.Select(l => Math.Max(l, threshold)).Order().ToList();
        if (top[(int)(0.9 * (top.Count - 1))] >= Steady * top[(int)(0.1 * (top.Count - 1))]) return false;
        var low = body.Select(l => Math.Max(l, threshold / 8)).Order().ToList();
        return low[(int)(0.5 * (low.Count - 1))] < Dips * low[(int)(0.1 * (low.Count - 1))];
    }

    /// A short word on its own: a sound up to `Short` that rises out of real quiet and falls back
    /// into it (under gate / 4, about -52 dBFS, in the 0.6 s before it and in the pause after),
    /// and that swells and fades by 10 dB or more: at least 5% of its 10 ms steps (and 3 of them),
    /// from where it rises to where it fades, are that far under its 90th percentile. Such a word
    /// ("Thanks.", "Good morning everyone,") is one smooth syllable or a run of voiced ones, so the
    /// steady test, which looks for dips inside, dropped it even at -26 dBFS; and a quiet one
    /// ("Thanks." at -36 dBFS) has under 0.25 s over the gate, so it needs `MinWord` over gate / 4
    /// instead (a knock with a 150 ms tail has 0.15 s). A fan, hum or hiss is there on both sides;
    /// a short burst of one in silence has at most one low step at each edge (its 5th percentile
    /// stays within 2 dB, 9 dB with 50 ms fades), and Ming makes up a sentence for a hum or fan
    /// burst. Not for a forced cut, whose end isn't a pause.
    /// Where it rises and fades: over gate / 4, or 30 dB under its loudest step if that's lower;
    /// over gate / 4 alone, a quiet word lost its rise and fade (an "s" or breath at -55 dBFS) and
    /// only its flat top was left. 30 ms frames and their 10th percentile put Samantha's "Good
    /// morning everyone." at 7.5 to 11.4 dB depending on where the frames fell, so it came and
    /// went with a few ms of lead-in; 10 ms steps and their 5th percentile give it 14.6 to 16.5.
    internal bool IsWord(List<double> frameLevels, double gate)
    {
        int first = frameLevels.FindIndex(l => l >= gate), last = frameLevels.FindLastIndex(l => l >= gate);
        if (first < 0 || (last - first + 1) * Frame > Short * Rate) return false;
        double quiet = gate / 4;
        if (lead is not { } q || q > quiet || last + 1 >= frameLevels.Count || frameLevels.Skip(last + 1).Min() > quiet) return false;
        var steps = new List<double>();
        for (int i = 0; i + Step10 <= current.Count; i += Step10)
        {
            double sum = 0;
            for (int k = i; k < i + Step10; k++) sum += (double)current[k] * current[k];
            steps.Add(Math.Sqrt(sum / Step10) / 32768);
        }
        double rise = Math.Min(quiet, steps.Max() / Fade);
        int from = steps.FindIndex(l => l >= rise), to = steps.FindLastIndex(l => l >= rise);
        var body = steps.GetRange(from, to - from + 1).Select(l => Math.Max(l, gate / 8)).Order().ToList();
        int low = Math.Max(2, (int)(0.05 * (body.Count - 1)));
        return low < body.Count && body[(int)(0.9 * (body.Count - 1))] >= Swell * body[low] && IsVoiced(frameLevels);
    }

    /// Whether a word has voice in it: 2 or more of its full frames (within 3 dB of its 90th
    /// percentile) cross zero under `Voiced` times a sample. Voiced speech crosses slowly (every
    /// voice tested had full frames at 0.01 to 0.06); a hiss crosses about every other sample (0.46
    /// and up) and, faded in and out over 0.3 s, swells like a word. Edge frames half silence
    /// cross slowly whatever they hold, hence full frames only and more than one.
    bool IsVoiced(List<double> frameLevels)
    {
        double full = frameLevels.Order().ElementAt((int)(0.9 * (frameLevels.Count - 1))) / Math.Sqrt(2);
        int slow = 0;
        for (int i = 0; i < frameLevels.Count; i++)
        {
            if (frameLevels[i] < full) continue;
            int start = i * Frame, end = Math.Min(current.Count, start + Frame), crossings = 0;
            for (int k = start + 1; k < end; k++) if (current[k] >= 0 != current[k - 1] >= 0) crossings++;
            if (crossings < Voiced * (end - start - 1)) slow++;
        }
        return slow >= 2;
    }

    /// The frame's level over 100 Hz (RMS after the high-pass), the filter running on across frames.
    double High(short[] frame)
    {
        double a = HighPass, x0 = hx, y = hy, total = 0;
        foreach (var s in frame)
        {
            double x = s;
            y = a * (y + x - x0);
            x0 = x;
            total += y * y;
        }
        hx = x0; hy = y;
        return frame.Length == 0 ? 0 : Math.Sqrt(total / frame.Length) / 32768;
    }

    /// Rumble, not speech: under a quarter of the loud frames' energy is over 100 Hz. Speech keeps
    /// nearly all of it there (-0.3 to -1 dB in testing, the low male voices included); brown noise
    /// with almost nothing over 20 Hz keeps -20 to -28 dB, and Ming made a sentence of 15 of 17 such
    /// segments ("I'm going to go ahead and start the meeting."), which the loudness rules can't
    /// tell from a voice. Brown noise up to about 12 Hz keeps -10 dB and goes too; a 50 Hz hum or a
    /// fan keeps about -5 dB and is left to the steady test.
    internal static bool IsRumble(List<double> frameLevels, List<double> frameHighs, double gate)
    {
        double full = 0, above = 0;
        for (int i = 0; i < frameLevels.Count && i < frameHighs.Count; i++)
        {
            if (frameLevels[i] < gate) continue;
            full += frameLevels[i] * frameLevels[i];
            above += frameHighs[i] * frameHighs[i];
        }
        return above < Above * full;
    }

    /// Emits `current[..end]` and keeps what follows as the start of the next segment.
    void Close(int end)
    {
        end = Math.Clamp(end, 0, current.Count);
        var samples = current.GetRange(0, end).ToArray();
        var rest = current.GetRange(end, current.Count - end);
        var restLevels = levels.GetRange(end / Frame, levels.Count - end / Frame);
        var restHighs = highs.GetRange(end / Frame, highs.Count - end / Frame);
        var restSpeech = speech.GetRange(end / Frame, speech.Count - end / Frame);
        double start = currentStart;
        var sent = levels.GetRange(0, Math.Min(levels.Count, end / Frame));
        bool said = IsWord(levels, line)
            ? sent.Count(l => l >= line / 4) * Frame >= MinWord * Rate
            : loudFrames * Frame >= MinSpeech * Rate && !IsSteady(sent, line);
        said = said && !IsRumble(sent, highs.GetRange(0, sent.Count), line);
        current.Clear(); levels.Clear(); highs.Clear(); speech.Clear();
        quietFrames = 0; loudFrames = 0;
        if (said) Emitted?.Invoke(new Segment(++index, Math.Round(start, 3), samples));

        // A forced cut carries on with the remainder; after a pause the remainder is silence.
        if (restSpeech.Contains(true))
        {
            currentStart = start + end / (double)Rate;
            lead = null;
            current.AddRange(rest);
            levels.AddRange(restLevels);
            highs.AddRange(restHighs);
            speech.AddRange(restSpeech);
            int trailing = 0;
            for (int i = speech.Count - 1; i >= 0 && !speech[i]; i--) trailing++;
            quietFrames = trailing;
            loudFrames = speech.Count(v => v);
        }
    }
}
