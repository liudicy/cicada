using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using static Cicada.Strings;

namespace Cicada.App;

/// Left-click on the tray icon when not listening (while listening the click shows or hides the
/// notes window instead, which sits in the same corner): Cicada's home, the counterpart of the
/// Mac's menu bar panel. It rises above the notification area and goes away when it loses focus.
sealed class TrayFlyout : Window
{
    readonly Controller app;
    readonly ContentControl body = new();
    readonly DispatcherTimer clock = new() { Interval = TimeSpan.FromSeconds(1) };
    DateTime hiddenAt;

    public TrayFlyout(Controller app)
    {
        this.app = app;
        // The Mac panel's 16-point corners and soft shadow (Ui.Floating), so a transparent window.
        WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent;
        Topmost = true; ShowInTaskbar = false; ResizeMode = ResizeMode.NoResize;
        Width = 360 + 2 * Ui.ShadowRoom; SizeToContent = SizeToContent.Height; FontFamily = Palette.Font; Title = L("知了");
        Content = Ui.Floating(body, Palette.Surface);
        Deactivated += (_, _) => { Hide(); hiddenAt = DateTime.UtcNow; };
        KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Escape) Hide(); };
        SizeChanged += (_, _) => Anchor();
        clock.Tick += (_, _) => { if (app.Listen.Listening) Refresh(); };
        IsVisibleChanged += (_, _) => { if (IsVisible) clock.Start(); else clock.Stop(); };
    }

    /// Opens, or closes when it is already open (a second click on the icon). A click that just
    /// closed it by taking focus away doesn't reopen it straight away.
    public void Toggle()
    {
        if (IsVisible) { Hide(); return; }
        if ((DateTime.UtcNow - hiddenAt).TotalMilliseconds < 300) return;
        app.PanelOpened();
        Refresh();
        Show();
        Anchor();
        Activate();
    }

    /// Next to the notification area, on whichever edge the taskbar is.
    void Anchor()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Left > 0 ? area.Left + 12 - Ui.ShadowRoom : area.Right - ActualWidth - 12 + Ui.ShadowRoom;
        Top = area.Top > 0 ? area.Top + 12 - Ui.ShadowRoom : area.Bottom - ActualHeight - 12 + Ui.ShadowRoom;
    }

    public void Refresh() => body.Content = Build();

    void Do(Action act) { Hide(); act(); }

    // The Mac's menu bar panel (Views.swift › MenuPanel): who and how it is, the one big button,
    // the choices made before a meeting on grey rows, 同声传译, what shows while listening, and two
    // buttons at the bottom. Two weights only (Palette.Strong).
    FrameworkElement Build()
    {
        var listen = app.Listen;
        var s = app.Settings;
        var stack = new StackPanel { Margin = new Thickness(18, 18, 18, 18) };

        var status = listen.Listening && listen.SessionId is { } sid && app.Store.Get(sid) is { } live
            ? Ui.Row(6, Ui.LiveDot(6), Ui.Text($"{L("正在听")} {Languages.Clock((DateTimeOffset.Now - live.StartedAt).TotalSeconds)}", 13, Palette.Secondary, wrap: false))
            : app.AutoEnded
                ? Ui.Row(6, Ui.Dot(Palette.Tertiary, 6), Ui.Text(L("会议已自动结束"), 13, Palette.Secondary, wrap: false))
            : app.Ling.HasKey
                ? Ui.Row(6, Ui.Dot(Palette.Toggle, 6), Ui.Text(L("没在听"), 13, Palette.Secondary, wrap: false))
                : Ui.Row(6, Ui.Dot(Palette.Tertiary, 6), Ui.Text(L("还没接上 Ling"), 13, Palette.Secondary, wrap: false));
        var title = Ui.Row(12, AppIcon.Small(40), Ui.Stack(1, Ui.Text(L("知了"), 17, Palette.Ink, Palette.Strong, wrap: false), status));
        var head = Ui.Spread(title, Ui.IconButton(Icons.Gear, L("打开设置"), () => Do(app.ShowSettings), Palette.Body, 36, 18));
        stack.Children.Add(head);

        // A newer release (the Mac's UpdateBanner), right under the header: Cicada downloads the
        // installer, checks it and opens it.
        if (app.Updates.Available is { } update)
        {
            var size = update.Size > 0 ? $"{update.Size / 1_048_576.0:0} MB · " : "";
            var detail = app.UpdateProgress is { } p0 ? LF("正在下载 %@：%lld%%", update.Version, (long)(p0 * 100))
                : app.UpdateFailure is { } f ? LF("没能自动更新：%@。已打开下载页", f)
                : size + SettingsWindow.UpdateHint(update);
            var text = Ui.Stack(2, Ui.Text(LF("新版本 %@", update.Version), 13, Palette.Ink, Palette.Strong, wrap: false),
                                Ui.Text(detail, 11, Palette.Secondary),
                                Ui.LinkText(L("更新说明"), () => Do(app.OpenReleaseNotes), 11));
            var download = Ui.Button(update.Setup is null ? L("下载") : app.UpdateFailure is null ? L("安装") : L("重试"), app.InstallUpdate, Ui.Kind.Primary, height: 30);
            download.IsEnabled = app.UpdateProgress is null;
            var dock = new DockPanel();
            DockPanel.SetDock(download, Dock.Right);
            download.VerticalAlignment = VerticalAlignment.Center; download.Margin = new Thickness(10, 0, 0, 0);
            var dot = Ui.Dot(Palette.Live, 7);
            dot.Margin = new Thickness(0, 5, 8, 0); dot.VerticalAlignment = VerticalAlignment.Top;
            DockPanel.SetDock(dot, Dock.Left);
            dock.Children.Add(download); dock.Children.Add(dot); dock.Children.Add(text);
            var strip = new Border { Background = Palette.AccentPale, CornerRadius = new CornerRadius(9), Padding = new Thickness(10), Margin = new Thickness(0, 14, 0, 0), Child = dock };
            stack.Children.Add(strip);
        }

        // The one thing to do
        var main = new StackPanel { Margin = new Thickness(0, 18, 0, 0) };
        if (listen.Listening && app.Ending is { } p)
        {
            // About to end by itself (MeetingEndingStrip, compact): the panel takes no focus either.
            var strip = Ui.Stack(3, Ui.Text(app.EndingTitle(p), 13, Palette.Ink, FontWeights.Bold),
                                 Ui.Text(LF("%lld 秒后结束会议并整理纪要", Controller.EndingLeft(p)), 12, Palette.Secondary));
            var keep = Ui.Row(8, Ui.Button(L("继续记录"), app.KeepRecording, Ui.Kind.Primary, height: 32),
                              Ui.Button(L("现在结束"), () => { Hide(); _ = app.StopListening(); }, height: 32));
            keep.Margin = new Thickness(0, 8, 0, 0);
            strip.Children.Add(keep);
            main.Children.Add(new Border { Background = Palette.AccentPale, CornerRadius = new CornerRadius(10), Padding = new Thickness(12), Margin = new Thickness(0, 0, 0, 10), Child = strip });
        }
        if (listen.Listening)
        {
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(8) });
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            var end = Ui.Button(L("结束"), () => Do(app.RequestStop), Ui.Kind.Pale, Icons.Stop, 48, iconFill: true);
            var showing = app.NotesVisible;
            var show = Ui.Button(showing ? L("隐藏纪要窗") : L("显示纪要"), () => Do(app.ToggleNotes), Ui.Kind.Standard, Icons.Notes, 48);
            Grid.SetColumn(show, 2);
            grid.Children.Add(end); grid.Children.Add(show);
            main.Children.Add(grid);
        }
        else
        {
            var label = Ui.Row(10, Ui.Dot(Palette.Live, 8), Ui.Text(L("开始听"), 15, Brushes.White, Palette.Strong, wrap: false), DarkKey(Hotkey.Label.Replace('+', ' ')));
            var start = new Button { Content = label, Height = 48, HorizontalAlignment = HorizontalAlignment.Stretch, Background = Palette.Ink, BorderThickness = new Thickness(0), Cursor = System.Windows.Input.Cursors.Hand, HorizontalContentAlignment = HorizontalAlignment.Center };
            start.Template = Surface(12, dim: true);
            start.Click += (_, _) => Do(() => _ = app.ToggleListening());
            System.Windows.Automation.AutomationProperties.SetName(start, L("开始听"));
            main.Children.Add(start);
        }
        stack.Children.Add(main);

        // The choice people change before a meeting
        var spoken = Languages.Targets.FirstOrDefault(t => t.Code == Languages.FromSystem(System.Globalization.CultureInfo.CurrentUICulture.Name))?.Code;
        var target = s.Target == "system" ? spoken ?? "zh-Hans" : s.Target;
        stack.Children.Add(Gap(ChoiceRow(L("翻译成"), Ui.TargetName(target), s.Target == "system" ? L("跟随系统") : null, Ui.TargetOptions(), s.Target, app.SetTarget), 12));

        // 同声传译
        stack.Children.Add(Rule());
        var cable = Endpoints.Cable() is not null;
        var speakState = s.Speak && cable && app.Ling.HasKey
            ? (UIElement)Ui.Text(L("对方听得到"), 12, Palette.Success, wrap: false)
            : Ui.LinkText(s.Speak ? L("去设置") : L("打开"), () => Do(app.ShowSettings), 12);
        stack.Children.Add(Ui.Spread(Ui.Text(L("同声传译"), 14, Palette.Ink, Palette.Strong, wrap: false), speakState));
        var talk = Ui.Row(12, Ui.Keycap(PushToTalk.Label, big: false), Ui.Stack(1,
            Ui.Text(s.Speak ? LF("按住%@说话", PushToTalk.Label) : L("同声传译没打开"), 14, Palette.Ink, wrap: false),
            Ui.Text(LF("对方听到 %@", Ui.TargetName(app.Speak.Target)), 12, Palette.Secondary, wrap: false)));
        stack.Children.Add(Gap(new Border { BorderBrush = Palette.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12), Padding = new Thickness(12, 10, 12, 10), Child = talk, Opacity = s.Speak ? 1 : 0.7 }, 10));

        // What shows while listening
        stack.Children.Add(Rule());
        stack.Children.Add(Ui.Text(L("听的时候显示"), 14, Palette.Ink, Palette.Strong, wrap: false));
        var tiles = new System.Windows.Controls.Primitives.UniformGrid { Rows = 1, Margin = new Thickness(0, 10, 0, 0) };
        tiles.Children.Add(Tile("notes", L("纪要"), NotesPicture()));
        tiles.Children.Add(Tile("subtitles", L("字幕条"), BarPicture()));
        stack.Children.Add(tiles);

        // Two buttons along the bottom
        stack.Children.Add(Rule());
        var foot = new Grid();
        foot.ColumnDefinitions.Add(new ColumnDefinition());
        foot.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(8) });
        foot.ColumnDefinitions.Add(new ColumnDefinition());
        var records = Ui.Button(L("会议记录"), () => Do(app.ShowRecords), Ui.Kind.Standard, Icons.Notes, 42);
        var quit = Ui.Button(L("退出"), () => Do(() => _ = app.Quit()), Ui.Kind.Standard, Icons.Power, 42);
        Grid.SetColumn(quit, 2);
        foot.Children.Add(records); foot.Children.Add(quit);
        stack.Children.Add(foot);
        return stack;
    }

    static FrameworkElement Gap(FrameworkElement e, double top) { e.Margin = new Thickness(e.Margin.Left, top, e.Margin.Right, e.Margin.Bottom); return e; }

    static FrameworkElement Rule() => new Border { Height = 1, Background = Palette.Line, Margin = new Thickness(0, 16, 0, 16) };

    /// The shortcut inside the ink button: a keycap drawn for a dark ground.
    static FrameworkElement DarkKey(string keys) => new Border
    {
        BorderBrush = new SolidColorBrush(Color.FromArgb(0x55, 0xFF, 0xFF, 0xFF)), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(5),
        Padding = new Thickness(6, 1, 6, 2), Child = Ui.Text(keys, 12, Palette.NightText, wrap: false),
    };

    /// A grey row: what it is on the left in grey, the choice in ink with maybe a pale tag, a chevron;
    /// a click opens the choices.
    FrameworkElement ChoiceRow(string label, string value, string? tag, IEnumerable<(string value, string label)> options, string selected, Action<string> changed)
    {
        var name = Ui.Text(label, 13, Palette.Secondary, wrap: false);
        name.MinWidth = 76; name.Margin = new Thickness(0, 0, 12, 0);  // "Translate to" runs wider than 翻译成
        var shown = Ui.Row(8, Ui.Text(value, 15, Palette.Ink, wrap: false));
        if (tag is not null) ((StackPanel)shown).Children.Add(Gap2(Ui.Badge(tag)));
        var chevron = Ui.Icon(Icons.Chevron, 14, Palette.Secondary, stroke: 1.6);
        var dock = new DockPanel();
        DockPanel.SetDock(name, Dock.Left); DockPanel.SetDock(chevron, Dock.Right);
        dock.Children.Add(name); dock.Children.Add(chevron); dock.Children.Add(shown);
        name.VerticalAlignment = VerticalAlignment.Center;
        var b = new Button { Content = dock, Height = 52, HorizontalAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(14, 0, 14, 0), Background = Palette.Mica, BorderThickness = new Thickness(0), Cursor = System.Windows.Input.Cursors.Hand, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        b.Template = Surface(12, dim: false);
        b.Click += (_, _) =>
        {
            var menu = new ContextMenu { PlacementTarget = b, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom, FontFamily = Palette.Font, MinWidth = b.ActualWidth };
            foreach (var (v, text) in options)
            {
                var item = new MenuItem { Header = text, IsCheckable = true, IsChecked = v == selected };
                item.Click += (_, _) => { changed(v); Refresh(); };
                menu.Items.Add(item);
            }
            menu.IsOpen = true;
        };
        System.Windows.Automation.AutomationProperties.SetName(b, $"{label} {value}");
        return b;
        static FrameworkElement Gap2(FrameworkElement e) { e.Margin = new Thickness(8, 0, 0, 0); return e; }
    }

    /// One of 纪要 / 字幕条: a small picture of what shows on screen, the chosen one outlined in ink.
    FrameworkElement Tile(string view, string label, FrameworkElement picture)
    {
        var on = app.Settings.View == view;
        var content = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Children = { picture, Gap(Ui.Text(label, 13, Palette.Ink, wrap: false), 8) } };
        ((FrameworkElement)content.Children[1]).HorizontalAlignment = HorizontalAlignment.Center;
        var b = new Button
        {
            Content = content, Height = 76, HorizontalAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(view == "notes" ? 0 : 4, 0, view == "notes" ? 4 : 0, 0),
            Background = on ? Palette.Surface : Palette.Mica, BorderBrush = on ? Palette.Ink : Brushes.Transparent, BorderThickness = new Thickness(on ? 2 : 0),
            Cursor = System.Windows.Input.Cursors.Hand,
        };
        b.Template = Surface(12, dim: false);
        b.Click += (_, _) => { app.SetView(view); Refresh(); };
        System.Windows.Automation.AutomationProperties.SetName(b, label);
        return b;
    }

    static FrameworkElement NotesPicture() => Frame(new StackPanel { Margin = new Thickness(5, 5, 5, 0), Children = { Bar(16), Bar(12), Bar(14) } });
    static FrameworkElement BarPicture() => Frame(new Border { Height = 4, Width = 16, CornerRadius = new CornerRadius(1), Background = Palette.Body, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 4) });
    static FrameworkElement Bar(double w) => new Border { Height = 1.5, Width = w, Background = Palette.Body, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 0, 0, 3) };
    static FrameworkElement Frame(UIElement inside) => new Border
    {
        Width = 30, Height = 22, CornerRadius = new CornerRadius(3), BorderBrush = Palette.Secondary, BorderThickness = new Thickness(1.2), Background = Brushes.White,
        HorizontalAlignment = HorizontalAlignment.Center, Child = inside,
    };

    /// A button surface with the bound background and border; hover darkens or dims it. The theme's
    /// Button style aligns left, so every button built on it says Stretch itself.
    static ControlTemplate Surface(double radius, bool dim)
    {
        var t = new ControlTemplate(typeof(Button));
        var border = new FrameworkElementFactory(typeof(Border), "bg");
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(radius));
        foreach (var (dp, path) in new[] { (Border.BackgroundProperty, "Background"), (Border.BorderBrushProperty, "BorderBrush"), (Border.BorderThicknessProperty, "BorderThickness"), (Border.PaddingProperty, "Padding") })
            border.SetBinding(dp, new System.Windows.Data.Binding(path) { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetBinding(ContentPresenter.HorizontalAlignmentProperty, new System.Windows.Data.Binding("HorizontalContentAlignment") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        content.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(content);
        t.VisualTree = border;
        var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        if (dim) hover.Setters.Add(new Setter(UIElement.OpacityProperty, 0.9));
        else hover.Setters.Add(new Setter(Border.BackgroundProperty, Palette.Selected, "bg"));
        t.Triggers.Add(hover);
        return t;
    }
}
