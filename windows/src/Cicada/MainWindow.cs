using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using static Cicada.Strings;

namespace Cicada.App;

/// How a meeting is described in lists: "10:03 · 23 分钟 · 待办 2".
static class Records
{
    public static string Meta(Session s, Controller app)
    {
        if (app.Listen.Listening && app.Listen.SessionId == s.Id) return L("正在听");
        var local = s.StartedAt.ToLocalTime();
        var day = local.Date == DateTime.Today || local.Date == DateTime.Today.AddDays(-1)
            ? local.ToString("HH:mm", Culture)
            : local.ToString(L("M月d日"), Culture);
        var parts = new List<string> { day, LF("%@ 分钟", Math.Max(1, (int)Math.Round(s.Duration.TotalMinutes))) };
        if (s.Notes?.Todos.Count is > 0 and var n) parts.Add(LF("待办 %@", n));
        return string.Join(" · ", parts);
    }

    public static string Group(Session s)
    {
        var d = s.StartedAt.ToLocalTime().Date;
        var monday = DateTime.Today.AddDays(-(((int)DateTime.Today.DayOfWeek + 6) % 7));
        return d == DateTime.Today ? L("今天") : d == DateTime.Today.AddDays(-1) ? L("昨天") : d >= monday ? L("本周") : L("更早");
    }
}

/// 会议记录, as the Mac's main window with no title bar: a grey list of one-line titles grouped by
/// day, the chosen one on a white pill, and the meeting set out like a document on one white
/// sheet: when and how long over a big title, 纪要 / 文字记录, the conclusions and to-dos in one
/// grey block, the summary, then the numbered topics.
sealed class MainWindow : Window
{
    readonly Controller app;
    readonly TextBox search = new();
    readonly StackPanel list = new();
    readonly ContentControl detail = new();
    string? selected;
    string tab = "notes";
    double? jumpTo;
    string? shownKey;
    bool refreshQueued;
    readonly ContentControl pill = new() { VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 8, 0, 0) };
    readonly ColumnDefinition listColumn = new() { Width = new GridLength(260) };
    readonly DispatcherTimer tick = new() { Interval = TimeSpan.FromMilliseconds(120) };
    readonly double[] levels = new double[8];
    FrameworkElement? left;
    // The pill is rebuilt only when what it says changes (a rebuild between press and release
    // would lose the click); the bars and the clock move in place.
    string? pillKey;
    readonly List<System.Windows.Shapes.Rectangle> bars = [];
    TextBlock? clock;

    public MainWindow(Controller app, string? select = null)
    {
        this.app = app;
        selected = select;
        Title = L("会议记录") + " · " + L("知了");
        Width = 1180; Height = Math.Min(780, SystemParameters.WorkArea.Height - 24); MinWidth = 860; MinHeight = 520;
        // One white sheet, as the Mac's main window: no cards, no second layer.
        Background = Palette.Surface; FontFamily = Palette.Font; Icon = AppIcon.Image;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        var grid = new Grid();
        grid.ColumnDefinitions.Add(listColumn);
        grid.ColumnDefinitions.Add(new ColumnDefinition());

        // The search box, with its icon and placeholder drawn over it
        var placeholder = Ui.Text(L("搜索标题、纪要和原话"), 13, Palette.Secondary, wrap: false);
        placeholder.IsHitTestVisible = false; placeholder.Margin = new Thickness(31, 0, 0, 0); placeholder.VerticalAlignment = VerticalAlignment.Center;
        var glass = Ui.Icon(Icons.Search, 16, Palette.Secondary);
        glass.HorizontalAlignment = HorizontalAlignment.Left; glass.Margin = new Thickness(10, 0, 0, 0); glass.IsHitTestVisible = false;
        System.Windows.Automation.AutomationProperties.SetName(search, L("搜索标题、纪要和原话"));
        search.TextChanged += (_, _) => { placeholder.Visibility = search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; Fill(); };
        Ui.StyleField(search);
        search.Margin = new Thickness(22, 0, 0, 0);
        placeholder.Margin = new Thickness(22, 0, 0, 0);
        glass.Margin = new Thickness(0);
        var ctrlF = Ui.Keycap("Ctrl F");
        ctrlF.HorizontalAlignment = HorizontalAlignment.Right; ctrlF.IsHitTestVisible = false;
        search.Margin = new Thickness(22, 0, 52, 0);
        var inside = new Grid { Children = { glass, search, placeholder, ctrlF } };
        search.TextChanged += (_, _) => ctrlF.Visibility = search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        var searchBox = Ui.FieldFrame(inside, search);
        searchBox.Background = Palette.Selected; searchBox.BorderThickness = new Thickness(0); searchBox.Height = 36; searchBox.Padding = new Thickness(12, 0, 6, 0);
        searchBox.Margin = new Thickness(10, 6, 10, 8);
        System.Windows.Shell.WindowChrome.SetIsHitTestVisibleInChrome(searchBox, true);
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.F && System.Windows.Input.Keyboard.Modifiers == System.Windows.Input.ModifierKeys.Control) { search.Focus(); search.SelectAll(); e.Handled = true; }
            else if (e.Key == System.Windows.Input.Key.Escape && search.IsKeyboardFocused) { search.Text = ""; e.Handled = true; }
        };

        // The list pane on the ground's grey, the logo where the title bar was.
        var logo = AppIcon.Small(20);
        logo.HorizontalAlignment = HorizontalAlignment.Left; logo.Margin = new Thickness(18, 14, 0, 6);
        var left = new DockPanel { Background = Palette.Mica };
        this.left = left;
        DockPanel.SetDock(logo, Dock.Top);
        DockPanel.SetDock(searchBox, Dock.Top);
        left.Children.Add(logo);
        left.Children.Add(searchBox);
        left.Children.Add(new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(10, 0, 10, 12) });

        var right = new Border { Background = Palette.Surface, Child = detail };
        Grid.SetColumn(right, 1);
        grid.Children.Add(left); grid.Children.Add(right);
        // The Mac's toolbar pill, centred in the title bar: the brand is the listening switch.
        System.Windows.Shell.WindowChrome.SetIsHitTestVisibleInChrome(pill, true);
        Grid.SetColumnSpan(pill, 2);
        grid.Children.Add(pill);
        Content = Ui.Frameless(this, grid);
        // The pill's clock and level move while listening; nothing else needs a timer.
        tick.Tick += (_, _) => { if (app.Listen.Listening) Pill(); else { tick.Stop(); Pill(); } };
        Closed += (_, _) => tick.Stop();
        Refresh();
    }

    public void Select(string id) { selected = id; tab = "notes"; shownKey = null; Fill(); }

    public void Refresh()
    {
        if (refreshQueued) return;
        refreshQueued = true;
        Dispatcher.BeginInvoke(() => { refreshQueued = false; Fill(); });
    }

    static bool Matches(Session s, string q) =>
        q.Length == 0
        || SessionStore.DisplayTitle(s).Contains(q, StringComparison.OrdinalIgnoreCase)
        || (s.Notes?.Summary.Contains(q, StringComparison.OrdinalIgnoreCase) ?? false)
        || s.Lines.Any(l => l.Src.Contains(q, StringComparison.OrdinalIgnoreCase) || (l.Dst?.Contains(q, StringComparison.OrdinalIgnoreCase) ?? false));

    void Fill()
    {
        Pill();
        var all = app.Store.All();
        // No meetings yet: only the welcome. An empty list and search box are noise.
        listColumn.Width = new GridLength(all.Count == 0 ? 0 : 260);
        if (left is not null) left.Visibility = all.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        var q = search.Text.Trim();
        var shown = all.Where(s => Matches(s, q)).ToList();
        list.Children.Clear();
        string? group = null;
        foreach (var s in shown)
        {
            var g = Records.Group(s);
            if (g != group)
            {
                group = g;
                var h = Ui.Text(g, 12, Palette.Secondary, wrap: false);
                h.Margin = new Thickness(12, list.Children.Count == 0 ? 8 : 18, 0, 6);
                list.Children.Add(h);
            }
            list.Children.Add(Item(s));
        }
        // An empty page replaces the meeting, so the next real one must draw again.
        if (all.Count == 0) { selected = null; shownKey = null; detail.Content = Welcome(); return; }
        if (shown.Count == 0) { shownKey = null; detail.Content = Empty(L("没有找到"), ""); return; }
        if (selected is null || shown.All(s => s.Id != selected)) selected = shown[0].Id;
        foreach (var child in list.Children.OfType<Button>()) Paint(child);
        // Store changes come in a burst while a meeting runs; redraw the open page only if it changed.
        if (PageKey() == shownKey) return;
        ShowDetail();
    }

    Button Item(Session s)
    {
        var live = app.Listen.Listening && app.Listen.SessionId == s.Id;
        var b = new Button
        {
            Tag = s.Id, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(12, 11, 12, 11), BorderThickness = new Thickness(0),
            Cursor = System.Windows.Input.Cursors.Hand, Margin = new Thickness(0, 0, 0, 2), Background = Brushes.Transparent,
            Content = live ? Ui.Row(8, Ui.LiveDot(6), Ui.Text(SessionStore.DisplayTitle(s), 14, Palette.Ink, wrap: false)) : Ui.Text(SessionStore.DisplayTitle(s), 14, Palette.Ink, wrap: false),
            ToolTip = Records.Meta(s, app),
        };
        b.Template = RowTemplate();
        b.Click += (_, _) => { selected = s.Id; tab = "notes"; foreach (var child in list.Children.OfType<Button>()) Paint(child); ShowDetail(); };
        System.Windows.Automation.AutomationProperties.SetName(b, SessionStore.DisplayTitle(s));
        return b;
    }

    void Paint(Button b)
    {
        var on = (string)b.Tag == selected;
        // The Mac's list: the chosen meeting on a white pill on the grey pane.
        b.Background = on ? Palette.Surface : Brushes.Transparent;
        var label = b.Content as TextBlock ?? (b.Content as Panel)?.Children.OfType<TextBlock>().FirstOrDefault();
        if (label is not null) label.FontWeight = on ? FontWeights.Bold : FontWeights.Normal;
    }

    /// A list row: white and raised when chosen, a grey wash under the mouse otherwise.
    static ControlTemplate RowTemplate()
    {
        var t = new ControlTemplate(typeof(Button));
        var border = new FrameworkElementFactory(typeof(Border), "bg");
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(10));
        border.SetBinding(Border.BackgroundProperty, new System.Windows.Data.Binding("Background") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        border.SetBinding(Border.PaddingProperty, new System.Windows.Data.Binding("Padding") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        border.AppendChild(new FrameworkElementFactory(typeof(ContentPresenter)));
        t.VisualTree = border;
        var hover = new MultiTrigger();
        hover.Conditions.Add(new Condition(UIElement.IsMouseOverProperty, true));
        hover.Conditions.Add(new Condition(Control.BackgroundProperty, Brushes.Transparent));
        hover.Setters.Add(new Setter(Border.BackgroundProperty, Palette.Selected, "bg"));
        t.Triggers.Add(hover);
        return t;
    }

    // MARK: Welcome and the pill

    /// No meetings yet (Views.swift › welcome): the logo, one line and the one thing to do; or,
    /// not set up yet, what is left, each step opening the onboarding where it is.
    FrameworkElement Welcome()
    {
        var s = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 480, Margin = new Thickness(24, 40, 24, 60) };
        var mark = AppIcon.Small(72);
        mark.Effect = new System.Windows.Media.Effects.DropShadowEffect { Color = Color.FromRgb(0xE8, 0x55, 0x2B), Opacity = 0.25, BlurRadius = 26, ShadowDepth = 8, Direction = 270 };
        s.Children.Add(mark);
        var left = app.SetupLeft;
        var title = Ui.Text(left > 0 ? LF("还差 %@ 步就能用", left) : L("还没有会议"), 26, Palette.Ink, FontWeights.Bold, wrap: false);
        title.HorizontalAlignment = HorizontalAlignment.Center; title.Margin = new Thickness(0, 26, 0, 8);
        s.Children.Add(title);
        var line = Ui.Text(left > 0 ? L("知了把电脑里放出来的会议声音变成字幕和纪要。") : L("打开会议或视频，开始听后，每一场都会存在这里。"), 15, Palette.Secondary);
        line.TextAlignment = TextAlignment.Center;
        s.Children.Add(line);
        if (left > 0) { s.Children.Add(Checklist()); return s; }

        var label = Ui.Row(10, Ui.Dot(Palette.Live, 9), Ui.Text(L("开始听"), 15, Brushes.White, Palette.Strong, wrap: false),
            new Border { BorderBrush = new SolidColorBrush(Color.FromArgb(0x55, 0xFF, 0xFF, 0xFF)), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(5), Padding = new Thickness(6, 0, 6, 1), Child = Ui.Text(Hotkey.Label.Replace('+', ' '), 12, Palette.NightText, wrap: false) });
        var start = Capsule(label, Palette.Ink, null, 44, new Thickness(22, 0, 22, 0), () => _ = app.ToggleListening(), L("开始听"));
        start.HorizontalAlignment = HorizontalAlignment.Center; start.Margin = new Thickness(0, 30, 0, 0);
        s.Children.Add(start);
        var sample = Ui.LinkText(L("先听一段示例"), () => _ = app.PlaySample(), 13);
        sample.Foreground = Palette.Secondary; sample.HorizontalAlignment = HorizontalAlignment.Center; sample.Margin = new Thickness(0, 16, 0, 0);
        s.Children.Add(sample);
        return s;
    }

    FrameworkElement Checklist()
    {
        var (key, audio, sample) = app.SetupDone;
        var first = !key ? 0 : !audio ? 1 : !sample ? 2 : 3;
        (string title, string detail, bool done)[] steps =
        [
            (L("接上 Ling"), key ? L("key 已加密存在这台电脑上") : L("识别、翻译和纪要都靠它，约 1 分钟"), key),
            (L("听一下电脑里的声音"), L("放一段测试声音，看音量条动起来"), audio),
            (L("看看效果"), L("一段 9 秒的英文会议，字幕和纪要一句句出来"), sample),
            (L("同声传译"), LF("按住%@说话，对方听到翻译后的声音", PushToTalk.Label), false),
        ];
        var list = new StackPanel();
        for (int i = 0; i < steps.Length; i++)
        {
            var (title, detail, done) = steps[i];
            var now = i == first;
            var n = i;
            var disc = new Border
            {
                Width = 26, Height = 26, CornerRadius = new CornerRadius(13), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 14, 0),
                Background = done ? Palette.Ink : now ? Palette.Live : Palette.Surface, BorderBrush = done ? Palette.Ink : now ? Palette.Live : Palette.Line, BorderThickness = new Thickness(1),
                Child = done ? Ui.Icon(Icons.Check, 13, Brushes.White, stroke: 2) : Center(Ui.Text((i + 1).ToString(), 12, now ? Brushes.White : Palette.Body, FontWeights.Bold, wrap: false)),
            };
            var head = Ui.Row(8, Ui.Text(title, 14, done ? Palette.Secondary : Palette.Ink, done ? FontWeights.Normal : Palette.Strong, wrap: false));
            if (i == 3) ((StackPanel)head).Children.Add(Ui.Badge(L("可选"), Palette.Surface, Palette.Secondary));
            var text = Ui.Stack(1, head, Ui.Helper(detail));
            FrameworkElement? action = now ? Ui.Button(L("继续设置"), () => app.ShowOnboarding(n), Ui.Kind.Primary, height: 32)
                : i == 3 && first == 3 ? Ui.Button(L("去设置"), () => app.ShowOnboarding(3), height: 32) : null;
            var row = new DockPanel { Margin = new Thickness(0, 14, 0, 14) };
            DockPanel.SetDock(disc, Dock.Left);
            row.Children.Add(disc);
            if (action is not null) { action.Margin = new Thickness(12, 0, 0, 0); DockPanel.SetDock(action, Dock.Right); row.Children.Add(action); }
            row.Children.Add(text);
            list.Children.Add(new Border { BorderBrush = Palette.Line, BorderThickness = new Thickness(0, i == 0 ? 0 : 1, 0, 0), Child = row });
        }
        return new Border { Background = Palette.Page, CornerRadius = new CornerRadius(16), Padding = new Thickness(18, 2, 18, 2), Margin = new Thickness(0, 28, 0, 0), Child = list, MinWidth = 440 };
        static FrameworkElement Center(FrameworkElement e) { e.HorizontalAlignment = HorizontalAlignment.Center; e.VerticalAlignment = VerticalAlignment.Center; return e; }
    }

    /// The title bar's switch (ListenPill.swift), led by the logo: a white pill while idle or not
    /// set up, an ink one with the level, the time and 结束 while listening.
    void Pill()
    {
        var listen = app.Listen;
        var live = listen.Listening && listen.SessionId is { } id ? app.Store.Get(id) : null;
        var left = app.SetupLeft;
        var key = live is not null ? (app.Ending is { } e ? $"ending|{app.EndingTitle(e)}|{Controller.EndingLeft(e)}" : "live")
            : left > 0 ? $"setup|{left}" : $"idle|{app.AutoEnded}";
        if (live is not null)
        {
            if (!tick.IsEnabled) tick.Start();
            Array.Copy(levels, 1, levels, 0, levels.Length - 1);
            levels[^1] = Math.Max(listen.Level <= 0 ? 0 : Math.Clamp((20 * Math.Log10(listen.Level) + 50) / 50, 0, 1), levels[^2] * 0.7);
        }
        if (key != pillKey)
        {
            pillKey = key;
            pill.Content = live is not null ? LivePill() : IdlePill(left);
        }
        for (int i = 0; i < bars.Count && i < levels.Length; i++) bars[i].Height = 3 + levels[i] * 12;
        if (clock is not null && live is not null) clock.Text = Languages.Clock((DateTimeOffset.Now - live.StartedAt).TotalSeconds);
    }

    FrameworkElement IdlePill(int left)
    {
        bars.Clear(); clock = null;
        var sep = new Border { Width = 1, Height = 14, Background = Palette.Line, VerticalAlignment = VerticalAlignment.Center };
        var content = left > 0
            ? Ui.Row(9, AppIcon.Small(22), Ui.Text(L("知了"), 13, Palette.Ink, FontWeights.Heavy, wrap: false), sep, Ui.Text(LF("还差 %@ 步", left), 13, Palette.AccentText, Palette.Strong, wrap: false), Ui.Text(L("继续设置"), 11, Palette.Secondary, wrap: false))
            : Ui.Row(9, AppIcon.Small(22), Ui.Text(L("知了"), 13, Palette.Ink, FontWeights.Heavy, wrap: false), sep, Ui.Text(app.AutoEnded ? L("会议已自动结束") : L("开始听"), 13, Palette.Ink, Palette.Strong, wrap: false), Ui.Text(Hotkey.Label.Replace('+', ' '), 11, Palette.Secondary, wrap: false));
        return Capsule(content, Palette.Surface, Palette.Line, 32, new Thickness(5, 0, 12, 0),
            left > 0 ? () => app.ShowOnboarding() : () => _ = app.ToggleListening(), left > 0 ? L("继续设置") : L("开始听"));
    }

    FrameworkElement LivePill()
    {
        bars.Clear();
        var mark = AppIcon.Small(22);
        UIElement state;
        if (app.Ending is { } p)
        {
            clock = null;
            state = Ui.Row(10, mark, Ui.Text(app.EndingTitle(p), 13, Brushes.White, Palette.Strong, wrap: false), Ui.Text(LF("%lld 秒后结束", Controller.EndingLeft(p)), 13, new SolidColorBrush(Color.FromRgb(0xF4, 0xA5, 0x8C)), wrap: false));
        }
        else
        {
            var meter = new StackPanel { Orientation = Orientation.Horizontal, Height = 15, VerticalAlignment = VerticalAlignment.Center };
            for (int i = 0; i < levels.Length; i++)
            {
                var r = new System.Windows.Shapes.Rectangle { Width = 3, Height = 3, RadiusX = 1, RadiusY = 1, Margin = new Thickness(0, 0, 2, 0), VerticalAlignment = VerticalAlignment.Bottom, Fill = Palette.Live };
                bars.Add(r); meter.Children.Add(r);
            }
            clock = Ui.Text("00:00", 13, Brushes.White, wrap: false);
            state = Ui.Row(10, mark, Ui.Text(L("正在听"), 13, Brushes.White, Palette.Strong, wrap: false), meter, clock);
        }
        var show = Capsule(state, Brushes.Transparent, null, 32, new Thickness(0), app.ShowNotes, L("显示纪要"));
        var end = app.Ending is not null
            ? Capsule(Ui.Text(L("继续记录"), 12, Palette.Ink, Palette.Strong, wrap: false), Brushes.White, null, 24, new Thickness(12, 0, 12, 0), app.KeepRecording, L("继续记录"))
            : Capsule(Ui.Text(L("结束"), 12, Brushes.White, Palette.Strong, wrap: false), new SolidColorBrush(Color.FromRgb(0x2F, 0x32, 0x3A)), null, 24, new Thickness(12, 0, 12, 0), app.RequestStop, L("结束会议"));
        end.Margin = new Thickness(10, 0, 0, 0);
        return new Border { Background = Palette.Ink, CornerRadius = new CornerRadius(16), Height = 32, Padding = new Thickness(5, 0, 4, 0), Child = Ui.Row(0, show, end) };
    }

    /// A rounded button with no theme chrome: the pill and its parts.
    static Button Capsule(UIElement content, Brush background, Brush? border, double height, Thickness padding, Action click, string name)
    {
        var b = new Button { Content = content, Height = height, Padding = padding, Background = background, BorderBrush = border ?? Brushes.Transparent, BorderThickness = new Thickness(border is null ? 0 : 1), Cursor = System.Windows.Input.Cursors.Hand, Focusable = false };
        var t = new ControlTemplate(typeof(Button));
        var bg = new FrameworkElementFactory(typeof(Border), "bg");
        bg.SetValue(Border.CornerRadiusProperty, new CornerRadius(height / 2));
        foreach (var (dp, path) in new[] { (Border.BackgroundProperty, "Background"), (Border.BorderBrushProperty, "BorderBrush"), (Border.BorderThicknessProperty, "BorderThickness"), (Border.PaddingProperty, "Padding") })
            bg.SetBinding(dp, new System.Windows.Data.Binding(path) { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        var cp = new FrameworkElementFactory(typeof(ContentPresenter));
        cp.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        bg.AppendChild(cp);
        t.VisualTree = bg;
        var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(UIElement.OpacityProperty, 0.9));
        t.Triggers.Add(hover);
        b.Template = t;
        b.Click += (_, _) => click();
        System.Windows.Automation.AutomationProperties.SetName(b, name);
        return b;
    }

    static FrameworkElement Empty(string title, string hint)
    {
        var s = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var t = Ui.Text(title, 16, Palette.Ink); t.TextAlignment = TextAlignment.Center; s.Children.Add(t);
        if (hint.Length > 0) { var h = Ui.Text(hint, 13, Palette.Secondary); h.TextAlignment = TextAlignment.Center; h.Margin = new Thickness(0, 6, 0, 0); s.Children.Add(h); }
        return s;
    }

    /// What the open page shows; a store change that leaves it the same doesn't redraw it.
    string? PageKey() => selected is not null && app.Store.Get(selected) is { } cur
        ? $"{selected}|{tab}|{SessionStore.DisplayTitle(cur)}|{cur.Lines.Count}|{cur.Notes?.Covered}|{cur.Notes?.Final}|{app.Listen.Listening}"
        : null;

    void ShowDetail()
    {
        shownKey = PageKey();
        if (selected is null || app.Store.Get(selected) is not { } s) { detail.Content = Empty(L("还没有会议记录"), ""); return; }
        var live = app.Listen.Listening && app.Listen.SessionId == s.Id;
        var top = new StackPanel();

        // When, how long, and from what into what, above the title.
        var local = s.StartedAt.ToLocalTime();
        var spoken = s.Lines.Select(l => l.SrcLang).FirstOrDefault(x => x is not null);
        var into = s.Lines.Select(l => l.DstLang).FirstOrDefault(x => x is not null);
        var meta = new List<string> { local.ToString(L("M月d日"), Culture) + " " + local.ToString("HH:mm", Culture) };
        meta.Add(live ? L("正在听") : LF("%@ 分钟", Math.Max(1, (int)Math.Round(s.Duration.TotalMinutes))));
        if (spoken is not null && into is not null) meta.Add($"{Ui.SpokenName(spoken)} → {Ui.TargetName(into)}");
        top.Children.Add(Ui.Text(string.Join(" · ", meta), 13, live ? Palette.AccentText : Palette.Secondary));

        var title = Ui.Text(SessionStore.DisplayTitle(s), 28, Palette.Ink, FontWeights.Bold);
        var rename = Ui.IconButton(Icons.Pencil, L("重命名"), () => Rename(s), Palette.Tertiary, 30, 15);
        var titleRow = Ui.Row(6, title, rename);
        titleRow.Margin = new Thickness(0, 6, 0, 0);
        // As the Mac's context menu: only when the notes have a name to go back to.
        if ((s.Renamed ?? !s.Title.StartsWith("会议 ")) && !string.IsNullOrEmpty(s.Notes?.Title))
        {
            var reset = Ui.LinkText(L("恢复自动标题"), () => app.Store.ResetTitle(s.Id));
            reset.VerticalAlignment = VerticalAlignment.Center;
            reset.Margin = new Thickness(6, 0, 0, 0);
            titleRow.Children.Add(reset);
        }
        top.Children.Add(titleRow);

        // 纪要 / 文字记录 on the left, what to do with it on the right, one hairline under both.
        var tabs = Ui.Tabs([("notes", L("纪要")), ("transcript", s.Lines.Count > 0 ? $"{L("文字记录")} {s.Lines.Count}" : L("文字记录"))], tab, t => { tab = t; ShowDetail(); }, 15);
        var tools = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top };
        var hasNotes = s.Notes is { IsEmpty: false };
        if (!hasNotes && !live) tools.Children.Add(Small(Ui.Button(L("生成纪要"), () => _ = app.Notes.Generate(s.Id), Ui.Kind.Primary, height: 32)));
        else
        {
            Button? copy = null;
            copy = Small(Ui.Button(L("复制纪要"), () =>
            {
                try { Clipboard.SetText(SessionStore.NotesMarkdown(s)); } catch (Exception e) { Log.Debug($"copy: failed {e.GetType().Name}"); return; }
                Flash(copy!, L("已复制"));
            }, Ui.Kind.Standard, height: 32));
            copy.IsEnabled = hasNotes;
            tools.Children.Add(copy);
        }
        tools.Children.Add(Spaced(Small(Ui.Button(L("导出…"), () => Export(s), Ui.Kind.Standard, height: 32)), 8));
        Button? more = null;
        more = Ui.Button("···", () =>
        {
            var menu = new ContextMenu { PlacementTarget = more, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom, FontFamily = Palette.Font };
            var r = new MenuItem { Header = L("重命名") }; r.Click += (_, _) => Rename(s); menu.Items.Add(r);
            var d = new MenuItem { Header = L("删除"), IsEnabled = !live, Foreground = Palette.Danger }; d.Click += (_, _) => Delete(s); menu.Items.Add(d);
            menu.IsOpen = true;
        }, Ui.Kind.Standard, height: 32);
        more.MinWidth = 0; more.Width = 36; more.Padding = new Thickness(0);
        tools.Children.Add(Spaced(more, 8));
        var bar = Ui.Spread(tabs, tools);
        bar.Margin = new Thickness(0, 18, 0, 0);
        top.Children.Add(bar);
        top.Children.Add(new Border { Height = 1, Background = Palette.Line });

        // One centred column, like a page: content runs into the old title bar's height.
        var page = new StackPanel { MaxWidth = 700, Margin = new Thickness(48, 56, 48, 48) };
        page.Children.Add(top);
        var body = tab == "transcript" ? Transcript(s) : Notes(s, live);
        body.Margin = new Thickness(0, 28, 0, 0);
        page.Children.Add(body);
        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = page };
        if (pendingJump is { } jump) { pendingJump = null; jump(scroll); }
        detail.Content = scroll;
    }

    static Button Small(Button b) { b.MinWidth = 0; b.Padding = new Thickness(12, 0, 12, 0); return b; }

    Action<ScrollViewer>? pendingJump;

    static T Spaced<T>(T e, double left) where T : FrameworkElement { e.Margin = new Thickness(left, 0, 0, 0); return e; }

    FrameworkElement Notes(Session s, bool live)
    {
        if (s.Notes is not { IsEmpty: false } n)
            return Empty(live ? L("纪要会在会议进行中自动生成") : L("生成纪要"), "");
        var article = new StackPanel();
        void Jump(double t) { tab = "transcript"; jumpTo = t; ShowDetail(); }

        // The conclusions first, in one quiet grey block; to-dos with an open circle.
        var items = n.Conclusions.Select(c => (c, todo: false)).Concat(n.Todos.Select(t => (c: t, todo: true))).ToList();
        if (items.Count > 0)
        {
            var block = new StackPanel();
            block.Children.Add(Ui.Text(n.Todos.Count == 0 ? L("结论") : L("结论和待办"), 13, Palette.Secondary));
            foreach (var (item, todo) in items)
            {
                var row = new DockPanel { Margin = new Thickness(0, 12, 0, 0) };
                FrameworkElement mark = todo
                    ? new System.Windows.Shapes.Ellipse { Width = 11, Height = 11, Stroke = Palette.Live, StrokeThickness = 1.5 }
                    : new System.Windows.Shapes.Ellipse { Width = 5, Height = 5, Fill = Palette.Body };
                var markBox = new Border { Width = 26, Height = 20, Child = mark, VerticalAlignment = VerticalAlignment.Top };
                mark.HorizontalAlignment = HorizontalAlignment.Left; mark.VerticalAlignment = VerticalAlignment.Center;
                DockPanel.SetDock(markBox, Dock.Left);
                row.Children.Add(markBox);
                if (item.T is { } t)
                {
                    var at = Ui.LinkText(Languages.Clock(t), () => Jump(t), 13);
                    at.VerticalAlignment = VerticalAlignment.Top; at.Margin = new Thickness(16, 1, 0, 0);
                    DockPanel.SetDock(at, Dock.Right);
                    row.Children.Add(at);
                }
                row.Children.Add(Ui.Text(item.Text + (item.Owner is { Length: > 0 } o ? $"（{o}）" : ""), 15, item.Support == 0 ? Palette.Tertiary : Palette.Ink));
                block.Children.Add(row);
            }
            article.Children.Add(new Border { Background = Palette.Mica, CornerRadius = new CornerRadius(16), Padding = new Thickness(26, 22, 26, 22), Child = block, Margin = new Thickness(0, 0, 0, 32) });
        }

        if (n.Summary.Length > 0)
        {
            var sum = Ui.Text(n.Summary, 15, Palette.Body);
            sum.LineHeight = 28;
            article.Children.Add(sum);
        }

        // The topics as numbered rows between hairlines.
        if (n.Topics.Count > 0)
        {
            var label = Ui.Text(L("议题"), 13, Palette.Secondary);
            label.Margin = new Thickness(0, 36, 0, 10);
            article.Children.Add(label);
            for (int i = 0; i < n.Topics.Count; i++)
            {
                var t = n.Topics[i];
                article.Children.Add(new Border { Height = 1, Background = Palette.Line });
                var num = Ui.Text($"{i + 1:00}", 14, Palette.AccentText, wrap: false);
                num.Width = 40; num.VerticalAlignment = VerticalAlignment.Top; num.Margin = new Thickness(0, 2, 0, 0);
                var start = t.Start;
                var at = Ui.LinkText(Languages.Clock(start), () => Jump(start), 13);
                at.VerticalAlignment = VerticalAlignment.Top; at.Margin = new Thickness(16, 2, 0, 0);
                var text = new StackPanel();
                var head = Ui.Row(8, Ui.Text(t.Title, 17, Palette.Ink, FontWeights.Bold));
                if (live && i == n.Topics.Count - 1) head.Children.Add(Spaced(Ui.Badge(L("正在讲")), 8));
                text.Children.Add(head);
                if (t.Summary.Length > 0) text.Children.Add(Gap(Ui.Text(t.Summary, 14, Palette.Body), 8));
                foreach (var p in t.Points) text.Children.Add(Gap(Ui.Text("· " + p, 14, Palette.Secondary), 4));
                var row = new DockPanel { Margin = new Thickness(0, 18, 0, 20) };
                DockPanel.SetDock(num, Dock.Left); DockPanel.SetDock(at, Dock.Right);
                row.Children.Add(num); row.Children.Add(at); row.Children.Add(text);
                article.Children.Add(row);
            }
            article.Children.Add(new Border { Height = 1, Background = Palette.Line });
        }

        var terms = NoteTerm.Ordered(n.Terms).Take(12).ToList();
        if (terms.Count > 0)
        {
            var label = Ui.Text(L("人名和术语"), 13, Palette.Secondary);
            label.Margin = new Thickness(0, 36, 0, 10);
            article.Children.Add(label);
            var chips = new WrapPanel();
            foreach (var t in terms)
                chips.Children.Add(new Border { Background = Palette.Mica, CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 5, 10, 6), Margin = new Thickness(0, 0, 8, 8), Child = Ui.Text(t.Note.Length > 0 ? $"{t.Name} · {t.Note}" : t.Name, 13, Palette.Body, wrap: false) });
            article.Children.Add(chips);
        }
        return article;
    }

    FrameworkElement Transcript(Session s)
    {
        var body = new StackPanel();
        FrameworkElement? target = null;
        // The line nearest the topic's time (older notes may hold a time no line has).
        var nearest = jumpTo is { } t0 && s.Lines.Count > 0 ? s.Lines.MinBy(l => Math.Abs(l.T - t0)) : null;
        foreach (var (l, who, ink) in NotesWindow.Speakers(s.Lines, app.Settings.SpeakerVoices))
        {
            var line = NotesWindow.TranscriptRow(l, who, ink);
            if (ReferenceEquals(l, nearest)) target = line;
            body.Children.Add(line);
        }
        if (target is Panel row)
        {
            // A topic's time opens the transcript at what was said then, marked for a moment.
            row.Background = Palette.AccentPale;
            // Measured once laid out: before that every row is at the top.
            pendingJump = scroll =>
            {
                void Jump(object? _, RoutedEventArgs __)
                {
                    row.Loaded -= Jump;
                    var y = row.TransformToAncestor(scroll).Transform(new Point(0, 0)).Y;
                    scroll.ScrollToVerticalOffset(Math.Max(0, scroll.VerticalOffset + y - 24));
                }
                row.Loaded += Jump;
            };
            var fade = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
            fade.Tick += (_, _) => { row.Background = Brushes.Transparent; fade.Stop(); };
            fade.Start();
        }
        jumpTo = null;
        return body;
    }

    static FrameworkElement Gap(FrameworkElement e, double top) { e.Margin = new Thickness(0, top, 0, 0); return e; }

    static void Flash(Button b, string text)
    {
        var label = ((StackPanel)b.Content).Children.OfType<TextBlock>().Last();
        var was = label.Text;
        label.Text = text;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };
        timer.Tick += (_, _) => { label.Text = was; timer.Stop(); };
        timer.Start();
    }

    void Export(Session s)
    {
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            FileName = SafeName(SessionStore.DisplayTitle(s)) + ".md", Filter = "Markdown (*.md)|*.md", DefaultExt = ".md",
        };
        if (dialog.ShowDialog(this) == true) File.WriteAllText(dialog.FileName, SessionStore.Markdown(s));
    }

    static string SafeName(string name) => string.Concat(name.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '-' : c)).Trim();

    void Rename(Session s)
    {
        var notesTitle = s.Notes?.Title;
        var answer = Dialogs.Prompt(this, L("重命名"), SessionStore.DisplayTitle(s), notesTitle is { Length: > 0 } ? LF("清空就用纪要起的名字：%@", notesTitle) : null, L("保存"));
        if (answer is null) return;
        if (answer.Length == 0) app.Store.ResetTitle(s.Id); else app.Store.Rename(s.Id, answer);
    }

    void Delete(Session s)
    {
        if (Dialogs.Confirm(this, L("删除这次会议？"), LF("“%@”的纪要和文字记录都会删掉，没法恢复。", SessionStore.DisplayTitle(s)), L("删除"), danger: true))
            app.Store.Delete(s.Id);
    }
}
