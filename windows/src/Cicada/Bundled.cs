using System.Text;

namespace Cicada.App;

/// Files carried inside Cicada.exe (EmbeddedResource in Cicada.csproj), so the exe alone is the
/// whole app: Cicada-Setup.exe is downloaded as one file and installs by copying itself.
static class Bundled
{
    static readonly System.Reflection.Assembly Self = typeof(Bundled).Assembly;
    // MSBuild writes %(RecursiveDir) with the build machine's separator: "en.lproj\" on Windows CI.
    static readonly Dictionary<string, string> Names = Self.GetManifestResourceNames().ToDictionary(n => n.Replace('\\', '/'), n => n);

    /// "en.lproj/Localizable.strings" and the like, for Strings.Load.
    public static string? Strings(string path)
    {
        if (!Names.TryGetValue("strings/" + path, out var name) || Self.GetManifestResourceStream(name) is not { } s) return null;
        using var reader = new StreamReader(s, Encoding.UTF8);
        return reader.ReadToEnd();
    }

    /// The onboarding sample as a file (SoundPlayer and FileAudioSource both want a path), written
    /// to the temp folder the first time it's asked for.
    public static string? Sample()
    {
        var path = Path.Combine(Path.GetTempPath(), $"cicada-sample-{Controller.Version}.wav");
        try
        {
            if (File.Exists(path)) return path;
            using var s = Self.GetManifestResourceStream("sample.wav");
            if (s is null) return null;
            var part = path + ".part";
            using (var f = File.Create(part)) s.CopyTo(f);
            File.Move(part, path, overwrite: true);
            return path;
        }
        catch (Exception e) { Log.Debug($"sample: unavailable {e.GetType().Name}"); return null; }
    }
}
