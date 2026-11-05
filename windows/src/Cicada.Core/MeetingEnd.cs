namespace Cicada;

/// When a meeting is over (MeetingEnd.swift), so one nobody ended doesn't run on for hours and pull
/// the next video or meeting into its notes.
///
/// Two signals, as on the Mac. The main one: a meeting app (Zoom, 腾讯会议…) that was reading a
/// microphone during this meeting lets go of it, which is what hanging up looks like from outside; a
/// short grace covers switching devices. The fallback, for meetings in a browser or in the room:
/// nothing was recognised for a while ("nothing recognised" counts words, not sound, so background
/// music doesn't keep a meeting alive). While a meeting app is still in a call, silence doesn't
/// count. Pure: the controller ticks it with the clock and `MicUse.Calls`.
public sealed class MeetingEndWatch
{
    public enum Silence { Prompt, End, Off }

    public sealed record Config(bool FollowApps = true, Silence Silence = Silence.Prompt, double SilenceAfter = 600,
                                double Countdown = 60, double AppGrace = 30);

    /// Why the meeting ends: an app hung up (its name), silence, or nobody spoke at all (nothing to
    /// keep, so it just stops, without a countdown).
    public sealed record Reason(string Kind, string Name = "")
    {
        public static readonly Reason SilenceEnd = new("silence");
        public static readonly Reason Nobody = new("nobody");
        public static Reason AppLeft(string name) => new("app", name);
        public override string ToString() => Name.Length > 0 ? $"{Kind}({Name})" : Kind;
    }

    public sealed record Pending(Reason Reason, DateTimeOffset Deadline);

    public Config Settings;
    public Pending? Waiting { get; private set; }
    public DateTimeOffset LastSpeech { get; private set; }
    /// Meeting apps seen in a call during this meeting (id → name).
    public Dictionary<string, string> InCall { get; private set; } = [];

    public MeetingEndWatch(Config config, DateTimeOffset start)
    {
        Settings = config;
        LastSpeech = start;
    }

    /// Words were recognised (theirs or mine): a silence countdown stops. A hang-up doesn't: the
    /// next video would talk over it.
    public void Heard(DateTimeOffset now)
    {
        LastSpeech = now;
        if (Waiting?.Reason.Kind == "silence") Waiting = null;
    }

    /// 继续记录: forget the hang-up and start counting silence again.
    public void KeepGoing(DateTimeOffset now)
    {
        Waiting = null;
        LastSpeech = now;
        InCall = [];
    }

    /// `calls`: meeting apps reading a microphone now. `said`: the meeting has lines. One without
    /// keeps listening for the silence time, then stops quietly. Returns why it ends now, if it does.
    public Reason? Tick(DateTimeOffset now, IReadOnlyDictionary<string, string> calls, bool said)
    {
        var c = Settings;
        bool inACall = c.FollowApps && calls.Count > 0;
        double silent = (now - LastSpeech).TotalSeconds;
        if (!said)
        {
            InCall = c.FollowApps ? new Dictionary<string, string>(calls) : [];
            Waiting = null;
            return c.Silence != Silence.Off && !inACall && silent >= c.SilenceAfter ? Reason.Nobody : null;
        }
        bool appWaiting = Waiting?.Reason.Kind == "app";
        if (c.FollowApps)
        {
            foreach (var (id, name) in calls) InCall[id] = name;
            bool hungUp = InCall.Count > 0 && InCall.Keys.All(k => !calls.ContainsKey(k));
            if (appWaiting && !hungUp) Waiting = null; // rejoined
            if (hungUp && (Waiting is null || Waiting.Reason.Kind == "silence"))
            {
                var name = InCall.OrderBy(p => p.Key, StringComparer.Ordinal).First().Value;
                Waiting = new Pending(Reason.AppLeft(name), now.AddSeconds(c.AppGrace));
            }
        }
        else if (appWaiting) Waiting = null;
        if (Waiting is null && c.Silence != Silence.Off && !inACall && silent >= c.SilenceAfter)
        {
            if (c.Silence == Silence.End) return Reason.SilenceEnd;
            Waiting = new Pending(Reason.SilenceEnd, now.AddSeconds(c.Countdown));
        }
        if ((c.Silence == Silence.Off || inACall) && Waiting?.Reason.Kind == "silence") Waiting = null;
        if (Waiting is { } p && now >= p.Deadline)
        {
            Waiting = null;
            return p.Reason;
        }
        return null;
    }

    public static Silence ParseSilence(string s) => s switch { "end" => Silence.End, "off" => Silence.Off, _ => Silence.Prompt };
}

/// Which meeting apps are reading a microphone, from what Windows records for its privacy settings:
/// under HKCU\…\CapabilityAccessManager\ConsentStore\microphone every app that used the mic has a key
/// (desktop apps under NonPackaged, by their path with `#` for `\`; Store apps by package family)
/// whose LastUsedTimeStop is 0 while it has the mic open. The reading is in the app; this is pure.
public static class MicUse
{
    /// Dedicated meeting apps (lower case program or package family prefix) → the name shown.
    /// Browsers aren't here, as on the Mac: a browser holding a mic isn't necessarily a meeting.
    static readonly (string Key, string Name)[] Apps =
    [
        ("zoom.exe", "Zoom"), ("wemeetapp.exe", "腾讯会议"), ("feishu.exe", "飞书"), ("lark.exe", "Lark"),
        ("dingtalk.exe", "钉钉"), ("teams.exe", "Teams"), ("ms-teams.exe", "Teams"), ("msteams_", "Teams"),
        ("ciscocollabhost.exe", "Webex"), ("webex.exe", "Webex"), ("cisco.webex", "Webex"),
    ];

    /// `entries`: each key's name (a path like "C:#Program Files#Zoom#bin#Zoom.exe" or a package family)
    /// and its LastUsedTimeStop. → {program: name} for the meeting apps using a mic now.
    public static Dictionary<string, string> Calls(IEnumerable<(string Key, long LastUsedTimeStop)> entries)
    {
        var byName = new SortedDictionary<string, string>(StringComparer.Ordinal); // one entry per app
        foreach (var (key, stop) in entries)
        {
            if (stop != 0) continue;
            var program = key.Split('#', '\\').Last().ToLowerInvariant();
            foreach (var (k, name) in Apps)
            {
                if (k.EndsWith('_') ? program.StartsWith(k, StringComparison.Ordinal) : program == k)
                {
                    if (!byName.ContainsKey(name)) byName[name] = k.TrimEnd('_');
                    break;
                }
            }
        }
        return byName.ToDictionary(p => p.Value, p => p.Key);
    }
}
