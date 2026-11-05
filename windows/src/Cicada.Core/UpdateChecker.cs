using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Cicada;

/// Checks GitHub Releases for a Windows build newer than the running one, as the Mac's
/// UpdateChecker: at launch, then whenever the last answer is 4 hours old (a 15-minute tick, so a
/// laptop that sleeps a lot still checks), and when the tray panel opens once it is an hour old.
/// Failures (offline, rate-limited, the repository not public: 404) are silent. This only finds
/// the update; the app offers Cicada-Setup.exe for download, which upgrades the installed copy
/// when opened (older releases only have the zip).
public sealed class UpdateChecker
{
    /// `Setup` is this PC's Cicada-Setup exe when the release has one; `Size` is the download's;
    /// `Checksums` the release's checksums.txt, which the in-app download is checked against.
    public sealed record Update(string Version, string Page, string? Zip, long Size, string? Setup = null, string? Checksums = null)
    {
        public string? Download => Setup ?? Zip;
    }

    public static readonly TimeSpan Every = TimeSpan.FromHours(4);
    public static readonly TimeSpan Stale = TimeSpan.FromHours(1);

    /// `CICADA_UPDATE_FEED` (or the `updatefeed` debug command) points at another release JSON,
    /// a list or a single release; a file path or file:// URL works, for testing.
    /// The list, not `releases/latest`: a release that ships only the Mac, Android or Linux has no
    /// Windows zip, so the newest Windows release may be further down.
    public string Feed { get; set; } = Environment.GetEnvironmentVariable("CICADA_UPDATE_FEED") is { Length: > 0 } f
        ? f : "https://api.github.com/repos/wquguru/cicada/releases?per_page=20";

    /// The running version, three parts ("1.4.0"), from VERSION via Directory.Build.props.
    public string Current { get; set; } = "0";

    /// The newer release, or null (none, or not checked yet).
    public Update? Available { get; private set; }
    /// When the feed last answered; kept in settings across launches.
    public DateTimeOffset? LastChecked { get; private set; }
    public event Action? Changed;

    readonly HttpClient http;
    readonly Action<DateTimeOffset> remember;
    Timer? timer;
    int checking;

    public UpdateChecker(DateTimeOffset? lastChecked, Action<DateTimeOffset> remember, HttpMessageHandler? handler = null)
    {
        LastChecked = lastChecked;
        this.remember = remember;
        http = handler is null ? new HttpClient() : new HttpClient(handler);
        http.Timeout = TimeSpan.FromSeconds(20);
        // GitHub's API refuses requests without a User-Agent.
        http.DefaultRequestHeaders.UserAgent.ParseAdd("Cicada-Windows");
        http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
    }

    public void Start()
    {
        _ = Check();
        timer = new Timer(_ => _ = CheckIfDue(Every), null, TimeSpan.FromMinutes(15), TimeSpan.FromMinutes(15));
    }

    public Task CheckIfDue(TimeSpan age) => Due(LastChecked, DateTimeOffset.UtcNow, age) ? Check() : Task.CompletedTask;

    public static bool Due(DateTimeOffset? last, DateTimeOffset now, TimeSpan age) =>
        // A clock set back leaves `last` in the future: check rather than wait for it.
        last is not { } l || now - l >= age || l > now;

    /// False when the feed couldn't be reached or answered with something unexpected.
    public async Task<bool> Check()
    {
        if (Interlocked.Exchange(ref checking, 1) == 1) return true;
        try
        {
            var text = await Read(Feed);
            if (Decode(text) is not { } releases) { Log.Debug("update: feed unreadable"); return false; }
            var newest = NewestWindows(releases, Arch);
            LastChecked = DateTimeOffset.UtcNow;
            remember(LastChecked.Value);
            Available = newest is not null && IsNewer(newest.Version, Current) ? newest : null;
            Log.Debug($"update: checked, latest Windows {newest?.Version ?? "none"}, running {Current}");
            Changed?.Invoke();
            return true;
        }
        catch (Exception e) { Log.Debug($"update: check failed {e.GetType().Name}"); return false; }
        finally { Volatile.Write(ref checking, 0); }
    }

    async Task<string> Read(string feed)
    {
        if (Uri.TryCreate(feed, UriKind.Absolute, out var uri) && uri.IsFile) return await File.ReadAllTextAsync(uri.LocalPath);
        if (!feed.Contains("://")) return await File.ReadAllTextAsync(feed);
        using var r = await http.GetAsync(feed);
        r.EnsureSuccessStatusCode();
        return await r.Content.ReadAsStringAsync();
    }

    /// The zip this PC should run: ARM64 on an ARM PC (even when this copy is the emulated x64 one).
    public static string Arch => RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "ARM64" : "x64";

    public static List<Release>? Decode(string text)
    {
        try
        {
            using var doc = JsonDocument.Parse(text);
            return doc.RootElement.ValueKind switch
            {
                JsonValueKind.Array => doc.RootElement.Deserialize<List<Release>>(),
                JsonValueKind.Object => doc.RootElement.Deserialize<Release>() is { TagName.Length: > 0 } one ? [one] : null,
                _ => null,
            };
        }
        catch (JsonException) { return null; }
    }

    /// The newest published release with a Windows build (installer or zip). A release without one
    /// only carries other platforms (Windows had no change), so it is skipped. On ARM, an x64-only
    /// release still counts.
    public static Update? NewestWindows(IEnumerable<Release> releases, string arch)
    {
        Update? best = null;
        foreach (var r in releases)
        {
            if (r.Draft || r.Prerelease || r.Assets is null) continue;
            var zip = r.Assets.FirstOrDefault(a => IsZip(a.Name, arch)) ?? (arch == "x64" ? null : r.Assets.FirstOrDefault(a => IsZip(a.Name, "x64")));
            var setup = r.Assets.FirstOrDefault(a => a.Name == SetupName(arch)) ?? (arch == "x64" ? null : r.Assets.FirstOrDefault(a => a.Name == SetupName("x64")));
            if (zip is null && setup is null) continue;
            var sums = r.Assets.FirstOrDefault(a => a.Name == "checksums.txt");
            var u = new Update(r.TagName.TrimStart('v'), r.HtmlUrl, zip?.Url, (setup ?? zip)!.Size, setup?.Url, sums?.Url);
            if (best is null || IsNewer(u.Version, best.Version)) best = u;
        }
        return best;
        static bool IsZip(string name, string arch) => name.StartsWith("Cicada-") && name.EndsWith($"-Windows-{arch}.zip");
    }

    /// The installer's release asset: no version in the name, so the site's link never goes stale.
    public static string SetupName(string arch) => arch == "ARM64" ? "Cicada-Setup-arm64.exe" : "Cicada-Setup.exe";

    /// One notification per version (the version last told is kept in settings), and none while
    /// listening: the next stop tells. Full screen and screen sharing are Windows' Do Not Disturb.
    public static bool ShouldNotify(string version, string? notified, bool busy) => !busy && version != notified;

    /// The SHA-256 of `name` in a sha256sum listing ("<hex>  <name>", or "<hex> *<name>").
    public static string? ChecksumFor(string text, string name)
    {
        foreach (var line in text.Split('\n'))
        {
            var parts = line.Trim().Split((char[]?)null, 2, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 2 && parts[1].TrimStart('*') == name) return parts[0].ToLowerInvariant();
        }
        return null;
    }

    /// Downloads the release's installer into a fresh temp folder and checks it against
    /// checksums.txt; returns its path. Fetched by the app, not the browser, the file carries no
    /// mark of the web, so SmartScreen doesn't stop the unsigned installer. Throws Failure (a
    /// string key) when there's nothing to install or the file doesn't match.
    public async Task<string> Download(Update u, Action<double>? progress = null)
    {
        if (u.Setup is null || u.Checksums is null) throw new Failure("这个版本没有可安装的文件");
        var name = Path.GetFileName(new Uri(u.Setup).LocalPath);
        var folder = Path.Combine(Path.GetTempPath(), $"CicadaUpdate-{u.Version}-{Guid.NewGuid():N}"[..40]);
        Directory.CreateDirectory(folder);
        var file = Path.Combine(folder, name);
        string? expected;
        try
        {
            expected = ChecksumFor(await Read(u.Checksums), name);
            await Fetch(u.Setup, file, u.Size, progress);
        }
        catch (Exception e) when (e is HttpRequestException or IOException or TaskCanceledException)
        {
            Log.Debug($"update: download failed {e.GetType().Name}");
            throw new Failure("下载失败");
        }
        string got;
        using (var f = File.OpenRead(file)) got = Convert.ToHexStringLower(await SHA256.HashDataAsync(f));
        if (expected is null || got != expected)
        {
            try { Directory.Delete(folder, true); } catch { }
            throw new Failure("下载的文件校验不通过");
        }
        Log.Debug($"update: downloaded {u.Version}, checksum ok");
        return file;
    }

    /// Removes installers left from earlier updates (each ~80 MB). Called at launch: by then the
    /// installer that ran has quit, or it's still letting go and the next launch gets it.
    public static void CleanDownloads(string? temp = null)
    {
        try
        {
            foreach (var d in Directory.GetDirectories(temp ?? Path.GetTempPath(), "CicadaUpdate-*"))
                try { Directory.Delete(d, true); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    async Task Fetch(string url, string to, long expected, Action<double>? progress)
    {
        if (Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.IsFile) { File.Copy(uri.LocalPath, to, true); progress?.Invoke(1); return; }
        using var r = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
        r.EnsureSuccessStatusCode();
        var total = r.Content.Headers.ContentLength ?? expected;
        await using var src = await r.Content.ReadAsStreamAsync();
        await using var dst = File.Create(to);
        var buffer = new byte[81920];
        long got = 0; int n, last = -1;
        while ((n = await src.ReadAsync(buffer)) > 0)
        {
            await dst.WriteAsync(buffer.AsMemory(0, n));
            got += n;
            // Whole percents only: each one re-renders the flyout and settings.
            if (total > 0 && (int)(got * 100 / total) is var pct && pct != last) { last = pct; progress?.Invoke(Math.Min(1, (double)got / total)); }
        }
    }

    /// Why installing didn't work: a shared string key, said to the user (the browser fallback opens).
    public sealed class Failure(string key) : Exception(key) { public string Key => Message; }

    /// Dotted numeric versions: "2.10.0" is newer than "2.9.1".
    public static bool IsNewer(string a, string b)
    {
        var x = a.Split('.').Select(p => int.TryParse(p, out var n) ? n : 0).ToArray();
        var y = b.Split('.').Select(p => int.TryParse(p, out var n) ? n : 0).ToArray();
        for (int i = 0; i < Math.Max(x.Length, y.Length); i++)
        {
            int l = i < x.Length ? x[i] : 0, r = i < y.Length ? y[i] : 0;
            if (l != r) return l > r;
        }
        return false;
    }

    public sealed class Release
    {
        [JsonPropertyName("tag_name")] public string TagName { get; set; } = "";
        [JsonPropertyName("html_url")] public string HtmlUrl { get; set; } = "";
        [JsonPropertyName("draft")] public bool Draft { get; set; }
        [JsonPropertyName("prerelease")] public bool Prerelease { get; set; }
        [JsonPropertyName("assets")] public List<Asset>? Assets { get; set; }
    }

    public sealed class Asset
    {
        [JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonPropertyName("browser_download_url")] public string? Url { get; set; }
        [JsonPropertyName("size")] public long Size { get; set; }
    }
}
