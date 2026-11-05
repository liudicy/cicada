// Unit tests for Cicada.Core: `scripts/test.sh` (or `dotnet run --project tests/Cicada.Tests`).
// Each test is a method below; a failed Check throws and the runner reports it. No network:
// LingClient runs against a fake handler.
using System.Net;
using System.Reflection;
using System.Text.Json.Nodes;
using Cicada;

Environment.SetEnvironmentVariable("CICADA_HOME", Path.Combine(Path.GetTempPath(), "cicada-tests-" + Environment.ProcessId));
Strings.Load(Path.Combine(AppContext.BaseDirectory, "Resources"), "zh-Hans");
int passed = 0, failed = 0;
foreach (var m in typeof(Tests).GetMethods(BindingFlags.Public | BindingFlags.Static).OrderBy(m => m.MetadataToken))
{
    try
    {
        if (m.Invoke(null, null) is Task t) await t;
        passed++;
    }
    catch (Exception e)
    {
        failed++;
        var inner = e is TargetInvocationException { InnerException: { } i } ? i : e;
        Console.WriteLine($"FAIL {m.Name}: {inner.Message}");
    }
}
try { Directory.Delete(Paths.Root, true); } catch { }
Console.WriteLine($"{passed} passed, {failed} failed");
return failed == 0 ? 0 : 1;

static class Tests
{
    static void Check(bool ok, string what) { if (!ok) throw new Exception(what); }
    static void Equal<T>(T expected, T actual, string what)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new Exception($"{what}: expected «{expected}», got «{actual}»");
    }

    // MARK: Cicada-Setup.exe

    public static void SetupDecidesFromWhereItRuns()
    {
        const string home = @"C:\Users\a\AppData\Local\Programs\Cicada\Cicada.exe";
        const string download = @"C:\Users\a\Downloads\Cicada-Setup.exe";
        Equal(SetupPlan.Step.Run, SetupPlan.Decide(false, home, home, "1.4.0", "1.4.0"), "the installed copy just runs");
        Equal(SetupPlan.Step.Run, SetupPlan.Decide(false, @"c:\users\A\appdata\local\programs\cicada\CICADA.EXE", home, "1.4.0", "1.4.0"), "paths compare without case");
        Equal(SetupPlan.Step.Run, SetupPlan.Decide(true, download, home, null, "1.4.0"), "a dev build never installs");
        Equal(SetupPlan.Step.Install, SetupPlan.Decide(false, download, home, null, "1.4.0"), "nothing installed: install");
        Equal(SetupPlan.Step.Upgrade, SetupPlan.Decide(false, download, home, "1.3.9", "1.4.0"), "older installed: upgrade");
        Equal(SetupPlan.Step.Open, SetupPlan.Decide(false, download, home, "1.4.0", "1.4.0"), "same version: open it");
        Equal(SetupPlan.Step.Open, SetupPlan.Decide(false, download, home, "1.10.0", "1.9.0"), "never downgrade");
        Equal("知了", SetupPlan.ShortcutName("zh-Hans"), "Chinese shortcut");
        Equal("Cicada", SetupPlan.ShortcutName("ja"), "other languages");
    }

    public static void StringsLoadFromAReader()
    {
        var files = new Dictionary<string, string> { ["en.lproj/Localizable.strings"] = "\"知了\" = \"Cicada\";", ["en.lproj/Windows.strings"] = "\"安装\" = \"Install\";" };
        try
        {
            Strings.Load(p => files.GetValueOrDefault(p), "en");
            Equal("Cicada", Strings.L("知了"), "the Mac table");
            Equal("Install", Strings.L("安装"), "the Windows table over it");
        }
        finally { Strings.Load(Path.Combine(AppContext.BaseDirectory, "Resources"), "zh-Hans"); }
    }

    // MARK: 结束会议 (the Mac's MeetingEndTests, case for case)

    static readonly DateTimeOffset T0 = DateTimeOffset.FromUnixTimeSeconds(1_000_000);
    static readonly Dictionary<string, string> Zoom = new() { ["zoom.exe"] = "Zoom" };
    static readonly Dictionary<string, string> NoCalls = [];
    static MeetingEndWatch Watch(MeetingEndWatch.Silence silence = MeetingEndWatch.Silence.Prompt, bool followApps = true) =>
        new(new MeetingEndWatch.Config(FollowApps: followApps, Silence: silence), T0);
    static DateTimeOffset At(double s) => T0.AddSeconds(s);

    public static void HangUpEndsAfterTheGrace()
    {
        var w = Watch();
        Equal(null, w.Tick(At(10), Zoom, true), "in a call");
        Equal(null, w.Tick(At(20), NoCalls, true), "hung up");
        Equal(new MeetingEndWatch.Pending(MeetingEndWatch.Reason.AppLeft("Zoom"), At(50)), w.Waiting, "the grace");
        Equal(null, w.Tick(At(49), NoCalls, true), "still in the grace");
        Equal(MeetingEndWatch.Reason.AppLeft("Zoom"), w.Tick(At(50), NoCalls, true), "ends");
    }

    public static void RejoiningWithinTheGraceKeepsGoing()
    {
        var w = Watch();
        w.Tick(At(10), Zoom, true); w.Tick(At(20), NoCalls, true);
        Equal(null, w.Tick(At(30), Zoom, true), "rejoined");
        Equal(null, w.Waiting, "nothing pending");
    }

    public static void SpeechDoesNotCancelAHangUp()
    {
        var w = Watch();
        w.Tick(At(10), Zoom, true); w.Tick(At(20), NoCalls, true);
        w.Heard(At(25));
        Equal(MeetingEndWatch.Reason.AppLeft("Zoom"), w.Tick(At(50), NoCalls, true), "the next video would talk over it");
    }

    public static void KeepGoingForgetsTheHangUp()
    {
        var w = Watch();
        w.Tick(At(10), Zoom, true); w.Tick(At(20), NoCalls, true);
        w.KeepGoing(At(30));
        Equal(null, w.Tick(At(100), NoCalls, true), "kept going");
        Equal(null, w.Waiting, "nothing pending");
    }

    public static void SilencePromptsThenEnds()
    {
        var w = Watch();
        w.Heard(At(5));
        Equal(null, w.Tick(At(604), NoCalls, true), "not yet");
        Equal(null, w.Waiting, "no prompt yet");
        Equal(null, w.Tick(At(605), NoCalls, true), "the prompt");
        Equal(new MeetingEndWatch.Pending(MeetingEndWatch.Reason.SilenceEnd, At(665)), w.Waiting, "a countdown");
        Equal(MeetingEndWatch.Reason.SilenceEnd, w.Tick(At(665), NoCalls, true), "ends");
    }

    public static void WordsCancelTheSilencePrompt()
    {
        var w = Watch();
        w.Tick(At(600), NoCalls, true);
        Equal("silence", w.Waiting?.Reason.Kind, "prompted");
        w.Heard(At(620));
        Equal(null, w.Waiting, "words cancel it");
        Equal(null, w.Tick(At(700), NoCalls, true), "and it starts over");
    }

    public static void SilenceEndModeEndsAtOnceAndOffNever()
    {
        Equal(MeetingEndWatch.Reason.SilenceEnd, Watch(MeetingEndWatch.Silence.End).Tick(At(600), NoCalls, true), "end");
        var off = Watch(MeetingEndWatch.Silence.Off);
        Equal(null, off.Tick(At(99_999), NoCalls, true), "off");
        Equal(null, off.Waiting, "off: nothing pending");
    }

    public static void SilenceDoesNotCountDuringACall()
    {
        var w = Watch();
        Equal(null, w.Tick(At(5_000), Zoom, true), "a muted call");
        Equal(null, w.Waiting, "no prompt in a call");
        var plain = Watch(followApps: false);
        Equal(null, plain.Tick(At(600), Zoom, true), "not following apps");
        Equal("silence", plain.Waiting?.Reason.Kind, "then a call says nothing");
    }

    public static void NothingSaidStopsQuietlyAfterTheSilence()
    {
        var w = Watch();
        Equal(null, w.Tick(At(599), NoCalls, false), "not yet");
        Equal(MeetingEndWatch.Reason.Nobody, w.Tick(At(600), NoCalls, false), "stops");
        Equal(null, w.Waiting, "no countdown");
        Equal(MeetingEndWatch.Reason.Nobody, Watch(MeetingEndWatch.Silence.End).Tick(At(600), NoCalls, false), "end mode too");
        Equal(null, Watch(MeetingEndWatch.Silence.Off).Tick(At(5_000), NoCalls, false), "off keeps listening");
        Equal(null, Watch().Tick(At(5_000), Zoom, false), "a muted webinar keeps listening");
    }

    public static void NothingSaidKeepsListening()
    {
        var w = Watch();
        w.Tick(At(10), Zoom, false);
        Equal(null, w.Tick(At(500), NoCalls, false), "a call that ended before anyone spoke");
        Equal(null, w.Waiting, "nothing pending");
        w.Heard(At(5_001));
        Equal(null, w.Tick(At(5_002), NoCalls, true), "is forgotten once someone does");
        Equal(null, w.Waiting, "still nothing pending");
    }

    public static void MicUseCountsOnlyMeetingAppsWithTheMicOpen()
    {
        var calls = MicUse.Calls([
            ("C:#Program Files#Zoom#bin#Zoom.exe", 0), ("C:#Users#me#AppData#Roaming#Zoom#bin#Zoom.exe", 0),
            ("C:#Program Files (x86)#Tencent#WeMeet#wemeetapp.exe", 133_000_000_000), // used earlier, closed now
            ("C:#Program Files#Google#Chrome#Application#chrome.exe", 0),               // a browser isn't a meeting app
            ("MSTeams_8wekyb3d8bbwe", 0),
        ]);
        Equal("Teams=msteams,Zoom=zoom.exe", string.Join(",", calls.OrderBy(p => p.Value).Select(p => $"{p.Value}={p.Key}")), "meeting apps reading a mic");
        Equal(0, MicUse.Calls([]).Count, "none");
    }

    public static void WordsFireOnNewAndGrownLinesOnly()
    {
        var store = new SessionStore();
        var id = store.Begin().Id;
        int heard = 0;
        store.Words += w => { if (w == id) heard++; };
        store.Append(id, new TranscriptLine { Id = "h1-1", Src = "so we will", Dst = "所以我们会", SrcLang = "en", DstLang = "zh-CN" });
        store.Append(id, new TranscriptLine { Id = "m1", Speaker = "me", Src = "好的", Dst = "OK", SrcLang = "zh-CN", DstLang = "en" });
        store.Replace(id, new TranscriptLine { Id = "h1-1", Src = "so we will", Dst = "所以我们将", SrcLang = "en", DstLang = "zh-CN" });
        Equal(2, heard, "a retranslation isn't speech");
        store.Replace(id, new TranscriptLine { Id = "h1-1", Src = "so we will ship", Dst = "所以我们会发布", SrcLang = "en", DstLang = "zh-CN" });
        Equal(3, heard, "a half sentence that grew is");
        store.Delete(id);
    }

    // MARK: Records

    public static void SessionJsonMatchesTheMac()
    {
        var s = new Session
        {
            Id = "20261103-101611", Title = "会议 11月3日 10:16", HasAudio = false,
            StartedAt = DateTimeOffset.Parse("2026-11-03T15:16:11Z"),
            Lines = [new TranscriptLine { Id = "h1-1", T = 2.7636849899291995, Src = "你好/世界", SrcLang = "zh-CN", DstLang = "en" }],
        };
        var json = Json.Write(s);
        Check(json.Contains("\"startedAt\": \"2026-11-03T15:16:11Z\""), "dates are whole-second ISO-8601 UTC");
        Check(json.Contains("你好/世界"), "Chinese and slashes are written as they are");
        Check(!json.Contains("\"dst\""), "nil optionals are left out");
        Check(!json.Contains("endedAt") && !json.Contains("notes"), "absent fields stay absent");
        Check(json.Contains("2.7636849899291995"), "doubles keep full precision");
        var keys = JsonNode.Parse(json)!.AsObject().Select(p => p.Key).ToList();
        Check(keys.SequenceEqual(keys.Order(StringComparer.Ordinal)), "keys are sorted like the Mac's");
        var lineKeys = JsonNode.Parse(json)!["lines"]![0]!.AsObject().Select(p => p.Key).ToList();
        Check(lineKeys.SequenceEqual(lineKeys.Order(StringComparer.Ordinal)), "line keys are sorted");
    }

    public static void ReadsAMacRecord()
    {
        const string mac = """
        {
          "endedAt" : "2026-11-02T15:24:12Z",
          "hasAudio" : true,
          "id" : "20261102-101639",
          "lines" : [
            {
              "dst" : "Hello",
              "dstLang" : "en",
              "id" : "h1-1",
              "speaker" : "them",
              "src" : "你好",
              "srcLang" : "zh-CN",
              "t" : 2.5,
              "voice" : 1
            }
          ],
          "notes" : {
            "conclusions" : [ ], "covered" : 1, "final" : true, "summary" : "总结",
            "terms" : [ { "heard" : [ ], "name" : "鸟哥", "note" : "分享者" } ],
            "title" : "标题", "todos" : [ { "owner" : "你", "support" : 3, "t" : 202.4, "text" : "记录" } ],
            "topics" : [ { "pointTimes" : [ 12.4, null ], "points" : [ "a", "b" ], "start" : 0, "summary" : "s", "title" : "t" } ],
            "updatedAt" : "2026-11-02T15:24:40Z"
          },
          "startedAt" : "2026-11-02T15:16:39Z",
          "title" : "会议 11月2日 10:16",
          "voiceNames" : { "1" : "Emma" }
        }
        """;
        var s = Json.Read<Session>(mac)!;
        Equal(1, s.Lines.Count, "lines");
        Equal(1, s.Lines[0].Voice, "voice");
        Equal("Emma", s.VoiceNames!["1"], "voice names");
        Equal(12.4, s.Notes!.Topics[0].PointTime(0), "point time");
        Equal(null, s.Notes!.Topics[0].PointTime(1), "missing point time");
        Check(JsonNode.DeepEquals(JsonNode.Parse(mac), JsonNode.Parse(Json.Write(s))), "written back unchanged");
    }

    public static void StoreSavesAndDropsEmptyMeetings()
    {
        var store = new SessionStore();
        var empty = store.Begin(DateTimeOffset.Parse("2026-01-01T01:00:00Z"));
        store.End(empty.Id);
        Check(store.Get(empty.Id) is null && !Directory.Exists(Path.Combine(Paths.Sessions, empty.Id)), "an empty meeting is removed");
        var s = store.Begin(DateTimeOffset.Parse("2026-01-01T02:00:00Z"));
        store.Append(s.Id, new TranscriptLine { Id = "h1-1", Src = "hi", SrcLang = "en", DstLang = "zh-CN" });
        store.End(s.Id);
        var file = Path.Combine(Paths.Sessions, s.Id, "session.json");
        Check(File.Exists(file), "record written on end");
        Equal(1, Json.Read<Session>(File.ReadAllText(file))!.Lines.Count, "line saved");
        Check(new SessionStore().Get(s.Id) is not null, "loaded again");
        Check(s.Title.StartsWith("会议 "), "default title is the Mac's Chinese form");
    }

    public static void DisplayTitle()
    {
        var s = new Session { Title = "会议 1月1日 10:00", StartedAt = DateTimeOffset.Now, Notes = new MeetingNotes { Title = "路线评审", Summary = "x" } };
        Check(SessionStore.DisplayTitle(s).EndsWith(" 路线评审"), "notes' name after the date");
        s.Renamed = true; s.Title = "我的会";
        Equal("我的会", SessionStore.DisplayTitle(s), "the user's title wins");
        Check(SessionStore.Markdown(s).Split('\n')[0].TrimEnd() == "# 我的会", "the export is headed by the shown title");
    }

    public static void KeepsTheMacsImportAndRoomFields()
    {
        // A Mac record of an imported room recording, plus a key no version knows yet.
        const string mac = """
        {"endedAt":"2026-01-01T02:10:00Z","futureKey":{"a":[1,2]},"hasAudio":true,"id":"20260101-100000","importing":false,"lines":[],"room":true,"sourceFile":"周会.m4a","sourcePath":"/Users/x/周会.m4a","startedAt":"2026-01-01T02:00:00Z","title":"会议 1月1日 10:00"}
        """;
        var s = Json.Read<Session>(mac)!;
        Equal(true, s.Room, "room");
        Equal("周会.m4a", s.SourceFile, "sourceFile");
        Check(JsonNode.DeepEquals(JsonNode.Parse(mac), JsonNode.Parse(Json.Write(s))), "written back with every key: " + Json.Write(s));
    }

    public static void RenameLikeTheMac()
    {
        var store = new SessionStore();
        var id = store.Begin(DateTimeOffset.Parse("2026-01-02T02:00:00Z")).Id;
        store.Append(id, new TranscriptLine { Id = "h1-1", Src = "hi", SrcLang = "en", DstLang = "zh-CN" });
        store.SetNotes(id, new MeetingNotes { Title = "路线评审", Summary = "x" });
        var shown = SessionStore.DisplayTitle(store.Get(id)!);
        store.Rename(id, " " + shown + " ");
        Equal(null, store.Get(id)!.Renamed, "saving the shown title unchanged isn't a rename");
        store.SetNotes(id, new MeetingNotes { Title = "预算", Summary = "y" });
        Check(SessionStore.DisplayTitle(store.Get(id)!).EndsWith(" 预算"), "so a later name from the notes still shows");
        store.Rename(id, "我的会");
        Equal(true, store.Get(id)!.Renamed, "renamed");
        store.Rename(id, "  ");
        Equal(false, store.Get(id)!.Renamed, "an empty title goes back to the automatic one");
        Check(SessionStore.DisplayTitle(store.Get(id)!).EndsWith(" 预算"), "the notes' name again");
        store.Delete(id);
    }

    public static void MeetingCutShortEndsAfterItsLastLine()
    {
        var start = DateTimeOffset.Parse("2026-01-03T02:00:00Z");
        var dir = Path.Combine(Paths.Sessions, "20260103-crash");
        Directory.CreateDirectory(dir);
        var s = new Session { Id = "20260103-crash", Title = "会议", StartedAt = start, Lines = [new() { Id = "h1-1", Src = "a", T = 3 }, new() { Id = "h1-2", Src = "b", T = 70 }] };
        File.WriteAllText(Path.Combine(dir, "session.json"), Json.Write(s));
        var store = new SessionStore();
        Equal(start.AddSeconds(75), store.Get(s.Id)!.EndedAt, "last line + 5 s");
        store.Delete(s.Id);
    }

    // MARK: Hearing

    public static void ParsesMingReplies()
    {
        var h = Translator.ParseHeard("LANG: en\nORIGINAL: Hello there.\nTRANSLATION: 你好。", "zh-CN", null)!;
        Equal("en", h.Lang, "lang"); Equal("Hello there.", h.Original, "original"); Equal("你好。", h.Translation, "translation");
        Equal(null, Translator.ParseHeard("作为一个人工智能语言模型，这个问题超出我目前的学习范围了", "zh-CN", null), "no labelled lines");
        Equal(null, Translator.ParseHeard("LANG: en\nORIGINAL: NONE\nTRANSLATION: 无", "zh-CN", null), "no speech");
        Equal(null, Translator.ParseHeard("LANG: en\nORIGINAL: ...\nTRANSLATION: …", "zh-CN", null), "punctuation only");
        var same = Translator.ParseHeard("LANG: zh\nORIGINAL: 好的\nTRANSLATION: OK", "zh-CN", "en")!;
        Equal("zh-CN", same.Lang, "zh normalized"); Equal("好的", same.Translation, "already in the target: kept as is");
        var wrong = Translator.ParseHeard("LANG: en\nORIGINAL: Hi\nTRANSLATION: Hi again", "zh-CN", null)!;
        Equal(null, wrong.Translation, "a translation not in Chinese is dropped for the text translator");
        Equal("ja", Translator.ParseHeard("lang: ja-JP\noriginal: はい\ntranslation: 是", "zh-CN", null)!.Lang, "labels in any case");
    }

    // Same cases as the Android and Linux ports' noise tests.
    public static void DropsNoise()
    {
        foreach (var o in new[] { "嗯。", "Mm.", "uh, um", "呃呃呃呃呃", "嗯，嗯，嗯，嗯，嗯，嗯，嗯，嗯，嗯，嗯，嗯，嗯。", string.Concat(Enumerable.Repeat("滴答", 50)),
                                  "hmmmm", "うーん", "음…", "喂？", "No no no no no no",
                         "（无语音内容）", "[Music]", "♪♪", "这段音频是一段旋律，没有说话声。", "There is no speech in this audio." })
            Check(Translator.IsNoise(o), $"noise: {o}");
        foreach (var o in new[] { "嗯，好的。", "OK.", "Oh no, it crashed.", "对", "对对对", "谢谢谢谢", "喂喂，能听到吗？", "No, no, no.",
                                  "えーと、来週の件ですが", "あの人です", "Okay, let's move on to the quarterly numbers.", "（笑）好的" })
            Check(!Translator.IsNoise(o), $"kept: {o}");
        var spoken = "我们今天讨论一下这个季度的数字和下个季度的计划安排";
        Check(Translator.IsNoise(spoken, 1.0), "more than anyone says in a second");
        Check(!Translator.IsNoise(spoken, 4.0), "said in four seconds");
        Equal(null, Translator.ParseHeard("LANG: zh-CN\nORIGINAL: 嗯，嗯，嗯，嗯，嗯，嗯。\nTRANSLATION: 嗯，嗯，嗯，嗯，嗯，嗯。", "zh-CN", null), "hold music");
        Equal(800, Translator.HearTokens(0), "unknown length"); Equal(380, Translator.HearTokens(8), "a full segment");
        Equal(800, Translator.HearTokens(30), "capped");
    }

    public static void NormalizesLanguages()
    {
        Equal("zh-CN", Languages.Normalize("zh-Hans", "en"), "zh-Hans");
        Equal("zh-TW", Languages.Normalize("zh-TW", "en"), "zh-TW");
        Equal("zh-CN", Languages.Normalize("cmn", "en"), "cmn");
        Equal("en", Languages.Normalize("en-US", "ja"), "en-US");
        Equal("ja", Languages.Normalize("", "ja"), "empty falls back");
        Equal("zh-TW", Languages.FromSystem("zh-Hant-HK"), "system zh-Hant");
        Equal("zh-CN", Languages.FromSystem("zh-CN"), "system zh-CN");
        Equal("en", Languages.FromSystem("en-GB"), "system en");
        Equal("Simplified Chinese", Languages.EnglishName("zh-CN"), "english name");
        Equal("Japanese", Languages.EnglishName("ja"), "english name ja");
        Equal("01:05", Languages.Clock(65.9), "clock"); Equal("1:00:01", Languages.Clock(3601), "clock hours");
    }

    public static void CleansTranslations()
    {
        Equal("你好", Translator.CleanTranslation("Translation: 你好", "zh-CN"), "label stripped");
        Equal("你好", Translator.CleanTranslation("“你好”", "zh-CN"), "wrapping quotes");
        Equal("Hello", Translator.CleanTranslation("Here is the translation:\nHello", "en"), "remark line dropped");
        Equal(null, Translator.CleanTranslation("请提供需要翻译的字幕内容", "en"), "a request for input is not a translation");
        Equal(null, Translator.CleanTranslation("Hello", "zh-CN"), "wrong script");
        Equal("Done.", Translator.CleanTranslation("<think>x</think>Done.", "en"), "leaked reasoning");
    }

    public static void JoinsCutSentences()
    {
        var last = new TranscriptLine { Src = "We finished the migration and", SrcLang = "en" };
        Check(ListenEngine.Continues(last, 0.2, new Heard("en", "the error rate dropped.", null)), "mid-sentence cut joins");
        Check(!ListenEngine.Continues(last, 1.5, new Heard("en", "next", null)), "a long gap doesn't");
        Check(!ListenEngine.Continues(new TranscriptLine { Src = "Done.", SrcLang = "en" }, 0.1, new Heard("en", "Next", null)), "after a full stop doesn't");
        Check(!ListenEngine.Continues(last, 0.1, new Heard("ja", "はい", null)), "another language doesn't");
        Equal("我们完成了迁移", ListenEngine.Join("我们完成了", "迁移", "zh-CN"), "CJK joins without a space");
        Equal("a b", ListenEngine.Join("a ", " b", "en"), "others with one space");
    }

    // MARK: Segmenter

    static short[] Tone(double seconds, double amp = 0.3) =>
        Enumerable.Range(0, (int)(seconds * 16000)).Select(i => (short)(Math.Sin(2 * Math.PI * 300 * i / 16000) * amp * 32767)).ToArray();
    static short[] Silence(double seconds) => new short[(int)(seconds * 16000)];

    static List<Segment> Cut(params short[][] parts)
    {
        var seg = new Segmenter();
        var list = new List<Segment>();
        seg.Emitted += list.Add;
        foreach (var p in parts) for (int i = 0; i < p.Length; i += 1600) seg.Feed(p.AsSpan(i, Math.Min(1600, p.Length - i)));
        seg.Flush();
        return list;
    }

    public static void SegmentsOnPauses()
    {
        var list = Cut(Silence(0.5), Tone(2), Silence(1), Tone(1.5), Silence(1));
        Equal(2, list.Count, "two stretches");
        Check(Math.Abs(list[0].Start - 0.35) < 0.05, $"starts just before the speech (pre-roll), got {list[0].Start}");
        Check(Math.Abs(list[1].Start - 3.35) < 0.05, $"second start, got {list[1].Start}");
        Check(list[0].Seconds is > 2.1 and < 2.4, $"length with lead-in and tail, got {list[0].Seconds}");
    }

    public static void CutsLongSpeechAtItsQuietestMoment()
    {
        // 7 s of speech, a 0.3 s dip (shorter than a pause), 4 s more: one cut, at the dip.
        var list = Cut(Tone(7), Tone(0.3, 0.004), Tone(4), Silence(1));
        Equal(2, list.Count, "split in two");
        Check(list[0].Seconds is > 6.9 and < 7.4, $"cut inside the dip, got {list[0].Seconds}");
        Check(list.All(s => s.Seconds <= 8.0), "no segment over 8 s");
        Check(Math.Abs(list[1].Start - (list[0].Start + list[0].Seconds)) < 0.001, "the rest carries on without a gap");
    }

    public static void IgnoresClicks()
    {
        Equal(0, Cut(Silence(1), Tone(0.1), Silence(1)).Count, "under 0.25 s of sound is not speech");
        Equal(0, Cut(Tone(3, 0.002)).Count, "below the gate is silence");
    }

    public static void WavRoundTrip()
    {
        var pcm = Tone(0.5);
        var path = Path.Combine(Path.GetTempPath(), $"cicada-test-{Environment.ProcessId}.wav");
        File.WriteAllBytes(path, Wav.Bytes(pcm));
        Check(Wav.Read(path).SequenceEqual(pcm), "16 kHz mono reads back exactly");
        File.Delete(path);
        Equal(16000, Wav.Resample(new double[48000], 48000).Length, "48 kHz to 16 kHz");
    }

    // MARK: Notes

    public static void ParsesNotes()
    {
        const string reply = """
        ```json
        {"title": "“发布评审”", "summary": "讨论发布。",
         "topics": [{"start": 0, "title": "进展", "summary": "一句", "points": [{"text": "迁移完成", "evidence": ["L2"]}, "旧格式要点", {"text": "", "evidence": []}],
                     "fishbone": {"question": "为何延期", "branches": [{"label": "测试", "detail": "x", "t": 3, "evidence": ["L1"]}, {"label": "设计", "detail": "y", "evidence": ["L9"]}]}}],
         "conclusions": [{"text": "周五上线", "evidence": ["L1", "L2", "L99"]}],
         "todos": [{"text": "发说明", "owner": "", "evidence": ["L2"]}],
         "terms": [{"name": "Stripe", "note": "支付", "heard": ["Stripe", "Strip"]}]}
        ```
        """;
        var n = NotesEngine.Parse(reply, [1.0, 5.0], 0)!;
        Equal("发布评审", n.Title, "title quotes trimmed");
        Equal(2, n.Topics[0].Points.Count, "empty points dropped, plain strings kept");
        Equal(5.0, n.Topics[0].PointTime(0), "point time from evidence");
        Equal(null, n.Topics[0].PointTime(1), "no evidence, no time");
        Equal(2, n.Topics[0].Fishbone!.Branches.Count, "fishbone kept");
        Equal(0, n.Topics[0].Fishbone!.Branches[1].Support, "evidence beyond the transcript doesn't count");
        Equal(2, n.Conclusions[0].Support, "support counts real lines");
        Equal(null, n.Todos[0].Owner, "empty owner is none");
        Equal("Strip", string.Join(",", n.Terms[0].Heard), "the correct spelling isn't a mishearing");
        Equal(null, NotesEngine.Parse("not json", [], 0), "garbage");
        Equal(null, NotesEngine.Parse("{}", [], 0), "empty notes");
    }

    public static void TopicStartsAtItsFirstCitedLine()
    {
        double[] times = [5, 11, 49, 180];
        var raw = "{\"summary\":\"s\",\"topics\":[{\"start\":289,\"title\":\"发布说明\",\"points\":[{\"text\":\"发给设计组\",\"evidence\":[\"L3\"]}]},{\"start\":999,\"title\":\"别的\",\"points\":[\"x\"]}]}";
        var n = NotesEngine.Parse(raw, times, 0)!;
        Equal(49.0, n.Topics[0].Start, "the cited line's time, not the model's 289");
        Equal(180.0, n.Topics[1].Start, "never after the last line");
        var late = NotesEngine.Parse("{\"summary\":\"s\",\"topics\":[{\"start\":5,\"title\":\"整场\",\"points\":[{\"text\":\"p\",\"evidence\":[\"L4\"]}]}]}", times, 0)!;
        Equal(5.0, late.Topics[0].Start, "a rewrite citing only late lines keeps the model's earlier start");
    }

    public static void KeepsEarliestTimes()
    {
        var old = new MeetingNotes { Topics = [new NoteTopic { Title = "t", Points = ["a"], PointTimes = [3] }], Todos = [new NoteItem { Text = "x", T = 2 }] };
        var next = new MeetingNotes { Topics = [new NoteTopic { Title = "t", Points = ["a", "b"], PointTimes = [9, null] }], Todos = [new NoteItem { Text = "x", T = 8 }] };
        NotesEngine.CarryTimes(old, next);
        Equal(3.0, next.Topics[0].PointTime(0), "a point keeps when it was first heard");
        Equal(2.0, next.Todos[0].T, "to-dos too");
    }

    public static void NotesAndExportNameSpeakersLikeTheMac()
    {
        // Two voices, five substantive lines each: 说话人 1 (voice 7) and 说话人 2 (voice 9).
        var lines = Enumerable.Range(0, 10).Select(i => new TranscriptLine { Id = $"h{i}-1", T = i * 10, Src = $"we will ship line {i}", Voice = i % 2 == 0 ? 7 : 9, SrcLang = "en", DstLang = "zh-CN" }).ToList();
        var s = new Session { Title = "会议 1月1日 10:00", StartedAt = DateTimeOffset.Now, Lines = lines,
            VoiceNames = new() { ["7"] = "George" }, VoiceGuesses = new() { ["9"] = new VoiceGuess { Name = "Anna" } } };
        var names = SpeakerLabels.Names(s);
        Equal("George,Anna", $"{names[1]},{names[2]}", "the user's name, else Ling's guess");
        var p = NotesEngine.Prompt(new MeetingNotes(), lines, 0, "English", final: true, names);
        Check(p.Contains("[L1 00:00 George]") && p.Contains("[L2 00:10 Anna]"), "named in the notes prompt");
        Check(SessionStore.Markdown(s).Contains("George："), "and in the export");
        try
        {
            SpeakerLabels.Voices = false;
            Check(NotesEngine.Prompt(new MeetingNotes(), lines, 0, "English", final: true).Contains("[L1 00:00 对方]"), "说话人识别 off: no speakers in the notes");
            var md = SessionStore.Markdown(s);
            Check(!md.Contains("George") && !md.Contains("说话人"), "nor in the export");
        }
        finally { SpeakerLabels.Voices = true; }
    }

    public static void NotesPromptIsTheMacs()
    {
        var lines = new List<TranscriptLine> { new() { T = 1, Src = "你好", Speaker = "them" }, new() { T = 65, Src = "我来说", Speaker = "me" } };
        var p = NotesEngine.Prompt(new MeetingNotes(), lines, 0, "Simplified Chinese", final: false);
        Check(p.StartsWith("You keep notes for a meeting that is still going on. Update them with the new lines.\nWrite the notes in Simplified Chinese. Return JSON only.\n"), "opening");
        Check(p.Contains("[L1 00:01 对方] 你好\n[L2 01:05 你] 我来说"), "transcript lines");
        Check(p.Contains("These are the first lines: make one topic."), "first update");
        Check(p.EndsWith("No markdown, no text outside the JSON."), "ending");
        var f = NotesEngine.Prompt(new MeetingNotes(), lines, 0, "English", final: true);
        Check(f.Contains("This meeting ran 01:04: use at most 1 topic."), "final topic limit");
        Check(NotesEngine.Written(new MeetingNotes { Summary = "讨论发布 Stripe" }, "Simplified Chinese"), "Chinese notes");
        Check(!NotesEngine.Written(new MeetingNotes { Summary = "We talked" }, "Simplified Chinese"), "English isn't Chinese");
    }

    // MARK: Strings

    public static void LoadsTheMacsTranslations()
    {
        Strings.Load(Path.Combine(AppContext.BaseDirectory, "Resources"), "en");
        Equal("Live notes", Strings.L("实时纪要"), "an English string");
        Equal("没有这条", Strings.L("没有这条"), "missing keys show the Chinese");
        Strings.Load(Path.Combine(AppContext.BaseDirectory, "Resources"), "zh-Hans");
        Equal("实时纪要", Strings.L("实时纪要"), "Chinese is the key");
        Strings.Load(Path.Combine(AppContext.BaseDirectory, "Resources"), "en");
        var s = new Session { Title = "会议 11月4日 10:27", StartedAt = new DateTimeOffset(2026, 11, 4, 10, 27, 0, TimeSpan.Zero) };
        Check(!SessionStore.DisplayTitle(s).Contains('月'), "English dates whatever Windows' language: " + SessionStore.DisplayTitle(s));
        Strings.Load(Path.Combine(AppContext.BaseDirectory, "Resources"), "zh-Hans");
        var t = Strings.Parse("/* c */\n\"a \\\"b\\\"\" = \"x\\ny\";\n// line\n\"%@ 分钟\" = \"%@ min\";");
        Equal("x\ny", t["a \"b\""], "escapes");
        Equal("%@ min", t["%@ 分钟"], "placeholders kept");
        Equal("3 分钟", Strings.LF("%@ 分钟", 3), "LF fills %@");
    }

    // MARK: Ling

    sealed class Fake(Func<string, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public readonly List<(DateTime at, string body)> Calls = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancel)
        {
            var body = await request.Content!.ReadAsStringAsync(cancel);
            lock (Calls) Calls.Add((DateTime.UtcNow, body));
            return respond(body);
        }
    }

    static HttpResponseMessage Reply(string content, string? finish = "stop") => new(HttpStatusCode.OK)
    {
        Content = new StringContent(new JsonObject
        {
            ["choices"] = new JsonArray(new JsonObject { ["message"] = new JsonObject { ["content"] = content }, ["finish_reason"] = finish }),
            ["usage"] = new JsonObject { ["prompt_tokens"] = 1, ["completion_tokens"] = 1 },
        }.ToJsonString()),
    };

    static LingClient Client(Fake fake)
    {
        var key = new AIKey(new PlainProtector());
        key.Save("sk-test-0000000000");
        return new LingClient(key, fake);
    }

    public static async Task LingRequestShape()
    {
        var fake = new Fake(_ => Reply("ok"));
        var ling = Client(fake);
        await ling.Chat("the content", "Translate.", Priority.Translate, model: LingClient.AudioModel, audio: [1, 2, 3]);
        var body = JsonNode.Parse(fake.Calls[0].body)!;
        Equal("disabled", body["thinking"]!["type"]!.GetValue<string>(), "thinking disabled");
        Equal("system", body["messages"]![0]!["role"]!.GetValue<string>(), "content in the system message");
        Equal("the content", body["messages"]![0]!["content"]!.GetValue<string>(), "content");
        Equal("audio_url", body["messages"]![1]!["content"]![0]!["type"]!.GetValue<string>(), "audio first");
        Equal("data:audio/wav;base64,AQID", body["messages"]![1]!["content"]![0]!["audio_url"]!["url"]!.GetValue<string>(), "WAV as a data URL");
        Equal("Translate.", body["messages"]![1]!["content"]![1]!["text"]!.GetValue<string>(), "fixed instruction last");
    }

    public static async Task LingDropsHijackedAndRefusedReplies()
    {
        foreach (var (reply, finish) in new[] { ("根据现有检索证据，……", "stop"), ("作为一个人工智能语言模型，这个问题超出……", "stop"), ("fine", (string?)null) })
        {
            var ling = Client(new Fake(_ => Reply(reply, finish)));
            try { await ling.Chat("c", "i", Priority.Translate); throw new Exception($"accepted «{reply}»"); }
            catch (LingException e) { Equal(LingException.Kind.Hijacked, e.Failure, "dropped as hijacked"); }
        }
    }

    public static async Task LingRetriesAudioOnceWhenBusy()
    {
        int calls = 0;
        var fake = new Fake(_ => Interlocked.Increment(ref calls) == 1 ? new HttpResponseMessage(HttpStatusCode.TooManyRequests) : Reply("LANG: en\nORIGINAL: Hi.\nTRANSLATION: 嗨。"));
        var ling = Client(fake);
        var reply = await ling.Chat("c", "i", Priority.Translate, model: LingClient.AudioModel, audio: [1]);
        Check(reply.Contains("ORIGINAL: Hi."), "second attempt answered");
        Equal(2, calls, "one retry");
        var text = Client(new Fake(_ => new HttpResponseMessage(HttpStatusCode.TooManyRequests)));
        try { await text.Chat("c", "i", Priority.Translate); throw new Exception("text translation retried"); }
        catch (LingException e) { Equal(LingException.Kind.RateLimited, e.Failure, "text fails fast"); }
    }

    public static async Task LingMarksABadKey()
    {
        var ling = Client(new Fake(_ => new HttpResponseMessage(HttpStatusCode.Unauthorized)));
        try { await ling.Chat("c", "i", Priority.Translate); } catch (LingException e) { Equal(LingException.Kind.InvalidKey, e.Failure, "401"); }
        Equal(KeyState.Invalid, ling.KeyState, "key state");
        Check(!ling.Usable, "no longer usable");
    }

    public static async Task LingGateSpacesStartsAndServesPriorityFirst()
    {
        var old = LingClient.Spacing;
        LingClient.Spacing = 0.2;
        try
        {
            var fake = new Fake(_ => Reply("ok"));
            var ling = Client(fake);
            var first = ling.Chat("first", "i", Priority.Notes);
            await Task.Delay(20);
            // Queued while the gate is closed: the translation goes before the earlier notes call.
            var notes = ling.Chat("notes", "i", Priority.Notes);
            await Task.Delay(20);
            var translate = ling.Chat("translate", "i", Priority.Translate);
            await Task.WhenAll(first, notes, translate);
            var order = fake.Calls.Select(c => JsonNode.Parse(c.body)!["messages"]![0]!["content"]!.GetValue<string>()).ToList();
            Equal("first,translate,notes", string.Join(",", order), "priority order");
            for (int i = 1; i < fake.Calls.Count; i++)
                Check((fake.Calls[i].at - fake.Calls[i - 1].at).TotalSeconds >= 0.18, "starts spaced");
        }
        finally { LingClient.Spacing = old; }
    }

    // MARK: Voices

    public static void FbankMatchesKaldi()
    {
        var x = new short[19200];
        for (int t = 0; t < x.Length; t++)
            x[t] = (short)Math.Round(8000 * Math.Sin(2 * Math.PI * 220 * t / 16000) + 3000 * Math.Sin(2 * Math.PI * 1375 * t / 16000) + 1500 * Math.Sin(2 * Math.PI * 3100 * t / 16000 * (1 + t / 19200.0)));
        var f = Fbank.Features(x)!;
        var fx = JsonNode.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "fbank.json")))!;
        Equal(fx["frames"]!.GetValue<int>() * Fbank.Bins, f.Length, "frame count");
        foreach (var (row, values) in fx["rows"]!.AsObject())
        {
            int r = int.Parse(row);
            var want = values!.AsArray().Select(v => v!.GetValue<double>()).ToArray();
            var worst = Enumerable.Range(0, Fbank.Bins).Max(b => Math.Abs(f[r * Fbank.Bins + b] - want[b]));
            Check(worst < 2e-3, $"row {r} off by {worst:F5} from numpy/Kaldi");
        }
        Check(Fbank.Features(new short[4000]) is null, "under 0.5 s gives no voiceprint");
    }

    static float[] Unit(params float[] v) { var n = MathF.Sqrt(v.Sum(x => x * x)); return v.Select(x => x / n).ToArray(); }

    public static void ClustersVoicesAsTheMacDoes()
    {
        var c = new VoiceClusterer();
        Check(c.Label(Unit(1, 0, 0), 1.0) is null, "a short first line starts no voice");
        Equal(0, c.Label(Unit(1, 0, 0), 3.0), "a long one does");
        Equal(0, c.Label(Unit(0.9f, 0.3f, 0), 1.0), "a similar line joins it, even short");
        Equal(1, c.Label(Unit(0, 1, 0), 2.5), "a long unlike line is a new voice");
        Check(c.Label(Unit(0, 0, 1), 1.0) is null, "a short unlike line stays 对方");
    }

    public static void NumbersVoicesOnceTwoHaveSaidEnough()
    {
        TranscriptLine L(int i, int? v, string text = "we should ship it") => new() { Id = $"h{i}", Speaker = "them", Src = text, Voice = v };
        var lines = new List<TranscriptLine>();
        for (int i = 0; i < 5; i++) lines.Add(L(i, 7));
        Equal(0, SpeakerLabels.Numbers(lines).Count, "one voice alone: still 对方");
        for (int i = 5; i < 9; i++) lines.Add(L(i, 3));
        lines.Add(L(9, 3, "yeah"));
        Equal(0, SpeakerLabels.Numbers(lines).Count, "\"yeah\" doesn't count towards a name");
        lines.Add(L(10, 3, "我们下周一定上线"));
        var n = SpeakerLabels.Numbers(lines);
        Check(n["h0"] == 1 && n["h10"] == 2 && !n.ContainsKey("h20"), "numbers in the order voices got there");
    }

    sealed class FakePrint(Func<short[], float[]?> f) : IVoiceprint { public float[]? Embed(short[] s) => f(s); }

    public static async Task NeverJoinsTwoVoices()
    {
        // Two halves of one "sentence" (no full stop, 0.4 s apart) in two different voices.
        var fake = new Fake(body =>
        {
            if (!body.Contains("Ming-3.0-audio-flash")) return Reply("{}");
            var url = JsonNode.Parse(body)!["messages"]![1]!["content"]![0]!["audio_url"]!["url"]!.GetValue<string>();
            return Reply(url.Length < 110_000 ? "LANG: en\nORIGINAL: so what we need\nTRANSLATION: 所以我们需要" : "LANG: en\nORIGINAL: is a plan for Monday\nTRANSLATION: 周一的计划");
        });
        var old = LingClient.Spacing; LingClient.Spacing = 0.05;
        try
        {
            var ling = Client(fake);
            var store = new SessionStore();
            var engine = new ListenEngine(ling, new Translator(ling), store, new NotesEngine(ling, store), new AppSettings { Target = "zh-CN" })
            {
                // Told apart by length: the first stretch is 2.5 s, the second 3 s.
                Voiceprint = new FakePrint(s => s.Length < 50_000 ? Unit(1, 0, 0) : Unit(0, 1, 0)),
            };
            var path = Path.Combine(Path.GetTempPath(), $"cicada-voices-{Environment.ProcessId}.wav");
            File.WriteAllBytes(path, Wav.Bytes([.. Tone(2.5), .. Silence(0.7), .. Tone(3), .. Silence(1)]));
            var src = new FileAudioSource(path, speed: 0);
            var ended = new TaskCompletionSource();
            src.Ended += _ => ended.TrySetResult();
            engine.Start(src);
            await ended.Task;
            await Task.Delay(100);
            await engine.Stop();
            var lines = store.All().First().Lines;
            Equal(2, lines.Count, "two voices, two lines (not joined)");
            Check(lines[0].Voice == 0 && lines[1].Voice == 1, "each with its voice");
        }
        finally { LingClient.Spacing = old; }
    }

    // MARK: Speaking

    sealed class Sink : ISpeechSink
    {
        public int Rate; public readonly List<byte[]> Chunks = [];
        public void Begin(int rate) => Rate = rate;
        public void Write(byte[] pcm) => Chunks.Add(pcm);
        public Task End() => Task.CompletedTask;
    }

    sealed class NoVoice : ISystemVoice
    {
        public int Calls;
        public Task<(byte[] pcm, int rate)?> Speak(string text, string language) { Calls++; return Task.FromResult<(byte[], int)?>((new byte[480], 16000)); }
        public bool Has(string language) => true;
    }

    public static void ParsesMingVoiceStream()
    {
        var pcm = LingClient.SpeechChunk("data:{\"type\":\"speech.audio.delta\",\"audio\":\"AQIDBA==\"}", out var done);
        Check(!done && pcm is { Length: 4 } && pcm[3] == 4, "a delta carries its PCM");
        LingClient.SpeechChunk("data:{\"type\":\"speech.audio.done\"}", out done);
        Check(done, "done ends the stream");
        Check(LingClient.SpeechChunk(": keep-alive", out _) is null && LingClient.SpeechChunk("data:{oops", out _) is null, "noise is skipped");
    }

    public static void PicksTheRoomsLanguage()
    {
        Equal("en", SpeakEngine.TargetFor("room", "en", "zh-CN"), "the language the other side speaks");
        Equal("en", SpeakEngine.TargetFor("room", null, "zh-CN"), "English before anyone spoke");
        Equal("en", SpeakEngine.TargetFor("room", "zh-CN", "zh-CN"), "never my own language");
        Equal("zh-CN", SpeakEngine.TargetFor("room", "en", "en"), "an English speaker in an English room gets Chinese");
        Equal("ja", SpeakEngine.TargetFor("ja", "en", "zh-CN"), "a chosen language wins");
    }

    public static void ChecksTheVirtualCablePackage()
    {
        Check(!VirtualCable.Verify("not the package"u8.ToArray()), "anything else is refused");
        Equal(64, VirtualCable.PackageSha256.Length, "a full SHA-256 is pinned");
    }

    static SpeakEngine Speaker(LingClient ling, NoVoice voice, AppSettings? settings = null) =>
        new(ling, new Translator(ling, new Fake(_ => new HttpResponseMessage(HttpStatusCode.ServiceUnavailable))), new SessionStore(), settings ?? new AppSettings(), () => "en", () => null, voice);

    public static async Task SpeaksTheTranslationNeverTheOriginal()
    {
        var old = LingClient.Spacing;
        LingClient.Spacing = 0.01;
        try
        {
            // Ming hears and translates; Ming's voice streams two chunks.
            var spoken = new List<string>();
            var fake = new Fake(body =>
            {
                if (body.Contains(LingClient.AudioModel)) return Reply("LANG: zh-CN\nORIGINAL: 我们周三能测完吗？\nTRANSLATION: Can we finish testing by Wednesday?");
                if (body.Contains(LingClient.VoiceModel))
                {
                    lock (spoken) spoken.Add(JsonNode.Parse(body)!["input"]!.GetValue<string>());
                    return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("data:{\"type\":\"speech.audio.delta\",\"audio\":\"AAABAA==\"}\n\ndata:{\"type\":\"speech.audio.delta\",\"audio\":\"AgADAA==\"}\n\ndata:{\"type\":\"speech.audio.done\"}\n\n") };
                }
                return Reply("x");
            });
            var voice = new NoVoice();
            var sink = new Sink();
            var engine = Speaker(Client(fake), voice, new AppSettings { SpeakFrom = "zh-CN" });
            var heard = await engine.Speak(Wav.Bytes(Tone(1)), sink);
            Equal("Can we finish testing by Wednesday?", heard, "the room hears the translation");
            Equal("Can we finish testing by Wednesday?", spoken.Single(), "and only it is voiced");
            Check(sink.Rate == 24000 && sink.Chunks.Count == 2, "Ming's 24 kHz stream reaches the virtual mic");
            Equal("ming", engine.LastVoice, "voiced by Ming");

            // No translation (Ming echoes the original, Ling and Google fail): nothing reaches the room.
            var echo = new Fake(body => body.Contains(LingClient.AudioModel)
                ? Reply("LANG: zh-CN\nORIGINAL: 我们周三能测完吗？\nTRANSLATION: 我们周三能测完吗？")
                : new HttpResponseMessage(HttpStatusCode.InternalServerError));
            var quiet = new Sink();
            var voice2 = new NoVoice();
            var e2 = Speaker(Client(echo), voice2, new AppSettings { SpeakFrom = "zh-CN" });
            Check(await e2.Speak(Wav.Bytes(Tone(1)), quiet) is null, "no translation, nothing said");
            Check(quiet.Chunks.Count == 0 && voice2.Calls == 0 && e2.State == SpeakEngine.Phase.Failed, "and no voice at all");
        }
        finally { LingClient.Spacing = old; }
    }

    public static async Task WhatISayGoesAheadOfTheMeeting()
    {
        var old = LingClient.Spacing;
        LingClient.Spacing = 0.2;
        try
        {
            var fake = new Fake(body => body.Contains(LingClient.AudioModel)
                ? Reply("LANG: zh-CN\nORIGINAL: 好的\nTRANSLATION: OK")
                : body.Contains(LingClient.VoiceModel) ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("data:{\"type\":\"speech.audio.done\"}\n\n") } : Reply("ok"));
            var ling = Client(fake);
            var first = ling.Chat("meeting 1", "i", Priority.Translate);
            await Task.Delay(20);
            var queued = ling.Chat("meeting 2", "i", Priority.Translate);
            await Task.Delay(20);
            var said = Speaker(ling, new NoVoice(), new AppSettings { SpeakFrom = "zh-CN" }).Speak(Wav.Bytes(Tone(1)), new Sink());
            await Task.WhenAll(first, queued, (Task)said);
            var order = fake.Calls.Select(c => c.body.Contains(LingClient.AudioModel) ? "hear" : c.body.Contains("meeting 2") ? "meeting 2" : c.body.Contains("meeting 1") ? "meeting 1" : "other").ToList();
            Equal("meeting 1,hear,meeting 2", string.Join(",", order.Where(o => o != "other")), "my words jump the queue");
        }
        finally { LingClient.Spacing = old; }
    }

    public static async Task ListenEngineEndToEndWithAFakeMing()
    {
        // Two stretches of "speech", told apart by length (1 s, then 1.6 s); the fake Ming
        // answers the first one slower, and lines still come out in order.
        var fake = new Fake(body =>
        {
            if (body.Contains("Ming-3.0-audio-flash"))
            {
                var url = JsonNode.Parse(body)!["messages"]![1]!["content"]![0]!["audio_url"]!["url"]!.GetValue<string>();
                bool first = url.Length < 60_000; // base64 of ~1.3 s at 32 kB/s, with lead-in and tail
                if (first) Thread.Sleep(400);
                return Reply(first ? "LANG: en\nORIGINAL: First one.\nTRANSLATION: 第一句。" : "LANG: en\nORIGINAL: Second one.\nTRANSLATION: 第二句。");
            }
            return Reply("{}");
        });
        var old = LingClient.Spacing;
        LingClient.Spacing = 0.05;
        try
        {
            var ling = Client(fake);
            var store = new SessionStore();
            var notes = new NotesEngine(ling, store);
            var engine = new ListenEngine(ling, new Translator(ling), store, notes, new AppSettings { Target = "zh-CN" });
            var path = Path.Combine(Path.GetTempPath(), $"cicada-e2e-{Environment.ProcessId}.wav");
            File.WriteAllBytes(path, Wav.Bytes([.. Tone(1), .. Silence(1), .. Tone(1.6), .. Silence(1)]));
            var src = new FileAudioSource(path, speed: 0);
            var ended = new TaskCompletionSource();
            src.Ended += _ => ended.TrySetResult();
            engine.Start(src);
            await ended.Task;
            await Task.Delay(100);
            await engine.Stop();
            var s = store.Get(engine.SessionId!)!;
            Equal("First one.|Second one.", string.Join("|", s.Lines.Select(l => l.Src)), "in segment order");
            Equal("第一句。", s.Lines[0].Dst, "translation from the same call");
            Equal("h1-1", s.Lines[0].Id, "Mac-style ids");
            Check(s.EndedAt is not null, "ended");
            File.Delete(path);
        }
        finally { LingClient.Spacing = old; }
    }

    // MARK: Updates (the Mac's UpdateCheckerTests)

    static string Rel(string tag, params string[] assets) =>
        $$"""{"tag_name":"{{tag}}","html_url":"https://example.com/{{tag}}","assets":[{{string.Join(",", assets.Select(a => $$"""{"name":"{{a}}","browser_download_url":"https://example.com/{{a}}","size":1048576}"""))}}]}""";

    public static void UpdateVersionsCompareByNumber()
    {
        Check(UpdateChecker.IsNewer("2.10.0", "2.9.1"), "2.10 > 2.9");
        Check(UpdateChecker.IsNewer("1.4.1", "1.4"), "1.4.1 > 1.4");
        Check(!UpdateChecker.IsNewer("1.4.0", "1.4"), "1.4.0 = 1.4");
        Check(!UpdateChecker.IsNewer("1.3.9", "1.4.0"), "older");
    }

    public static void UpdateNotifiesOncePerVersionWhenIdle()
    {
        Check(UpdateChecker.ShouldNotify("1.1.0", null, false), "first time");
        Check(UpdateChecker.ShouldNotify("1.2.0", "1.1.0", false), "a newer version");
        Check(!UpdateChecker.ShouldNotify("1.1.0", "1.1.0", false), "already told");
        Check(!UpdateChecker.ShouldNotify("1.1.0", null, true), "held while listening");
        Equal("ab12", UpdateChecker.ChecksumFor("ff00  Cicada-1.1.0-Windows-x64.zip\nAB12 *Cicada-Setup.exe\n", "Cicada-Setup.exe"), "sha256sum line");
        Equal(null, UpdateChecker.ChecksumFor("ff00  Cicada-Setup-arm64.exe", "Cicada-Setup.exe"), "other file");
    }

    /// The in-app download: the installer is kept only when it matches checksums.txt.
    public static async Task UpdateDownloadChecksTheInstaller()
    {
        var dir = Directory.CreateTempSubdirectory("cicada-upd-").FullName;
        var exe = Path.Combine(dir, "Cicada-Setup.exe");
        File.WriteAllText(exe, "installer");
        var sha = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(exe)));
        File.WriteAllText(Path.Combine(dir, "checksums.txt"), $"{sha}  Cicada-Setup.exe\n");
        File.WriteAllText(Path.Combine(dir, "bad.txt"), "0000  Cicada-Setup.exe\n");
        var checker = new UpdateChecker(null, _ => { });
        var u = new UpdateChecker.Update("1.1.0", "https://example.com", null, 9, new Uri(exe).AbsoluteUri, new Uri(Path.Combine(dir, "checksums.txt")).AbsoluteUri);
        var got = await checker.Download(u);
        Equal("installer", File.ReadAllText(got), "downloaded copy");
        Check(got != exe && Path.GetFileName(got) == "Cicada-Setup.exe", "into its own folder, same name");
        try { await checker.Download(u with { Checksums = new Uri(Path.Combine(dir, "bad.txt")).AbsoluteUri }); throw new Exception("bad checksum accepted"); }
        catch (UpdateChecker.Failure f) { Equal("下载的文件校验不通过", f.Key, "bad checksum refused"); }
        try { await checker.Download(u with { Setup = null }); throw new Exception("zip-only accepted"); }
        catch (UpdateChecker.Failure f) { Equal("这个版本没有可安装的文件", f.Key, "nothing to install"); }
        UpdateChecker.CleanDownloads(Path.GetDirectoryName(Path.GetDirectoryName(got)));
        Check(!File.Exists(got), "left-over installer removed");
    }

    public static void UpdateSkipsReleasesWithoutAWindowsZip()
    {
        var list = UpdateChecker.Decode($"[{Rel("v1.6.0", "Cicada-1.6.0-macOS-AppleSilicon.zip")},{Rel("v1.5.0", "Cicada-1.5.0-Windows-x64.zip", "Cicada-1.5.0-Windows-ARM64.zip")}]")!;
        var u = UpdateChecker.NewestWindows(list, "x64")!;
        Equal("1.5.0", u.Version, "newest with a Windows zip");
        Equal("https://example.com/Cicada-1.5.0-Windows-x64.zip", u.Zip, "this PC's zip");
        Equal(1048576L, u.Size, "size");
        Equal("https://example.com/Cicada-1.5.0-Windows-ARM64.zip", UpdateChecker.NewestWindows(list, "ARM64")!.Zip, "ARM zip");
    }

    public static void UpdateOnArmFallsBackToX64AndSkipsDrafts()
    {
        var draft = Rel("v2.0.0", "Cicada-2.0.0-Windows-x64.zip").Replace("\"tag_name\"", "\"draft\":true,\"tag_name\"");
        var list = UpdateChecker.Decode($"[{draft},{Rel("v1.5.0", "Cicada-1.5.0-Windows-x64.zip")}]")!;
        var u = UpdateChecker.NewestWindows(list, "ARM64")!;
        Equal("1.5.0", u.Version, "draft skipped");
        Equal("https://example.com/Cicada-1.5.0-Windows-x64.zip", u.Zip, "x64 on ARM");
        Equal(1, UpdateChecker.Decode(Rel("v1.5.0"))!.Count, "a single release");
        Equal(null, UpdateChecker.Decode("{\"message\":\"Not Found\"}"), "GitHub's 404");
        Equal(null, UpdateChecker.Decode("<html>"), "not JSON");
        // A release with the installer: it's what to download, on each architecture.
        var withSetup = UpdateChecker.Decode("""
            [{"tag_name":"v1.6.0","html_url":"https://example.com/r","assets":[
              {"name":"Cicada-1.6.0-Windows-x64.zip","browser_download_url":"https://example.com/z","size":5},
              {"name":"Cicada-Setup.exe","browser_download_url":"https://example.com/setup","size":7},
              {"name":"Cicada-Setup-arm64.exe","browser_download_url":"https://example.com/setup-arm","size":8}]},
             {"tag_name":"v1.7.0","html_url":"https://example.com/r2","assets":[
              {"name":"Cicada-Setup.exe","browser_download_url":"https://example.com/setup2","size":9}]}]
            """)!;
        var x = UpdateChecker.NewestWindows(withSetup, "x64")!;
        Equal("1.7.0", x.Version, "a release with only the installer counts");
        Equal("https://example.com/setup2", x.Download, "the installer is the download");
        var older = UpdateChecker.NewestWindows(withSetup.Take(1), "ARM64")!;
        Equal("https://example.com/setup-arm", older.Download, "ARM's installer");
        Equal(8L, older.Size, "its size");
    }

    public static void UpdateDueAfterTheAge()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_000_000);
        Check(UpdateChecker.Due(null, now, UpdateChecker.Every), "never checked");
        Check(!UpdateChecker.Due(now.AddHours(-1), now, UpdateChecker.Every), "an hour ago");
        Check(UpdateChecker.Due(now.AddHours(-4), now, UpdateChecker.Every), "4 hours ago");
        Check(UpdateChecker.Due(now.AddHours(2), now, UpdateChecker.Every), "clock set back");
    }

    public static async Task UpdateCheckReadsAFeedFile()
    {
        var file = Path.Combine(Path.GetTempPath(), $"cicada-feed-{Environment.ProcessId}.json");
        File.WriteAllText(file, $"[{Rel("v9.0.0", "Cicada-9.0.0-Windows-x64.zip", "Cicada-9.0.0-Windows-ARM64.zip")}]");
        DateTimeOffset? saved = null;
        var c = new UpdateChecker(null, at => saved = at) { Feed = file, Current = "1.0.0" };
        try
        {
            Check(await c.Check(), "reached");
            Equal("9.0.0", c.Available?.Version, "found");
            Check(saved is not null && c.LastChecked == saved, "remembered");
            c.Current = "9.0.0";
            await c.Check();
            Equal(null, c.Available, "up to date");
            c.Feed = file + ".missing";
            Check(!await c.Check(), "unreachable");
        }
        finally { File.Delete(file); }
    }
}
