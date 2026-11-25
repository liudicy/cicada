using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using static Cicada.Strings;

namespace Cicada.App;

/// 改正听错的词's pieces, shared by the notes window and the meeting record (the Mac's FixViews.swift
/// and NotesViews.swift › FixedWords, FixConfirmCard, joinFixed): the line with its fixed words
/// underlined, what each was heard as with 改回, the 这样改对吗？ card, the banner over a finished
/// meeting, and the toast with 撤销.
static class FixViews
{
    static readonly SolidColorBrush ChipFill = Frozen(0xF2, 0xF3, 0xF5);
    static SolidColorBrush Frozen(byte r, byte g, byte b) { var x = new SolidColorBrush(Color.FromRgb(r, g, b)); x.Freeze(); return x; }

    static readonly TextDecorationCollection Dotted = MakeDotted();
    static TextDecorationCollection MakeDotted()
    {
        var pen = new Pen(Palette.Tertiary, 1.2) { DashStyle = new DashStyle([1, 2], 0), DashCap = PenLineCap.Round };
        pen.Freeze();
        var c = new TextDecorationCollection { new TextDecoration(TextDecorationLocation.Underline, pen, 2, TextDecorationUnit.FontRecommended, TextDecorationUnit.Pixel) };
        c.Freeze();
        return c;
    }

    /// The line as shown, each fixed word with a dotted underline; words waiting for the user
    /// (这样改对吗？) on a pale wash, as heard.
    public static TextBlock LineText(TranscriptLine l, double size, Brush color)
    {
        var t = Ui.Text("", size, color);
        var (text, marks) = Correction.Apply(l.Fixes ?? [], l.Src);
        var style = new byte[text.Length];
        foreach (var (start, length) in marks) for (int i = start; i < start + length && i < style.Length; i++) style[i] = 1;
        foreach (var f in l.Fixes ?? [])
            if (f.Ask == true && f.From.Length > 0 && text.IndexOf(f.From, StringComparison.Ordinal) is var at and >= 0)
                for (int i = at; i < at + f.From.Length; i++) if (style[i] == 0) style[i] = 2;
        int from = 0;
        for (int i = 1; i <= text.Length; i++)
        {
            if (i < text.Length && style[i] == style[from]) continue;
            var run = new Run(text[from..i]);
            if (style[from] == 1) run.TextDecorations = Dotted;
            else if (style[from] == 2) run.Background = Palette.AccentPale;
            t.Inlines.Add(run);
            from = i;
        }
        return t;
    }

    /// The records' search (#33, TranscriptSearch.highlighted on the Mac): every term in `t` on the
    /// pale accent; in the match being looked at, solid accent with white text. The runs are split
    /// where a mark starts or ends, keeping their own look (a fixed word's underline) otherwise.
    public static T Mark<T>(T t, IReadOnlyList<string> terms, bool current) where T : TextBlock
    {
        if (terms.Count == 0) return t;
        var runs = t.Inlines.OfType<Run>().ToList();
        if (runs.Count == 0 || runs.Count != t.Inlines.Count) return t;
        var text = string.Concat(runs.Select(r => r.Text));
        var spans = TranscriptSearch.Spans(text, terms);
        if (spans.Count == 0) return t;
        var marked = new bool[text.Length];
        foreach (var (start, length) in spans) for (int i = start; i < start + length; i++) marked[i] = true;
        t.Inlines.Clear();
        int at = 0;
        foreach (var r in runs)
        {
            int end = at + r.Text.Length;
            for (int from = at; from < end;)
            {
                int to = from + 1;
                while (to < end && marked[to] == marked[from]) to++;
                var piece = new Run(text[from..to]) { TextDecorations = r.TextDecorations, Background = r.Background };
                if (r.ReadLocalValue(TextElement.ForegroundProperty) != DependencyProperty.UnsetValue) piece.Foreground = r.Foreground;
                if (marked[from])
                {
                    piece.Background = current ? Palette.Live : Palette.AccentPale;
                    piece.Foreground = current ? Brushes.White : Palette.AccentText;
                }
                t.Inlines.Add(piece);
                from = to;
            }
            at = end;
        }
        return t;
    }

    /// Under a paragraph: each fixed word, what it was heard as, and 改回. `edit`: 改这句… after them
    /// (the meeting record).
    public static FrameworkElement FixedWords(TranscriptLine l, Action<LineFix> revert, Action? edit = null)
    {
        var wrap = new WrapPanel { Margin = new Thickness(0, 4, 0, 0) };
        foreach (var f in (l.Fixes ?? []).Where(f => f.Applied))
        {
            var c = Correction.Label(f);
            var words = new TextBlock { FontFamily = Palette.Font, FontSize = 11, Foreground = Palette.Ink, VerticalAlignment = VerticalAlignment.Center };
            words.Inlines.Add(new Run(L("听成")) { Foreground = Palette.Tertiary });
            words.Inlines.Add(new Run(" " + c.From));
            words.Inlines.Add(new Run(" → ") { Foreground = Palette.Tertiary });
            words.Inlines.Add(new Run(c.To));
            var back = Ui.LinkText(L("改回"), () => revert(f), 11);
            back.FontWeight = FontWeights.SemiBold;
            back.Margin = new Thickness(6, 0, 0, 0);
            wrap.Children.Add(new Border
            {
                Background = ChipFill, CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 3, 8, 3), Margin = new Thickness(0, 0, 6, 4),
                Child = Ui.Row(0, words, back),
            });
        }
        if (edit is not null)
        {
            var link = Ui.LinkText(L("改这句…"), edit, 11);
            link.FontWeight = FontWeights.SemiBold;
            link.VerticalAlignment = VerticalAlignment.Center;
            link.Margin = new Thickness(2, 0, 0, 4);
            wrap.Children.Add(link);
        }
        return wrap;
    }

    /// 这样改对吗？: a name sound couldn't check, asked about once. Clicks only: the notes window
    /// never takes focus. 对 fixes every line waiting on it and adds it to the word list; × puts it
    /// off until after the meeting (稍后再看).
    public static FrameworkElement ConfirmCard(TranscriptLine line, LineFix fix, int count, Action<bool> answer, Action? later)
    {
        var c = Correction.Label(fix);
        var head = new DockPanel();
        if (count > 1)
        {
            var n = Ui.Text($"1 / {count}", 12, Palette.Tertiary, wrap: false);
            DockPanel.SetDock(n, Dock.Right);
            head.Children.Add(n);
        }
        var title = Ui.Text(L("这样改对吗？"), 13, Palette.Ink, FontWeights.Bold, wrap: false);
        var hint = Ui.Text(L("确认后整场一起改，以后也这样改"), 12, Palette.Tertiary, wrap: false);
        hint.Margin = new Thickness(8, 0, 4, 0);
        head.Children.Add(Ui.Row(0, title, hint));

        var words = new TextBlock { FontFamily = Palette.Font, FontSize = 14, Foreground = Palette.Ink, TextTrimming = TextTrimming.CharacterEllipsis };
        words.Inlines.Add(new Run(c.From));
        words.Inlines.Add(new Run(" → ") { Foreground = Palette.Tertiary });
        words.Inlines.Add(new Run(c.To) { FontWeight = FontWeights.Bold });
        var where = Ui.Text($"{Languages.Clock(line.T)} · {line.Src}", 11, Palette.Tertiary, wrap: false);
        var buttons = Ui.Row(8, Small(Ui.Button(L("对"), () => answer(true), Ui.Kind.Primary, height: 28)), Small(Ui.Button(L("不对"), () => answer(false), height: 28)));
        if (later is not null)
        {
            var x = Ui.IconButton(Icons.Close, L("稍后再看"), later, Palette.Tertiary, 28, 11);
            buttons.Children.Add(x);
            x.Margin = new Thickness(2, 0, 0, 0);
        }
        var body = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
        DockPanel.SetDock(buttons, Dock.Right);
        buttons.Margin = new Thickness(8, 0, 0, 0);
        body.Children.Add(buttons);
        body.Children.Add(Ui.Stack(2, words, where));
        return new Border
        {
            Background = Palette.Surface, BorderBrush = Palette.Stroke, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10),
            Padding = new Thickness(12, 10, 12, 10), Child = new StackPanel { Children = { head, body } },
        };
    }

    static Button Small(Button b) { b.MinWidth = 0; b.Padding = new Thickness(14, 0, 14, 0); return b; }

    /// Above a finished meeting's transcript: how many words were fixed, and the ones waiting for
    /// the user, one at a time (对 / 不对 / 改成…). Nothing once there was nothing to fix.
    public static FrameworkElement? Banner(Session s, LiveFixes fixes, Action<string> show, Action<TranscriptLine, string> edit)
    {
        var waiting = fixes.Pending(s.Id);
        var fixedCount = s.Lines.Sum(l => (l.Fixes ?? []).Count(f => f.Applied));
        if (waiting.Count == 0)
            return fixedCount > 0 ? Ui.Text(LF("改了 %lld 处听错的词", fixedCount), 12, Palette.Tertiary) : null;
        var (line, fix) = waiting[0];
        var c = Correction.Label(fix);
        var title = Ui.Text(LF("改了 %lld 处听错的词，%lld 处等你确认", fixedCount, waiting.Count), 13, Palette.Ink, FontWeights.SemiBold);
        var what = new TextBlock { FontFamily = Palette.Font, FontSize = 12, Foreground = Palette.Secondary };
        what.Inlines.Add(new Run($"{c.From} → {c.To}？"));
        what.Inlines.Add(new Run($" · {Languages.Clock(line.T)}") { Foreground = Palette.Tertiary });
        var text = Ui.Stack(2, title, what);
        text.Cursor = Cursors.Hand;
        text.Background = Brushes.Transparent;
        text.MouseLeftButtonUp += (_, _) => show(line.Id);
        var buttons = Ui.Row(8,
            Small(Ui.Button(L("对"), () => fixes.Answer(fix, true, s.Id), Ui.Kind.Primary, height: 30)),
            Small(Ui.Button(L("不对"), () => fixes.Answer(fix, false, s.Id), Ui.Kind.Subtle, height: 30)),
            Small(Ui.Button(L("改成…"), () => edit(line, Correction.Apply((line.Fixes ?? []).Where(f => f.Applied).ToList(), line.Src).Text), Ui.Kind.Subtle, height: 30)));
        var dock = new DockPanel();
        DockPanel.SetDock(buttons, Dock.Right);
        buttons.Margin = new Thickness(10, 0, 0, 0);
        dock.Children.Add(buttons);
        dock.Children.Add(text);
        return new Border
        {
            Background = AccentWash, BorderBrush = Palette.AccentPale, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12),
            Padding = new Thickness(14, 10, 14, 10), Child = dock,
        };
    }

    static readonly SolidColorBrush AccentWash = Frozen(0xFE, 0xF6, 0xF3);

    /// The last fix decision said back for a few seconds, with 撤销 (null when there is none).
    public static FrameworkElement? Toast(LiveFixes fixes)
    {
        if (fixes.Toast is not { } t) return null;
        var row = Ui.Row(14, Ui.Text(t.Text, 13, Brushes.White, wrap: false));
        if (fixes.CanUndo)
        {
            var undo = Ui.Text(L("撤销"), 13, new SolidColorBrush(Color.FromRgb(0xFF, 0xB5, 0x9C)), FontWeights.SemiBold, wrap: false);
            undo.Cursor = Cursors.Hand;
            undo.Margin = new Thickness(14, 0, 0, 0);
            undo.MouseLeftButtonDown += (_, e) => { e.Handled = true; fixes.Undo(); };
            System.Windows.Automation.AutomationProperties.SetName(undo, L("撤销"));
            row.Children.Add(undo);
        }
        return new Border
        {
            Background = Palette.Night, CornerRadius = new CornerRadius(10), Padding = new Thickness(14, 9, 14, 9), Child = row,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom,
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 16, ShadowDepth = 4, Opacity = 0.25 },
        };
    }

    /// 改这句… in the meeting record: the line as shown, to rewrite. What changed becomes the
    /// user's own fix, on every line heard the same way or only this one; Enter applies, Esc
    /// cancels.
    public sealed class Editor : StackPanel
    {
        readonly TranscriptLine line;
        readonly string session;
        readonly LiveFixes fixes;
        readonly Action done;
        readonly TextBox box;
        readonly ContentControl options = new();
        bool everywhere = true, keep = true;

        public Editor(TranscriptLine line, string session, LiveFixes fixes, string start, Action done)
        {
            this.line = line; this.session = session; this.fixes = fixes; this.done = done;
            box = new TextBox { Text = start, FontSize = 15, TextWrapping = TextWrapping.Wrap, AcceptsReturn = false };
            System.Windows.Automation.AutomationProperties.SetName(box, L("改这句"));
            box.TextChanged += (_, _) => Options();
            box.KeyDown += (_, e) =>
            {
                if (e.Key == Key.Enter) { e.Handled = true; Apply(); }
                else if (e.Key == Key.Escape) { e.Handled = true; done(); }
            };
            Children.Add(Ui.Field(box));
            options.Margin = new Thickness(0, 8, 0, 0);
            Children.Add(options);
            var hint = Ui.Text(L("回车 改成 · esc 取消"), 11, Palette.Tertiary, wrap: false);
            hint.VerticalAlignment = VerticalAlignment.Center;
            var buttons = Ui.Row(8, Small(Ui.Button(L("取消"), done, height: 30)), Small(Ui.Button(L("改成"), Apply, Ui.Kind.Primary, height: 30)));
            var bar = Ui.Spread(hint, buttons);
            bar.Margin = new Thickness(0, 8, 0, 0);
            Children.Add(bar);
            Options();
            Loaded += (_, _) => { box.Focus(); box.CaretIndex = box.Text.Length; };
        }

        void Options()
        {
            if (fixes.SameHeard(line.Id, session, box.Text) is not { } same) { options.Content = null; return; }
            var stack = new StackPanel();
            var heard = new TextBlock { FontFamily = Palette.Font, FontSize = 12, Foreground = Palette.Ink };
            heard.Inlines.Add(new Run(L("听成") + " ") { Foreground = Palette.Tertiary });
            heard.Inlines.Add(new Run(same.Heard));
            stack.Children.Add(heard);
            if (same.Count > 1)
            {
                var all = new RadioButton { Content = LF("整场听成 %@ 的 %lld 处都改", same.Heard, same.Count), IsChecked = everywhere, FontSize = 12, Margin = new Thickness(0, 6, 0, 0), GroupName = "scope" + line.Id };
                var one = new RadioButton { Content = L("只改这一处"), IsChecked = !everywhere, FontSize = 12, Margin = new Thickness(0, 4, 0, 0), GroupName = "scope" + line.Id };
                all.Checked += (_, _) => { everywhere = true; Options(); };
                one.Checked += (_, _) => { everywhere = false; Options(); };
                stack.Children.Add(all); stack.Children.Add(one);
            }
            // Only a word for a word can teach the list: an added or dropped word can't.
            if (same.Swap)
            {
                var remember = new CheckBox { Content = L("记进词表，以后自动改"), IsChecked = keep, FontSize = 12, Margin = new Thickness(0, 6, 0, 0), IsEnabled = same.Count <= 1 || everywhere };
                remember.Checked += (_, _) => keep = true;
                remember.Unchecked += (_, _) => keep = false;
                stack.Children.Add(remember);
            }
            options.Content = stack;
        }

        void Apply()
        {
            if (fixes.SameHeard(line.Id, session, box.Text) is not { } same) { done(); return; }
            var all = same.Count > 1 ? everywhere : true;
            fixes.Edit(line.Id, session, box.Text, all, keep && all);
            done();
        }
    }
}
