using System.Text.Json;
using System.Text.Json.Nodes;

namespace Cicada;

/// Keeps the live meeting's notes up to date: every ~45 s with new speech, one Ling call sends the
/// current notes plus the new lines and gets the whole notes back as JSON; a final pass rewrites
/// them over the whole transcript when the meeting ends. A failed or odd reply never replaces good
/// notes. The prompt and parsing are the Mac's (Notes.swift), so both write the same notes.
public sealed class NotesEngine
{
    public enum State { Idle, Updating, NoKey, InvalidKey, RateLimited, Failed }

    public const double Interval = 45;
    readonly LingClient ling;
    readonly SessionStore store;
    readonly object gate = new();
    string? sessionId;
    bool inFlight;
    string? pendingFinal;
    DateTime lastAttempt = DateTime.MinValue;
    /// The language the shown notes were last written in.
    string? writtenIn;
    Timer? timer;

    public MeetingNotes Notes { get; private set; } = new();
    public State Status { get; private set; } = State.Idle;
    /// cicadactl notesproblem failed|ratelimited|idle: shows what a failed round looks like.
    public void SimulateStatus(string state) { Status = Enum.TryParse<State>(state, true, out var s) ? s : State.Idle; Changed?.Invoke(); }
    /// While a meeting runs and has notes: when the next live update is due.
    public DateTime? NextUpdate { get { lock (gate) return sessionId is null || Notes.IsEmpty || inFlight ? null : lastAttempt.AddSeconds(Interval); } }
    /// The session the notes belong to (stays set after the meeting ends).
    public string? ShownId { get; private set; }
    /// The language notes are written in (English name), from 纪要语言.
    public Func<string> Language { get; set; } = () => "Simplified Chinese";
    public event Action? Changed;

    public NotesEngine(LingClient ling, SessionStore store) { this.ling = ling; this.store = store; }

    /// Names for the translation glossary: "江充 (note; misheard as 江松, 江冲)".
    public IReadOnlyList<string> Glossary() => Notes.Terms.Take(30)
        .Select(t => t.Heard.Count == 0 ? $"{t.Name} ({t.Note})" : $"{t.Name} ({t.Note}; misheard as {string.Join(", ", t.Heard)})").ToList();

    public void Begin(string id)
    {
        lock (gate)
        {
            sessionId = id; ShownId = id; writtenIn = null;
            Notes = store.Get(id)?.Notes ?? new MeetingNotes();
            Status = ling.HasKey ? State.Idle : State.NoKey;
            lastAttempt = DateTime.UtcNow;
        }
        timer?.Dispose();
        timer = new Timer(_ => Tick(), null, TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(5));
        Changed?.Invoke();
    }

    /// The meeting ended: one last pass over the whole transcript. The task ends when it's written.
    public Task Finish()
    {
        timer?.Dispose(); timer = null;
        string? id;
        lock (gate) { id = sessionId; sessionId = null; }
        return id is null ? Task.CompletedTask : Update(id, final: true);
    }

    public void Show(string id)
    {
        lock (gate) { ShownId = id; Notes = store.Get(id)?.Notes ?? new MeetingNotes(); }
        Changed?.Invoke();
    }

    /// Notes for a finished meeting that has none.
    public Task Generate(string id) => Update(id, final: true);

    void Tick()
    {
        string? id;
        lock (gate)
        {
            if (Status == State.NoKey && ling.Usable) Status = State.Idle;
            id = sessionId;
            if (id is null || inFlight) return;
            var s = store.Get(id);
            if (s is null || s.Lines.Count <= Notes.Covered) return;
            var since = (DateTime.UtcNow - lastAttempt).TotalSeconds;
            // First notes as soon as there is something to say, then every 45 s.
            bool due = Notes.IsEmpty ? s.Lines.Count >= 3 || since > 20 : since >= Interval;
            if (!due) return;
        }
        _ = Update(id, final: false);
    }

    async Task Update(string id, bool final)
    {
        Session? session;
        MeetingNotes baseNotes;
        lock (gate)
        {
            if (inFlight) { if (final) pendingFinal = id; return; }
            session = store.Get(id);
            if (session is null || session.Lines.Count == 0) return;
            if (!ling.HasKey) { Status = State.NoKey; Changed?.Invoke(); return; }
            inFlight = true;
            lastAttempt = DateTime.UtcNow;
            Status = State.Updating;
            baseNotes = final ? new MeetingNotes() : (id == ShownId ? Notes : session.Notes ?? new MeetingNotes());
        }
        Changed?.Invoke();
        try
        {
            var lines = session.Lines.ToList();
            var lang = Language();
            // The language changed mid-meeting: write the notes again from the start in the new one.
            // (The script check can't tell Chinese from Japanese, so extending them would keep the old.)
            if (!final && writtenIn is not null && writtenIn != lang) { baseNotes = new MeetingNotes(); Log.Debug($"notes: language now {lang}, rewriting"); }
            int from = final ? 0 : Math.Min(baseNotes.Covered, lines.Count);
            var prompt = Prompt(baseNotes, lines, from, lang, final, SpeakerLabels.Voices ? SpeakerLabels.Names(session) : null);
            MeetingNotes? next = null;
            for (int attempt = 1; attempt <= (final ? 2 : 1); attempt++)
            {
                var raw = await ling.Chat(prompt, $"Update the notes. Write them in {lang}.", Priority.Notes, json: true, maxTokens: 6000, timeout: 90);
                var parsed = Parse(raw, lines.Select(l => l.T).ToList(), lines.FirstOrDefault()?.T ?? 0);
                if (parsed is null) break;
                if (Written(parsed, lang)) { next = parsed; break; }
                Log.Debug($"notes: {(final ? "final" : "live")} reply not in {lang} (attempt {attempt}), dropped");
            }
            if (next is null)
            {
                Log.Debug("notes: no usable reply, kept the previous notes");
                Status = State.Failed;
                return;
            }
            CarryTimes(baseNotes, next);
            next.Title ??= baseNotes.Title ?? session.Notes?.Title;
            next.Covered = lines.Count;
            next.UpdatedAt = DateTimeOffset.Now;
            next.Final = final;
            lock (gate) { if (id == ShownId) Notes = next; writtenIn = lang; }
            store.SetNotes(id, next);
            Status = State.Idle;
            Log.Debug($"notes: {(final ? "final" : "live")} update {lines.Count - from} new lines -> {next.Topics.Count} topics, {next.Terms.Count} terms");
        }
        catch (LingException e)
        {
            Status = e.Failure switch
            {
                LingException.Kind.InvalidKey => State.InvalidKey,
                LingException.Kind.RateLimited => State.RateLimited,
                LingException.Kind.NoKey => State.NoKey,
                _ => State.Failed,
            };
            Log.Debug($"notes: update failed {e.Message}");
        }
        finally
        {
            string? queued;
            lock (gate) { inFlight = false; queued = pendingFinal; pendingFinal = null; }
            Changed?.Invoke();
            if (queued is not null) await Update(queued, final: true);
        }
    }

    /// The model echoes points it already had without evidence: keep the times they had, and a
    /// point keeps the time it was first heard.
    public static void CarryTimes(MeetingNotes old, MeetingNotes next)
    {
        var known = new Dictionary<string, double>();
        foreach (var t in old.Topics)
            for (int i = 0; i < t.Points.Count; i++)
                if (t.PointTime(i) is { } x) known.TryAdd(t.Points[i], x);
        foreach (var t in next.Topics)
        {
            var times = t.Points.Select((p, i) => Min(t.PointTime(i), known.TryGetValue(p, out var k) ? k : null)).ToList();
            t.PointTimes = times.Any(x => x is not null) ? times : null;
        }
        var items = new Dictionary<string, double>();
        foreach (var i in old.Conclusions.Concat(old.Todos)) if (i.T is { } t) items.TryAdd(i.Text, t);
        foreach (var i in next.Conclusions.Concat(next.Todos)) i.T = Min(i.T, items.TryGetValue(i.Text, out var t) ? t : null);
    }

    static double? Min(double? a, double? b) => a is null ? b : b is null ? a : Math.Min(a.Value, b.Value);

    public static bool Written(MeetingNotes notes, string language) =>
        Languages.WrittenIn(notes.Summary + string.Concat(notes.Topics.Select(t => t.Title)), language);

    // MARK: Prompt (Notes.swift › prompt, word for word)

    public static string Prompt(MeetingNotes notes, IReadOnlyList<TranscriptLine> lines, int from, string language, bool final,
                                IReadOnlyDictionary<int, string>? names = null)
    {
        var numbers = SpeakerLabels.Voices ? SpeakerLabels.Numbers(lines) : [];
        string Line(int i)
        {
            var l = lines[i];
            // As Notes.swift: a named voice as its name, else 说话人N once voices are told apart,
            // 未识别 for a voice not on show.
            var who = l.Speaker == "me" ? "你" : numbers.TryGetValue(l.Id, out var n) ? names?.GetValueOrDefault(n) ?? $"说话人{n}" : numbers.Count == 0 ? "对方" : "未识别";
            return $"[L{i + 1} {Languages.Clock(l.T)} {who}] {l.Src}";
        }
        var current = notes.IsEmpty ? "{}" : CompactJson(notes);
        int context = Math.Max(0, from - 2);
        var p = $"You keep notes for a meeting {(final ? "that has just ended. Rewrite them from the whole transcript" : "that is still going on. Update them with the new lines")}.\n"
              + $"Write the notes in {language}. Return JSON only.\n";
        if (!final) p += $"Current notes (JSON):\n{current}\n\n";
        if (context < from) p += "Already covered (context only):\n" + string.Join("\n", Enumerable.Range(context, from - context).Select(Line)) + "\n\n";
        p += $"{(final ? "Transcript" : "New lines")} (id, mm:ss, speaker 对方=the other side / 你=me / a name or 说话人N=one person on the other side, told apart by voice and possibly wrong / 未识别=someone on the other side not identified, text). Speech recognition makes mistakes, often in names: correct them from context, and write a public figure's name as the news spells it.\n";
        p += string.Join("\n", Enumerable.Range(from, lines.Count - from).Select(Line));
        if (final && lines.Count > 0)
        {
            var span = lines[^1].T - lines[0].T;
            int most = Math.Max(1, Math.Min(8, (int)(span / 180) + 1));
            p += $"\n\nThis meeting ran {Languages.Clock(span)}: use at most {most} topic{(most == 1 ? "" : "s")}.";
        }
        else if (!final && notes.Topics.Count > 0 && lines.Count > 0 && lines[^1].T - notes.Topics[^1].Start < 120)
        {
            var topic = notes.Topics[^1];
            p += $"\n\nThe current topic \"{topic.Title}\" started at {Languages.Clock(topic.Start)}, under 2 minutes ago: do not start a new topic in this update; add the new lines to it.";
        }
        else if (!final && notes.Topics.Count == 0)
        {
            p += "\n\nThese are the first lines: make one topic.";
        }
        p += "\n\nReturn the full notes as one JSON object with exactly these keys:\n"
           + "{\"title\": \"the meeting's name: what it is about, a few words\",\n"
           + " \"summary\": \"2-3 sentences on the whole meeting so far\",\n"
           + " \"topics\": [{\"start\": seconds, \"title\": \"short title\", \"summary\": \"one sentence\", \"points\": [{\"text\": \"key point\", \"evidence\": [\"L4\"]}], \"evidence\": [\"L3\"],\n"
           + "             \"fishbone\": null or {\"question\": \"the problem or question\", \"branches\": [{\"label\": \"2-6 words\", \"detail\": \"one short line\", \"t\": seconds, \"evidence\": [\"L5\"]}]}}],\n"
           + " \"conclusions\": [{\"text\": \"...\", \"evidence\": [\"L7\", \"L8\"]}],\n"
           + " \"todos\": [{\"text\": \"...\", \"owner\": \"对方\" or \"你\" or null, \"evidence\": [\"L9\"]}],\n"
           + " \"terms\": [{\"name\": \"correct spelling\", \"note\": \"who or what, a few words\", \"heard\": [\"how it was misrecognised\"]}]}\n"
           + "Rules (be brief: these notes are read at a glance during the meeting):\n"
           + "- title: a name for the whole meeting, like a calendar entry (at most 12 Chinese characters or 6 words; no date, no quotes, not \"会议\" alone). Keep the current title unless the meeting's subject has clearly changed.\n"
           + "- summary: at most 3 short sentences.\n"
           + $"- Topics in time order, at most 8 in total. A topic is a stretch of the meeting, usually 3-10 minutes, not a single remark: start a new one only when the subject clearly changes and the current topic started at least 2 minutes before the newest line{(final ? "" : "; add at most one new topic per update")}. Otherwise add to the current one, and merge small neighbouring topics. Keep earlier topics as they are unless new lines correct them. The last topic is the one being discussed now.\n"
           + "- At most 4 points per topic, each one short phrase. Merge rather than repeat.\n"
           + "- At most 5 conclusions and only real to-dos (often none).\n"
           + "- Add a fishbone only to a topic that discusses causes, reasons or factors (3-5 branches); otherwise null.\n"
           + "- Every topic, point, branch, conclusion and to-do needs evidence: the ids of the lines that say it. Never state anything the transcript does not say.\n"
           + "- terms: at most 10 in total, replacing less useful ones rather than adding: first names the transcript misspells (heard), then the people, places and jargon a reader would not know. Leave out what everyone knows (a famous company, index or politician) unless it was misheard. name is the correct spelling in the transcript's language (no translation in brackets); heard lists only the wrong forms the transcript used; note is a few words.\n"
           + $"- Write the meeting title and every summary, title, point, branch, conclusion and to-do in {language}, even when the transcript is in another language. Only term names keep the transcript's spelling.\n"
           + "- Write about what was said, never about the transcript or recognition quality.\n"
           + "- Use empty arrays when there is nothing. No markdown, no text outside the JSON.";
        return p;
    }

    /// The current notes as sent back to the model (no bookkeeping fields).
    static string CompactJson(MeetingNotes n)
    {
        var o = new JsonObject();
        if (n.Title is not null) o["title"] = n.Title;
        o["summary"] = n.Summary;
        o["topics"] = new JsonArray(n.Topics.Select(t => (JsonNode)new JsonObject
        {
            ["start"] = t.Start, ["title"] = t.Title, ["summary"] = t.Summary,
            ["points"] = new JsonArray(t.Points.Select(p => (JsonNode)JsonValue.Create(p)!).ToArray()),
            ["fishbone"] = t.Fishbone is null ? null : JsonSerializer.SerializeToNode(t.Fishbone, Json.Compact),
        }).ToArray());
        o["conclusions"] = new JsonArray(n.Conclusions.Select(i => (JsonNode)JsonValue.Create(i.Text)!).ToArray());
        o["todos"] = new JsonArray(n.Todos.Select(i => (JsonNode)JsonValue.Create(i.Text)!).ToArray());
        o["terms"] = JsonSerializer.SerializeToNode(n.Terms, Json.Compact);
        return o.ToJsonString(Json.Compact);
    }

    // MARK: Parse

    /// Lenient: missing keys become empty, evidence ids are checked against the transcript.
    public static MeetingNotes? Parse(string raw, IReadOnlyList<double> times, double startedAt)
    {
        int a = raw.IndexOf('{'), b = raw.LastIndexOf('}');
        if (a < 0 || b <= a) return null;
        JsonObject root;
        try { root = JsonNode.Parse(raw[a..(b + 1)]) as JsonObject ?? throw new JsonException(); }
        catch (JsonException) { return null; }

        static string Str(JsonNode? v) => v is JsonValue jv && jv.TryGetValue<string>(out var s) ? s.Trim() : "";
        static double? Num(JsonNode? v) => v is JsonValue jv
            ? jv.TryGetValue<double>(out var d) ? d : jv.TryGetValue<string>(out var s) && double.TryParse(s, System.Globalization.CultureInfo.InvariantCulture, out var p) ? p : null
            : null;
        HashSet<int> LineNumbers(JsonNode? v)
        {
            var set = new HashSet<int>();
            if (v is not JsonArray arr) return set;
            foreach (var id in arr)
            {
                var s = Str(id);
                var digits = new string(s.SkipWhile(c => !char.IsDigit(c)).ToArray());
                if (int.TryParse(digits, out var n) && n >= 1 && n <= times.Count) set.Add(n);
            }
            return set;
        }
        int Support(JsonNode? v) => LineNumbers(v).Count;
        double? Time(JsonNode? v) { var s = LineNumbers(v); return s.Count == 0 ? null : times[s.Min() - 1]; }
        static IEnumerable<JsonObject> Objects(JsonNode? v) => v is JsonArray arr ? arr.OfType<JsonObject>() : [];

        var n = new MeetingNotes { Summary = Str(root["summary"]) };
        var title = Str(root["title"]).Trim('"', '“', '”', '「', '」', '《', '》');
        n.Title = title.Length == 0 ? null : title;
        foreach (var t in Objects(root["topics"]))
        {
            var topicTitle = Str(t["title"]);
            if (topicTitle.Length == 0) continue;
            Fishbone? fish = null;
            if (t["fishbone"] is JsonObject f)
            {
                var branches = Objects(f["branches"]).Select(br => new FishboneBranch
                {
                    Label = Str(br["label"]), Detail = Str(br["detail"]), T = Num(br["t"]), Support = Support(br["evidence"]),
                }).Where(br => br.Label.Length > 0).ToList();
                if (branches.Count >= 2) fish = new Fishbone { Question = Str(f["question"]), Branches = branches };
            }
            var points = new List<string>();
            var pointTimes = new List<double?>();
            if (t["points"] is JsonArray ps)
            {
                foreach (var p in ps)
                {
                    var text = p is JsonObject po ? Str(po["text"]) : Str(p);
                    if (text.Length == 0) continue;
                    points.Add(text);
                    pointTimes.Add(p is JsonObject po2 ? Time(po2["evidence"]) : null);
                }
            }
            // The model's "start" is sometimes misread (04:49 for 00:49), and the lines it cites can
            // all be late ones (a rewrite cites what's fresh): a topic starts at the earlier of the two,
            // and never after the last line.
            var cited = new[] { Time(t["evidence"]) }.Concat(pointTimes).Where(x => x is not null).Select(x => x!.Value).ToList();
            var said = Num(t["start"]);
            var start = cited.Count == 0 ? said ?? startedAt : said is { } x0 ? Math.Min(x0, cited.Min()) : cited.Min();
            if (times.Count > 0 && start > times[^1]) start = times[^1];
            n.Topics.Add(new NoteTopic
            {
                Start = start, Title = topicTitle, Summary = Str(t["summary"]),
                Points = points, Fishbone = fish, PointTimes = pointTimes.Any(x => x is not null) ? pointTimes : null,
            });
        }
        List<NoteItem> Items(string key) => Objects(root[key]).Select(i =>
        {
            var owner = Str(i["owner"]);
            return new NoteItem { Text = Str(i["text"]), Owner = owner.Length == 0 ? null : owner, Support = Support(i["evidence"]), T = Time(i["evidence"]) };
        }).Where(i => i.Text.Length > 0).ToList();
        n.Conclusions = Items("conclusions");
        n.Todos = Items("todos");
        n.Terms = Objects(root["terms"]).Select(t =>
        {
            var name = Str(t["name"]);
            var heard = t["heard"] is JsonArray h ? h.Select(Str).Where(x => x.Length > 0 && x != name).ToList() : [];
            return new NoteTerm { Name = name, Note = Str(t["note"]), Heard = heard };
        }).Where(t => t.Name.Length > 0).ToList();
        // The model keeps every term it ever had: bound the glossary, keeping the misheard ones.
        if (n.Terms.Count > 20) n.Terms = NoteTerm.Ordered(n.Terms).Take(20).ToList();
        return n.IsEmpty ? null : n;
    }
}
