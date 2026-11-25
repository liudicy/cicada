using System.Globalization;
using System.Text;

namespace Cicada;

/// UI text. The Chinese text is the key, as on the Mac, and the translations are the Mac's own
/// `Resources/{en,ja,ko}.lproj/Localizable.strings`, copied next to the app at build time, plus
/// `windows/src/Cicada/Strings/*.lproj/Windows.strings` for text only the Windows app has, and the
/// Mac's `Localizable.stringsdict` for plurals ("1 line", "2 lines"). Placeholders are the Mac's
/// `%@`, filled in order. Never for prompts, logs or stored values.
public static class Strings
{
    static Dictionary<string, string> table = [];
    static Dictionary<string, Plural> plurals = [];

    /// A stringsdict entry: the format with `%#@n@` placeholders, and each variable's forms by
    /// plural category ("one", "other").
    public sealed record Plural(string Format, Dictionary<string, Dictionary<string, string>> Forms);
    public static string Language { get; private set; } = "zh-Hans";
    /// Dates in the app's language, not Windows': English Cicada on Chinese Windows writes "Nov 4".
    public static CultureInfo Culture { get; private set; } = CultureInfo.GetCultureInfo("zh-CN");

    /// Loads the table for `language` ("en", "ja", "ko"; anything else is Chinese) from
    /// `folder`/<lang>.lproj/Localizable.strings.
    public static void Load(string folder, string? language = null) =>
        Load(path => File.Exists(Path.Combine(folder, path)) ? File.ReadAllText(Path.Combine(folder, path), Encoding.UTF8) : null, language);

    /// The same from `read("<lang>.lproj/<name>")`: the app reads the tables from inside its exe,
    /// so the installer is one file that already speaks the user's language.
    public static void Load(Func<string, string?> read, string? language = null)
    {
        var ui = language ?? CultureInfo.CurrentUICulture.Name;
        var head = ui.Split('-')[0];
        Language = head is "en" or "ja" or "ko" ? head : "zh-Hans";
        Culture = CultureInfo.GetCultureInfo(Language switch { "en" => "en-US", "ja" => "ja-JP", "ko" => "ko-KR", _ => "zh-CN" });
        // The Mac's table, then the Windows-only strings over it (Windows.strings, same format).
        table = [];
        foreach (var name in new[] { "Localizable.strings", "Windows.strings" })
        {
            if (read($"{Language}.lproj/{name}") is not { } text) continue;
            foreach (var (k, v) in Parse(text)) table[k] = v;
        }
        plurals = read($"{Language}.lproj/Localizable.stringsdict") is { } dict ? ParsePlurals(dict) : [];
    }

    /// Only English has more than one form among the app's languages: "one" for exactly 1.
    static string Category(object? n) =>
        Language == "en" && n is IConvertible c && c.ToDouble(CultureInfo.InvariantCulture) == 1 ? "one" : "other";

    public static string L(string key) => table.TryGetValue(key, out var v) && v.Length > 0 ? v : key;

    /// L() with the Mac's `%@` placeholders: LF("纪要停留在 %@。", clock). A key in the stringsdict
    /// takes its plural form for the number: `%#@n@` (or `%2$#@n@`) becomes variable n's "one" or
    /// "other" text.
    public static string LF(string key, params object[] args)
    {
        var plural = plurals.GetValueOrDefault(key);
        var text = plural?.Format ?? L(key);
        var b = new StringBuilder();
        int next = 0;
        for (int i = 0; i < text.Length; i++)
        {
            // %#@n@ or %2$#@n@: the variable's form for its number, with the number in it.
            int j = i + 1;
            int? position = null;
            if (plural is not null && text[i] == '%' && j + 1 < text.Length && char.IsDigit(text[j]) && text[j + 1] == '$') { position = text[j] - '1'; j += 2; }
            if (plural is not null && text[i] == '%' && j + 1 < text.Length && text[j] == '#' && text[j + 1] == '@' && text.IndexOf('@', j + 2) is var end && end > 0)
            {
                int at = position ?? next++;
                var n = at >= 0 && at < args.Length ? args[at] : null;
                var forms = plural.Forms.GetValueOrDefault(text[(j + 2)..end]) ?? [];
                var form = forms.GetValueOrDefault(Category(n)) ?? forms.GetValueOrDefault("other") ?? "";
                b.Append(form.Replace("%lld", $"{n}").Replace("%ld", $"{n}").Replace("%d", $"{n}"));
                i = end;
            }
            else if (text[i] == '%' && i + 1 < text.Length && text[i + 1] == '@')
            {
                b.Append(next < args.Length ? args[next++] : "");
                i++;
            }
            // The Mac's integer placeholders (Swift interpolation of an Int becomes %lld).
            else if (text[i] == '%' && i + 3 < text.Length && text.AsSpan(i + 1, 3) is "lld")
            {
                b.Append(next < args.Length ? args[next++] : "");
                i += 3;
            }
            else if (text[i] == '%' && i + 2 < text.Length && char.IsDigit(text[i + 1]) && text[i + 2] == '$' && i + 3 < text.Length && text[i + 3] == '@')
            {
                int n = text[i + 1] - '1';
                b.Append(n >= 0 && n < args.Length ? args[n] : "");
                i += 3;
            }
            // A numbered integer: "All %2$lld places heard as %1$@".
            else if (text[i] == '%' && i + 5 < text.Length && char.IsDigit(text[i + 1]) && text[i + 2] == '$' && text.AsSpan(i + 3, 3) is "lld")
            {
                int n = text[i + 1] - '1';
                b.Append(n >= 0 && n < args.Length ? args[n] : "");
                i += 5;
            }
            // A percent sign, written %% in a format ("正在下载 %@：%lld%%").
            else if (text[i] == '%' && i + 1 < text.Length && text[i + 1] == '%') { b.Append('%'); i++; }
            else b.Append(text[i]);
        }
        return b.ToString();
    }

    /// The Mac's Localizable.stringsdict (an XML plist of dicts and strings) as key → Plural. A
    /// small reader of its own: XmlReader refuses the plist's DOCTYPE unless told to skip DTDs.
    public static Dictionary<string, Plural> ParsePlurals(string xml)
    {
        int i = 0;
        string? Tag()
        {
            while (true)
            {
                int a = xml.IndexOf('<', i); if (a < 0) return null;
                int e = xml.IndexOf('>', a); if (e < 0) return null;
                i = e + 1;
                var t = xml[(a + 1)..e].Trim();
                if (!t.StartsWith('?') && !t.StartsWith('!')) return t;
            }
        }
        string Text(string close)
        {
            int e = xml.IndexOf(close, i); if (e < 0) e = xml.Length;
            var t = xml[i..e]; i = Math.Min(xml.Length, e + close.Length);
            return t.Replace("&lt;", "<").Replace("&gt;", ">").Replace("&quot;", "\"").Replace("&apos;", "'").Replace("&amp;", "&");
        }
        Dictionary<string, object> Dict()
        {
            var m = new Dictionary<string, object>();
            while (Tag() is { } t && t != "/dict")
            {
                if (t != "key") continue;
                var k = Text("</key>");
                switch (Tag())
                {
                    case "dict": m[k] = Dict(); break;
                    case "string": m[k] = Text("</string>"); break;
                    case "string/": m[k] = ""; break;
                }
            }
            return m;
        }
        var result = new Dictionary<string, Plural>();
        while (Tag() is { } t) if (t == "dict") break;
        foreach (var (key, v) in Dict())
        {
            if (v is not Dictionary<string, object> entry || entry.GetValueOrDefault("NSStringLocalizedFormatKey") is not string format) continue;
            var forms = entry.Where(e => e.Value is Dictionary<string, object>).ToDictionary(
                e => e.Key, e => ((Dictionary<string, object>)e.Value).Where(f => f.Value is string).ToDictionary(f => f.Key, f => (string)f.Value));
            result[key] = new Plural(format, forms);
        }
        return result;
    }

    /// `"key" = "value";` lines, with /* */ and // comments and \" \\ \n escapes.
    public static Dictionary<string, string> Parse(string text)
    {
        var result = new Dictionary<string, string>();
        int i = 0;
        string? ReadString()
        {
            while (i < text.Length)
            {
                if (text[i] == '"') break;
                if (text[i] == '/' && i + 1 < text.Length && text[i + 1] == '*') { i = text.IndexOf("*/", i + 2) is var e && e < 0 ? text.Length : e + 2; continue; }
                if (text[i] == '/' && i + 1 < text.Length && text[i + 1] == '/') { i = text.IndexOf('\n', i) is var e && e < 0 ? text.Length : e + 1; continue; }
                if (text[i] == ';' || text[i] == '=' || char.IsWhiteSpace(text[i])) { i++; continue; }
                i++;
            }
            if (i >= text.Length) return null;
            i++;
            var b = new StringBuilder();
            while (i < text.Length && text[i] != '"')
            {
                if (text[i] == '\\' && i + 1 < text.Length)
                {
                    i++;
                    b.Append(text[i] switch { 'n' => '\n', 't' => '\t', _ => text[i] });
                }
                else b.Append(text[i]);
                i++;
            }
            i++;
            return b.ToString();
        }
        while (true)
        {
            var key = ReadString();
            if (key is null) break;
            var value = ReadString();
            if (value is null) break;
            result[key] = value;
        }
        return result;
    }
}
