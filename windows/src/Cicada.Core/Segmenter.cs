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
    public static double Threshold = 0.01;       // the Mac AudioRouter's gate (about -40 dBFS)
    public static double Pause = 0.6, MaxLength = 8.0, MinSpeech = 0.25;
    const double PreRoll = 0.15, Tail = 0.15, CutWindow = 2.0;

    readonly List<short> pending = [];           // samples not yet a whole frame
    readonly List<short> current = [];           // the open segment
    readonly List<double> levels = [];           // per frame of `current`
    readonly Queue<short[]> before = new();      // recent quiet frames, for the pre-roll
    long consumed;                               // samples seen, for timestamps
    double currentStart;
    int quietFrames, loudFrames, index;

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

    void Step(short[] frame)
    {
        double level = Rms(frame);
        bool loud = level >= Threshold;
        double now = consumed / (double)Rate;
        consumed += frame.Length;

        if (current.Count == 0)
        {
            if (!loud)
            {
                before.Enqueue(frame);
                while (before.Count > PreRoll * Rate / Frame) before.Dequeue();
                return;
            }
            currentStart = now - before.Count * Frame / (double)Rate;
            foreach (var f in before) { current.AddRange(f); levels.Add(0); }
            before.Clear();
            quietFrames = 0; loudFrames = 0;
        }

        current.AddRange(frame);
        levels.Add(level);
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

    /// Emits `current[..end]` and keeps what follows as the start of the next segment.
    void Close(int end)
    {
        end = Math.Clamp(end, 0, current.Count);
        var samples = current.GetRange(0, end).ToArray();
        var rest = current.GetRange(end, current.Count - end);
        var restLevels = levels.GetRange(end / Frame, levels.Count - end / Frame);
        double start = currentStart;
        bool speech = loudFrames * Frame >= MinSpeech * Rate;
        current.Clear(); levels.Clear();
        quietFrames = 0; loudFrames = 0;
        if (speech) Emitted?.Invoke(new Segment(++index, Math.Round(start, 3), samples));

        // A forced cut carries on with the remainder; after a pause the remainder is silence.
        if (restLevels.Any(l => l >= Threshold))
        {
            currentStart = start + end / (double)Rate;
            current.AddRange(rest);
            levels.AddRange(restLevels);
            int trailing = 0;
            for (int i = levels.Count - 1; i >= 0 && levels[i] < Threshold; i--) trailing++;
            quietFrames = trailing;
            loudFrames = levels.Count(l => l >= Threshold);
        }
    }
}
