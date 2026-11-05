using System.Threading.Channels;

namespace Cicada;

/// Listening end to end: system audio → segments → Ming (language, original, translation in one
/// call) → lines in the record, plus live notes. UI-free; the app shows `Lines` and listens to
/// `Changed` (raised on worker threads: marshal to the UI thread).
///
/// Ming takes ~2.2 s whatever the segment's length, so segments overlap in flight: request starts
/// still go through LingClient's gate, and lines are delivered in segment order.
public sealed class ListenEngine
{
    readonly LingClient ling;
    readonly Translator translator;
    readonly SessionStore store;
    readonly NotesEngine notes;
    readonly AppSettings settings;
    readonly object gate = new();

    IAudioSource? source;
    Channel<short[]>? audio;
    Task? worker;
    Segmenter? segmenter;
    readonly Dictionary<int, Heard?> done = [];
    readonly Dictionary<int, Segment> segments = [];
    // 说话人识别: voiceprints are made alongside Ming's reply (order doesn't matter there), and
    // grouped in line order when the line is recorded (it does there).
    readonly Dictionary<int, Task<float[]?>> prints = [];
    VoiceClusterer clusterer = new();
    /// Set by the app: the voiceprint model, or null where there is none (the Mac CLI, tests).
    public IVoiceprint? Voiceprint { get; set; }
    readonly List<Task> inFlight = [];
    int nextToDeliver = 1, lineCount;
    TranscriptLine? last;
    double lastEnd;
    string? hint, candidate;
    int candidateVotes;

    public bool Listening { get; private set; }
    public string? SessionId { get; private set; }
    /// The meeting's language so far (null until Ming has heard something).
    public string? Spoken => hint;
    /// Segments sent and not yet back: the UI shows "…" while this is above zero.
    public int Pending { get { lock (gate) return segments.Count; } }
    /// The last error worth showing ("key 无效", "网络不通"), cleared by the next good reply.
    /// What last went wrong talking to Ling (null once a segment gets through); the windows word it.
    public LingException.Kind? Problem { get; private set; }

    /// The user pressed 重试: hide the bar until the next failure says otherwise.
    public void ClearProblem() { Problem = null; Changed?.Invoke(); }

    /// Debug pipe only: show a failure's bar without breaking the network ("network", "ratelimited"…).
    public void SimulateProblem(string kind) { Problem = Enum.TryParse<LingException.Kind>(kind, true, out var k) ? k : null; Changed?.Invoke(); }
    public double Level { get; private set; }
    public event Action? Changed;

    public ListenEngine(LingClient ling, Translator translator, SessionStore store, NotesEngine notes, AppSettings settings)
    {
        this.ling = ling; this.translator = translator; this.store = store; this.notes = notes; this.settings = settings;
        translator.Glossary = notes.Glossary;
    }

    public string Target => settings.TargetCode;

    public void Start(IAudioSource from)
    {
        if (Listening) return;
        var session = store.Begin();
        SessionId = session.Id;
        lock (gate)
        {
            done.Clear(); segments.Clear(); inFlight.Clear(); prints.Clear(); clusterer = new();
            nextToDeliver = 1; lineCount = 0; last = null; lastEnd = 0;
            hint = null; candidate = null; candidateVotes = 0; Problem = null;
        }
        notes.Language = () => Languages.EnglishName(settings.NotesCode);
        notes.Begin(session.Id);
        segmenter = new Segmenter();
        segmenter.Emitted += Send;
        audio = Channel.CreateUnbounded<short[]>(new UnboundedChannelOptions { SingleReader = true });
        var reader = audio.Reader;
        // One reader thread owns the segmenter: audio callbacks only queue buffers.
        worker = Task.Run(async () =>
        {
            await foreach (var buf in reader.ReadAllAsync())
            {
                segmenter.Feed(buf);
                Level = Rms(buf);
            }
            segmenter.Flush();
        });
        source = from;
        source.Samples += OnSamples;
        source.Start();
        Listening = true;
        Log.Debug($"listen: started {session.Id} target={Target}");
        Changed?.Invoke();
    }

    void OnSamples(short[] buf) => audio?.Writer.TryWrite(buf);

    static double Rms(short[] buf)
    {
        if (buf.Length == 0) return 0;
        double sum = 0;
        foreach (var s in buf) sum += (double)s * s;
        return Math.Sqrt(sum / buf.Length) / 32768;
    }

    /// Stops listening, waits (briefly) for segments still at Ming, ends the record (at `endedAt` for
    /// a meeting that ended by itself) and writes the final notes. The task ends when the record is
    /// saved; the notes' final pass may run on.
    public async Task Stop(DateTimeOffset? endedAt = null)
    {
        if (!Listening) return;
        Listening = false;
        if (source is not null) { source.Samples -= OnSamples; source.Stop(); }
        audio?.Writer.TryComplete();
        if (worker is not null) await worker;
        Task[] waiting;
        lock (gate) waiting = inFlight.ToArray();
        await Task.WhenAny(Task.WhenAll(waiting), Task.Delay(15_000));
        var id = SessionId!;
        store.End(id, endedAt);
        Log.Debug($"listen: stopped {id}, {lineCount} lines");
        Changed?.Invoke();
        _ = notes.Finish();
    }

    void Send(Segment seg)
    {
        var wav = Wav.Bytes(seg.Samples);
        string? lang;
        lock (gate)
        {
            segments[seg.Index] = seg; lang = hint;
            if (settings.SpeakerVoices && Voiceprint is { } vp) prints[seg.Index] = Task.Run(() => vp.Embed(seg.Samples));
        }
        Changed?.Invoke();
        var task = Task.Run(async () =>
        {
            Heard? heard = null;
            var started = DateTime.UtcNow;
            try
            {
                heard = await translator.Hear(wav, Target, lang);
                Problem = null;
            }
            catch (LingException e)
            {
                Problem = e.Failure is LingException.Kind.Hijacked or LingException.Kind.Parse ? null : e.Failure;
                Log.Debug($"listen: segment {seg.Index} failed {e.Message}");
            }
            Log.Debug($"listen: segment {seg.Index} {seg.Seconds:F1}s -> {(heard is null ? "nothing" : heard.Lang)} in {(DateTime.UtcNow - started).TotalMilliseconds:F0} ms");
            lock (gate) done[seg.Index] = heard;
            Deliver();
        });
        lock (gate) { inFlight.Add(task); inFlight.RemoveAll(t => t.IsCompleted); }
    }

    /// Hands finished segments on in order: one slow reply holds back those after it.
    void Deliver()
    {
        var ready = new List<(Segment seg, Heard? heard)>();
        lock (gate)
        {
            while (done.Remove(nextToDeliver, out var heard))
            {
                ready.Add((segments[nextToDeliver], heard));
                segments.Remove(nextToDeliver);
                nextToDeliver++;
            }
        }
        foreach (var (seg, heard) in ready) if (heard is not null) Record(seg, heard);
        if (ready.Count > 0) Changed?.Invoke();
    }

    void Record(Segment seg, Heard heard)
    {
        var id = SessionId!;
        var target = Target;
        // The meeting's language moves only after two segments agree, so one misheard stretch
        // doesn't flip the hint (the Mac waits for confidence the same way).
        lock (gate)
        {
            if (hint is null) hint = heard.Lang;
            else if (heard.Lang != hint)
            {
                if (candidate == heard.Lang) candidateVotes++; else { candidate = heard.Lang; candidateVotes = 1; }
                if (candidateVotes >= 2) { hint = candidate; candidate = null; candidateVotes = 0; }
            }
            else { candidate = null; candidateVotes = 0; }
        }

        // Whose voice: a line with hardly a letter ("." from a breath) gets none.
        int? voice = null;
        Task<float[]?>? print;
        lock (gate) { prints.Remove(seg.Index, out print); }
        if (print is not null && heard.Original.Count(char.IsLetter) >= 2)
        {
            var v = print.Wait(3000) ? print.Result : null;
            if (v is not null) lock (gate) voice = clusterer.Label(v, seg.Seconds);
        }

        TranscriptLine line;
        bool joined = false;
        lock (gate)
        {
            // Two voices never share a line, however the sentence was cut.
            if (last is not null && Continues(last, seg.Start - lastEnd, heard) && (voice is null || last.Voice is null || voice == last.Voice))
            {
                last.Src = Join(last.Src, heard.Original, heard.Lang);
                last.Dst = last.Dst is null || heard.Translation is null ? null : Join(last.Dst, heard.Translation, target);
                line = last;
                joined = true;
            }
            else
            {
                line = new TranscriptLine
                {
                    Id = $"h{++lineCount}-{seg.Index}", T = seg.Start, Speaker = "them",
                    Src = heard.Original, Dst = heard.Translation, SrcLang = heard.Lang, DstLang = target, Voice = voice,
                };
                last = line;
            }
            lastEnd = seg.Start + seg.Seconds;
        }
        if (joined) store.Replace(id, line.Copy()); else store.Append(id, line.Copy());

        // A joined sentence is translated again as a whole; a line Ming didn't translate gets text translation.
        if ((joined || line.Dst is null) && line.SrcLang != target)
        {
            var src = line.Src;
            _ = Task.Run(async () =>
            {
                var dst = await translator.Translate(src, line.SrcLang, target, Translator.Kind.Sentence);
                TranscriptLine copy;
                lock (gate)
                {
                    if (dst is null || line.Src != src) return;
                    line.Dst = dst;
                    copy = line.Copy();
                }
                store.Replace(id, copy);
                Changed?.Invoke();
            });
        }
    }

    /// A segment continues the last line when the cut came mid-sentence: no sentence end on the
    /// last line, a short gap, the same language, and the joined line not too long to read.
    public static bool Continues(TranscriptLine last, double gap, Heard next)
    {
        if (gap > 0.8 || last.SrcLang != next.Lang) return false;
        var text = last.Src.TrimEnd();
        if (text.Length == 0 || ".!?。！？…".Contains(text[^1])) return false;
        bool cjk = next.Lang.StartsWith("zh") || next.Lang.StartsWith("ja") || next.Lang.StartsWith("ko");
        int size = cjk ? text.Length + next.Original.Length : (text + " " + next.Original).Split(' ', StringSplitOptions.RemoveEmptyEntries).Length;
        return size <= (cjk ? 80 : 45);
    }

    public static string Join(string a, string b, string lang)
    {
        bool cjk = lang.StartsWith("zh") || lang.StartsWith("ja");
        a = a.TrimEnd(); b = b.TrimStart();
        if (cjk) return a + b;
        return a + " " + b;
    }
}
