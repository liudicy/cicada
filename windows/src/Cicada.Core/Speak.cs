using System.Security.Cryptography;

namespace Cicada;

/// Where the room's voice goes: the virtual mic (VB-Cable's "CABLE Input"), or the speakers for a
/// preview. Takes 16-bit mono PCM at `rate` and returns once it has played.
public interface ISpeechSink
{
    /// Starts a sentence: PCM chunks follow, then End.
    void Begin(int rate);
    void Write(byte[] pcm);
    Task End();
}

/// Windows' own voice, for when Ming's can't speak: 16-bit mono PCM, or null.
public interface ISystemVoice
{
    Task<(byte[] pcm, int rate)?> Speak(string text, string language);
    /// Whether this PC has a voice for the language (Chinese Windows often has only Chinese ones).
    bool Has(string language);
}

/// A voice the room can hear: one of Ming's (through the Ling key) or Windows' own.
public sealed record VoiceOption(string Id, string Name, string Tags);

/// Which voices to offer for each language the room may hear: Ming's hand-picked natural ones, as
/// on the Mac (Voices.swift › VoiceCatalog), then Windows' voice so there is always one.
public static class VoiceCatalog
{
    public const string SystemId = "system";

    public static string Key(string code) { var b = code.Split('-')[0]; return b.Length == 0 ? "en" : b; }

    /// Ming's `language_id` for languages that need it (zh and en work without).
    public static string? MingLanguage(string code) => Key(code) is "ja" or "ko" or "de" or "fr" or "es" ? Key(code) : null;

    public static IReadOnlyList<VoiceOption> Ming(string language) => Key(language) switch
    {
        "en" => [new("ming:US_Emma", "Emma", "女 · 美式 · 自然对话"), new("ming:UK_George", "George", "男 · 英式 · 稳重"), new("ming:UK_Charlotte", "Charlotte", "女 · 英式 · 平稳")],
        "zh" => [new("ming:灵小雅", "小雅", "女 · 清亮 · 播报"), new("ming:灵小棠", "小棠", "女 · 温和 · 沉稳"), new("ming:灵小锋", "小锋", "男 · 温暖 · 亲切"), new("ming:灵卓然", "卓然", "男 · 沉着 · 清楚")],
        "ja" or "ko" or "de" or "fr" or "es" => [new("ming:US_Emma", "Emma", "女 · Ming"), new("ming:UK_George", "George", "男 · Ming")],
        _ => [],
    };

    public static IReadOnlyList<VoiceOption> Options(string language, bool windowsHasIt = true) =>
        windowsHasIt ? [.. Ming(language), new(SystemId, "Windows", "本机")] : Ming(language);

    /// What a language uses until the user picks: Ming's first voice with a key, else Windows'.
    public static string DefaultId(string language, bool hasKey) => hasKey && Ming(language).Count > 0 ? Ming(language)[0].Id : SystemId;

    /// A short line to try a voice with, in the language it will speak.
    public static string Sample(string language) => Key(language) switch
    {
        "zh" => "谢谢大家。我们来看一下上线时间表，并确定谁负责麦克风测试。",
        "ja" => "皆さん、ありがとうございます。発売スケジュールを確認しましょう。",
        "ko" => "감사합니다. 출시 일정을 함께 확인해 보겠습니다.",
        "es" => "Gracias a todos. Revisemos el calendario de lanzamiento.",
        "fr" => "Merci à tous. Regardons ensemble le calendrier de lancement.",
        "de" => "Danke an alle. Schauen wir uns den Zeitplan für den Start an.",
        "pt" => "Obrigado a todos. Vamos ver o cronograma de lançamento.",
        _ => "Thanks everyone. Let's look at the launch timeline and decide who owns the microphone tests.",
    };
}

/// Hold to talk, the Mac's SpeakEngine: what I said (a 16 kHz WAV) → Ming hears and translates it in
/// one call → a voice speaks the translation into the virtual mic, so the meeting hears it in the
/// room's language. Never speaks anything untranslated: no translation, no sound.
public sealed class SpeakEngine
{
    public enum Phase { Idle, Recording, Translating, Speaking, Failed }

    readonly LingClient ling;
    readonly Translator translator;
    readonly SessionStore store;
    readonly AppSettings settings;
    readonly Func<string?> roomLanguage;
    readonly Func<(string id, DateTimeOffset startedAt)?> openMeeting;
    readonly ISystemVoice systemVoice;
    int lineCount;
    readonly SemaphoreSlim one = new(1, 1);

    public Phase State { get; private set; }
    /// What the bar shows: what I said, then what the room heard (or why nothing was sent).
    public string? Said { get; private set; }
    public string? Heard { get; private set; }
    public string? Problem { get; private set; }
    /// "ming" or "system": how the last sentence was voiced.
    public string? LastVoice { get; private set; }
    public event Action? Changed;

    public SpeakEngine(LingClient ling, Translator translator, SessionStore store, AppSettings settings,
        Func<string?> roomLanguage, Func<(string id, DateTimeOffset startedAt)?> openMeeting, ISystemVoice systemVoice)
    {
        this.ling = ling; this.translator = translator; this.store = store; this.settings = settings;
        this.roomLanguage = roomLanguage; this.openMeeting = openMeeting; this.systemVoice = systemVoice;
    }

    /// The language I speak: the setting, else Windows'.
    public string MyLanguage => settings.SpeakFrom == "system" ? Languages.FromSystem(System.Globalization.CultureInfo.CurrentUICulture.Name) : settings.SpeakFrom;

    /// The room's language (SpeakEngine.swift › targetCode): the chosen one, else the language the
    /// other side has been speaking, else English; never my own.
    public string Target => TargetFor(settings.SpeakTo, roomLanguage(), MyLanguage);

    public static string TargetFor(string speakTo, string? room, string mine)
    {
        if (speakTo != "room") return speakTo;
        var r = room ?? "en";
        return VoiceCatalog.Key(r) == VoiceCatalog.Key(mine) ? (VoiceCatalog.Key(mine) == "en" ? "zh-CN" : "en") : r;
    }

    DateTimeOffset? pressedAt;

    public void BeginRecording()
    {
        pressedAt = DateTimeOffset.Now;
        State = Phase.Recording; Said = Heard = Problem = null;
        Changed?.Invoke();
    }

    public void Cancel()
    {
        if (State == Phase.Recording) { State = Phase.Idle; Changed?.Invoke(); }
    }

    /// One utterance: `wav` is 16 kHz mono. Returns what the room heard, or null if nothing was sent.
    public async Task<string?> Speak(byte[] wav, ISpeechSink sink)
    {
        await one.WaitAsync();
        try
        {
            var released = DateTime.UtcNow;
            var to = Target;
            State = Phase.Translating; Said = Heard = Problem = null;
            Changed?.Invoke();
            Heard? heard = null;
            try { heard = await translator.Hear(wav, to, MyLanguage, Priority.Speak); }
            catch (LingException e) { Log.Debug($"speak: hear failed {e.Message}"); return Fail(e.Failure is LingException.Kind.Network or LingException.Kind.Timeout ? Strings.L("连不上 Ling，没有发出去") : Strings.L("没翻译成功，没有发出去")); }
            if (heard is null) return Fail(Strings.L("没听清，没有发出去"));
            Said = heard.Original;
            var text = heard.Translation;
            // Ming didn't translate it: the text translator gets one try; failing that, silence.
            if (text is null && heard.Lang != to) text = await translator.Translate(heard.Original, heard.Lang, to, Translator.Kind.Sentence, Priority.Speak);
            if (string.IsNullOrWhiteSpace(text)) return Fail(Strings.L("没翻译成功，没有发出去"));
            var translatedAt = DateTime.UtcNow;
            Heard = text;
            State = Phase.Speaking;
            Changed?.Invoke();
            Record(heard, text, to, pressedAt ?? DateTimeOffset.Now.AddSeconds(-(wav.Length - 44) / 32000.0));
            pressedAt = null;
            var voiced = await Voice(text, to, sink);
            Log.Debug($"speak: {heard.Lang} → {to} via {LastVoice ?? "nothing"}, translated in {(translatedAt - released).TotalMilliseconds:F0} ms, voiced by {(DateTime.UtcNow - released).TotalMilliseconds:F0} ms");
            if (!voiced) return Fail(systemVoice.Has(to) ? Strings.L("没能发出声音") : Strings.L("这台电脑没有这种语言的声音，没有发出去"));
            State = Phase.Idle;
            Changed?.Invoke();
            return text;
        }
        finally { one.Release(); }
    }

    /// Something stopped the sentence before it got here (no mic, no virtual mic): say so on the bar.
    public void Report(string why) => Fail(why);

    string? Fail(string why)
    {
        State = Phase.Failed; Problem = why; pressedAt = null;
        Log.Debug($"speak: nothing sent ({why})");
        Changed?.Invoke();
        return null;
    }

    /// The sentence joins the meeting being listened to, as the Mac's "me" lines do.
    /// Timed from when I started speaking, like the other side's lines.
    void Record(Heard heard, string text, string to, DateTimeOffset spokeAt)
    {
        if (openMeeting() is not { } m) return;
        var line = new TranscriptLine
        {
            Id = $"m{++lineCount}", T = Math.Max(0, (spokeAt - m.startedAt).TotalSeconds), Speaker = "me",
            Src = heard.Original, Dst = text, SrcLang = heard.Lang, DstLang = to,
        };
        store.Append(m.id, line);
    }

    /// Ming's voice, else Windows'. True once some sound went out.
    public async Task<bool> Voice(string text, string language, ISpeechSink sink)
    {
        var id = settings.SpeakVoices.TryGetValue(VoiceCatalog.Key(language), out var chosen) ? chosen : VoiceCatalog.DefaultId(language, ling.HasKey);
        if (id.StartsWith("ming:") && ling.HasKey)
        {
            int chunks = 0;
            try
            {
                await foreach (var pcm in ling.Speech(text, id["ming:".Length..], VoiceCatalog.MingLanguage(language)))
                {
                    if (chunks++ == 0) sink.Begin(24000);
                    sink.Write(pcm);
                }
            }
            catch (LingException e) { Log.Debug($"speak: ming voice failed {e.Message}"); }
            if (chunks > 0) { await sink.End(); LastVoice = "ming"; return true; }
        }
        var own = await systemVoice.Speak(text, language);
        if (own is not { } v || v.pcm.Length == 0) { LastVoice = null; return false; }
        sink.Begin(v.rate);
        sink.Write(v.pcm);
        await sink.End();
        LastVoice = "system";
        return true;
    }
}

/// VB-Cable, the virtual mic: downloaded from VB-Audio when the user asks, never bundled, and run
/// only if it is the exact package checked here (as BlackHole is on the Mac).
public static class VirtualCable
{
    public const string PackageUrl = "https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip";
    public const string PackageSha256 = "b950e39f01af1d04ea623c8f6d8eb9b6ea5c477c637295fabf20631c85116bfb";
    /// The render endpoint the app writes to, and the capture one meeting apps pick as the mic.
    public const string InputName = "CABLE Input", OutputName = "CABLE Output";

    public static bool Verify(byte[] package) => Convert.ToHexString(SHA256.HashData(package)).Equals(PackageSha256, StringComparison.OrdinalIgnoreCase);
}
