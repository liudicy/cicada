using System.Text.Json;
using System.Text.Json.Nodes;

namespace Cicada;

/// Keeps the live meeting's notes up to date: every ~45 s with new speech, one Ling call sends the
/// current notes plus the new lines and gets the whole notes back as JSON; a final pass rewrites
/// them over the whole transcript when the meeting ends. A failed or odd reply never replaces good
/// notes. The prompt and parsing are the Mac's (Notes.swift), so both write the same notes.
public sealed class NotesEngine
{
    /// Unreachable: the notes' own request couldn't reach the service (network, proxy, timeout);
    /// another request failing, such as naming speakers, never sets it.
    public enum State { Idle, Updating, NoKey, InvalidKey, RateLimited, Unreachable, Failed }

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
        lock (gate)
        {
            ShownId = id; Notes = store.Get(id)?.Notes ?? new MeetingNotes();
            // A round that failed belongs to the meeting it ran for, not to the record opened now.
            if (sessionId is null && Status is State.Failed or State.Unreachable or State.RateLimited) Status = State.Idle;
        }
        Changed?.Invoke();
    }

    /// The finished meeting whose notes 生成纪要 is writing now (Notes.swift › generatingID): its
    /// page says so and the button waits, as a long meeting's notes take half a minute and more.
    public string? GeneratingId { get; private set; }

    /// The meeting whose final pass is running now (from 结束 or 生成纪要).
    string? finalId;
    /// A final pass is over, whether it wrote notes or not (存到文件夹 waits for it).
    public event Action<string>? FinalDone;
    /// The final pass for this meeting is running or waiting its turn.
    public bool Settling(string id) { lock (gate) return finalId == id || pendingFinal == id; }

    /// Notes for a finished meeting that has none.
    public async Task Generate(string id)
    {
        lock (gate) { if (GeneratingId is not null) return; GeneratingId = id; }
        Changed?.Invoke();
        try { await Update(id, final: true); }
        finally
        {
            lock (gate) GeneratingId = null;
            Changed?.Invoke();
        }
    }

    void Tick()
    {
        string? id;
        lock (gate)
        {
            if (Status == State.NoKey && ling.Usable) Status = State.Idle;
            // The service answers again (the check after a network change, or any other request): the
            // banner goes now, not after the next round, which runs on its usual 45 s.
            if (Status == State.Unreachable && ling.Health.Failure?.Why != AICheck.Reason.Unreachable) Status = State.Idle;
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
        List<NoteTerm> prior;
        lock (gate)
        {
            if (inFlight) { if (final) pendingFinal = id; return; }
            session = store.Get(id);
            if (session is null || session.Lines.Count == 0) { if (final) FinalDone?.Invoke(id); return; }
            if (!ling.HasKey) { Status = State.NoKey; Changed?.Invoke(); if (final) FinalDone?.Invoke(id); return; }
            inFlight = true;
            if (final) finalId = id;
            lastAttempt = DateTime.UtcNow;
            Status = State.Updating;
            baseNotes = final ? new MeetingNotes() : (id == ShownId ? Notes : session.Notes ?? new MeetingNotes());
            prior = (id == ShownId ? Notes : session.Notes)?.Terms ?? [];
        }
        Changed?.Invoke();
        try
        {
            var lines = session.Lines.ToList();
            var lang = Language();
            // The language changed mid-meeting: write the notes again from the start in the new one.
            // (The script check can't tell Chinese from Japanese, so extending them would keep the old.)
            bool fresh = !final && writtenIn is not null && writtenIn != lang;
            if (fresh) { baseNotes = new MeetingNotes(); Log.Debug($"notes: language now {lang}, rewriting"); }
            int from = final ? 0 : Math.Min(baseNotes.Covered, lines.Count);
            var names = SpeakerLabels.Voices ? SpeakerLabels.Names(session) : null;
            var startedAt = lines.FirstOrDefault()?.T ?? 0;
            // A live update returns only the last topics: when it rewrote them all, its reply grew with
            // the meeting until, about an hour in, it was cut off at max_tokens or fell into a loop and
            // the notes stopped updating. The final pass still rewrites everything once.
            int frozen = final || fresh ? 0 : Math.Max(0, baseNotes.Topics.Count - EditableTopics);
            var prompt = Prompt(baseNotes, lines, from, lang, final, names, frozen);
            var next = final ? await LongFinal(lines, names, lang, startedAt) : null;
            for (int attempt = 1; next is null && attempt <= (final || fresh ? 2 : 1); attempt++)
            {
                var raw = await ling.Chat(prompt, $"Update the notes. Write them in {lang}.", Priority.Notes, json: true, maxTokens: 6000, timeout: 90, patient: final);
                var parsed = Parse(raw, lines.Select(l => l.T).ToList(), startedAt);
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
            if (!final && !fresh) next.Topics = Merge(baseNotes.Topics, frozen, next.Topics);
            if (!fresh) next.Terms = NoteTerm.KeepingOrder(prior, next.Terms);
            next.Terms = HeardAsSaid(next.Terms, lines);
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
                LingException.Kind.Network or LingException.Kind.Timeout => State.Unreachable,
                _ => State.Failed,
            };
            Log.Debug($"notes: update failed {e.Message}");
        }
        finally
        {
            string? queued;
            lock (gate) { inFlight = false; if (final) finalId = null; queued = pendingFinal; pendingFinal = null; }
            Changed?.Invoke();
            if (final) FinalDone?.Invoke(id);
            if (queued is not null) await Update(queued, final: true);
        }
    }

    /// Terms keep only the heard forms the recognizer really wrote (`Src`). The notes read lines
    /// with fixes in, so a wrong fix came back as a heard form ("X平台 heard as platform"), went to
    /// the translator and the next fix's request as a known mishearing, and was proposed again.
    public static List<NoteTerm> HeardAsSaid(List<NoteTerm> terms, IReadOnlyList<TranscriptLine> lines)
    {
        foreach (var t in terms) t.Heard = t.Heard.Where(h => lines.Any(l => l.Src.Contains(h, StringComparison.OrdinalIgnoreCase))).ToList();
        return terms;
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
            // A topic starts no later than its first point (the reply dates it from the lines it cites now).
            if (times.Where(x => x is not null).Min() is { } first && first < t.Start) t.Start = first;
        }
        var items = new Dictionary<string, double>();
        foreach (var i in old.Conclusions.Concat(old.Todos)) if (i.T is { } t) items.TryAdd(i.Text, t);
        foreach (var i in next.Conclusions.Concat(next.Todos)) i.T = Min(i.T, items.TryGetValue(i.Text, out var t) ? t : null);
    }

    static double? Min(double? a, double? b) => a is null ? b : b is null ? a : Math.Min(a.Value, b.Value);

    public static bool Written(MeetingNotes notes, string language) =>
        Languages.WrittenIn(notes.Summary + string.Concat(notes.Topics.Select(t => t.Title)), language);

    /// A long meeting's final pass: each part noted on its own, all at once, then merged into one.
    /// null when a step fails: the caller then makes one pass over the whole transcript, as before.
    async Task<MeetingNotes?> LongFinal(List<TranscriptLine> lines, IReadOnlyDictionary<int, string>? names, string lang, double startedAt)
    {
        var parts = Parts(lines);
        if (parts.Count <= 1) return null;
        var started = DateTime.UtcNow;
        var times = lines.Select(l => l.T).ToList();
        async Task<string?> Ask(string prompt, string instruction)
        {
            try { return await ling.Chat(prompt, instruction, Priority.Notes, json: true, maxTokens: 6000, timeout: 90); }
            catch (Exception e) { Log.Debug($"notes: long final call failed {e.Message}"); return null; }
        }
        var replies = await Task.WhenAll(parts.Select((r, i) =>
            Ask(Prompt(new MeetingNotes(), lines.Take(r.End.Value).ToList(), r.Start.Value, lang, final: true, names, part: (i + 1, parts.Count)),
                $"Write the notes for this part. Write them in {lang}.")));
        var notes = new List<string>();
        var topics = new List<NoteTopic>();
        for (int i = 0; i < replies.Length; i++)
        {
            var raw = replies[i];
            var parsed = raw is null ? null : Parse(raw, times, startedAt);
            if (raw is null || parsed is null || parsed.Topics.Count == 0)
            {
                Log.Debug($"notes: final part {i + 1}/{parts.Count} failed, one pass instead");
                return null;
            }
            // Without its topics: given them, the merge wrote them all back out and was cut off.
            int a = raw.IndexOf('{'), b = raw.LastIndexOf('}');
            if (JsonNode.Parse(raw[a..(b + 1)]) is not JsonObject part) return null;
            part.Remove("topics");
            notes.Add(part.ToJsonString(Json.Compact));
            topics.AddRange(Thinned(parsed.Topics, PartTopics(parts.Count), lines[parts[i].End.Value - 1].T));
        }
        bool voices = SpeakerLabels.Voices && SpeakerLabels.Numbers(lines).Count > 0;
        var prompt = MergePrompt(notes, lines, lang, voices);
        for (int attempt = 1; attempt <= 2; attempt++)
        {
            var raw = await Ask(prompt, $"Merge the notes. Write them in {lang}.");
            var merged = raw is null ? null : Parse(raw, times, startedAt);
            if (merged is null) break;
            merged.Topics = topics;
            if (Written(merged, lang))
            {
                Log.Debug($"notes: final in {parts.Count} parts -> {merged.Topics.Count} topics in {(int)(DateTime.UtcNow - started).TotalSeconds} s");
                return merged;
            }
            Log.Debug($"notes: merged reply not in {lang} (attempt {attempt}), dropped");
        }
        Log.Debug($"notes: merging {parts.Count} parts failed, one pass instead");
        return null;
    }

    // MARK: Live topics (Notes.swift › merge)

    /// The most topics the final notes have (the prompt says so too; the model doesn't always listen).
    public const int MaxTopics = 8;
    /// The most topics live notes have. Live notes used to stop at `MaxTopics` and pour everything
    /// after into the last topic, whose summary then grew into a wall of "最新…又…补充…"; past this,
    /// the two shortest neighbouring settled topics are joined instead, so the newest can start.
    public const int LiveMaxTopics = 12;
    /// A topic summary longer than this is a log the model kept appending to, not one sentence.
    public const int TopicSummaryLimit = 160;
    /// How many of the last topics a live update may rewrite; earlier ones stay as they are.
    public const int EditableTopics = 2;

    /// A live reply's topics after the `frozen` ones it was told to leave alone: with some frozen, at
    /// most the editable ones plus one new, from the end (the model sometimes echoes the whole list),
    /// never a copy of a frozen one, each summary kept to one sentence; and no more than
    /// `LiveMaxTopics` in all (past that, settled neighbours are joined). A reply with no topics of
    /// its own keeps the ones it had.
    public static List<NoteTopic> Merge(IReadOnlyList<NoteTopic> old, int frozen, IReadOnlyList<NoteTopic> returned)
    {
        var kept = old.Take(frozen).ToList();
        var fixedTitles = kept.Select(t => t.Title).ToHashSet();
        var own = returned.Where(t => !fixedTitles.Contains(t.Title)).ToList();
        var tail = kept.Count == 0 ? own : own.TakeLast(old.Count - kept.Count + 1).ToList();
        if (tail.Count == 0) return old.ToList();
        foreach (var t in tail) t.Summary = Shortened(t.Summary);
        tail = Capped(tail, LiveMaxTopics - Math.Min(kept.Count, 1));
        while (kept.Count + tail.Count > LiveMaxTopics && kept.Count >= 2)
        {
            // The pair spanning the least time, its end being the next topic's start.
            var ends = kept.Skip(1).Select(t => t.Start).Append(tail[0].Start).ToList();
            int i = 0;
            for (int j = 1; j < kept.Count - 1; j++)
                if (ends[j + 1] - kept[j].Start < ends[i + 1] - kept[i].Start) i = j;
            kept[i] = Joined(kept[i], kept[i + 1]);
            kept.RemoveAt(i + 1);
        }
        return Capped(kept.Concat(tail).ToList(), LiveMaxTopics);
    }

    /// Two neighbouring topics as one: both titles and summaries, and up to the 4 points the prompt
    /// allows, taken evenly from each.
    public static NoteTopic Joined(NoteTopic a, NoteTopic b)
    {
        int fromA = Math.Min(a.Points.Count, Math.Max(2, 4 - b.Points.Count));
        int fromB = Math.Min(b.Points.Count, 4 - fromA);
        var times = Enumerable.Range(0, fromA).Select(a.PointTime).Concat(Enumerable.Range(0, fromB).Select(b.PointTime)).ToList();
        var gap = a.Summary.Length == 0 || "。！？；".Contains(a.Summary[^1]) ? "" : " ";
        return new NoteTopic
        {
            Start = a.Start, Title = $"{a.Title} / {b.Title}", Summary = a.Summary + gap + b.Summary,
            Points = a.Points.Take(fromA).Concat(b.Points.Take(fromB)).ToList(), Fishbone = a.Fishbone ?? b.Fishbone,
            PointTimes = times.Any(x => x is not null) ? times : null,
        };
    }

    /// A runaway topic summary cut back to its first sentence (or to the limit, with "…").
    public static string Shortened(string summary)
    {
        if (summary.Length <= TopicSummaryLimit) return summary;
        var head = summary[..TopicSummaryLimit];
        var end = head.IndexOfAny("。！？；.!?;".ToCharArray(), 10);
        return end >= 0 ? head[..(end + 1)] : head.Trim() + "…";
    }

    /// At most `count` topics (at least one): the points of any after that go into the last kept.
    /// The last kept is a copy: it may be one of the shown notes' topics.
    public static List<NoteTopic> Capped(List<NoteTopic> topics, int count)
    {
        topics = topics.ToList();
        while (topics.Count > Math.Max(1, count))
        {
            var extra = topics[^1]; topics.RemoveAt(topics.Count - 1);
            var last = topics[^1]; topics.RemoveAt(topics.Count - 1);
            var times = Enumerable.Range(0, last.Points.Count).Select(last.PointTime)
                .Concat(Enumerable.Range(0, extra.Points.Count).Select(extra.PointTime)).ToList();
            topics.Add(new NoteTopic
            {
                Start = last.Start, Title = last.Title, Summary = last.Summary, Fishbone = last.Fishbone,
                Points = last.Points.Concat(extra.Points).ToList(), PointTimes = times.Any(x => x is not null) ? times : null,
            });
        }
        return topics;
    }

    // MARK: Prompt (Notes.swift › prompt, word for word)

    /// `part`: in a long meeting's final pass, which part `from..lines.Count` is (1-based, of `Of`).
    public static string Prompt(MeetingNotes notes, IReadOnlyList<TranscriptLine> lines, int from, string language, bool final,
                                IReadOnlyDictionary<int, string>? names = null, int frozen = 0, (int Index, int Of)? part = null)
    {
        var numbers = SpeakerLabels.Voices ? SpeakerLabels.Numbers(lines) : [];
        string Line(int i)
        {
            var l = lines[i];
            // As Notes.swift: a named voice as its name, else 说话人N once voices are told apart,
            // 未识别 for a voice not on show.
            var who = l.Speaker == "me" ? "你" : numbers.TryGetValue(l.Id, out var n) ? names?.GetValueOrDefault(n) ?? $"说话人{n}" : numbers.Count == 0 ? "对方" : "未识别";
            return $"[L{i + 1} {Languages.Clock(l.T)} {who}] {l.Shown}";
        }
        var current = notes.IsEmpty ? "{}" : CompactJson(notes, frozen);
        int context = Math.Max(0, from - 2);
        var task = part is { } pt ? $"that has just ended. It was long, so it is noted in parts: write the notes for part {pt.Index} of {pt.Of} only, from the lines below"
                 : final ? "that has just ended. Rewrite them from the whole transcript" : "that is still going on. Update them with the new lines";
        var p = $"You keep notes for a meeting {task}.\n"
              + $"Write the notes in {language}. Return JSON only.\n";
        if (!final)
        {
            if (frozen > 0)
                p += "Earlier topics (settled: kept as they are, do not return them):\n"
                   + string.Join("\n", notes.Topics.Take(frozen).Select(t => $"- {Languages.Clock(t.Start)} {t.Title}: {t.Summary}")) + "\n\n";
            p += $"Current notes (JSON{(frozen > 0 ? ", latest topics only" : "")}):\n{current}\n\n";
        }
        if (context < from) p += "Already covered (context only):\n" + string.Join("\n", Enumerable.Range(context, from - context).Select(Line)) + "\n\n";
        p += $"{(final ? "Transcript" : "New lines")} (id, mm:ss, speaker 对方=the other side / 你=me / a name or 说话人N=one person on the other side, told apart by voice and possibly wrong / 未识别=someone on the other side not identified, text). Speech recognition makes mistakes, often in names: correct them from context, and write a public figure's name as the news spells it.\n";
        p += string.Join("\n", Enumerable.Range(from, lines.Count - from).Select(Line));
        // The model splits too eagerly when only told how long a topic should be: say plainly
        // whether this update may start one.
        if (final && from < lines.Count)
        {
            var span = lines[^1].T - lines[from].T;
            int most = Math.Max(1, Math.Min(part is { } q ? PartTopics(q.Of) : MaxTopics, (int)(span / 180) + 1));
            p += $"\n\nThis {(part is null ? "meeting" : "part")} ran {Languages.Clock(span)}: use at most {most} topic{(most == 1 ? "" : "s")}.";
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
        return p + "\n\n" + Format(language, numbers.Count > 0, final, frozen);
    }

    /// The reply's JSON shape and the rules for its contents.
    static string Format(string language, bool voices, bool final, int frozen) =>
        "Return the full notes as one JSON object with exactly these keys:\n"
           + "{\"title\": \"the meeting's name: what it is about, a few words\",\n"
           + " \"summary\": \"2-3 sentences on the whole meeting so far\",\n"
           + " \"topics\": [{\"start\": seconds, \"title\": \"short title\", \"summary\": \"one sentence on the whole topic\", \"points\": [{\"text\": \"key point\", \"evidence\": [\"L4\"]}], \"evidence\": [\"L3\"],\n"
           + "             \"fishbone\": null or {\"question\": \"the problem or question\", \"branches\": [{\"label\": \"2-6 words\", \"detail\": \"one short line\", \"t\": seconds, \"evidence\": [\"L5\"]}]}}],\n"
           + " \"conclusions\": [{\"text\": \"...\", \"evidence\": [\"L7\", \"L8\"]}],\n"
           + $" \"todos\": [{{\"text\": \"...\", \"owner\": {(!voices ? "\"对方\" or \"你\" or null" : "the person's label from the transcript (a name like \"George\", or \"说话人2\"), \"你\", or null when unclear")}, \"evidence\": [\"L9\"]}}],\n"
           + " \"terms\": [{\"name\": \"correct spelling\", \"note\": \"who or what, a few words\", \"heard\": [\"how it was misrecognised\"]}]}\n"
           + "Rules (be brief: these notes are read at a glance during the meeting):\n"
           + "- title: a name for the whole meeting, like a calendar entry (at most 12 Chinese characters or 6 words; no date, no quotes, not \"会议\" alone). Keep the current title unless the meeting's subject has clearly changed.\n"
           + "- summary: at most 3 short sentences.\n"
           + $"- Topics in time order, {(frozen > 0 ? "returning only the topics in the current notes and at most one new one after them" : $"at most {MaxTopics} in total")}. A topic is a stretch of the meeting, usually 3-10 minutes, not a single remark: start a new one only when the subject clearly changes and the current topic started at least 2 minutes before the newest line{(final ? "" : "; add at most one new topic per update")}. Otherwise add to the current one, and merge small neighbouring topics. Keep earlier topics as they are unless new lines correct them. The last topic is the one being discussed now.\n"
           + "- A topic's summary is one sentence on the whole topic, at most 40 Chinese characters or 25 words: as the topic grows, rewrite it; never append to it or narrate what came next (\"最新\", \"又\", \"补充\", \"then\", \"later\").\n"
           + "- At most 4 points per topic, each one short phrase. Merge rather than repeat.\n"
           + "- At most 5 conclusions and only real to-dos (often none).\n"
           + "- Add a fishbone only to a topic that discusses causes, reasons or factors (3-5 branches); otherwise null.\n"
           + "- Every topic, point, branch, conclusion and to-do needs evidence: the ids of the lines that say it. Never state anything the transcript does not say.\n"
           + "- terms: at most 10 in total, replacing less useful ones rather than adding: first names the transcript misspells (heard), then the people, places and jargon a reader would not know. Leave out what everyone knows (a famous company, index or politician) unless it was misheard. name is the correct spelling in the transcript's language (no translation in brackets); heard lists only the wrong forms the transcript used, and only of that same thing: a name said again and again in one spelling that context doesn't tie to a known one (\"我们 twoty\", \"our platform\") is a thing of its own, its own term with that spelling, not a mishearing of a similar name; note is a few words.\n"
           + $"- Write the meeting title and every summary, title, point, branch, conclusion and to-do in {language}, even when the transcript is in another language. Only term names keep the transcript's spelling.\n"
           + "- Write about what was said, never about the transcript or recognition quality.\n"
           + "- Use empty arrays when there is nothing. No markdown, no text outside the JSON.";

    /// The current notes as sent back to the model (no bookkeeping fields). `from`: the first topic
    /// sent (earlier ones go as a list of titles).
    static string CompactJson(MeetingNotes n, int from = 0)
    {
        var o = new JsonObject();
        if (n.Title is not null) o["title"] = n.Title;
        o["summary"] = n.Summary;
        o["topics"] = new JsonArray(n.Topics.Skip(from).Select(t => (JsonNode)new JsonObject
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

    // MARK: Long meetings

    /// How a long meeting's final pass is split: over `SplitMinutes`, into equal parts by time of at
    /// most `PartMinutes`. One pass covered a 91-minute meeting but only the first hour of a 4-hour one.
    public const double SplitMinutes = 100, PartMinutes = 60;
    public static List<Range> Parts(IReadOnlyList<TranscriptLine> lines)
    {
        if (lines.Count == 0) return [];
        double first = lines[0].T, last = lines[^1].T;
        var minutes = (last - first) / 60;
        if (minutes <= SplitMinutes) return [0..lines.Count];
        int count = (int)Math.Ceiling(minutes / PartMinutes);
        var length = (last - first) / count;
        var bounds = new List<int> { 0 };
        for (int k = 1; k < count; k++)
        {
            var at = first + length * k;
            int i = -1;
            for (int j = 0; j < lines.Count; j++) if (lines[j].T >= at) { i = j; break; }
            if (i > bounds[^1]) bounds.Add(i);
        }
        bounds.Add(lines.Count);
        return bounds.Zip(bounds.Skip(1), (a, b) => a..b).ToList();
    }

    /// Each part's share of the topics: the merge keeps them as they are, so every part has some.
    public static int PartTopics(int parts) => Math.Max(2, MaxTopics / Math.Max(1, parts));

    /// At most `count` of a part's `topics`, neighbours joined: a part's reply often has more topics
    /// than asked. Keeping the first ones lost the end of the part, and keeping some spread from first
    /// to last kept a topic's "（续）" stub at the part's end and dropped the topic itself. The same
    /// subject twice is joined first, under the first one's title; then the pair spanning the least
    /// time (to the next topic's start, or `end` for the last), as live notes do.
    public static List<NoteTopic> Thinned(IReadOnlyList<NoteTopic> topics, int count, double end)
    {
        var list = topics.ToList();
        while (list.Count > Math.Max(1, count))
        {
            double Span(int i) => (i + 2 < list.Count ? list[i + 2].Start : end) - list[i].Start;
            int same = Enumerable.Range(0, list.Count - 1).FirstOrDefault(i => Subject(list[i].Title) == Subject(list[i + 1].Title), -1);
            int at = same;
            if (at < 0)
            {
                // The first of equal spans, as the Mac does.
                at = 0;
                for (int i = 1; i < list.Count - 1; i++) if (Span(i) < Span(at)) at = i;
            }
            var one = Joined(list[at], list[at + 1]);
            if (same >= 0) (one.Title, one.Summary) = (list[at].Title, list[at].Summary);
            list[at] = one;
            list.RemoveAt(at + 1);
        }
        return list;
    }

    /// A topic title without a trailing bracket ("预算评审（续）", "Budget (cont.)"): what it is about.
    public static string Subject(string title)
    {
        var t = title.Trim();
        if (t.Length == 0 || !"）)".Contains(t[^1])) return t;
        int open = t.LastIndexOfAny(['（', '(']);
        return open > 0 ? t[..open].Trim() : t;
    }

    /// The whole meeting's title, summary, conclusions, to-dos and terms from its parts' notes (the
    /// replies as they came, with their evidence line ids). Asked to merge topics too, the model
    /// kept the first parts' and dropped the rest, so topics are joined in code.
    public static string MergePrompt(IReadOnlyList<string> parts, IReadOnlyList<TranscriptLine> lines, string language, bool voices)
    {
        var p = "You keep notes for a meeting that has just ended. It was long, so each part was noted on its own; below are those notes, in time order (JSON; evidence ids are transcript lines, L1 the first). Merge them into the notes for the whole meeting.\n"
              + $"Write the notes in {language}. Return JSON only.\n\n";
        for (int i = 0; i < parts.Count; i++) p += $"Part {i + 1} of {parts.Count}:\n{parts[i]}\n\n";
        if (lines.Count > 0)
            p += $"This meeting ran {Languages.Clock(lines[^1].T - lines[0].T)}. Return \"topics\": []: the parts' topics are kept as they are. Name and summarise the whole meeting, every part of it; keep each conclusion, to-do and term once, with the evidence ids it had (joined when you merge two).\n\n";
        return p + Format(language, voices, final: true, frozen: 0);
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
                    Label = Str(br["label"]), Detail = Str(br["detail"]), T = Time(br["evidence"]) ?? Num(br["t"]), Support = Support(br["evidence"]),
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
            // When it was first said, from its lines: the model's own "start" drifts by tens of
            // minutes in a long meeting (a topic said at 51-85 min came back as starting at 23) and is
            // sometimes misread (04:49 for 00:49). Never after the last line.
            var cited = new[] { Time(t["evidence"]) }.Concat(pointTimes).Where(x => x is not null).Select(x => x!.Value).ToList();
            var start = cited.Count > 0 ? cited.Min() : Num(t["start"]) ?? startedAt;
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
