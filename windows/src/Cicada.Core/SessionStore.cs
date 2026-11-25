using System.Globalization;
using System.Text;

namespace Cicada;

/// The meeting records: one folder per meeting under Sessions\<yyyyMMdd-HHmmss>\ with
/// session.json, as on the Mac. Saves are debounced by 1.5 s; a meeting with no lines is removed
/// when it ends. Thread-safe; `Changed` fires on whichever thread made the change.
public sealed class SessionStore
{
    readonly object gate = new();
    readonly Dictionary<string, Session> sessions = [];
    readonly HashSet<string> dirty = [];
    Timer? saveTimer;
    public event Action<string>? Changed;
    /// The moment recognised words land in a record: a new line (theirs or mine) or a half sentence
    /// that grew. What 结束会议 counts as someone speaking (MeetingEndWatch.Heard).
    public event Action<string>? Words;
    /// A record was written to disk (存到文件夹 follows its changes); on the saving thread.
    public event Action<string>? Saved;
    /// The app's audio encoder (Media Foundation); null where there is none (the Mac CLI, tests
    /// that don't set one): meetings are then kept without a recording.
    public IAudioFiles? Audio { get; set; }

    public SessionStore() { Load(); }

    static string Folder(string id) => Path.Combine(Paths.Sessions, id);
    static string FileOf(string id) => Path.Combine(Folder(id), "session.json");

    void Load()
    {
        if (!Directory.Exists(Paths.Sessions)) return;
        foreach (var dir in Directory.GetDirectories(Paths.Sessions))
        {
            var file = Path.Combine(dir, "session.json");
            if (!File.Exists(file)) continue;
            try
            {
                if (Json.Read<Session>(File.ReadAllText(file)) is not { } s) continue;
                // The app quit mid-meeting: it ended just after its last line (SessionStore.swift › load).
                s.EndedAt ??= s.Lines.Count > 0 ? s.StartedAt.AddSeconds(s.Lines[^1].T + 5) : s.StartedAt;
                sessions[s.Id] = s;
            }
            catch (Exception e) { Log.Debug($"store: skipped {Path.GetFileName(dir)}: {e.GetType().Name}"); }
        }
    }

    /// Newest first.
    public List<Session> All()
    {
        lock (gate) return sessions.Values.OrderByDescending(s => s.StartedAt).ToList();
    }

    public Session? Get(string id)
    {
        lock (gate) return sessions.GetValueOrDefault(id);
    }

    public Session Begin(DateTimeOffset? at = null)
    {
        var start = at ?? DateTimeOffset.Now;
        var id = start.ToLocalTime().ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
        var s = new Session { Id = id, Title = DefaultTitle(start), StartedAt = start, HasAudio = false };
        lock (gate) sessions[id] = s;
        return s;
    }

    /// The stored default title is always Chinese ("会议 11月1日 14:30"), as on the Mac; the UI
    /// shows DisplayTitle instead.
    public static string DefaultTitle(DateTimeOffset at) =>
        "会议 " + at.ToLocalTime().ToString("M月d日 HH:mm", CultureInfo.InvariantCulture);

    /// The user's own title, else the date and the name the notes gave the meeting, else the
    /// default title in the UI language (Session.displayTitle).
    public static string DisplayTitle(Session s)
    {
        if (s.Renamed ?? !s.Title.StartsWith("会议 ")) return s.Title;
        var local = s.StartedAt.ToLocalTime();
        var ui = Strings.Culture;
        if (string.IsNullOrEmpty(s.Notes?.Title))
            return Strings.L("会议") + " " + local.ToString(Strings.L("M月d日 HH:mm"), ui);
        var date = local.Year == DateTimeOffset.Now.Year ? local.ToString(Strings.L("M月d日"), ui) : local.ToString(Strings.L("yyyy年M月d日"), ui);
        return $"{date} {s.Notes!.Title}";
    }

    public void Append(string id, TranscriptLine line)
    {
        Mutate(id, s => s.Lines.Add(line));
        Words?.Invoke(id);
    }

    public void Replace(string id, TranscriptLine line)
    {
        bool grew = false;
        Mutate(id, s =>
        {
            int i = s.Lines.FindIndex(l => l.Id == line.Id);
            if (i < 0) return;
            grew = line.Src.Length > s.Lines[i].Src.Length; // a half sentence joined, not a retranslation
            // The listening engine keeps its own copy of the line and knows nothing of its fixes
            // (SetFixes): a retranslation or a join keeps them.
            line.Fixes ??= s.Lines[i].Fixes;
            s.Lines[i] = line;
        });
        if (grew) Words?.Invoke(id);
    }

    /// A line's fixes (Correction): what the AI service proposed and the user decided.
    public void SetFixes(string id, string lineId, IReadOnlyList<LineFix> fixes)
    {
        Mutate(id, s =>
        {
            int i = s.Lines.FindIndex(l => l.Id == lineId);
            if (i < 0) return;
            var line = s.Lines[i].Copy();
            line.Fixes = fixes.Count == 0 ? null : [.. fixes];
            s.Lines[i] = line;
        });
    }

    public void SetNotes(string id, MeetingNotes notes) => Mutate(id, s => s.Notes = notes);

    /// Heard through a microphone in the room for some or all of it (SessionStore.swift › markLiveInRoom).
    public void MarkRoom(string id)
    {
        if (Get(id) is { Room: not true }) Mutate(id, s => s.Room = true);
    }

    /// An empty title, or the one shown already, goes back to / stays on the automatic one
    /// (SessionStore.swift › rename): saving the dialog unchanged mustn't freeze the notes' name.
    public void Rename(string id, string title)
    {
        var t = title.Trim();
        if (Get(id) is not { } current || t == DisplayTitle(current)) return;
        if (t.Length == 0) { ResetTitle(id); return; }
        Mutate(id, s => { s.Title = t; s.Renamed = true; });
    }

    /// Back to the default title, so the name the notes give the meeting shows again.
    public void ResetTitle(string id) => Mutate(id, s => { s.Title = DefaultTitle(s.StartedAt); s.Renamed = false; });

    /// The meeting ended (at `endedAt` when it ended by itself a while ago): kept if anything was
    /// said, removed otherwise.
    /// The meeting's recording, if any, is closed by then (ListenEngine.Stop): it is rewrapped into
    /// system.m4a in the background, cut at `endedAt` when the meeting ended by itself a while ago
    /// (its silent tail), as SessionStore.swift › end does.
    public void End(string id, DateTimeOffset? endedAt = null)
    {
        bool empty;
        double? until = null;
        lock (gate)
        {
            if (!sessions.TryGetValue(id, out var s)) return;
            s.EndedAt = endedAt is { } at ? (at > s.StartedAt ? at : s.StartedAt) : DateTimeOffset.Now;
            empty = s.Lines.Count == 0;
            var m4a = Recording.SystemAudio(id);
            s.HasAudio = File.Exists(m4a) || File.Exists(Recording.Partial(m4a));
            if (endedAt is not null) until = s.Duration.TotalSeconds;
        }
        if (empty) { Delete(id); return; }
        MarkDirty(id); Flush();
        _ = Task.Run(() => FinishAudio(id, until));
    }

    /// Recordings a meeting didn't get to close (the app was killed or the PC went off): the
    /// partial file is rewrapped now, as SessionStore.swift › load does. Call once Audio is set.
    public void FinishLeftovers(string? live = null)
    {
        List<string> left;
        lock (gate) left = sessions.Keys.Where(id => id != live && File.Exists(Recording.Partial(Recording.SystemAudio(id)))).ToList();
        foreach (var id in left)
        {
            Mutate(id, s => s.HasAudio = true);
            _ = Task.Run(() => FinishAudio(id, null));
        }
    }

    /// system.aac into system.m4a. A partial file beside an .m4a means the last rewrap was cut
    /// short: it is done again. One that fails leaves the partial file for the next launch.
    void FinishAudio(string id, double? until)
    {
        var m4a = Recording.SystemAudio(id);
        var partial = Recording.Partial(m4a);
        if (Audio is not { } audio || !File.Exists(partial)) return;
        try
        {
            if (File.Exists(m4a)) File.Delete(m4a);
            var started = DateTime.UtcNow;
            if (audio.Rewrap(partial, m4a, until))
            {
                File.Delete(partial);
                Log.Debug($"store: recording {id} finished in {(DateTime.UtcNow - started).TotalMilliseconds:F0} ms");
            }
            else
            {
                try { File.Delete(m4a); } catch { }
                Log.Debug($"store: recording {id} rewrap failed");
            }
        }
        catch (Exception e) { Log.Debug($"store: recording {id} rewrap failed {e.GetType().Name}"); }
        Changed?.Invoke(id);
    }

    public void Delete(string id)
    {
        lock (gate) { sessions.Remove(id); dirty.Remove(id); }
        try { if (Directory.Exists(Folder(id))) Directory.Delete(Folder(id), recursive: true); } catch (Exception e) { Log.Debug($"store: delete failed {e.GetType().Name}"); }
        Changed?.Invoke(id);
    }

    void Mutate(string id, Action<Session> change)
    {
        lock (gate)
        {
            if (!sessions.TryGetValue(id, out var s)) return;
            change(s);
        }
        MarkDirty(id);
        Changed?.Invoke(id);
    }

    void MarkDirty(string id)
    {
        lock (gate)
        {
            dirty.Add(id);
            saveTimer ??= new Timer(_ => Flush(), null, Timeout.Infinite, Timeout.Infinite);
            saveTimer.Change(1500, Timeout.Infinite);
        }
    }

    /// Writes every changed record now (also on quit).
    public void Flush()
    {
        List<(string id, string json)> writes;
        lock (gate)
        {
            writes = dirty.Where(sessions.ContainsKey).Select(id => (id, Json.Write(sessions[id]))).ToList();
            dirty.Clear();
        }
        foreach (var (id, json) in writes)
        {
            try
            {
                Directory.CreateDirectory(Folder(id));
                var tmp = FileOf(id) + ".tmp";
                File.WriteAllText(tmp, json, new UTF8Encoding(false));
                File.Move(tmp, FileOf(id), overwrite: true);
                Saved?.Invoke(id);
            }
            catch (Exception e) { Log.Debug($"store: save failed {e.GetType().Name}"); }
        }
    }

    // MARK: Export

    /// The record as Markdown: notes, then the bilingual transcript.
    public static string Markdown(Session s)
    {
        var b = new StringBuilder();
        b.AppendLine($"# {DisplayTitle(s)}").AppendLine();
        b.AppendLine(s.StartedAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture)).AppendLine();
        if (s.Notes is { IsEmpty: false } n) b.AppendLine($"## {Strings.L("纪要")}").AppendLine().Append(NotesBody(n));
        b.AppendLine($"## {Strings.L("文字记录")}").AppendLine();
        var numbers = SpeakerLabels.Voices ? SpeakerLabels.Numbers(s.Lines) : [];
        var names = SpeakerLabels.Names(s);
        foreach (var l in s.Lines.OrderBy(x => x.T))
        {
            // Your own lines (the talk key) say so: what the meeting heard was their translation (同传).
            var who = l.Speaker == "me" ? Strings.L("你 · 同传") : numbers.TryGetValue(l.Id, out var num) ? names.GetValueOrDefault(num) ?? Strings.LF("说话人 %lld", num) : null;
            b.AppendLine($"**{Languages.Clock(l.T)}**{(who is null ? "" : $" {who}：")} {l.Shown}  ");
            if (!string.IsNullOrEmpty(l.Dst) && l.Dst != l.Src && l.Dst != l.Shown) b.AppendLine($"{l.Dst}");
            b.AppendLine();
        }
        return b.ToString();
    }

    /// The notes alone (复制纪要): title, summary, topics, conclusions, to-dos.
    public static string NotesMarkdown(Session s) =>
        s.Notes is { IsEmpty: false } n ? $"# {DisplayTitle(s)}\n\n" + NotesBody(n) : "";

    static string NotesBody(MeetingNotes n)
    {
        var b = new StringBuilder();
        b.AppendLine(n.Summary).AppendLine();
        foreach (var t in n.Topics)
        {
            b.AppendLine($"### {Languages.Clock(t.Start)} {t.Title}").AppendLine();
            if (t.Summary.Length > 0) b.AppendLine(t.Summary).AppendLine();
            foreach (var p in t.Points) b.AppendLine($"- {p}");
            b.AppendLine();
        }
        if (n.Conclusions.Count > 0)
        {
            b.AppendLine($"### {Strings.L("结论")}").AppendLine();
            foreach (var c in n.Conclusions) b.AppendLine($"- {c.Text}");
            b.AppendLine();
        }
        if (n.Todos.Count > 0)
        {
            b.AppendLine($"### {Strings.L("待办")}").AppendLine();
            foreach (var t in n.Todos) b.AppendLine($"- [ ] {t.WithOwner}");
            b.AppendLine();
        }
        return b.ToString();
    }
}
