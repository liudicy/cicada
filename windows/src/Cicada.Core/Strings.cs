using System.Globalization;
using System.Text;

namespace Cicada;

/// UI text. The Chinese text is the key, as on the Mac, and the translations are the Mac's own
/// `Resources/{en,ja,ko}.lproj/Localizable.strings`, copied next to the app at build time, plus
/// `windows/src/Cicada/Strings/*.lproj/Windows.strings` for text only the Windows app has.
/// Placeholders are the Mac's `%@`, filled in order. Never for prompts, logs or stored values.
public static class Strings
{
    static Dictionary<string, string> table = [];
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
    }

    public static string L(string key) => table.TryGetValue(key, out var v) && v.Length > 0 ? v : key;

    /// L() with the Mac's `%@` placeholders: LF("纪要停留在 %@。", clock).
    public static string LF(string key, params object[] args)
    {
        var text = L(key);
        var b = new StringBuilder();
        int next = 0;
        for (int i = 0; i < text.Length; i++)
        {
            if (text[i] == '%' && i + 1 < text.Length && text[i + 1] == '@')
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
            else b.Append(text[i]);
        }
        return b.ToString();
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
