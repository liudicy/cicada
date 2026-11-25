using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using static Cicada.Strings;

namespace Cicada.App;

/// 设置 › 词表 (the Mac's WordListSettings.swift): the switches for 改正听错的词, and the word list
/// itself: each word, what it has been heard as, where it came from and how often it fixed a line.
/// Everything is edited in place; changes count from the next sentence on.
sealed partial class SettingsWindow
{
    string wordQuery = "";
    /// A deleted word, shown in its place with 撤销 for a few seconds.
    (Vocabulary.Term Term, int Index)? deleted;
    DateTime deletedAt;
    /// The word whose spelling is being changed, and what was typed as a heard form per word.
    string? renaming;
    readonly Dictionary<string, string> newHeard = [];
    /// A heard form typed under a word that another word already has: whose it should be.
    (string Word, string Heard, string Owner)? conflict;

    FrameworkElement[] WordCards()
    {
        var s = app.Settings;
        var usable = app.Ling.Usable;
        FrameworkElement fixControl = usable
            ? Ui.Switch(s.FixMisheard, v => { s.FixMisheard = v; Save(); Render(); }, L("会中改正听错的词"))
            : Ui.LinkText(L("去设置"), () => { current = "ai"; Render(); });
        var ask = Ui.Switch(s.AskNames, v => { s.AskNames = v; Save(); }, L("没见过的名字和专称先问我"));
        ask.IsEnabled = s.FixMisheard && usable;
        var switches = Group(
            Card(null, L("会中改正听错的词"), usable ? LF("走 %@，只发文字", app.Ling.ServiceName) : L("接上 AI 服务后才会改"), fixControl),
            Card(null, L("没见过的名字和专称先问我"), L("关掉就只改词表里的词和同音错字"), ask));

        var terms = app.Vocabulary.Terms;
        var head = new DockPanel { Margin = new Thickness(6, 8, 0, 0) };
        var import = Ui.Button(L("粘贴导入…"), ImportWords, Ui.Kind.Primary, height: 32);
        import.MinWidth = 0;
        DockPanel.SetDock(import, Dock.Right);
        head.Children.Add(import);
        if (terms.Count > 12)
        {
            var search = new TextBox { Text = wordQuery, Width = 160 };
            System.Windows.Automation.AutomationProperties.SetName(search, L("搜索词表"));
            search.TextChanged += (_, _) => { wordQuery = search.Text; Dispatcher.BeginInvoke(() => { Render(); FocusSearch(); }); };
            var field = Ui.Field(search);
            field.Margin = new Thickness(0, 0, 10, 0);
            DockPanel.SetDock(field, Dock.Right);
            head.Children.Add(field);
        }
        var title = Ui.Text(L("词"), 13, Palette.Secondary, FontWeights.SemiBold, wrap: false);
        if (terms.Count > 0) title.Inlines.Add(new Run($"  {terms.Count}") { Foreground = Palette.Tertiary, FontWeight = FontWeights.Normal });
        title.VerticalAlignment = VerticalAlignment.Center;
        head.Children.Add(title);

        FrameworkElement list;
        if (terms.Count == 0 && deleted is null)
        {
            var empty = Ui.Text(L("还没有词。把常用的人名、产品名贴进来，会中就照这些写法改"), 12, Palette.Tertiary);
            empty.Margin = new Thickness(6, 0, 0, 0);
            list = empty;
        }
        else
        {
            var rows = new List<FrameworkElement>();
            if (deleted is { } d)
            {
                var text = new TextBlock { FontFamily = Palette.Font, FontSize = 13, Foreground = Palette.Secondary, VerticalAlignment = VerticalAlignment.Center };
                text.Inlines.Add(new Run(L("已删除") + " "));
                text.Inlines.Add(new Run(d.Term.Word) { FontWeight = FontWeights.Bold });
                var undo = Ui.LinkText(L("撤销"), () => { app.Vocabulary.Insert(d.Term, d.Index); deleted = null; Render(); }, 12);
                undo.VerticalAlignment = VerticalAlignment.Center;
                var row = Ui.Spread(text, undo);
                row.MinHeight = 40;
                rows.Add(row);
            }
            var q = Vocabulary.Key(wordQuery);
            // Most recently useful first, then the rest newest first.
            var shown = Enumerable.Reverse(terms).OrderByDescending(t => t.Used ?? DateTimeOffset.MinValue)
                .Where(t => q.Length == 0 || Vocabulary.Key(t.Word).Contains(q) || t.Heard.Any(h => Vocabulary.Key(h).Contains(q)));
            foreach (var t in shown) rows.Add(WordRow(t, terms));
            list = Group([.. rows]);
        }
        var foot = Ui.Text(LF("最多 %lld 个，满了优先用最近的。只存在这台电脑上", Vocabulary.Limit), 11, Palette.Tertiary);
        foot.Margin = new Thickness(6, 0, 0, 0);
        return [switches, head, list, foot];
    }

    void FocusSearch()
    {
        // The page is drawn again on each key: give the search box its focus back.
        var box = FindChild<TextBox>(scroll, b => System.Windows.Automation.AutomationProperties.GetName(b) == L("搜索词表"));
        if (box is not null) { box.Focus(); box.CaretIndex = box.Text.Length; }
    }

    static T? FindChild<T>(DependencyObject root, Func<T, bool> match) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var c = VisualTreeHelper.GetChild(root, i);
            if (c is T t && match(t)) return t;
            if (FindChild(c, match) is { } found) return found;
        }
        return null;
    }

    /// One word: its spelling (a click changes it), what it was heard as (× takes one off, a field
    /// adds one), where it came from, how often it fixed a line, and delete.
    FrameworkElement WordRow(Vocabulary.Term t, List<Vocabulary.Term> all)
    {
        FrameworkElement word;
        if (renaming == t.Word)
        {
            var box = new TextBox { Text = t.Word, Width = 140, FontWeight = FontWeights.SemiBold };
            void Done() { if (renaming != t.Word) return; renaming = null; app.Vocabulary.Rename(t.Word, box.Text); Render(); }
            box.KeyDown += (_, e) =>
            {
                if (e.Key == Key.Enter) { e.Handled = true; Done(); }
                else if (e.Key == Key.Escape) { e.Handled = true; renaming = null; Render(); }
            };
            box.LostKeyboardFocus += (_, _) => Done();
            box.Loaded += (_, _) => { box.Focus(); box.SelectAll(); };
            word = Ui.Field(box);
        }
        else
        {
            var w = Ui.Text(t.Word, 13, Palette.Ink, FontWeights.SemiBold, wrap: false);
            w.Width = 140; w.Cursor = Cursors.Hand; w.ToolTip = L("点一下改写法");
            w.MouseLeftButtonUp += (_, _) => { renaming = t.Word; Render(); };
            word = w;
        }
        word.VerticalAlignment = VerticalAlignment.Center;

        var heard = new WrapPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 0, 0) };
        foreach (var h in t.Heard) heard.Children.Add(HeardChip(h, () => { app.Vocabulary.Forget(h, t.Word); Render(); }));
        var add = new TextBox { Text = newHeard.GetValueOrDefault(t.Word, ""), Width = 120, FontSize = 11, MinHeight = 0, Padding = new Thickness(4, 1, 4, 1) };
        System.Windows.Automation.AutomationProperties.SetName(add, L("加一个容易听错的词"));
        var hint = Ui.Text(L("加一个容易听错的词"), 11, Palette.Tertiary, wrap: false);
        hint.IsHitTestVisible = false; hint.Margin = new Thickness(7, 0, 0, 0); hint.VerticalAlignment = VerticalAlignment.Center;
        hint.Visibility = add.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        add.TextChanged += (_, _) => { newHeard[t.Word] = add.Text; hint.Visibility = add.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; };
        add.KeyDown += (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; AddHeard(t, add.Text); } };
        var addBox = new Border
        {
            BorderBrush = Palette.FieldLine, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(5), Margin = new Thickness(0, 2, 4, 2),
            Child = new Grid { Children = { add, hint } },
            // Only while pointed at (or typed in): hidden, it would still take room and wrap the forms.
            Visibility = add.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed,
        };
        add.BorderThickness = new Thickness(0); add.Background = Brushes.Transparent;
        heard.Children.Add(addBox);

        var source = Ui.Text(t.Source == "live" ? L("会中确认") : L("你加的"), 11, t.Source == "live" ? Palette.AccentText : Palette.Tertiary, wrap: false);
        source.MinWidth = 64; source.VerticalAlignment = VerticalAlignment.Center;
        var count = Ui.Text(t.Fixes > 0 ? LF("改过 %lld 次", t.Fixes) : L("还没用上"), 11, Palette.Tertiary, wrap: false);
        count.MinWidth = 64; count.VerticalAlignment = VerticalAlignment.Center;
        var trash = Ui.IconButton(Icons.Trash, L("从词表里删掉"), () => Remove(t, all), Palette.Tertiary, 28, 13);
        trash.Opacity = 0.35;
        var right = Ui.Row(8, source, count, trash);
        var dock = new DockPanel { MinHeight = 40, Margin = new Thickness(0, 4, 0, 4), Background = Brushes.Transparent };
        DockPanel.SetDock(word, Dock.Left); DockPanel.SetDock(right, Dock.Right);
        dock.Children.Add(word); dock.Children.Add(right); dock.Children.Add(heard);
        dock.MouseEnter += (_, _) => { addBox.Visibility = Visibility.Visible; trash.Opacity = 1; };
        dock.MouseLeave += (_, _) => { if (add.Text.Length == 0 && !add.IsKeyboardFocused) addBox.Visibility = Visibility.Collapsed; trash.Opacity = 0.35; };

        if (conflict is { } c && c.Word == t.Word)
        {
            var say = Ui.Text(LF("“%@”已经记在 %@ 下", c.Heard, c.Owner), 12, Palette.Ink);
            say.VerticalAlignment = VerticalAlignment.Center;
            var move = Ui.Button(LF("改给 %@", t.Word), () =>
            {
                app.Vocabulary.Forget(c.Heard, c.Owner);
                app.Vocabulary.Confirm(c.Heard, t.Word, t.Source);
                conflict = null; Render();
            }, Ui.Kind.Primary, height: 28);
            var both = Ui.Button(L("两个都留"), () => { app.Vocabulary.Confirm(c.Heard, t.Word, t.Source); conflict = null; Render(); }, height: 28);
            move.MinWidth = both.MinWidth = 0;
            var bar = Ui.Spread(say, Ui.Row(8, both, move));
            bar.Margin = new Thickness(0, 0, 0, 10);
            return new StackPanel { Children = { dock, bar } };
        }
        return dock;
    }

    static FrameworkElement HeardChip(string text, Action remove)
    {
        var x = Ui.IconButton(Icons.Close, L("删掉这个听错的词"), remove, Palette.Tertiary, 14, 8);
        x.Visibility = Visibility.Collapsed;
        x.Margin = new Thickness(3, 0, 0, 0);
        var chip = new Border
        {
            Background = Palette.Subtle, CornerRadius = new CornerRadius(5), Padding = new Thickness(6, 2, 6, 2), Margin = new Thickness(0, 2, 4, 2),
            Child = Ui.Row(0, Ui.Text(text, 11, Palette.Secondary, wrap: false), x),
        };
        chip.MouseEnter += (_, _) => x.Visibility = Visibility.Visible;
        chip.MouseLeave += (_, _) => x.Visibility = Visibility.Collapsed;
        return chip;
    }

    void AddHeard(Vocabulary.Term t, string typed)
    {
        var h = typed.Trim();
        newHeard.Remove(t.Word);
        if (h.Length == 0 || Correction.Length(h) > 40) { Render(); return; }
        if (app.Vocabulary.Owners(h, t.Word).FirstOrDefault() is { } owner) conflict = (t.Word, h, owner);
        else app.Vocabulary.Confirm(h, t.Word, t.Source);
        Render();
    }

    void Remove(Vocabulary.Term t, List<Vocabulary.Term> all)
    {
        var index = Math.Max(0, all.FindIndex(x => x.Word == t.Word));
        app.Vocabulary.Remove(t.Word);
        deleted = (t, index);
        var at = deletedAt = DateTime.UtcNow;
        var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(8) };
        timer.Tick += (_, _) => { timer.Stop(); if (deletedAt == at) { deleted = null; Render(); } };
        timer.Start();
        Render();
    }

    /// 粘贴导入: many words at once, each line one word, heard forms after "=". The counts follow
    /// what is pasted, and the button says how many go in.
    void ImportWords()
    {
        var dialog = new Window
        {
            Owner = this, WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent, ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false, SizeToContent = SizeToContent.Height, Width = 456 + 32, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            FontFamily = Palette.Font, Title = L("粘贴导入"),
        };
        var box = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 180, FontSize = 13, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        System.Windows.Automation.AutomationProperties.SetName(box, L("粘贴导入"));
        var placeholder = Ui.Text("Uniswap V3\nMorpho = 莫拉、莫法\n巡检", 13, Palette.Tertiary);
        placeholder.IsHitTestVisible = false; placeholder.Margin = new Thickness(12, 8, 0, 0);
        var counts = Ui.Text("", 12, Palette.Secondary);
        var skipped = Ui.Text("", 11, Palette.AccentText);
        Vocabulary.ImportResult? result = null;
        Button? go = null, close = null;
        void Update()
        {
            placeholder.Visibility = box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            if (result is { } r)
            {
                counts.Text = LF("新增 %lld · 补充听成 %lld · 跳过 %lld", r.Added, r.Updated, r.Skipped.Count);
                counts.Foreground = Palette.Ink; counts.FontWeight = FontWeights.SemiBold;
                skipped.Text = r.Skipped.Count > 0 ? LF("第 %@ 行没加进去：超过 40 个字", string.Join("、", r.Skipped)) : "";
                return;
            }
            var p = app.Vocabulary.Preview(box.Text);
            counts.Text = box.Text.Trim().Length == 0 ? "" : LF("新增 %lld · 补充听成 %lld · 跳过 %lld", p.Added, p.Updated, p.Skipped.Count);
            if (go is not null)
            {
                ((StackPanel)go.Content).Children.OfType<TextBlock>().First().Text = LF("导入 %lld 个", p.Added + p.Updated);
                go.IsEnabled = p.Added + p.Updated > 0;
            }
        }
        box.TextChanged += (_, _) => Update();
        go = Ui.Button(LF("导入 %lld 个", 0), () =>
        {
            result = app.Vocabulary.Import(box.Text);
            box.Text = ""; box.IsEnabled = false;
            go!.Visibility = Visibility.Collapsed;
            ((StackPanel)close!.Content).Children.OfType<TextBlock>().First().Text = L("完成");
            Update();
            Render();
        }, Ui.Kind.Primary);
        close = Ui.Button(L("取消"), dialog.Close);
        close.IsCancel = true;
        var buttons = new Grid();
        buttons.ColumnDefinitions.Add(new ColumnDefinition());
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(8) });
        buttons.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetColumn(go, 2);
        buttons.Children.Add(close); buttons.Children.Add(go);
        Update();
        var field = new Border { BorderBrush = Palette.FieldLine, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Padding = new Thickness(4), Child = new Grid { Children = { box, placeholder } } };
        box.BorderThickness = new Thickness(0);
        var body = Ui.Stack(12, Ui.Text(L("粘贴导入"), 20, Palette.Ink, FontWeights.Bold), Ui.Text(L("一行一个。常被听错的词，写在 = 后面"), 12, Palette.Secondary), field, Ui.Stack(4, counts, skipped));
        dialog.Content = new Border
        {
            Margin = new Thickness(16), Background = Palette.Surface, BorderBrush = Palette.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(16),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 32, ShadowDepth = 8, Opacity = 0.25 },
            Child = new StackPanel
            {
                Children =
                {
                    new Border { Padding = new Thickness(24, 24, 24, 16), Child = body },
                    new Border { Padding = new Thickness(24, 0, 24, 24), Child = buttons },
                },
            },
        };
        dialog.Loaded += (_, _) => box.Focus();
        importing = dialog;
        dialog.ShowDialog();
        importing = null;
    }

    /// The paste dialog while it is open (the debug pipe types into it).
    Window? importing;

    /// Debug: paste `text` into an open 粘贴导入, or open it first.
    public void DebugImport(string text)
    {
        if (importing is null) { Dispatcher.BeginInvoke(ImportWords); Dispatcher.BeginInvoke(() => DebugImport(text), System.Windows.Threading.DispatcherPriority.ApplicationIdle); return; }
        if (FindChild<TextBox>(importing, _ => true) is { } box) box.Text = text.Replace('|', '\n');
    }
}
