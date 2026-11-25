namespace Cicada;

// 电脑和会议室: the room side's echo handling, and how its lines are shown (RoomMic.swift,
// EchoMatch.swift, RecordList.swift).

/// 打开麦克风 while the computer plays a meeting: the room mic hears the remote voices again from
/// the speakers (EchoGate in RoomMic.swift, same rules). The room mic hears silence while the
/// computer plays speech, until `Hang` after it, but only when that is needed and only for speech:
///
/// - Echo is measured: the room mic's loud end while the computer is loud over its floor while the
///   computer is quiet. Headphones or a meeting mic leave it where it was, and then nothing is
///   silenced, so people at the table are heard over a remote speaker too. Until there is enough
///   to tell (and whenever it is unclear) the speakers are taken to echo.
/// - Music isn't speech: a loud stretch the computer's side has recognized no words in for `Music`
///   seconds stops closing the gate. Words close it again. Longer than the Mac's 4 s: here words
///   only come back after a whole segment has gone to the service.
public sealed class EchoGate(Func<double>? clock = null)
{
    public const double Hang = 0.4;
    /// Seconds of loud audio without words before it counts as music.
    public const double Music = 20;
    /// A pause this long ends a loud stretch.
    public const double StretchGap = 1.5;
    /// Computer audio this recent makes a room block "during"; this long ago, "the computer is quiet".
    public const double During = 0.15, QuietAfter = 1.0;
    /// The ratio at or over which there is echo, and under which there is none.
    public const double EchoRatio = 3, ClearRatio = 2;
    /// Seconds of each that a decision needs, and how much is kept.
    public const double Enough = 3, Window = 20;

    /// Seconds; a monotonic clock shared with EchoMatch's times.
    public readonly Func<double> Clock = clock ?? (() => Environment.TickCount64 / 1000.0);
    readonly object gate = new();
    double until = double.NegativeInfinity, lastLoud = double.NegativeInfinity, stretchStart = double.NegativeInfinity, lastWords = double.NegativeInfinity;
    readonly List<(double t, double rms, double s)> during = [], quiet = [];
    bool echo = true;
    /// Debug (`roomEchoSim`): pretend the measurement says this.
    public bool? Forced { get; set; }

    /// When the computer last played something loud.
    public double LastLoud { get { lock (gate) return lastLoud; } }
    /// Whether the speakers reach the room mic, as last measured.
    public bool Echo { get { lock (gate) return Forced ?? echo; } }
    public bool PlayingMusic { get { var now = Clock(); lock (gate) return MusicLocked(now); } }
    public bool Closed { get { var now = Clock(); lock (gate) return now < until; } }

    bool MusicLocked(double now) => now - lastLoud <= StretchGap && now - stretchStart >= Music && lastWords < now - Music;

    /// A loud buffer of the computer's audio.
    public void Hold()
    {
        var now = Clock();
        lock (gate)
        {
            if (now - lastLoud > StretchGap) stretchStart = now;
            lastLoud = now;
            if (MusicLocked(now) || !(Forced ?? echo)) return;
            until = Math.Max(until, now + Hang);
        }
    }

    /// The computer's side recognized words.
    public void HeardWords() { var now = Clock(); lock (gate) lastWords = now; }

    /// A buffer of what the room mic heard, before any silencing.
    public void RoomLevel(double rms, double seconds)
    {
        var now = Clock();
        lock (gate)
        {
            var since = now - lastLoud;
            if (since <= During) during.Add((now, rms, seconds)); else if (since >= QuietAfter) quiet.Add((now, rms, seconds)); else return;
            during.RemoveAll(b => b.t < now - Window);
            quiet.RemoveAll(b => b.t < now - Window * 3);
            if (Ratio(during.Select(b => (b.rms, b.s)), quiet.Select(b => (b.rms, b.s))) is not { } r) return;
            var was = echo;
            if (r >= EchoRatio) echo = true; else if (r < ClearRatio) echo = false;
            if (was == echo) return;
            Log.Debug($"room echo: {(echo ? "speakers reach the mic" : "none")} (x{r:F1})");
            if (!echo) until = double.NegativeInfinity;
        }
    }

    /// The room mic's loud end (a fifth of it louder) while the computer is loud over its floor (the
    /// quietest fifth) while it is quiet, or null without `Enough` of both. People at the table
    /// talking over the computer raise it too: that errs on the side of echo.
    public static double? Ratio(IEnumerable<(double rms, double s)> during, IEnumerable<(double rms, double s)> quiet)
    {
        var d = during.ToList(); var q = quiet.ToList();
        if (d.Sum(b => b.s) < Enough || q.Sum(b => b.s) < Enough) return null;
        var ds = d.Select(b => b.rms).Order().ToList(); var qs = q.Select(b => b.rms).Order().ToList();
        return ds[ds.Count * 4 / 5] / Math.Max(qs[qs.Count / 5], 0.0002);
    }
}

/// 电脑和会议室's last line of defence against hearing a remote sentence twice: once from the
/// computer's audio, once more from the speakers into the room mic. A room line made mostly of
/// what the computer played around the same time is dropped (EchoMatch.swift, same numbers).
public static class EchoMatch
{
    /// Times in seconds on EchoGate's clock.
    public sealed record Heard(string Text, double Start, double End);

    /// Seconds around the room line where the computer's lines count.
    public const double Window = 3.0;
    /// How long a room line waits for the computer's line it may echo.
    public const double Hold = 2.5;
    /// Share of the room line found in the computer's lines that makes it an echo.
    public const double Contained = 0.6;

    public static bool IsEcho(Heard room, IEnumerable<Heard> online)
    {
        var near = online.Where(o => o.End >= room.Start - Window && o.Start <= room.End + Window).ToList();
        if (near.Count == 0) return false;
        var r = Units(room.Text);
        if (r.Count == 0) return false;
        var o = near.Select(n => Units(n.Text)).ToList();
        // A word or two ("OK", "对"): the very same words near it.
        if (r.Count <= 2) return o.Any(x => x.SequenceEqual(r));
        var mine = Pairs(r).ToHashSet();
        var theirs = o.SelectMany(Pairs).ToHashSet();
        return (double)mine.Count(theirs.Contains) / mine.Count >= Contained;
    }

    /// Lower-case words, each CJK character on its own; punctuation and spacing don't count.
    public static List<string> Units(string text)
    {
        var output = new List<string>();
        var word = new System.Text.StringBuilder();
        foreach (var rune in text.ToLowerInvariant().EnumerateRunes())
        {
            if (Cjk(rune.Value))
            {
                if (word.Length > 0) { output.Add(word.ToString()); word.Clear(); }
                output.Add(rune.ToString());
            }
            else if (System.Text.Rune.IsLetterOrDigit(rune)) word.Append(rune.ToString());
            else if (word.Length > 0) { output.Add(word.ToString()); word.Clear(); }
        }
        if (word.Length > 0) output.Add(word.ToString());
        return output;
    }

    static IEnumerable<string> Pairs(List<string> u) => u.Count < 2 ? u : Enumerable.Range(1, u.Count - 1).Select(i => u[i - 1] + " " + u[i]);

    static bool Cjk(int v) => v is >= 0x3040 and <= 0x30FF or >= 0x3400 and <= 0x4DBF or >= 0x4E00 and <= 0x9FFF or >= 0xAC00 and <= 0xD7AF or >= 0xF900 and <= 0xFAFF;
}

/// The computer's recent lines, for the room side to check its own against.
public sealed class EchoFilter(EchoGate gate)
{
    public readonly EchoGate Gate = gate;
    readonly List<EchoMatch.Heard> online = [];

    public void Online(EchoMatch.Heard h)
    {
        lock (online)
        {
            online.Add(h);
            online.RemoveAll(o => o.End < h.End - 20);
        }
    }

    public bool IsEcho(EchoMatch.Heard room) { lock (online) return EchoMatch.IsEcho(room, online); }

    /// The computer played nothing loud around this room line: there is nothing for it to echo.
    public bool Quiet(EchoMatch.Heard room) => Gate.LastLoud < room.Start - EchoMatch.Window;
}

/// A meeting that heard both: each of the other side's lines says where (RecordList.swift).
public static class Places
{
    /// The room mic and the computer's audio both brought in the other side's lines.
    public static bool HeardBoth(IEnumerable<TranscriptLine> lines)
    {
        bool room = false, computer = false;
        foreach (var l in lines)
        {
            if (l.Speaker != "them") continue;
            if (l.Via == "room") room = true; else computer = true;
            if (room && computer) return true;
        }
        return false;
    }

    /// The other side's lines where the place changes from the line before: their label shows again.
    public static HashSet<string> Starts(IEnumerable<TranscriptLine> lines)
    {
        var output = new HashSet<string>();
        string? last = "\0";
        foreach (var l in lines)
        {
            var key = l.Speaker == "me" ? "me" : l.Via;
            if (l.Speaker != "me" && key != last) output.Add(l.Id);
            last = key;
        }
        return output;
    }

    public static string Place(TranscriptLine l) => l.Via == "room" ? Strings.L("现场") : Strings.L("线上");
}
