using System.Globalization;
using System.Text.Json.Serialization;

namespace Cicada;

/// The app's settings, in settings.json beside the records (never the Ling key: that has its own file).
public sealed class AppSettings
{
    /// What subtitles translate into; "system" follows the Windows display language.
    [JsonPropertyName("target")] public string Target { get; set; } = "system";
    /// 纪要语言: the notes' language code; "system" is the same as the subtitles'.
    [JsonPropertyName("notesLanguage")] public string NotesLanguage { get; set; } = "system";
    [JsonPropertyName("model")] public string Model { get; set; } = LingClient.DefaultModel;
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
    /// 说话人识别: tell the other side's voices apart (on by default, as on the Mac).
    [JsonPropertyName("speakerVoices")] public bool SpeakerVoices { get; set; } = true;
    /// 同声传译: hold right Ctrl to speak into the meeting in its language.
    [JsonPropertyName("speak")] public bool Speak { get; set; }
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

    [JsonIgnore] public string TargetCode => Target == "system" ? Languages.FromSystem(CultureInfo.CurrentUICulture.Name) : Target;
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
