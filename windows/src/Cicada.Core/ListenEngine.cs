using System.Threading.Channels;

namespace Cicada;

/// Listening end to end: system audio → segments → the AI service's hear model (Ming on Ling:
/// language, original, translation in one call) → lines in the record, plus live notes. UI-free; the app shows `Lines` and listens to
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
    Channel<(short[] buf, double at)>? audio;
    /// When this side began (Stopwatch ticks): with `offset`, the meeting's clock.
    long began;
    /// 保存会议录音: the main side writes what it hears to the meeting's system.aac.
    IAudioWriter? recorder;
    /// The main side's recording, which 电脑和会议室's room side adds itself into (`Join`).
    public RoomMix? Mix => recorder as RoomMix;
    /// The room side: the main side's recording, where what the room mic hears goes too.
    RoomMix? roomMix;
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
    /// What last went wrong talking to the AI service (null once a segment gets through); the
    /// windows word it with Words().
    public LingException.Kind? Problem { get; private set; }
    /// The HTTP status behind Problem == Http.
    public int ProblemStatus { get; private set; }
    /// Stretches in a row the service answered with a 5xx; said from the third (ListenEngine.swift's
    /// cloudFailures): one isn't worth a bar, but a meeting with no subtitles and no reason is worse.
    int serverErrors;
    public const int ServerErrorsShown = 3;
    public static bool IsServerError(LingException.Kind kind, int status) => kind == LingException.Kind.Http && status >= 500;

    /// A stretch that couldn't be heard, in words: (title, what to do, whether 设置 fixes it). Ling
    /// keeps its own words; another service is named. A hear model that refuses audio (400, 404,
    /// 415, 422: AICheck's deaf) is a settings problem, not the network; `hear` names it. A lost
    /// connection needs nothing from the user: segments keep going out and pick up by themselves.
    public static (string? Title, string Body, bool Settings) Words(LingException.Kind kind, int status, string service, string? hear = null)
    {
        var ling = service == "Ling";
        if (kind == LingException.Kind.Http && status is 400 or 404 or 415 or 422 && !ling)
            return (Strings.LF("%@ 听不了声音。", hear ?? service), Strings.L("在 设置 › AI 服务 里换一个"), true);
        return kind switch
        {
            // It answered, with an error (a gateway's 502): like busy, it passes by itself; not the network.
            LingException.Kind.Http when status >= 500 => (null, Strings.LF("%@ 暂时出错（HTTP %lld），稍后再试。", service, status), false),
            LingException.Kind.RateLimited => ling ?(Strings.L("Ling 太忙"), Strings.L("稍后会自动重试。"), false) : (null, Strings.LF("%@ 太忙，稍后再试", service), false),
            LingException.Kind.InvalidKey => (ling ? Strings.L("Ling key 无效") : Strings.LF("%@ 的 key 无效", service), Strings.L("去设置里换一个 key。"), true),
            LingException.Kind.NoKey => (ling ? Strings.L("Ling key 无效") : Strings.LF("需要 %@ 的 key 才能听", service), Strings.L("去设置里换一个 key。"), true),
            // The service hears the meeting here, so the subtitles wait with the notes.
            _ => (null, Strings.LF("字幕和纪要等 %@ 恢复 · 连上后自动继续", service), false),
        };
    }

    /// The user pressed 重试: hide the bar until the next failure says otherwise.
    public void ClearProblem() { Problem = null; Changed?.Invoke(); }

    /// Debug pipe only: show a failure's bar without breaking the network ("network", "ratelimited"…).
    public void SimulateProblem(string kind)
    {
        var parts = kind.Split(' ');
        Problem = Enum.TryParse<LingException.Kind>(parts[0], true, out var k) ? k : null;
        ProblemStatus = parts.Length > 1 && int.TryParse(parts[1], out var s) ? s : 0;
        Changed?.Invoke();
    }
    public double Level { get; private set; }
    public event Action? Changed;

    public ListenEngine(LingClient ling, Translator translator, SessionStore store, NotesEngine notes, AppSettings settings)
    {
        this.ling = ling; this.translator = translator; this.store = store; this.notes = notes; this.settings = settings;
        translator.Glossary = notes.Glossary;
    }

    public string Target => settings.TargetCode;

    /// 会议室: what listening hears is a microphone (its speech line follows the room's noise).
    public bool Room { get; private set; }

    /// 电脑和会议室's room side (the Mac's `.room` role): it adds to the main engine's meeting rather
    /// than keeping one, with its own language and pauses; its lines say `via: "room"` and their ids
    /// start at RoomIDs, so the two never share one.
    public bool RoomSide { get; }
    public const int RoomIDs = 1_000_000;
    /// 电脑和会议室: the main side holds the gate on loud audio and lists what it heard; the room
    /// side checks its lines against that before recording them.
    public EchoFilter? Echo { get; set; }
    /// When the computer's audio was loud (the talk key's echo check), fed while listening to it.
    public LoudnessLog? Loudness { get; set; }
    /// Seconds from the meeting's start to this side's first sample (the room side joins later).
    double offset;
    Channel<(Segment seg, Heard heard, double at, double queued)>? held;
    Task? holding;
    CancellationTokenSource? flush;
    readonly Dictionary<int, double> emitted = [];

    /// 改正听错的词 (set by the app): null leaves lines as heard.
    public LiveFixes? Fixes { get; set; }

    /// Debug (`heard <text>` after `silentlisten`): a finished sentence as if Ming heard it in
    /// `lang` with no translation, so the record, its translation and fixes and the windows all
    /// follow without any audio. Each comes as its own line (a pause before it).
    public void DebugHeard(string text, string lang)
    {
        if (!Listening || SessionId is null) return;
        var start = Math.Max(lastEnd + 2, System.Diagnostics.Stopwatch.GetElapsedTime(began).TotalSeconds);
        Segment seg;
        lock (gate) seg = new Segment(++debugSegments, start, new short[Segmenter.Rate / 2]);
        Record(seg, new Heard(lang, text, null));
        Changed?.Invoke();
    }
    int debugSegments = 100_000;

    public ListenEngine(LingClient ling, Translator translator, SessionStore store, NotesEngine notes, AppSettings settings, bool roomSide)
        : this(ling, translator, store, notes, settings) { RoomSide = roomSide; }

    public void Start(IAudioSource from, bool room = false)
    {
        if (Listening || RoomSide) return;
        var session = store.Begin();
        // The clock starts with the record, not after the encoder has opened.
        var since = System.Diagnostics.Stopwatch.GetTimestamp();
        SessionId = session.Id;
        Room = room;
        if (room) store.MarkRoom(session.Id);
        // A silent debug meeting has nothing to record: an empty recording would be retried every launch.
        if (settings.RecordAudio && store.Audio is { } files && from is not SilentSource)
        {
            var path = Recording.Partial(Recording.SystemAudio(session.Id));
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                recorder = files.Open(path) is { } file ? new RoomMix(file) : null;
            }
            catch (Exception e) { Log.Debug($"listen: recording not started {e.GetType().Name}"); }
            if (recorder is null) Log.Debug("listen: no recording, the encoder refused");
        }
        Begin(from, room, 0, since);
        Fixes?.MeetingStarted();
        notes.Language = () => Languages.EnglishName(settings.NotesCode);
        notes.Begin(session.Id);
        Log.Debug($"listen: started {session.Id} target={Target}");
        Changed?.Invoke();
    }

    /// The room side joins the meeting `sessionId`, which began at `startedAt`; what it hears goes
    /// into the meeting's recording `mix` (the main side's `Mix`) too.
    public void Join(IAudioSource mic, string sessionId, DateTimeOffset startedAt, RoomMix? mix = null)
    {
        if (Listening || !RoomSide) return;
        SessionId = sessionId;
        roomMix = mix;
        Room = true;
        store.MarkRoom(sessionId);
        Begin(mic, true, Math.Max(0, (DateTimeOffset.Now - startedAt).TotalSeconds));
        if (Echo is { } echo)
        {
            held = Channel.CreateUnbounded<(Segment, Heard, double, double)>(new UnboundedChannelOptions { SingleReader = true });
            flush = new CancellationTokenSource();
            holding = Hold(held.Reader, echo, flush.Token);
        }
        Log.Debug($"listen: room side joined {sessionId} at {offset:F1}s");
        Changed?.Invoke();
    }

    void Begin(IAudioSource from, bool room, double at, long? since = null)
    {
        lock (gate)
        {
            done.Clear(); segments.Clear(); inFlight.Clear(); prints.Clear(); clusterer = new(); emitted.Clear();
            nextToDeliver = 1; lineCount = RoomSide ? RoomIDs : 0; last = null; lastEnd = 0;
            hint = null; candidate = null; candidateVotes = 0; Problem = null; serverErrors = 0;
        }
        offset = at;
        segmenter = new Segmenter(room ? new VoiceGate() : null);
        segmenter.Emitted += Send;
        audio = Channel.CreateUnbounded<(short[], double)>(new UnboundedChannelOptions { SingleReader = true });
        var reader = audio.Reader;
        began = since ?? System.Diagnostics.Stopwatch.GetTimestamp();
        long fed = 0;
        // One reader thread owns the segmenter (and the recording): audio callbacks only queue buffers.
        worker = Task.Run(async () =>
        {
            await foreach (var (buf, at) in reader.ReadAllAsync())
            {
                // Keep the meeting's clock: a gap the source left (the PC silent, a source switch)
                // goes in as silence, so a line's t and the recording both stay on the wall clock.
                if (Recording.Behind(at, fed, buf.Length) is > 0 and var gap)
                {
                    var silence = new short[gap];
                    segmenter.Feed(silence);
                    Record(silence, fed);
                    fed += gap;
                }
                Record(buf, fed);
                fed += buf.Length;
                Level = Rms(buf);
                // The computer is playing speech: the room mic would hear it from the speakers.
                if (!RoomSide && Echo is { } echo && Level >= Segmenter.Threshold) echo.Gate.Hold();
                if (!RoomSide) Loudness?.Add(Level >= Segmenter.Threshold);
                segmenter.Feed(buf);
            }
            segmenter.Flush();
        });
        source = from;
        source.Samples += OnSamples;
        source.Start();
        Listening = true;
    }

    /// The room side's lines wait a moment for the computer's line they may echo (EchoMatch.Hold),
    /// in order; one around which the computer played nothing goes straight in. Stopping records
    /// what still waits without the wait: it was said.
    async Task Hold(ChannelReader<(Segment seg, Heard heard, double at, double queued)> reader, EchoFilter echo, CancellationToken stopping)
    {
        await foreach (var (seg, heard, at, queued) in reader.ReadAllAsync())
        {
            var h = new EchoMatch.Heard(heard.Original, at - seg.Seconds, at);
            if (!echo.Quiet(h))
            {
                var wait = queued + EchoMatch.Hold - echo.Gate.Clock();
                if (wait > 0) try { await Task.Delay(TimeSpan.FromSeconds(wait), stopping); } catch (OperationCanceledException) { }
            }
            if (echo.IsEcho(h)) { Log.Debug($"listen: room line dropped as an echo ({heard.Original.Length} chars)"); continue; }
            Record(seg, heard);
            Changed?.Invoke();
        }
    }

    void OnSamples(short[] buf) => audio?.Writer.TryWrite((buf, System.Diagnostics.Stopwatch.GetElapsedTime(began).TotalSeconds));

    /// `fed`: samples this side gave before these, so the room's land at their place in the meeting.
    void Record(short[] pcm, long fed)
    {
        if (RoomSide)
        {
            roomMix?.Room(pcm, (long)Math.Round(offset * Segmenter.Rate) + fed);
            return;
        }
        if (recorder is null) return;
        try { recorder.Write(pcm); }
        catch (Exception e)
        {
            Log.Debug($"listen: recording failed {e.GetType().Name} 0x{e.HResult:X8}, stopped");
            CloseRecording();
        }
    }

    void CloseRecording()
    {
        var r = recorder;
        recorder = null;
        try { r?.Close(); } catch (Exception e) { Log.Debug($"listen: recording close failed {e.GetType().Name}"); }
    }

    /// 听哪里 changed mid-meeting between the computer and the room: the same meeting goes on from the
    /// other source, its clock running on.
    public void SwitchSource(IAudioSource to, bool room)
    {
        if (!Listening || SessionId is not { } id) return;
        if (source is not null) { source.Samples -= OnSamples; source.Stop(); }
        if (room) store.MarkRoom(id);
        Room = room;
        if (segmenter is not null) segmenter.Gate = room ? new VoiceGate() : null;
        source = to;
        source.Samples += OnSamples;
        source.Start();
        Log.Debug($"listen: now {(room ? "the room" : "the computer")}");
        Changed?.Invoke();
    }

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
        CloseRecording();
        roomMix = null;
        await Task.WhenAny(Task.WhenAll(waiting), Task.Delay(15_000));
        var id = SessionId!;
        if (RoomSide)
        {
            // The meeting is the main side's to end; lines still waiting for their echo check go in.
            held?.Writer.TryComplete();
            flush?.Cancel();
            if (holding is not null) await holding;
            held = null; holding = null;
            Log.Debug($"listen: room side stopped, {lineCount - RoomIDs} lines");
            Changed?.Invoke();
            return;
        }
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
            if (Echo is { } echo) emitted[seg.Index] = echo.Gate.Clock();
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
                Interlocked.Exchange(ref serverErrors, 0);
                Problem = null;
            }
            catch (LingException e)
            {
                var server = IsServerError(e.Failure, e.Status);
                if (!server) Interlocked.Exchange(ref serverErrors, 0);
                if (!server || Interlocked.Increment(ref serverErrors) >= ServerErrorsShown)
                {
                    Problem = e.Failure is LingException.Kind.Hijacked or LingException.Kind.Parse ? null : e.Failure;
                    ProblemStatus = e.Status;
                }
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
        foreach (var (seg, heard) in ready)
        {
            if (heard is null) continue;
            // Words in the computer's audio: speech, which the room mic is silenced for (EchoGate).
            if (!RoomSide && Echo is { } words && !string.IsNullOrWhiteSpace(heard.Original)) words.Gate.HeardWords();
            if (RoomSide && held is { } h && Echo is { } echo) h.Writer.TryWrite((seg, heard, EmittedAt(seg), echo.Gate.Clock()));
            else Record(seg, heard);
        }
        if (ready.Count > 0) Changed?.Invoke();
    }

    /// When the segmenter let go of `seg` (just after its last word), on EchoGate's clock.
    double EmittedAt(Segment seg)
    {
        lock (gate) return emitted.Remove(seg.Index, out var at) ? at : Echo?.Gate.Clock() ?? 0;
    }

    void Record(Segment seg, Heard heard)
    {
        var id = SessionId!;
        var target = Target;
        // 电脑和会议室: what the computer said, for the room side to tell its copy of it.
        if (!RoomSide && Echo is { } echo)
        {
            var at = EmittedAt(seg);
            echo.Online(new EchoMatch.Heard(heard.Original, at - seg.Seconds, at));
        }
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
                    Id = $"h{++lineCount}-{(RoomSide ? RoomIDs : 0) + seg.Index}", T = Math.Round(offset + seg.Start, 3), Speaker = "them",
                    Src = heard.Original, Dst = heard.Translation, SrcLang = heard.Lang, DstLang = target, Voice = voice,
                    // 会议室 alone too: a meeting switched to it from 电脑和会议室 would otherwise
                    // mark its later room lines 线上 (as on the Mac).
                    Via = RoomSide || settings.ListensToRoom ? "room" : null,
                };
                last = line;
            }
            lastEnd = seg.Start + seg.Seconds;
        }
        if (joined) store.Replace(id, line.Copy()); else store.Append(id, line.Copy());
        // 改正听错的词: the word list's confirmed heard forms, without asking anyone.
        Fixes?.ApplyKnown(id, line.Id);

        // A joined sentence is translated again as a whole; a line Ming didn't translate gets text
        // translation. With 改正听错的词 every finished line is translated again by the AI service,
        // which also points out misheard words in the same request (the Mac's viaLingFixing): Ming
        // gives the translation with the audio, so there is no text request of its own to ride on.
        // The new translation (of the sentence as fixed) replaces Ming's; a joined line's second
        // pass may take back a fix it no longer proposes. Lines Ming already translated go at the
        // notes' priority, so the subtitles' hearing requests keep going first.
        var retranslate = (joined || line.Dst is null) && line.SrcLang != target;
        var context = line.SrcLang != target && ling.Usable ? Fixes?.Context(id, line.Id) : null;
        if (retranslate || context is not null)
        {
            var src = line.Src;
            var lineId = line.Id;
            _ = Task.Run(async () =>
            {
                string? dst = null;
                if (context is not null && Fixes is { } fixes
                    && await translator.TranslateFixing(src, line.SrcLang, target, context, retranslate ? Priority.Translate : Priority.Notes) is { } got)
                {
                    lock (gate) if (line.Src != src) return;
                    dst = got.Translation;
                    fixes.Received(id, lineId, got.Edits);
                }
                if (dst is null && !retranslate) return;
                dst ??= await translator.Translate(src, line.SrcLang, target, Translator.Kind.Sentence, lingTried: context is not null);
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
