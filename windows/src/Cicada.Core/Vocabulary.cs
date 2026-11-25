using System.Globalization;
using System.Text;
using System.Text.Json.Serialization;

namespace Cicada;

/// 词表: the spellings the user stands behind, and how speech recognition has misheard each. Only
/// these let a new name be fixed without asking: names the notes guess are often wrong, so they
/// stay suggestions until the user confirms one. One JSON file beside the records
/// (vocabulary.json, the Mac's format); not a secret, so not one of the key files. Thread-safe.
public sealed class Vocabulary
{
    public sealed class Term
    {
        [JsonPropertyName("fixes")] public int Fixes { get; set; }
        /// Wrong forms the recognizer produced, as confirmed or typed by the user.
        [JsonPropertyName("heard")] public List<string> Heard { get; set; } = [];
        /// "user" (added or imported), "live" (confirmed during a meeting).
        [JsonPropertyName("source")] public string Source { get; set; } = "user";
        [JsonPropertyName("used")] public DateTimeOffset? Used { get; set; }
        [JsonPropertyName("word")] public string Word { get; set; } = "";

        public Term Clone() => new() { Fixes = Fixes, Heard = [.. Heard], Source = Source, Used = Used, Word = Word };
    }

    /// More would make every sentence's request long, and more terms means more wrong swaps.
    public const int Limit = 300;

    readonly object gate = new();
    List<Term> terms = [];
    readonly string? path;
    public event Action? Changed;

    public Vocabulary(string? path)
    {
        this.path = path;
        try
        {
            if (path is not null && File.Exists(path) && Json.Read<List<Term>>(File.ReadAllText(path)) is { } saved) terms = saved;
        }
        catch (Exception e) { Log.Debug($"vocab: unreadable ({e.GetType().Name})"); }
    }

    public static string DefaultPath => Path.Combine(Paths.Root, "vocabulary.json");

    /// A copy of the list, in its order.
    public List<Term> Terms { get { lock (gate) return terms.Select(t => t.Clone()).ToList(); } }

    /// Same word whatever its width, case or spacing ("ＡＡＶＥ" is "aave").
    public static string Key(string s) =>
        string.Join(" ", s.Normalize(NormalizationForm.FormKC).ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    Term? Find(string word) { var w = Key(word); return terms.FirstOrDefault(t => Key(t.Word) == w); }

    public bool Knows(string heard, string word)
    {
        var h = Key(heard);
        lock (gate) return Find(word) is { } t && t.Heard.Any(x => Key(x) == h);
    }

    /// What a fix can teach the list, or null: both sides trimmed of spaces and punctuation, no
    /// punctuation inside, short, and a real swap. An edit that only adds or drops words around the
    /// heard ones ("我来" → "OK我来") or ends on a full stop ("持。" → "讲。") teaches nothing.
    public static (string Heard, string Word)? Learnable(string heard, string word)
    {
        static bool Edge(Rune r) => Rune.IsWhiteSpace(r) || Rune.IsPunctuation(r) || Rune.IsSymbol(r);
        static string Trim(string s)
        {
            var r = s.EnumerateRunes().ToList();
            int a = 0, b = r.Count;
            while (a < b && Edge(r[a])) a++;
            while (b > a && Edge(r[b - 1])) b--;
            return string.Concat(r.Skip(a).Take(b - a).Select(x => x.ToString()));
        }
        var h = Trim(heard); var w = Trim(word);
        if (h.Length == 0 || w.Length == 0 || new StringInfo(h).LengthInTextElements > 20 || new StringInfo(w).LengthInTextElements > 40
            || Key(h) == Key(w) || w.Contains(h, StringComparison.Ordinal) || h.Contains(w, StringComparison.Ordinal)
            || h.EnumerateRunes().Any(Rune.IsPunctuation)
            || w.EnumerateRunes().Any(r => Rune.IsPunctuation(r) && r.Value != '.' && r.Value != '-')) return null;
        return (h, w);
    }

    /// The user said yes to a fix (or added it): the word, and the form it was heard as. A pair
    /// that isn't a word for a word (`Learnable`) adds the word only, or nothing. A yes in a meeting
    /// never teaches a translation (平台 → platform): it would rewrite that word everywhere after.
    public void Confirm(string heard, string word, string source = "live")
    {
        if (heard.Length > 0)
        {
            if (Learnable(heard, word) is not { } l || (source != "user" && Correction.Translation(l.Heard, l.Word))) return;
            (heard, word) = l;
        }
        lock (gate)
        {
            if (Find(word) is { } t)
            {
                if (heard.Length > 0 && !t.Heard.Any(x => Key(x) == Key(heard))) t.Heard.Add(heard);
            }
            else terms.Add(new Term { Word = word, Heard = heard.Length == 0 ? [] : [heard], Source = source });
        }
        Save();
    }

    /// A heard form the user turned down twice stops being one.
    public void Forget(string heard, string word)
    {
        lock (gate)
        {
            if (Find(word) is not { } t) return;
            t.Heard.RemoveAll(x => Key(x) == Key(heard));
        }
        Save();
    }

    /// 词表 › click a word: its spelling changes; what it was heard as stays with it.
    public void Rename(string word, string to)
    {
        var n = to.Trim();
        lock (gate)
        {
            if (n.Length == 0 || Correction.Length(n) > 40 || Find(word) is not { } t) return;
            if (Find(n) is { } other && other != t)
            {
                // Renamed onto a word already there: the two become one.
                foreach (var h in t.Heard) if (!other.Heard.Any(x => Key(x) == Key(h))) other.Heard.Add(h);
                terms.Remove(t);
            }
            else t.Word = n;
        }
        Save();
    }

    /// The other words a heard form already belongs to ("莫拉" is Morpho's).
    public List<string> Owners(string heard, string? except = null)
    {
        lock (gate)
            return terms.Where(t => t.Heard.Any(x => Key(x) == Key(heard)) && Key(t.Word) != Key(except ?? "")).Select(t => t.Word).ToList();
    }

    /// Back where it was, after 撤销 on a delete.
    public void Insert(Term term, int index)
    {
        lock (gate)
        {
            if (Find(term.Word) is not null) return;
            terms.Insert(Math.Min(index, terms.Count), term.Clone());
        }
        Save();
    }

    /// 撤销: the list as it was.
    public void Restore(List<Term> saved)
    {
        lock (gate) terms = saved.Select(t => t.Clone()).ToList();
        Save();
    }

    public void Remove(string word)
    {
        lock (gate) terms.RemoveAll(t => Key(t.Word) == Key(word));
        Save();
    }

    public void Use(string word, DateTimeOffset? at = null)
    {
        lock (gate)
        {
            if (Find(word) is not { } t) return;
            t.Fixes++;
            t.Used = at ?? DateTimeOffset.Now;
        }
        Save();
    }

    /// For the request: the most recently useful first, "Morpho (heard as 莫拉, 莫法)".
    public List<string> PromptLines()
    {
        lock (gate)
            return terms.OrderByDescending(t => t.Used ?? DateTimeOffset.MinValue).Take(Limit)
                .Select(t => t.Heard.Count == 0 ? t.Word : $"{t.Word} (heard as {string.Join(", ", t.Heard)})").ToList();
    }

    /// 粘贴导入: one per line, heard forms after "=" ("Morpho = 莫拉、莫法"). Lines too long or empty
    /// are reported by number; a word already there gains the new heard forms.
    public sealed record ImportResult(int Added, int Updated, List<int> Skipped)
    {
        public override string ToString() => $"added={Added} updated={Updated} skipped=[{string.Join(",", Skipped)}]";
    }

    public static List<(int Line, string Word, List<string> Heard)> Parse(string text)
    {
        var out_ = new List<(int, string, List<string>)>();
        var lines = text.Replace("\r\n", "\n").Split('\n', '\r', '\u2028', '\u2029', '\u0085');
        for (int i = 0; i < lines.Length; i++)
        {
            var line = lines[i].Trim(' ', '\t', '　', ' ');
            if (line.Length == 0) continue;
            var parts = line.Split('=', 2).Select(p => p.Trim(' ', '\t', '　', ' ')).ToArray();
            var word = parts[0];
            var heard = parts.Length > 1
                ? parts[1].Split(['、', ',', '，', ';', '；']).Select(h => h.Trim(' ', '\t', '　', ' ')).Where(h => h.Length > 0).ToList()
                : [];
            if (word.Length == 0 || Correction.Length(word) > 40 || word.Any(char.IsControl)) { out_.Add((i + 1, "", [])); continue; }
            out_.Add((i + 1, word, heard));
        }
        return out_;
    }

    /// What 粘贴导入 would do, before it does it (the sheet's counts and its button).
    public ImportResult Preview(string text)
    {
        int added = 0, updated = 0;
        var skipped = new List<int>();
        var seen = new HashSet<string>();
        lock (gate)
            foreach (var (line, word, _) in Parse(text))
            {
                if (word.Length == 0) { skipped.Add(line); continue; }
                var k = Key(word);
                if (Find(word) is not null || seen.Contains(k)) updated++; else added++;
                seen.Add(k);
            }
        return new ImportResult(added, updated, skipped);
    }

    public ImportResult Import(string text)
    {
        int added = 0, updated = 0;
        var skipped = new List<int>();
        lock (gate)
            foreach (var (line, word, heard) in Parse(text))
            {
                if (word.Length == 0) { skipped.Add(line); continue; }
                if (Find(word) is { } t)
                {
                    foreach (var h in heard) if (!t.Heard.Any(x => Key(x) == Key(h))) t.Heard.Add(h);
                    updated++;
                }
                else { terms.Add(new Term { Word = word, Heard = heard, Source = "user" }); added++; }
            }
        Save();
        return new ImportResult(added, updated, skipped);
    }

    void Save()
    {
        Changed?.Invoke();
        if (path is null) return;
        string json;
        lock (gate) json = Json.Write(terms);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, json, new UTF8Encoding(false));
            File.Move(tmp, path, overwrite: true);
        }
        catch (Exception e) { Log.Debug($"vocab: save failed {e.GetType().Name}"); }
    }
}
