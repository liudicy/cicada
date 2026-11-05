namespace Cicada;

/// What a launch of the release exe should do. Cicada-Setup.exe is Cicada.exe under another name:
/// a copy that isn't the installed one installs itself into the user's folder (no admin), so
/// autostart, the Start menu and updates always point at one place.
public static class SetupPlan
{
    public enum Step
    {
        /// This is the installed copy (or a dev build): start as usual.
        Run,
        /// Nothing installed: ask, then copy in.
        Install,
        /// An older version is installed: offer to replace it.
        Upgrade,
        /// The same or a newer version is installed: open that one instead (never downgrade).
        Open,
    }

    public static Step Decide(bool dev, string running, string installed, string? installedVersion, string version)
    {
        if (dev || Same(running, installed)) return Step.Run;
        if (installedVersion is null) return Step.Install;
        return UpdateChecker.IsNewer(version, installedVersion) ? Step.Upgrade : Step.Open;
    }

    /// Windows paths: case-insensitive, `..` and `/` resolved.
    public static bool Same(string a, string b)
    {
        try { return string.Equals(Path.GetFullPath(a).TrimEnd('\\', '/'), Path.GetFullPath(b).TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase); }
        catch { return false; }
    }

    /// The Start menu entry is named in the language of the UI at install time, so people find
    /// what they see; the files and paths stay "Cicada" (Chinese names get mangled in downloads).
    public static string ShortcutName(string language) => language == "zh-Hans" ? "知了" : "Cicada";
    /// Every name a shortcut may have had, so a reinstall in another language leaves only one.
    public static readonly string[] ShortcutNames = ["知了", "Cicada"];
    /// Settings › Apps sorts and searches by name: both names, so either language finds it.
    public const string DisplayName = "知了 Cicada";
}
