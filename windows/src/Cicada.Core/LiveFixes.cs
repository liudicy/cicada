namespace Cicada;

/// 改正听错的词, between the translation and the records (the Mac's LiveFixes.swift): which fixes a
/// line takes, which wait for the user (待确认), and what the user's answers and edits teach the
/// word list. Who wins: the user's own decisions, then the word list, then a later pass, then the
/// first live guess. UI-free and thread-safe (replies arrive on worker threads); `Changed` fires on
/// whichever thread made the change, and the app shows `Pending`, `Asking` and `Toast`.
public sealed class LiveFixes
{
    readonly SessionStore store;
    readonly AppSettings settings;
    public Vocabulary Vocabulary { get; }
    readonly object gate = new();
    public event Action? Changed;

    /// The last thing the user did, said back with 撤销 for a few seconds.
    public sealed record Note(int Id, string Text);
    public Note? Toast { get; private set; }
    int toastIds;
    Timer? toastTimer;

    /// Fixes said no to in this meeting ("from→to"), and how often each heard form was turned down
    /// overall this run: twice and it leaves the word list.
    HashSet<string> refused = [];
    readonly Dictionary<string, int> refusals = [];
    /// 稍后再看 on the card: still waiting, but asked again only after the meeting.
    HashSet<string> deferred = [];
    /// What 撤销 puts back: the lines' fixes and the word list as they were.
    sealed record Step(string Session, Dictionary<string, List<LineFix>> Lines, List<Vocabulary.Term> Words, HashSet<string> Refused, HashSet<string> Deferred);
    readonly List<Step> undo = [];

    /// The card asks about at most this many names in a row; the rest wait for after the meeting.
    public const int AskAtOnce = 3;

    public LiveFixes(SessionStore store, Vocabulary vocabulary, AppSettings settings)
    {
        this.store = store; Vocabulary = vocabulary; this.settings = settings;
    }

    public void MeetingStarted() { lock (gate) { refused = []; deferred = []; undo.Clear(); } }

    static string Pair(string a, string b) => a + "\u001F" + b;
    static string KeyOf(LineFix f) { var c = Correction.Core(f.From, f.To); return Pair(c.From, c.To); }

    TranscriptLine? Line(string id, string lineId) => store.Get(id)?.Lines.FirstOrDefault(l => l.Id == lineId);

    // MARK: The service's proposals

    /// What a finished sentence's request carries; null while fixing is off. On a second pass (a
    /// joined line) the lines after it and the notes' summary are there too.
    public Translator.FixContext? Context(string id, string lineId)
    {
        if (!settings.FixMisheard || store.Get(id) is not { } s) return null;
        var lines = s.Lines.ToList();
        int i = lines.FindIndex(l => l.Id == lineId);
        var recent = i < 0 ? [] : lines.Skip(Math.Max(0, i - 3)).Take(i - Math.Max(0, i - 3)).Select(l => l.Shown).ToList();
        var following = i < 0 ? [] : lines.Skip(i + 1).Take(3).Select(l => l.Shown).ToList();
        var topic = s.Notes?.Title is { Length: > 0 } t ? t : s.Renamed == true ? s.Title : null;
        return new Translator.FixContext(topic, Vocabulary.PromptLines(), recent, following, s.Notes?.Summary is { Length: > 0 } sum ? sum : null);
    }

    /// The service's proposals for a line (none at all is an answer too: a later pass takes back
    /// what isn't proposed again).
    public void Received(string id, string lineId, IReadOnlyList<Correction.Edit> edits)
    {
        if (!settings.FixMisheard) return;
        lock (gate)
        {
            if (Line(id, lineId) is not { } line) return;
            var fresh = new List<LineFix>();
            foreach (var e in edits)
            {
                var verdict = Correction.Decide(e, Vocabulary.Knows, (a, b) => refused.Contains(Pair(a, b)));
                Log.Debug($"fix {verdict} c={e.Confidence:F2} line={lineId}");
                if (verdict == Correction.Verdict.Apply)
                {
                    fresh.Add(new LineFix(e.From, e.To));
                    // A listed word counts as used whichever way the fix was found (a sound-alike too).
                    Vocabulary.Use(Correction.Core(e.From, e.To).To);
                }
                else if (verdict == Correction.Verdict.Ask && settings.AskNames) fresh.Add(new LineFix(e.From, e.To, ask: true));
            }
            var before = line.Fixes ?? [];
            var fixes = Known(line.Src, Correction.Merge(before, fresh));
            var dropped = before.Count(f => f.Applied && f.User != true && !fixes.Contains(f));
            if (dropped > 0) Log.Debug($"fix recheck took back {dropped} line={lineId}");
            Set(fixes, lineId, id);
        }
        Changed?.Invoke();
    }

    /// The word list's confirmed heard forms, fixed without asking anyone: also with no AI service.
    /// Two characters at least, so a single 压 never turns into 押 everywhere.
    public void ApplyKnown(string id, string lineId)
    {
        if (!settings.FixMisheard) return;
        lock (gate)
        {
            if (Line(id, lineId) is not { } l) return;
            Set(Known(l.Src, l.Fixes ?? []), lineId, id);
        }
        Changed?.Invoke();
    }

    List<LineFix> Known(string src, IReadOnlyList<LineFix> fixes)
    {
        var out_ = fixes.ToList();
        foreach (var t in Vocabulary.Terms)
            foreach (var h in t.Heard)
            {
                // A heard form two words claim (两个都留) is never fixed silently. A translation a yes taught
                // before that was refused (平台 → platform) isn't either; one the user typed is.
                if (Correction.Length(h) < 2 || Correction.WordIn(h, src) < 0 || refused.Contains(Pair(h, t.Word))
                    || (t.Source != "user" && Correction.Translation(h, t.Word))
                    || Vocabulary.Owners(h, t.Word).Count > 0) continue;
                if (out_.Any(f => f.From == h || (f.Applied && f.From.Contains(h, StringComparison.Ordinal)) || (f.Off == true && f.From == h))) continue;
                out_.Add(new LineFix(h, t.Word));
            }
        return out_;
    }

    void Set(IReadOnlyList<LineFix> fixes, string lineId, string id)
    {
        if (Line(id, lineId) is not { } l || fixes.SequenceEqual(l.Fixes ?? [])) return;
        store.SetFixes(id, lineId, fixes);
    }

    // MARK: 待确认

    /// 待确认 in a meeting: each (from → to) once, oldest first.
    public List<(TranscriptLine Line, LineFix Fix)> Pending(string id)
    {
        var seen = new HashSet<string>();
        var out_ = new List<(TranscriptLine, LineFix)>();
        foreach (var l in store.Get(id)?.Lines.ToList() ?? [])
            foreach (var f in l.Fixes ?? [])
                if (f.Ask == true && seen.Add(KeyOf(f))) out_.Add((l, f));
        return out_;
    }

    /// What the notes window's card asks now: not what was put off (稍后再看), and only the first
    /// few, so a burst of names doesn't keep the card up all meeting.
    public (TranscriptLine Line, LineFix Fix, int Position, int Of)? Asking(string id)
    {
        HashSet<string> later;
        lock (gate) later = [.. deferred];
        var open = Pending(id).Where(p => !later.Contains(KeyOf(p.Fix))).ToList();
        if (open.Count == 0) return null;
        return (open[0].Line, open[0].Fix, 1, Math.Min(open.Count, AskAtOnce));
    }

    /// The card's ×: asked again only after the meeting.
    public void Later(LineFix fix, string id)
    {
        lock (gate)
        {
            Remember(id, []);
            deferred.Add(KeyOf(fix));
        }
        Say(Strings.L("已收进人名和术语，稍后再看"));
    }

    /// 对 / 不对 on a waiting fix: every line in the meeting waiting on the same change follows,
    /// and a yes goes into the word list so the next meeting fixes it without asking.
    public void Answer(LineFix fix, bool yes, string id)
    {
        var c = Correction.Core(fix.From, fix.To);
        lock (gate)
        {
            if (store.Get(id) is not { } s) return;
            bool Waiting(LineFix f) => f.Ask == true && Correction.Core(f.From, f.To) == c;
            var touched = s.Lines.Where(l => (l.Fixes ?? []).Any(Waiting)).ToList();
            var others = yes ? s.Lines.Where(l => l.Src.Contains(c.From, StringComparison.Ordinal) && !touched.Contains(l)).ToList() : [];
            Remember(id, touched.Concat(others).Select(l => l.Id));
            foreach (var l in touched)
                Set((l.Fixes ?? []).Select(f => Waiting(f) ? f with { Ask = null, User = yes ? true : f.User, Off = yes ? f.Off : true } : f).ToList(), l.Id, id);
            if (yes)
            {
                Vocabulary.Confirm(c.From, c.To);
                // The rest of the meeting heard the same way follows now, not with the next line.
                if (settings.FixMisheard)
                    foreach (var l in others)
                        if (Line(id, l.Id) is { } now) Set(Known(now.Src, now.Fixes ?? []), l.Id, id);
            }
            else refused.Add(Pair(c.From, c.To));
        }
        Log.Debug($"fix answered {(yes ? "yes" : "no")}");
        Say(yes ? Strings.LF("已改 %@ → %@，记进词表", c.From, c.To) : Strings.LF("这场不再问 %@", c.From));
    }

    /// 改回: this line goes back to what was heard, and the meeting stops making this change.
    public void Revert(LineFix fix, string lineId, string id)
    {
        var c = Correction.Core(fix.From, fix.To);
        lock (gate)
        {
            if (Line(id, lineId) is not { Fixes: { } fixes }) return;
            // The one still on: an earlier, already undone copy of the same change may sit before it.
            int k = fixes.FindIndex(f => f.From == fix.From && f.To == fix.To && f.Applied);
            if (k < 0) k = fixes.FindIndex(f => f.From == fix.From && f.To == fix.To);
            if (k < 0) return;
            Remember(id, [lineId]);
            var now = fixes.ToList();
            now[k] = now[k] with { Off = true, Ask = null, User = null };
            Set(now, lineId, id);
            refused.Add(Pair(c.From, c.To));
            refused.Add(Pair(fix.From, fix.To));
            var key = Pair(c.From, c.To);
            refusals[key] = refusals.GetValueOrDefault(key) + 1;
            if (refusals[key] >= 2) Vocabulary.Forget(c.From, c.To);
        }
        Log.Debug($"fix reverted line={lineId}");
        Say(Strings.LF("已改回 %@，这场不再改", Correction.Label(fix).From));
    }

    // MARK: 改这句…

    /// How many lines of the meeting the same edit would change ("整场听成 木娜 的 2 处都改").
    /// An edit that only adds or drops words stays on its line (count 1, nothing to learn).
    public (string Heard, int Count, bool Swap)? SameHeard(string lineId, string id, string edited)
    {
        if (store.Get(id) is not { } s || s.Lines.FirstOrDefault(l => l.Id == lineId) is not { } l
            || Correction.UserEdit(l.Shown, edited, l.Src, l.Fixes ?? []) is not { } e) return null;
        var n = e.Swap ? s.Lines.Count(x => x.Shown.Contains(e.Fix.From, StringComparison.Ordinal)) : 1;
        return (e.Heard, Math.Max(1, n), e.Swap);
    }

    /// The user rewrote a line (改这句…): what changed becomes their own fix, on this line or on
    /// every line showing the same words, and with `remember` the heard form joins the word list.
    public int Edit(string lineId, string id, string edited, bool everywhere, bool remember)
    {
        int count;
        string heard, to;
        bool learned;
        lock (gate)
        {
            if (store.Get(id) is not { } s || s.Lines.FirstOrDefault(l => l.Id == lineId) is not { } l
                || Correction.UserEdit(l.Shown, edited, l.Src, l.Fixes ?? []) is not { } e) return 0;
            everywhere = everywhere && e.Swap;
            var targets = everywhere ? s.Lines.Where(x => x.Shown.Contains(e.Fix.From, StringComparison.Ordinal)).ToList() : [l];
            Remember(id, targets.Select(t => t.Id));
            foreach (var t in targets)
            {
                // A guess still waiting on the same words is answered by the edit: not that.
                // The same change made again replaces any earlier copy (say, one undone with 改回).
                var fixes = (t.Fixes ?? []).Where(f => !(f.From == e.Fix.From && f.To == e.Fix.To)).Select(f => f.Ask == true && (f.From.Contains(e.Heard, StringComparison.Ordinal) || e.Heard.Contains(f.From, StringComparison.Ordinal))
                    ? f with { Ask = null, Off = true } : f).ToList();
                Set([.. fixes, e.Fix], t.Id, id);
            }
            count = targets.Count;
            heard = e.Heard;
            to = Correction.Core(e.Fix.From, e.Fix.To).To.Trim();
            // Only a change made everywhere teaches the word list (a one-off must not), and only a
            // word for a word (`Vocabulary.Learnable`).
            learned = remember && everywhere && Vocabulary.Learnable(heard, to) is not null;
            if (learned) Vocabulary.Confirm(heard, to, "user");
            // A swap reads as the words swapped; an added or dropped word as the span it changed
            // ("in → in now", not "in → now").
            if (!e.Swap) (heard, to) = (e.Fix.From, e.Fix.To);
        }
        Log.Debug($"fix edited lines={count} learned={learned}");
        Say(learned ? Strings.LF("已改 %lld 处：%@ → %@，记进词表", count, heard, to) : Strings.LF("已改 %lld 处：%@ → %@", count, heard, to));
        return count;
    }

    // MARK: 撤销

    void Remember(string id, IEnumerable<string> lines)
    {
        var s = store.Get(id);
        var before = new Dictionary<string, List<LineFix>>();
        foreach (var lid in lines) before[lid] = s?.Lines.FirstOrDefault(l => l.Id == lid)?.Fixes?.ToList() ?? [];
        undo.Add(new Step(id, before, Vocabulary.Terms, [.. refused], [.. deferred]));
        if (undo.Count > 20) undo.RemoveAt(0);
    }

    public bool CanUndo { get { lock (gate) return undo.Count > 0; } }

    public void Undo()
    {
        lock (gate)
        {
            if (undo.Count == 0) return;
            var step = undo[^1];
            undo.RemoveAt(undo.Count - 1);
            foreach (var (lid, fixes) in step.Lines) store.SetFixes(step.Session, lid, fixes);
            Vocabulary.Restore(step.Words);
            refused = step.Refused;
            deferred = step.Deferred;
            Toast = null;
        }
        Log.Debug("fix undone");
        Changed?.Invoke();
    }

    void Say(string text)
    {
        lock (gate)
        {
            var note = new Note(++toastIds, text);
            Toast = note;
            toastTimer?.Dispose();
            toastTimer = new Timer(_ =>
            {
                lock (gate) { if (Toast != note) return; Toast = null; }
                Changed?.Invoke();
            }, null, 6000, Timeout.Infinite);
        }
        Changed?.Invoke();
    }
}
