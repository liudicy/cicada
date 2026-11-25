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
        // The Mac marks these with a mic and a display; a word reads the same here.
        if (Places.HeardBoth(s.Lines)) parts.Add(L("电脑和会议室"));
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
    /// A line to show, marked for a moment (the fix banner's 听成 … → …？).
    string? jumpLine;
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
        search.TextChanged += (_, _) => { placeholder.Visibility = search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; searchMoved = true; Fill(); };
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
            // Enter goes to the next line found in the shown meeting (Shift+Enter: the one before).
            else if (e.Key == System.Windows.Input.Key.Enter && search.IsKeyboardFocused)
            {
                Step(System.Windows.Input.Keyboard.Modifiers == System.Windows.Input.ModifierKeys.Shift ? -1 : 1);
                e.Handled = true;
            }
        };
        // 本场 n / N under the search box, only while the shown meeting has lines found.
        matchText.VerticalAlignment = VerticalAlignment.Center;
        matchText.Typography.NumeralAlignment = FontNumeralAlignment.Tabular;
        var prev = Ui.IconButton(Icons.ChevronUp, L("上一个"), () => Step(-1), Palette.Secondary, 26, 14);
        var next = Ui.IconButton(Icons.Chevron, L("下一个"), () => Step(1), Palette.Secondary, 26, 14);
        prev.Focusable = false; next.Focusable = false;
        var steps = Ui.Row(0, prev, next);
        DockPanel.SetDock(steps, Dock.Right);
        matchBar.Children.Add(steps);
        matchBar.Children.Add(matchText);
        matchBar.Margin = new Thickness(22, -4, 14, 6);
        matchBar.Visibility = Visibility.Collapsed;
        DockPanel.SetDock(matchBar, Dock.Top);

        // The list pane on the ground's grey, the logo where the title bar was.
        var logo = AppIcon.Small(20);
        logo.HorizontalAlignment = HorizontalAlignment.Left; logo.Margin = new Thickness(18, 14, 0, 6);
        var left = new DockPanel { Background = Palette.Mica };
        this.left = left;
        DockPanel.SetDock(logo, Dock.Top);
        DockPanel.SetDock(searchBox, Dock.Top);
        left.Children.Add(logo);
        left.Children.Add(searchBox);
        left.Children.Add(matchBar);
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
        Closed += (_, _) => { tick.Stop(); ClosePlayer(); };
        playTick.Tick += (_, _) => UpdatePlayer();
        barTick.Tick += (_, _) => Bounce();
        Refresh();
    }

    public void Select(string id, string page = "notes") { selected = id; tab = page; shownKey = null; Fill(); }

    public void Refresh()
    {
        if (refreshQueued) return;
        refreshQueued = true;
        Dispatcher.BeginInvoke(() => { refreshQueued = false; Fill(); });
    }

    static bool Matches(Session s, string q)
    {
        if (q.Length == 0) return true;
        if (SessionStore.DisplayTitle(s).Contains(q, StringComparison.OrdinalIgnoreCase) || (s.Notes?.Summary.Contains(q, StringComparison.OrdinalIgnoreCase) ?? false)) return true;
        var terms = TranscriptSearch.Terms(q, s.Notes?.Terms);
        return s.Lines.Any(l => TranscriptSearch.Matches(l, terms));
    }

    // MARK: Searching inside the shown meeting (#33: a search opens the line, not just the meeting)

    readonly DockPanel matchBar = new();
    readonly TextBlock matchText = Ui.Text("", 12, Palette.Secondary, wrap: false);
    /// Which of the shown meeting's lines found the search is on.
    int matchIndex;
    /// The query changed or another meeting was opened: start again at the first line found.
    bool searchMoved;

    List<string> SearchTerms(Session? s) => s is null ? [] : TranscriptSearch.Terms(search.Text, s.Notes?.Terms);
    List<string> Found(Session? s) => s is null ? [] : TranscriptSearch.Matches(s.Lines, SearchTerms(s));
    string? CurrentMatch(Session? s) { var f = Found(s); return f.Count == 0 ? null : f[Math.Min(matchIndex, f.Count - 1)]; }
    Session? Shown => selected is null ? null : app.Store.Get(selected);

    /// A search that finds lines in the shown meeting opens its transcript at the first one.
    void ShowMatches()
    {
        searchMoved = false;
        matchIndex = 0;
        if (Found(Shown).Count > 0) tab = "transcript";
    }

    void Step(int d)
    {
        var n = Found(Shown).Count;
        if (n == 0) return;
        matchIndex = (Math.Min(matchIndex, n - 1) + d + n) % n;
        centredFound = null;   // Enter goes to the line even when it is the only one
        tab = "transcript";
        UpdateMatchBar();
        ShowDetail();
    }

    void UpdateMatchBar()
    {
        var n = search.Text.Trim().Length == 0 ? 0 : Found(Shown).Count;
        matchBar.Visibility = n > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (n > 0) matchText.Text = LF("本场 %lld / %lld", Math.Min(matchIndex, n - 1) + 1, n);
    }

    /// Debug `search <text>` / `searchstep <1|-1>`: types into the search box or steps, as Enter does.
    public System.Text.Json.Nodes.JsonObject DebugSearch(string? text, int step)
    {
        if (text is not null) search.Text = text; else Step(step);
        var meetings = app.Store.All().Count(s => Matches(s, search.Text.Trim()));
        var found = Found(Shown);
        var at = CurrentMatch(Shown);
        Log.Debug($"main search: \"{search.Text}\" {meetings} meetings, shown {selected ?? "-"} tab={tab} matches={found.Count} at={at ?? "-"}");
        return new() { ["query"] = search.Text, ["meetings"] = meetings, ["shown"] = selected, ["tab"] = tab, ["matches"] = found.Count, ["index"] = found.Count == 0 ? 0 : Math.Min(matchIndex, found.Count - 1) + 1, ["at"] = at };
    }

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
        if (all.Count == 0) { selected = null; shownKey = null; detail.Content = Welcome(); UpdateMatchBar(); return; }
        if (shown.Count == 0) { shownKey = null; detail.Content = Empty(L("没有找到"), ""); matchBar.Visibility = Visibility.Collapsed; return; }
        if (selected is null || shown.All(s => s.Id != selected)) { selected = shown[0].Id; if (q.Length > 0) searchMoved = true; }
        if (searchMoved) ShowMatches();
        UpdateMatchBar();
        foreach (var child in list.Children.OfType<Button>()) Paint(child);
        // Store changes come in a burst while a meeting runs; redraw the open page only if it changed.
        if (PageKey() == shownKey) { ShowToast(); return; }
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
        b.Click += (_, _) =>
        {
            selected = s.Id; tab = "notes";
            if (search.Text.Trim().Length > 0) ShowMatches();
            UpdateMatchBar();
            foreach (var child in list.Children.OfType<Button>()) Paint(child);
            ShowDetail();
        };
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
        // The key is in but the service turned it down (or can't be reached, or can't hear): the
        // reason, and the settings page that fixes it.
        var ling = app.Ling;
        var broken = app.KeyStepFailed ? ling.Health.Message(ling.ServiceLabel, ling.ServiceHost, ling.Config.TextModel, ling.HearName) : null;
        (string title, string detail, bool done)[] steps =
        [
            // A service whose check passed ticks it; another service is named (接上 ZenMux).
            (ling.Config.IsLing ? L("接上 Ling") : LF("接上 %@", ling.Config.Name), broken ?? (key ? L("key 已加密存在这台电脑上") : L("识别、翻译和纪要都靠它，约 1 分钟")), key),
            (L("听一下电脑里的声音"), L("放一段测试声音，看音量条动起来"), audio),
            (L("看看效果"), L("一段 9 秒的英文会议，字幕和纪要一句句出来"), sample),
            (L("同声传译"), LF("按住%@说话，线上的人听到翻译后的声音", PushToTalk.Label), false),
        ];
        var list = new StackPanel();
        for (int i = 0; i < steps.Length; i++)
        {
            var (title, detail, done) = steps[i];
            var now = i == first;
            var n = i;
            var failed = i == 0 && broken is not null;
            var disc = new Border
            {
                Width = 26, Height = 26, CornerRadius = new CornerRadius(13), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 14, 0),
                Background = done ? Palette.Ink : now ? Palette.Live : Palette.Surface, BorderBrush = done ? Palette.Ink : now ? Palette.Live : Palette.Line, BorderThickness = new Thickness(1),
                Child = done ? Ui.Icon(Icons.Check, 13, Brushes.White, stroke: 2) : Center(Ui.Text(failed ? "!" : (i + 1).ToString(), 12, now ? Brushes.White : Palette.Body, FontWeights.Bold, wrap: false)),
            };
            var head = Ui.Row(8, Ui.Text(title, 14, done ? Palette.Secondary : Palette.Ink, done ? FontWeights.Normal : Palette.Strong, wrap: false));
            if (i == 3) ((StackPanel)head).Children.Add(Ui.Badge(L("可选"), Palette.Surface, Palette.Secondary));
            var line = Ui.Helper(detail);
            if (failed) line.Foreground = Palette.Danger;
            var text = Ui.Stack(1, head, line);
            FrameworkElement? action = failed ? Ui.Button(L("打开设置"), app.ShowAISettings, Ui.Kind.Primary, height: 32)
                : now ? Ui.Button(L("继续设置"), () => app.ShowOnboarding(n), Ui.Kind.Primary, height: 32)
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
            left > 0 ? () => { if (app.KeyStepFailed && app.Ling.HasKey) app.ShowAISettings(); else app.ShowOnboarding(); } : () => _ = app.ToggleListening(), left > 0 ? L("继续设置") : L("开始听"));
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
        ? $"{selected}|{tab}|{SessionStore.DisplayTitle(cur)}|{cur.Lines.Count}|{cur.Notes?.Covered}|{cur.Notes?.Final}|{app.Listen.Listening}|{app.Notes.GeneratingId == selected}|{cur.HasAudio}|{Recording.Playable(cur)}|{app.Settings.RecordAudio}|{FixKey(cur)}|{cur.Lines.Sum(l => l.Dst?.Length ?? 0)}|{FolderExportUi.Key(app, selected)}|{search.Text.Trim()}|{matchIndex}"
        : null;

    void ShowDetail()
    {
        shownKey = PageKey();
        if (selected is null || app.Store.Get(selected) is not { } s) { detail.Content = Empty(L("还没有会议记录"), ""); return; }
        var live = app.Listen.Listening && app.Listen.SessionId == s.Id;
        var thisPage = $"{s.Id}|{tab}";
        double? keep = pageScroll is { } shownScroll && pageScrollKey == thisPage ? shownScroll.VerticalOffset : null;
        redrawing = keep is not null;
        var top = new StackPanel();

        // When, how long, and from what into what, above the title.
        var local = s.StartedAt.ToLocalTime();
        var spoken = s.Lines.Select(l => l.SrcLang).FirstOrDefault(x => x is not null);
        var into = s.Lines.Select(l => l.DstLang).FirstOrDefault(x => x is not null);
        var meta = new List<string> { local.ToString(L("M月d日"), Culture) + " " + local.ToString("HH:mm", Culture) };
        meta.Add(live ? L("正在听") : LF("%@ 分钟", Math.Max(1, (int)Math.Round(s.Duration.TotalMinutes))));
        if (s.Room == true) meta.Add(Places.HeardBoth(s.Lines) ? L("电脑和会议室") : L("会议室"));
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
        // 存到文件夹: where its file is, or why it isn't there yet.
        if (!live && FolderExportUi.Line(app, s) is { } exported) top.Children.Add(exported);
        if (PlayerArea(s, live) is { } audio) top.Children.Add(audio);
        // Under the page, not in its header: the controls stay while the transcript scrolls.
        var footer = player is not null ? PlayerFooter() : null;

        // 纪要 / 文字记录 on the left, what to do with it on the right, one hairline under both.
        FrameworkElement Tabs(double size) => Ui.Tabs([("notes", L("纪要")), ("transcript", s.Lines.Count > 0 ? $"{L("文字记录")} {s.Lines.Count}" : L("文字记录"))], tab, t => { tab = t; ShowDetail(); }, size);
        var tabs = Tabs(15);
        var tools = Tools(s, live);
        var bar = Ui.Spread(tabs, tools);
        bar.Margin = new Thickness(0, 18, 0, 0);
        top.Children.Add(bar);
        top.Children.Add(new Border { Height = 1, Background = Palette.Line });

        // One centred column, like a page: content runs into the old title bar's height.
        var page = new StackPanel { MaxWidth = 700, Margin = new Thickness(48, 56, 48, 48) };
        page.Children.Add(top);
        // The notes have no lines to light: the rows (and 回到正在播放) go with the transcript.
        if (tab != "transcript") { rows.Clear(); lit = -1; hovered = null; barTick.Stop(); }
        var body = tab == "transcript" ? Transcript(s) : Notes(s, live);
        body.Margin = new Thickness(0, 28, 0, 0);
        page.Children.Add(body);
        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = page };
        pageScroll = scroll; pageScrollKey = thisPage;

        // Once the title block scrolls away, a slim bar on top keeps the title (a click goes back
        // up), the tabs and the tools in view: the Mac's pinned bar.
        var pinnedTitle = Ui.Text(SessionStore.DisplayTitle(s), 14, Palette.Ink, FontWeights.Bold, wrap: false);
        pinnedTitle.TextTrimming = TextTrimming.CharacterEllipsis;
        pinnedTitle.VerticalAlignment = VerticalAlignment.Center;
        pinnedTitle.Cursor = System.Windows.Input.Cursors.Hand;
        pinnedTitle.ToolTip = L("回到顶部");
        pinnedTitle.MouseLeftButtonUp += (_, _) => scroll.ScrollToTop();
        var pinnedTabs = Tabs(14);
        pinnedTabs.Margin = new Thickness(18, -6, 0, 0);
        pinnedTabs.VerticalAlignment = VerticalAlignment.Center;
        var pinnedTools = Tools(s, live);
        pinnedTools.VerticalAlignment = VerticalAlignment.Center;
        var pinnedRow = new DockPanel { MaxWidth = 700, Margin = new Thickness(48, 0, 48, 0), Height = 48, LastChildFill = true };
        DockPanel.SetDock(pinnedTools, Dock.Right); DockPanel.SetDock(pinnedTabs, Dock.Right);
        pinnedRow.Children.Add(pinnedTools); pinnedRow.Children.Add(pinnedTabs); pinnedRow.Children.Add(pinnedTitle);
        var pinned = new Border
        {
            Background = Palette.Surface, BorderBrush = Palette.Line, BorderThickness = new Thickness(0, 0, 0, 1),
            VerticalAlignment = VerticalAlignment.Top, Visibility = Visibility.Collapsed, Child = pinnedRow,
            // Under the 44 px caption strip (the pill and window buttons), which it paints white so
            // the lines don't scroll behind the pill.
            Padding = new Thickness(0, 44, 0, 0), Margin = new Thickness(0, 0, SystemParameters.VerticalScrollBarWidth, 0),
        };
        scroll.ScrollChanged += (_, _) =>
        {
            var below = top.TranslatePoint(new Point(0, top.ActualHeight), scroll).Y;
            pinned.Visibility = below < 0 ? Visibility.Visible : Visibility.Collapsed;
        };
        if (pendingJump is { } jump) { pendingJump = null; jump(scroll); }
        else if (keep is { } y)
        {
            // The new page has no extent until laid out, so the offset goes back on once it is.
            void Keep(object? _, RoutedEventArgs __) { scroll.Loaded -= Keep; scroll.ScrollToVerticalOffset(y); }
            scroll.Loaded += Keep;
        }
        // Scrolling by hand while it plays stops the transcript following the recording. Only input
        // counts (wheel and touchpad, the scroll bar, keys, touch): the page's own scrolling doesn't.
        scroll.PreviewMouseWheel += (_, _) => UserScrolled();
        scroll.AddHandler(System.Windows.Controls.Primitives.ScrollBar.ScrollEvent, new System.Windows.Controls.Primitives.ScrollEventHandler((_, _) => UserScrolled()), true);
        scroll.PreviewKeyDown += (_, e) =>
        {
            if (e.Key is System.Windows.Input.Key.PageUp or System.Windows.Input.Key.PageDown or System.Windows.Input.Key.Up
                or System.Windows.Input.Key.Down or System.Windows.Input.Key.Home or System.Windows.Input.Key.End) UserScrolled();
        };
        scroll.ManipulationStarted += (_, _) => UserScrolled();
        // The last fix decision with 撤销, along the bottom of the page.
        toastHost.Margin = new Thickness(0, 0, 0, 18);
        toastHost.VerticalAlignment = VerticalAlignment.Bottom; toastHost.HorizontalAlignment = HorizontalAlignment.Center;
        if (toastHost.Parent is Grid old) old.Children.Remove(toastHost);
        var area = new Grid { Children = { scroll, pinned, toastHost } };
        if (footer is not null) area.Children.Add(BackToPlaying()); else backButton = null;
        var whole = new Grid();
        whole.RowDefinitions.Add(new RowDefinition());
        whole.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        whole.Children.Add(area);
        if (footer is not null) { Grid.SetRow(footer, 1); whole.Children.Add(footer); }
        detail.Content = whole;
        ShowToast();
    }

    readonly ContentControl toastHost = new();
    string? toastKey;

    void ShowToast()
    {
        var key = app.Fixes.Toast is { } t ? $"{t.Id}|{app.Fixes.CanUndo}" : null;
        if (key == toastKey && toastHost.Content is not null == (key is not null)) return;
        toastKey = key;
        toastHost.Content = FixViews.Toast(app.Fixes);
    }

    /// 生成纪要 or 复制纪要, 导出… and ···, beside the tabs (and again in the pinned bar).
    StackPanel Tools(Session s, bool live)
    {
        var tools = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top };
        var hasNotes = s.Notes is { IsEmpty: false };
        if (!hasNotes && !live)
        {
            var generating = app.Notes.GeneratingId == s.Id;
            var make = Small(Ui.Button(generating ? L("正在生成…") : L("生成纪要"), () => _ = app.Notes.Generate(s.Id), Ui.Kind.Primary, height: 32));
            make.IsEnabled = !generating;
            tools.Children.Add(make);
        }
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
        // Not while the meeting is still going, nor with nothing in it.
        var share = Small(Ui.Button(L("分享…"), () => app.ShareSheet(s), Ui.Kind.Standard, height: 32));
        share.IsEnabled = !live && (s.Lines.Count > 0 || hasNotes);
        tools.Children.Add(Spaced(share, 8));
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
        return tools;
    }

    static Button Small(Button b) { b.MinWidth = 0; b.Padding = new Thickness(12, 0, 12, 0); return b; }

    Action<ScrollViewer>? pendingJump;

    static T Spaced<T>(T e, double left) where T : FrameworkElement { e.Margin = new Thickness(left, 0, 0, 0); return e; }

    FrameworkElement Notes(Session s, bool live)
    {
        if (s.Notes is not { IsEmpty: false } n)
            return Empty(app.Notes.GeneratingId == s.Id ? L("正在整理纪要…") : live ? L("纪要会在会议进行中自动生成") : L("这场会议还没有纪要"), "");
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
                row.Children.Add(Ui.Text(item.WithOwner, 15, item.Support == 0 ? Palette.Tertiary : Palette.Ink));
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

    // 改这句…: the line being rewritten and what the editor opens with.
    string? editingLine;
    string editingStart = "";

    void EditLine(TranscriptLine l, string start)
    {
        editingLine = l.Id; editingStart = start; tab = "transcript"; jumpLine = l.Id;
        ShowDetail();
    }

    void EditDone() { editingLine = null; ShowDetail(); }

    /// Debug: 改这句… on line `line` of record `id`, as from its menu.
    public void DebugEdit(string id, string line)
    {
        selected = id;
        if (app.Store.Get(id)?.Lines.FirstOrDefault(l => l.Id == line) is { } l) EditLine(l, l.Shown);
    }

    /// A fix count and state per record, so a decision redraws the page.
    static string FixKey(Session s) => string.Join(",", s.Lines.Where(l => l.Fixes is not null).Select(l => string.Join("", l.Fixes!.Select(f => $"{f.From}>{f.To}{(f.Ask == true ? "?" : "")}{(f.Off == true ? "x" : "")}{(f.User == true ? "u" : "")};"))));

    FrameworkElement Transcript(Session s)
    {
        var body = new StackPanel();
        PlayRow? target = null;
        rows.Clear(); lit = -1; hovered = null;
        Action<double>? play = player is not null ? PlayFrom : null;
        // 改正听错的词: over a finished meeting, the fixes waiting for the user and how many were made.
        var live = app.Listen.Listening && app.Listen.SessionId == s.Id;
        if (!live && FixViews.Banner(s, app.Fixes, id => { jumpLine = id; ShowDetail(); }, EditLine) is { } banner)
        {
            banner.Margin = new Thickness(0, 0, 0, 14);
            body.Children.Add(banner);
        }
        // The line nearest the topic's time (older notes may hold a time no line has), or the one asked for.
        var nearest = jumpLine is { } jl ? s.Lines.FirstOrDefault(l => l.Id == jl)
            : jumpTo is { } t0 && s.Lines.Count > 0 ? s.Lines.MinBy(l => Math.Abs(l.T - t0)) : null;
        // The search's terms and the line found being looked at, which the page opens on (centred).
        var terms = SearchTerms(s);
        var found = CurrentMatch(s);
        PlayRow? foundRow = null;
        // Opened at a line while the recording plays: stay there (回到正在播放 goes back).
        if ((nearest is not null || found is not null) && playing) following = false;
        foreach (var (l, who, ink, place) in NotesWindow.Speakers(s.Lines, app.Settings.SpeakerVoices))
        {
            var editor = editingLine == l.Id ? new FixViews.Editor(l, s.Id, app.Fixes, editingStart, EditDone) : null;
            var line = NotesWindow.TranscriptRow(l, who, ink, place, play, revert: f => app.Fixes.Revert(f, l.Id, s.Id),
                edit: () => EditLine(l, l.Shown), editor: editor, terms: terms, found: l.Id == found);
            var menu = new ContextMenu { FontFamily = Palette.Font };
            var item = new MenuItem { Header = L("改这句…") };
            item.Click += (_, _) => EditLine(l, l.Shown);
            menu.Items.Add(item);
            line.ContextMenu = menu;
            var r = Row(l, (Panel)line, play is not null && editor is null);
            if (ReferenceEquals(l, nearest)) target = r;
            if (l.Id == found) foundRow = r;
            body.Children.Add(r.Card);
        }
        // Centred when the search moves to it or the page opens, not on every redraw: a live
        // meeting's next line mustn't pull the reader back from wherever they scrolled.
        var foundKey = found is null ? null : $"{s.Id}|{search.Text.Trim()}|{found}";
        var centre = foundKey != centredFound || !redrawing;
        centredFound = foundKey;
        if (target is null && centre && foundRow is { Card: var foundCard })
        {
            // Measured once laid out, as below.
            pendingJump = scroll =>
            {
                void Jump(object? _, RoutedEventArgs __) { foundCard.Loaded -= Jump; Center(foundCard); }
                foundCard.Loaded += Jump;
            };
        }
        if (target is { } marked)
        {
            // A topic's time opens the transcript at what was said then, marked for a moment.
            marked.Marked = true;
            Paint(marked);
            var row = marked.Card;
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
            fade.Tick += (_, _) => { marked.Marked = false; Paint(marked); fade.Stop(); };
            fade.Start();
        }
        jumpTo = null; jumpLine = null;
        if (player is not null) Dispatcher.BeginInvoke(UpdatePlayer, DispatcherPriority.Loaded);
        return body;
    }

    static TextBlock? FindTime(Panel row) =>
        row.Children.OfType<Panel>().FirstOrDefault()?.Children.OfType<TextBlock>().FirstOrDefault(t => (t.Tag as string) == "time");

    /// A transcript line in the record: the row on a rounded fill (the line playing, or under the
    /// pointer when a click would play it) with the playing bars at its right edge.
    sealed class PlayRow(double t, Border card, TextBlock? time, StackPanel bars, bool playable)
    {
        public double T = t;
        public Border Card = card;
        public TextBlock? Time = time;
        public StackPanel Bars = bars;
        public bool Playable = playable, Marked, ShowsPlay;
    }

    PlayRow Row(TranscriptLine l, Panel line, bool playable)
    {
        // The row's own bottom gap goes inside the fill, half above and half below the text.
        line.Margin = new Thickness(0, line.Margin.Top, 0, line.Margin.Bottom / 2);
        var bars = new StackPanel { Orientation = Orientation.Horizontal, Height = 12, Width = 13, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(8, line.Margin.Top + 3, 0, 0), Visibility = Visibility.Hidden };
        for (int i = 0; i < 3; i++)
            bars.Children.Add(new System.Windows.Shapes.Rectangle { Width = 3, Height = 8, RadiusX = 1.5, RadiusY = 1.5, Fill = Palette.Live, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(i == 0 ? 0 : 2, 0, 0, 0) });
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(bars, 1);
        grid.Children.Add(line); grid.Children.Add(bars);
        var card = new Border
        {
            CornerRadius = new CornerRadius(10), Background = Brushes.Transparent, Child = grid,
            Margin = new Thickness(-10, 0, -10, 0), Padding = new Thickness(10, line.Margin.Bottom, 10, 0),
        };
        var r = new PlayRow(l.T, card, FindTime(line), bars, playable);
        rows.Add(r);
        if (!playable) { bars.Visibility = Visibility.Collapsed; return r; }
        card.MouseEnter += (_, _) => { hovered = r; Paint(r); };
        card.MouseLeave += (_, _) => { if (hovered == r) hovered = null; Paint(r); };
        // A click anywhere on the line plays from it: a press and release without moving (a drag
        // is left alone), not on the time or the line's links, which act on their own.
        Point? down = null;
        card.PreviewMouseLeftButtonDown += (_, e) => down = OnLink(e.OriginalSource as DependencyObject, card) ? null : e.GetPosition(card);
        card.MouseLeftButtonUp += (_, e) =>
        {
            if (down is not { } d) return;
            down = null;
            var p = e.GetPosition(card);
            if (Math.Abs(p.X - d.X) > SystemParameters.MinimumHorizontalDragDistance || Math.Abs(p.Y - d.Y) > SystemParameters.MinimumVerticalDragDistance) return;
            PlayFrom(r.T);
        };
        return r;
    }

    /// The time, 改回 and 改这句… are links (a hand cursor) or buttons that handle their own click.
    static bool OnLink(DependencyObject? d, FrameworkElement stop)
    {
        for (; d is not null && d != stop; d = d is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d))
            if (d is System.Windows.Controls.Primitives.ButtonBase || d is FrameworkElement { Cursor: var c } && c == System.Windows.Input.Cursors.Hand
                || d is FrameworkContentElement { Cursor: var cc } && cc == System.Windows.Input.Cursors.Hand) return true;
        return false;
    }

    /// The line playing on the pale accent with its time in the accent and, while it plays, the
    /// bars; under the pointer a light fill and ▶ before the time; else as it was.
    void Paint(PlayRow r)
    {
        var current = lit >= 0 && lit < rows.Count && rows[lit] == r;
        var hover = r.Playable && hovered == r;
        r.Card.Background = current ? Palette.Playing : r.Marked ? Palette.AccentPale : hover ? Palette.Raised : Brushes.Transparent;
        r.Bars.Visibility = current && playing ? Visibility.Visible : r.Playable ? Visibility.Hidden : Visibility.Collapsed;
        if (r.Time is not { } time) return;
        time.Foreground = current || hover ? Palette.Live : time.Tag as string == "time" ? Palette.TimeLink : Palette.Tertiary;
        time.FontWeight = current || hover ? FontWeights.SemiBold : FontWeights.Normal;
        if (r.ShowsPlay == hover) return;
        r.ShowsPlay = hover;
        var clock = Languages.Clock(r.T);
        time.Inlines.Clear();
        if (hover) time.Inlines.Add(new System.Windows.Documents.Run("▶ ") { FontSize = 8, BaselineAlignment = BaselineAlignment.Center });
        time.Inlines.Add(new System.Windows.Documents.Run(clock));
    }

    /// The bars beside the playing line bounce (as the Mac's PlayingBars); held still when the
    /// system turns animations off.
    void Bounce()
    {
        if (lit < 0 || lit >= rows.Count) return;
        var t = Environment.TickCount64 / 1000.0;
        var still = !SystemParameters.ClientAreaAnimation;
        var i = 0;
        foreach (var bar in rows[lit].Bars.Children.OfType<System.Windows.Shapes.Rectangle>())
            bar.Height = 12 * (still ? 0.7 : 0.35 + 0.65 * Math.Abs(Math.Sin(t * 3.5 + i++ * 0.9)));
    }

    // MARK: 回放

    // One player for the open record, kept while the page redraws (lines and notes arriving) and
    // closed when another record opens, the record is deleted or the window closes.
    MediaPlayer? player;
    string? playerPath;
    bool playing, opened;
    double speed = 1;
    double? pendingSeek;
    readonly DispatcherTimer playTick = new() { Interval = TimeSpan.FromMilliseconds(200) };
    ScrollViewer? pageScroll;
    /// Which meeting and tab `pageScroll` shows: the same page drawn again (a live meeting's new
    /// line, the notes updating) stays where the reader had it instead of going back to the top.
    string? pageScrollKey;
    /// This draw is the same page again (set by ShowDetail for Transcript).
    bool redrawing;
    /// The search's line the page last centred: a redraw that leaves it the same doesn't pull back to it.
    string? centredFound;
    // The transcript's lines with their times, in time order, the one at the playhead and the one
    // under the pointer.
    readonly List<PlayRow> rows = [];
    int lit = -1;
    PlayRow? hovered;
    readonly DispatcherTimer barTick = new() { Interval = TimeSpan.FromMilliseconds(50) };
    /// The transcript keeps the playing line in view. Scrolling it by hand stops that until a line
    /// is picked, the bar is used or 回到正在播放 is pressed: following would yank the page away.
    bool following = true;
    Button? backButton;
    TextBlock? backText;
    // The bar's moving parts, rebuilt with the page.
    TextBlock? nowText, lengthText, speedText;
    Border? played;
    FrameworkElement? thumb;
    Grid? track;
    Button? playButton;
    double fallbackLength;

    /// Under the title: the player for a recording; while live, that it plays afterwards; else
    /// why there is none (and where to turn recording on).
    FrameworkElement? PlayerArea(Session s, bool live)
    {
        FrameworkElement Note(FrameworkElement e) { e.Margin = new Thickness(0, 12, 0, 0); return e; }
        if (live)
        {
            ClosePlayer();
            return app.Settings.RecordAudio ? Note(Ui.Text(L("会议结束后可以回放录音"), 12, Palette.Secondary)) : null;
        }
        var path = Recording.Playable(s);
        if (path is null)
        {
            ClosePlayer();
            // Just ended: system.aac is being rewrapped into system.m4a, a moment.
            if (File.Exists(Recording.Partial(Recording.SystemAudio(s.Id)))) return null;
            if (s.HasAudio || s.SourcePath is not null) return Note(Ui.Text(L("找不到录音，没法播放"), 12, Palette.Secondary));
            if (s.Lines.Count == 0) return null;
            var link = Ui.LinkText(L("保存会议录音"), () => { app.ShowSettings(); app.SettingsPage("privacy"); }, 12);
            return Note(Ui.Row(4, Ui.Text(L("这场会议没存录音 ·"), 12, Palette.Secondary, wrap: false), link));
        }
        if (playerPath != path)
        {
            ClosePlayer();
            playerPath = path;
            opened = false;
            player = new MediaPlayer();
            player.MediaOpened += (_, _) =>
            {
                opened = true;
                if (!playing) player!.Pause(); // MediaPlayer starts playing by itself once opened
                if (pendingSeek is { } t) { pendingSeek = null; player!.Position = TimeSpan.FromSeconds(t); }
                UpdatePlayer();
            };
            player.MediaEnded += (_, _) => Ended();
            player.MediaFailed += (_, e) => Log.Debug($"player: failed {e.ErrorException?.GetType().Name} 0x{e.ErrorException?.HResult:X8}");
            player.Open(new Uri(path));
            player.Pause();
            player.SpeedRatio = speed;
        }
        fallbackLength = s.Duration.TotalSeconds;
        return null;
    }

    /// The player along the bottom of the record, on white under a hairline.
    FrameworkElement PlayerFooter()
    {
        var bar = PlayerBar();
        bar.MaxWidth = 700;
        bar.Margin = new Thickness(48, 10, 48, 10);
        return new Border { Background = Palette.Surface, BorderBrush = Palette.Line, BorderThickness = new Thickness(0, 1, 0, 0), Child = bar };
    }

    /// Scrolled away from what is playing: one way back, at the bottom of the transcript.
    FrameworkElement BackToPlaying()
    {
        backText = Ui.Text("", 13, Brushes.White, FontWeights.SemiBold, wrap: false);
        System.Windows.Documents.Typography.SetNumeralAlignment(backText, FontNumeralAlignment.Tabular);
        var content = Ui.Row(6, Ui.Icon(Icons.Wave, 13, Brushes.White, stroke: 1.8), backText);
        backButton = Capsule(content, Palette.Ink, null, 34, new Thickness(16, 0, 16, 0), Follow, L("回到正在播放"));
        backButton.VerticalAlignment = VerticalAlignment.Bottom;
        backButton.HorizontalAlignment = HorizontalAlignment.Center;
        backButton.Margin = new Thickness(0, 0, 0, 16);
        backButton.Effect = new System.Windows.Media.Effects.DropShadowEffect { Color = Color.FromRgb(0x15, 0x17, 0x1C), Opacity = 0.18, BlurRadius = 20, ShadowDepth = 4, Direction = 270 };
        UpdateBack();
        return backButton;
    }

    void UpdateBack()
    {
        if (backButton is null || backText is null) return;
        var show = !following && player is not null && lit >= 0 && lit < rows.Count;
        backButton.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        if (show) backText.Text = L("回到正在播放") + " · " + Languages.Clock(rows[lit].T);
    }

    /// The transcript was scrolled by hand while it plays.
    void UserScrolled()
    {
        if (!following || !playing || player is null || tab != "transcript") return;
        following = false;
        Log.Debug($"player: stopped following at line {lit}");
        UpdateBack();
    }

    /// 回到正在播放 (and a line picked, or the bar used): follow again, from the playing line.
    void Follow()
    {
        var was = following;
        following = true;
        UpdateBack();
        if (!was && lit >= 0 && lit < rows.Count) Center(rows[lit].Card);
    }

    Border PlayerBar()
    {
        playButton = Capsule(Ui.Icon(playing ? Icons.Pause : Icons.Play, 14, Brushes.White, fill: true), Palette.Ink, null, 36, new Thickness(0), TogglePlay, playing ? L("暂停") : L("播放"));
        playButton.Width = 36;
        playButton.ToolTip = playing ? L("暂停") : L("播放");
        nowText = Clock("00:00");
        lengthText = Clock(Languages.Clock(fallbackLength));
        speedText = Ui.Text(SpeedLabel(), 12, Palette.Body, Palette.Strong, wrap: false);
        var speedButton = Capsule(speedText, Palette.Surface, Palette.Line, 26, new Thickness(9, 0, 9, 0), CycleSpeed, L("播放速度"));
        speedButton.ToolTip = L("播放速度");

        // The slider: a grey rail, the played part in the accent, a round handle; click or drag.
        var rail = new Border { Height = 4, CornerRadius = new CornerRadius(2), Background = Palette.Line, VerticalAlignment = VerticalAlignment.Center };
        played = new Border { Height = 4, CornerRadius = new CornerRadius(2), Background = Palette.Live, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Left, Width = 0 };
        thumb = new System.Windows.Shapes.Ellipse { Width = 12, Height = 12, Fill = Palette.Live, Stroke = Brushes.White, StrokeThickness = 2, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Left };
        track = new Grid { Height = 24, Background = Brushes.Transparent, Cursor = System.Windows.Input.Cursors.Hand, Margin = new Thickness(12, 0, 12, 0), Children = { rail, played, thumb } };
        System.Windows.Automation.AutomationProperties.SetName(track, L("播放"));
        void SeekTo(System.Windows.Input.MouseEventArgs e)
        {
            if (track.ActualWidth <= 0) return;
            var f = Math.Clamp(e.GetPosition(track).X / track.ActualWidth, 0, 1);
            Seek(f * Length());
        }
        track.MouseLeftButtonDown += (_, e) => { track.CaptureMouse(); SeekTo(e); e.Handled = true; };
        track.MouseMove += (_, e) => { if (track.IsMouseCaptured) SeekTo(e); };
        track.MouseLeftButtonUp += (_, _) => track.ReleaseMouseCapture();
        track.SizeChanged += (_, _) => UpdatePlayer();

        var bar = new DockPanel { LastChildFill = true };
        foreach (var (e, dock, left) in new (FrameworkElement, Dock, double)[] { (playButton, Dock.Left, 0), (nowText, Dock.Left, 12), (speedButton, Dock.Right, 12), (lengthText, Dock.Right, 0) })
        {
            e.VerticalAlignment = VerticalAlignment.Center;
            e.Margin = new Thickness(left, 0, 0, 0);
            DockPanel.SetDock(e, dock);
            bar.Children.Add(e);
        }
        bar.Children.Add(track);
        Dispatcher.BeginInvoke(UpdatePlayer, DispatcherPriority.Loaded);
        return new Border
        {
            Background = Palette.PlayerFill, BorderBrush = Palette.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12),
            Padding = new Thickness(8, 8, 10, 8), Child = bar,
        };

        static TextBlock Clock(string text)
        {
            var t = Ui.Text(text, 12, Palette.Secondary, wrap: false);
            System.Windows.Documents.Typography.SetNumeralAlignment(t, FontNumeralAlignment.Tabular);
            return t;
        }
    }

    string SpeedLabel() => speed == 1 ? "1×" : speed == 1.5 ? "1.5×" : "2×";

    double Length() => player is { NaturalDuration.HasTimeSpan: true } p ? p.NaturalDuration.TimeSpan.TotalSeconds : fallbackLength;

    double Now() => pendingSeek ?? player?.Position.TotalSeconds ?? 0;

    void TogglePlay()
    {
        if (player is null) return;
        if (playing) { player.Pause(); playing = false; playTick.Stop(); }
        else { player.Play(); playing = true; playTick.Start(); }
        Log.Debug($"player: {(playing ? "play" : "pause")} at {Now():F1}");
        UpdatePlayer(reveal: playing);
    }

    /// A line's time: play from there.
    void PlayFrom(double t)
    {
        if (player is null) return;
        Seek(t);
        player.Play();
        playing = true;
        playTick.Start();
        Log.Debug($"player: play from {t:F1}");
        UpdatePlayer(reveal: true);
    }

    void Seek(double t)
    {
        if (player is null) return;
        t = Math.Clamp(t, 0, Math.Max(0, Length()));
        if (opened) player.Position = TimeSpan.FromSeconds(t); else pendingSeek = t;
        // A seek (the bar, or a line picked) follows the recording again.
        var resume = !following;
        following = true;
        UpdatePlayer();
        if (resume && lit >= 0 && lit < rows.Count) Center(rows[lit].Card);
    }

    /// Played to the end: back to the start, paused.
    void Ended()
    {
        if (player is null) return;
        player.Pause();
        player.Position = TimeSpan.Zero;
        playing = false;
        playTick.Stop();
        UpdatePlayer();
    }

    void CycleSpeed()
    {
        speed = speed == 1 ? 1.5 : speed == 1.5 ? 2 : 1;
        if (player is not null) player.SpeedRatio = speed;
        if (speedText is not null) speedText.Text = SpeedLabel();
    }

    /// The bar and the lit line follow the playhead (every 200 ms while playing).
    void UpdatePlayer() => UpdatePlayer(false);

    /// `reveal`: playing just started, so the lit line is scrolled to even if it was lit already.
    void UpdatePlayer(bool reveal)
    {
        if (player is null) return;
        var now = Now();
        var length = Length();
        // MediaEnded doesn't always come (a PC with no sound device plays on past the end).
        if (playing && opened && length > 0 && now >= length) { Ended(); return; }
        if (nowText is not null) nowText.Text = Languages.Clock(now);
        if (lengthText is not null) lengthText.Text = Languages.Clock(length);
        if (playButton is not null)
        {
            var icon = playing ? Icons.Pause : Icons.Play;
            if (playButton.Tag as string != icon)
            {
                playButton.Tag = icon;
                playButton.Content = Ui.Icon(icon, 14, Brushes.White, fill: true);
                playButton.ToolTip = playing ? L("暂停") : L("播放");
                System.Windows.Automation.AutomationProperties.SetName(playButton, playing ? L("暂停") : L("播放"));
            }
        }
        if (track is not null && played is not null && thumb is not null && track.ActualWidth > 0)
        {
            var x = track.ActualWidth * (length > 0 ? Math.Clamp(now / length, 0, 1) : 0);
            played.Width = x;
            thumb.Margin = new Thickness(Math.Max(0, Math.Min(track.ActualWidth - thumb.Width, x - thumb.Width / 2)), 0, 0, 0);
        }
        // The line being said: the last one starting by now (a little ahead, so it lights as it
        // begins); once playback has begun it stays lit while paused.
        var at = playing || now > 0 ? rows.FindLastIndex(r => r.T <= now + 0.2) : -1;
        var was = lit;
        lit = at;
        if (was != at && was >= 0 && was < rows.Count) Paint(rows[was]);
        if (at >= 0)
        {
            // Every tick: the bars come and go with play and pause.
            Paint(rows[at]);
            if (playing && following && (at != was || reveal)) Center(rows[at].Card);
        }
        barTick.IsEnabled = playing && at >= 0;
        UpdateBack();
    }

    /// Scrolls the playing line to the middle of the transcript.
    void Center(FrameworkElement row)
    {
        if (pageScroll is not { } scroll || !row.IsLoaded) return;
        var y = row.TransformToAncestor(scroll).Transform(new Point(0, 0)).Y;
        scroll.ScrollToVerticalOffset(Math.Max(0, scroll.VerticalOffset + y - (scroll.ViewportHeight - row.ActualHeight) / 2));
    }

    void ClosePlayer()
    {
        playTick.Stop();
        playing = false;
        pendingSeek = null;
        if (player is not null)
        {
            player.Stop();
            player.Close();
            player = null;
        }
        playerPath = null;
        lit = -1;
        barTick.Stop();
        following = true;
    }

    /// For the debug pipe: where playback is, the lit line (index and time), whether the transcript
    /// follows it (and 回到正在播放 shows), and the line under the pointer.
    public string PlayerState() => player is null ? "none"
        : $"{(playing ? "playing" : "paused")} {Now():F1}/{Length():F1} x{speed} line {lit}{(lit >= 0 && lit < rows.Count ? $"@{rows[lit].T:F1}" : "")}"
          + $" following {(following ? "yes" : "no")} back {(backButton?.Visibility == Visibility.Visible ? "shown" : "hidden")}"
          + $" hover {(hovered is { } h ? rows.IndexOf(h) : -1)} offset {pageScroll?.VerticalOffset:F0}";

    /// "follow": 回到正在播放, as clicked; "row <i>": line i clicked.
    public void DebugPlay(string arg)
    {
        if (arg == "toggle") TogglePlay();
        else if (arg == "speed") CycleSpeed();
        else if (arg == "follow") Follow();
        else if (arg.StartsWith("row ") && int.TryParse(arg[4..], out var i) && i >= 0 && i < rows.Count && rows[i].Playable) PlayFrom(rows[i].T);
        else if (double.TryParse(arg, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var t)) PlayFrom(t);
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
        {
            ClosePlayer(); // it holds the recording open
            app.Store.Delete(s.Id);
            app.FolderExport.Deleted(s.Id); // its file in the folder stays
        }
    }
}
