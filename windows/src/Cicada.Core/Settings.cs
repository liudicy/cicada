using System.Globalization;
using System.Text.Json.Serialization;

namespace Cicada;

/// The app's settings, in settings.json beside the records (never an AI key: each has its own file).
public sealed class AppSettings
{
    /// What subtitles translate into; "system" follows the Windows display language.
    [JsonPropertyName("target")] public string Target { get; set; } = "system";
    /// 纪要语言: the notes' language code; "system" is the same as the subtitles'.
    [JsonPropertyName("notesLanguage")] public string NotesLanguage { get; set; } = "system";
    /// Ling's text model (the other services' are in AiModels).
    [JsonPropertyName("model")] public string Model { get; set; } = LingClient.DefaultModel;
    /// AI 服务 (the Mac's keys): the service, and per service the models chosen over its recommended
    /// ones. aiHearModels is the ports' own: what hears the audio (Ming on Ling).
    [JsonPropertyName("aiProvider")] public string AiProvider { get; set; } = "ling";
    [JsonPropertyName("aiModels")] public Dictionary<string, string> AiModels { get; set; } = [];
    [JsonPropertyName("aiHearModels")] public Dictionary<string, string> AiHearModels { get; set; } = [];
    [JsonPropertyName("aiVoiceModels")] public Dictionary<string, string> AiVoiceModels { get; set; } = [];
    [JsonPropertyName("aiCustomBase")] public string AiCustomBase { get; set; } = "";
    [JsonPropertyName("aiCustomVoiceBase")] public string AiCustomVoiceBase { get; set; } = "";
    [JsonPropertyName("aiCustomVoice")] public string AiCustomVoice { get; set; } = "";
    /// A custom service's hear model at its own address (the Mac's key); empty: the same one.
    [JsonPropertyName("aiCustomHearBase")] public string AiCustomHearBase { get; set; } = "";
    /// 语音和文字只发给你的服务 (the Mac's key): with the custom service, Google Translate is never
    /// asked. Kept when another service is picked, but only acts on the custom one (GoogleOff).
    [JsonPropertyName("aiCustomOnly")] public bool AiCustomOnly { get; set; }
    /// A custom service's notes (the Mac's keys): 另一个服务 (its own address, empty: the same one, and
    /// its own key in the `custom-notes` key file). Off keeps the address, so switching back and
    /// forth loses nothing. The notes model is AiModels["custom.notes"] (empty: the translation model).
    [JsonPropertyName("aiCustomNotesOwn")] public bool AiCustomNotesOwn { get; set; }
    [JsonPropertyName("aiCustomNotesBase")] public string AiCustomNotesBase { get; set; } = "";
    [JsonIgnore] public bool GoogleOff => AiProvider == "custom" && AiCustomOnly;
    /// 打开麦克风: "both" while the mic is on, else "system" (the Mac's listenSource values; "room",
    /// the mic alone, is the Mac's on macOS 14/15). Not saved: every launch starts with the mic off.
    [JsonIgnore] public string ListenSourceValue { get; set; } = ListenSource.System;
    [JsonIgnore] public string Listens => ListenSource.Parse(ListenSourceValue);
    [JsonIgnore] public bool ListensToRoom => Listens == ListenSource.Room;
    [JsonIgnore] public bool HearsBoth => Listens == ListenSource.Both;
    /// "notes" (the notes window, default) or "subtitles" (the subtitle bar).
    [JsonPropertyName("view")] public string View { get; set; } = "notes";
    /// Whether 知了还在任务栏右下角 was shown, after the first × on a window.
    [JsonPropertyName("trayHintShown")] public bool TrayHintShown { get; set; }
    /// 共享屏幕时让对方看到: let the notes window and subtitles show up in screen sharing.
    [JsonPropertyName("showInCapture")] public bool ShowInCapture { get; set; }
    [JsonPropertyName("onboarded")] public bool Onboarded { get; set; }
    /// The setup checklist (主窗口 › 还差几步): the onboarding heard the PC's sound / played the sample.
    [JsonPropertyName("heardSystemAudio")] public bool HeardSystemAudio { get; set; }
    [JsonPropertyName("sampleSeen")] public bool SampleSeen { get; set; }
    /// The UI language: "system", "zh-Hans", "en", "ja" or "ko".
    [JsonPropertyName("uiLanguage")] public string UiLanguage { get; set; } = "system";
    /// 字幕文字大小, in px.
    [JsonPropertyName("subtitleSize")] public int SubtitleSize { get; set; } = 24;
    /// 保存会议录音 (the Mac's key): keep what was heard as system.m4a in the meeting's folder.
    [JsonPropertyName("recordAudio")] public bool RecordAudio { get; set; } = true;
    /// 存到文件夹 (the Mac's keys): settled meetings are also written as Markdown into exportFolder
    /// (a path; empty until one is chosen). FolderExport.cs.
    [JsonPropertyName("exportOn")] public bool ExportOn { get; set; }
    [JsonPropertyName("exportFolder")] public string ExportFolder { get; set; } = "";
    /// 说话人识别: tell the other side's voices apart (on by default, as on the Mac).
    [JsonPropertyName("speakerVoices")] public bool SpeakerVoices { get; set; } = true;
    /// 会中改正听错的词 (the Mac's key): finished sentences carry the word list to the AI service,
    /// which points out misheard words (Correction). On by default; does nothing without a service.
    [JsonPropertyName("fixMisheard")] public bool FixMisheard { get; set; } = true;
    /// 没见过的名字和专称先问我: a new name is asked about once instead of left as heard.
    [JsonPropertyName("askNames")] public bool AskNames { get; set; } = true;
    /// 同声传译: hold the talk key to speak into the meeting in its language.
    [JsonPropertyName("speak")] public bool Speak { get; set; }
    /// The talk key, a TalkKey name ("rcontrol", "f13"…): not every keyboard has right Ctrl.
    [JsonPropertyName("talkKey")] public string TalkKey { get; set; } = Cicada.TalkKey.Default;
    /// 我说的语言: "system" or a source code.
    [JsonPropertyName("speakFrom")] public string SpeakFrom { get; set; } = "system";
    /// 对方听到的语言: "room" (what the other side speaks) or a target code.
    [JsonPropertyName("speakTo")] public string SpeakTo { get; set; } = "room";
    /// The voice for each language the room hears ("en" → "ming:US_Emma", or "system").
    [JsonPropertyName("speakVoices")] public Dictionary<string, string> SpeakVoices { get; set; } = [];
    /// The one-time "知了还在听" notice after the panel is first collapsed while listening.
    [JsonPropertyName("toldStillListening")] public bool ToldStillListening { get; set; }
    /// 结束会议 (MeetingEnd.cs), the Mac's keys: end when the meeting app hangs up; when nobody
    /// speaks, "prompt" (count down, then end), "end" or "off", after silenceMinutes.
    [JsonPropertyName("endWithApp")] public bool EndWithApp { get; set; } = true;
    [JsonPropertyName("silenceEnd")] public string SilenceEnd { get; set; } = "prompt";
    [JsonPropertyName("silenceMinutes")] public double SilenceMinutes { get; set; } = 10;
    /// When GitHub Releases last answered an update check (UpdateChecker).
    [JsonPropertyName("updateLastChecked")] public DateTimeOffset? UpdateLastChecked { get; set; }
    /// The version the update notification was last shown for: one per version.
    [JsonPropertyName("updateNotified")] public string? UpdateNotified { get; set; }
    /// The startup notification that VB-Cable holds the speaker was shown (CableDefaults.ShouldNotify);
    /// cleared when a real speaker is back.
    [JsonPropertyName("cableSpeakerNotified")] public bool CableSpeakerNotified { get; set; }

    [JsonIgnore] public string TargetCode => Target == "system" ? Languages.FromSystem(CultureInfo.CurrentUICulture.Name) : Target;
    /// The AI service in use, its address and models (what LingClient calls with).
    public AIConfig AIConfig() => Cicada.AIConfig.From(this);
    [JsonIgnore] public string NotesCode => NotesLanguage == "system" ? TargetCode : NotesLanguage;

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(Paths.Settings) && Json.Read<AppSettings>(File.ReadAllText(Paths.Settings)) is { } s) return s;
        }
        catch (Exception e) { Log.Debug($"settings: unreadable, defaults used ({e.GetType().Name})"); }
        return new AppSettings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Paths.Root);
            File.WriteAllText(Paths.Settings, Json.Write(this));
        }
        catch (Exception e) { Log.Debug($"settings: save failed {e.GetType().Name}"); }
    }
}
