namespace Cicada;

/// Searching a meeting's lines (the Mac's TranscriptSearch.swift): the records' Ctrl+F finds the
/// same lines as on the Mac, misheard names included, and marks them the same way (#33).
public static class TranscriptSearch
{
    // Ordinal: a match is exactly as long as its term, so the marks land on it.
    const StringComparison Fold = StringComparison.OrdinalIgnoreCase;

    /// The query, plus every way the notes say that name was heard (江充 also finds 江松).
    public static List<string> Terms(string query, IEnumerable<NoteTerm>? notes)
    {
        var q = query.Trim();
        if (q.Length == 0) return [];
        var output = new List<string> { q };
        foreach (var t in notes ?? [])
        {
            var forms = new[] { t.Name }.Concat(t.Heard).ToList();
            if (forms.Any(f => f.Length > 0 && (f.Contains(q, Fold) || q.Contains(f, Fold))))
                output.AddRange(forms.Where(f => f.Length > 0 && !output.Contains(f)).Distinct());
        }
        return output;
    }

    public static bool Matches(TranscriptLine l, IReadOnlyList<string> terms) =>
        terms.Any(t => l.Shown.Contains(t, Fold) || (l.Dst?.Contains(t, Fold) ?? false));

    /// The ids of the lines a search finds, in order.
    public static List<string> Matches(IEnumerable<TranscriptLine> lines, IReadOnlyList<string> terms) =>
        terms.Count == 0 ? [] : lines.Where(l => Matches(l, terms)).Select(l => l.Id).ToList();

    /// Where the terms are in `text`, as (start, length) spans in order, overlaps merged: the
    /// parts to mark.
    public static List<(int Start, int Length)> Spans(string text, IReadOnlyList<string> terms)
    {
        var marked = new bool[text.Length];
        foreach (var term in terms)
        {
            if (term.Length == 0) continue;
            for (int from = 0; from < text.Length;)
            {
                var at = text.IndexOf(term, from, Fold);
                if (at < 0) break;
                for (int i = at; i < at + term.Length && i < marked.Length; i++) marked[i] = true;
                from = at + Math.Max(1, term.Length);
            }
        }
        var spans = new List<(int, int)>();
        for (int i = 0; i < marked.Length; i++)
        {
            if (!marked[i]) continue;
            int start = i;
            while (i < marked.Length && marked[i]) i++;
            spans.Add((start, i - start));
        }
        return spans;
    }
}
