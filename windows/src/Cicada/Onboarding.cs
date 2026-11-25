using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using static Cicada.Strings;

namespace Cicada.App;

/// First run, as the Mac's setup window without Windows' title bar: the logo and a bar per step
/// along the top, a big heading with one grey line, the task in white cards, Back / Continue at the
/// bottom. Windows needs no permission for system audio and listening needs an AI key (recognition
/// is Ming's, or another service's hear model behind 用不了 Ling？), so: 接 Ling → 听声音 → 看效果 →
/// 同声传译, then where the tray icon lives.
sealed class Onboarding : Window
{
    readonly Controller app;
    readonly ContentControl stepper = new(), page = new(), footer = new();
    int step;
    const int Steps = 4;
    SystemAudioTap? tap;
    readonly DispatcherTimer meter = new() { Interval = TimeSpan.FromMilliseconds(80) };
    readonly double[] levels = new double[9];
    double level, peak;
    bool autoStart = true, playing;
    // 同声传译 is on while its step is showing (so 右 Ctrl can be tried); this is what it was before.
    bool? speakBefore;
    // Step 1: the key field and what we know about it
    readonly PasswordBox keyBox = new() { FontSize = 14, MinHeight = 34, VerticalContentAlignment = VerticalAlignment.Center };
    readonly TextBox keyText = new() { FontSize = 14, MinHeight = 34, VerticalContentAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
    readonly ContentControl keyStatus = new();
    bool checking;
    // A pasted key's prefix said something (a management key, another service's): that stays until the next paste.
    bool hinting;

    /// Opened by the installer: step 1 says so, and 开机时启动知了 shows what the installer set.
    readonly bool installed;
    /// The first page after installing carries 已装好: the installer's window becomes this one.
    readonly int badgeStep;

    public Onboarding(Controller app, bool installed = false)
    {
        this.app = app;
        this.installed = installed;
        if (installed) autoStart = AutoStart.Enabled;
        Title = L("设置知了");
        Width = 860; Height = 640; ResizeMode = ResizeMode.CanMinimize;
        Background = Palette.Page; FontFamily = Palette.Font; Icon = AppIcon.Image;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var dock = new DockPanel();
        DockPanel.SetDock(stepper, Dock.Top);
        DockPanel.SetDock(footer, Dock.Bottom);
        // The page scrolls if it must (a failed check's reason and proxy hint under the key).
        dock.Children.Add(stepper); dock.Children.Add(footer);
        dock.Children.Add(new ScrollViewer { Content = page, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Content = Ui.Frameless(this, dock, resizable: false, captionHeight: 24);
        meter.Tick += (_, _) => { if (step == 1) Meter(); };
        app.Speak.Changed += SpeakChanged;
        app.Ling.Changed += LingChanged;
        Closed += (_, _) => { StopTap(); app.Speak.Changed -= SpeakChanged; app.Ling.Changed -= LingChanged; LeaveSpeak(keep: false); };
        System.Windows.Automation.AutomationProperties.SetName(keyBox, L("API key"));
        System.Windows.Automation.AutomationProperties.SetName(keyText, L("API key"));
        keyBox.PasswordChanged += (_, _) => { if (keyText.Text != keyBox.Password) keyText.Text = keyBox.Password; };
        keyText.TextChanged += (_, _) => { if (keyBox.Password != keyText.Text) keyBox.Password = keyText.Text; };
        step = app.Ling.HasKey ? 1 : 0;
        badgeStep = installed ? step : -1;
        Render();
    }

    /// Dev: open on a given step (cicadactl show onboarding <n>).
    public Onboarding At(int to) { Go(to); return this; }

    void Go(int to)
    {
        StopTap();
        if (step == 3 && to != 3) LeaveSpeak(keep: to > 3 && Endpoints.Cable() is not null);
        if (to > Steps)
        {
            AutoStart.Enabled = autoStart;
            app.Settings.Onboarded = true; app.Settings.Save();
            Close();
            app.ShowFlyout();
            return;
        }
        step = Math.Max(0, to);
        if (step == 3 && speakBefore is null) { speakBefore = app.Settings.Speak; app.Settings.Speak = true; }
        Render();
    }

    /// Leaving 同声传译: keep it on (继续, with the virtual mic in), or put back what it was.
    void LeaveSpeak(bool keep)
    {
        if (speakBefore is not { } before) return;
        app.Settings.Speak = keep || before;
        app.Settings.Save();
        speakBefore = null;
    }

    // The service the key page was last shown for: another one's status and key don't carry over.
    string? shownProvider;

    void Render()
    {
        if (shownProvider != app.Settings.AiProvider) { shownProvider = app.Settings.AiProvider; keyBox.Clear(); keyStatus.Content = null; hinting = false; }
        stepper.Content = Stepper();
        page.Content = step switch { 0 => Other ? OtherStep() : KeyStep(), 1 => AudioStep(), 2 => SampleStep(), 3 => SpeakStep(), _ => DoneStep() };
        footer.Content = Footer();
    }

    // The Mac's setup layout (Onboarding.swift): the logo and a bar per step along the top. The last
    // page isn't a step: the logo alone.
    FrameworkElement Stepper()
    {
        var grid = new Grid { Margin = new Thickness(64, 36, 64, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var logo = AppIcon.Small(34);
        logo.Margin = new Thickness(0, 0, 14, 0); logo.VerticalAlignment = VerticalAlignment.Top;
        grid.Children.Add(logo);
        if (step >= Steps) return grid;
        string[] names = [Other ? L("接 AI 服务") : L("接 Ling"), L("听声音"), L("看效果"), L("同声传译")];
        for (int i = 0; i < names.Length; i++) grid.ColumnDefinitions.Add(new ColumnDefinition());
        for (int i = 0; i < names.Length; i++)
        {
            var bar = new Border { Height = 4, CornerRadius = new CornerRadius(2), Background = i <= step ? Palette.Ink : Palette.Line };
            var name = Ui.Text(names[i], 13, i == step ? Palette.Ink : Palette.Secondary, wrap: false);
            name.Margin = new Thickness(0, 9, 0, 0);
            var col = new StackPanel { Margin = new Thickness(i == 0 ? 0 : 6, 8, 0, 0), Children = { bar, name } };
            Grid.SetColumn(col, i + 1);
            grid.Children.Add(col);
        }
        return grid;
    }

    FrameworkElement Page(string title, string text, params UIElement[] body)
    {
        var s = new StackPanel { Margin = new Thickness(64, 30, 64, 0) };
        if (step == badgeStep)
        {
            var note = Ui.Row(10, Ui.Badge(L("已装好"), new SolidColorBrush(Color.FromRgb(0xE3, 0xF1, 0xE8)), Palette.Success),
                Ui.Text(L("开始菜单里有知了了，安装包可以删掉"), 12, Palette.Secondary, wrap: false));
            note.Margin = new Thickness(0, 0, 0, 14);
            s.Children.Add(note);
        }
        s.Children.Add(Ui.Text(title, 30, Palette.Ink, FontWeights.Bold));
        var p = Ui.Text(text, 14, Palette.Secondary);
        p.Margin = new Thickness(0, 8, 0, 0); p.LineHeight = 22;
        s.Children.Add(p);
        var head = s.Children.Count;
        foreach (var b in body) { if (b is FrameworkElement f) f.Margin = new Thickness(f.Margin.Left, f.Margin.Top + (s.Children.Count == head ? 24 : 16), f.Margin.Right, f.Margin.Bottom); s.Children.Add(b); }
        return s;
    }

    /// The Mac's white step card: 18-point corners, no line on the grey ground.
    static Border StepCard(UIElement child, Thickness? padding = null) => new()
    {
        Background = Brushes.White, CornerRadius = new CornerRadius(18),
        Padding = padding ?? new Thickness(22, 20, 22, 20), Child = child,
    };

    /// Two cards side by side, the first wider.
    static Grid Columns(UIElement main, UIElement side, double sideWidth = 236)
    {
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(sideWidth) });
        Grid.SetColumn(side, 2);
        g.Children.Add(main); g.Children.Add(side);
        return g;
    }

    /// The lead of a numbered row: a grey disc with the number, or a green-tinted tick once it's done.
    static FrameworkElement Disc(int n, bool done = false)
    {
        var disc = new Grid { Width = 26, Height = 26, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 0, 14, 0) };
        disc.Children.Add(new Ellipse { Fill = done ? new SolidColorBrush(Color.FromRgb(0xE3, 0xF1, 0xE8)) : Palette.Mica });
        if (done) disc.Children.Add(Ui.Icon(Icons.Check, 14, Palette.Success, stroke: 1.8));
        else { var num = Ui.Text($"{n}", 13, Palette.Ink, wrap: false); num.HorizontalAlignment = HorizontalAlignment.Center; num.VerticalAlignment = VerticalAlignment.Center; disc.Children.Add(num); }
        return disc;
    }

    /// A numbered row in a step card: the disc, a line in ink, a grey line, and maybe a control.
    static FrameworkElement Numbered(FrameworkElement lead, string title, string? detail, UIElement? right = null, UIElement? below = null)
    {
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(Ui.Text(title, 16, Palette.Ink));
        if (detail is not null) { var d = Ui.Text(detail, 13, Palette.Secondary); d.Margin = new Thickness(0, 3, 0, 0); text.Children.Add(d); }
        if (below is FrameworkElement b) { b.Margin = new Thickness(0, 14, 0, 0); text.Children.Add(b); }
        var dock = new DockPanel();
        DockPanel.SetDock(lead, Dock.Left);
        dock.Children.Add(lead);
        if (right is FrameworkElement r) { DockPanel.SetDock(r, Dock.Right); r.VerticalAlignment = below is null ? VerticalAlignment.Center : VerticalAlignment.Top; r.HorizontalAlignment = HorizontalAlignment.Right; r.Margin = new Thickness(16, 0, 0, 0); dock.Children.Add(r); }
        dock.Children.Add(text);
        return dock;
    }

    static FrameworkElement Divider(double gap = 20) => new Border { Height = 1, Background = Palette.Line, Margin = new Thickness(0, gap, 0, gap) };

    static FrameworkElement Tick(string text) => Ui.Row(6, Ui.Icon(Icons.Check, 14, Palette.Success, stroke: 1.8), Ui.Text(text, 14, Palette.Success, wrap: false));

    FrameworkElement Footer()
    {
        var back = Ui.Button(L("上一步"), () => Go(step - 1), Ui.Kind.Subtle, height: 44);
        back.MinWidth = 0; back.HorizontalAlignment = HorizontalAlignment.Left; back.Padding = new Thickness(0);
        ((TextBlock)((StackPanel)back.Content).Children[0]).Foreground = Palette.Secondary;
        UIElement left = back;
        if (step == 0 && Other)
        {
            var ling = Ui.LinkText(L("‹ 还是用 Ling"), () => Switch("ling"));
            ling.Foreground = Palette.Secondary;
            left = Ui.Row(16, ling, Ui.Row(8, Ui.Icon(Icons.Lock, 14, Palette.Secondary), Ui.Text(LF("仅保存在本机当前账户下，仅发送至 %@", app.Ling.Config.Name), 13, Palette.Secondary, wrap: false)));
        }
        else if (step == 0)
        {
            // A grey link, as on the Mac: Ling stays first and recommended.
            var other = Ui.LinkText(L("用不了 Ling？"), () => Switch("openrouter"));
            other.Foreground = Palette.Secondary;
            left = Ui.Row(16, Ui.Row(8, Ui.Icon(Icons.Lock, 14, Palette.Secondary), Ui.Text(L("key 加密存在这台电脑上，只发给 Ling"), 13, Palette.Secondary, wrap: false)), other);
        }
        var next = step switch
        {
            0 => Ui.Button(L("继续"), () => _ = SaveKey(), Ui.Kind.Primary, Icons.Arrow, height: 44, iconAfter: true),
            1 => Ui.Button(L("继续"), () => Go(2), peak >= 0.01 ? Ui.Kind.Primary : Ui.Kind.Standard, Icons.Arrow, height: 44, iconAfter: true),
            < Steps => Ui.Button(L("继续"), () => Go(step + 1), Ui.Kind.Primary, Icons.Arrow, height: 44, iconAfter: true),
            _ => Ui.Button(L("开始用"), () => Go(Steps + 1), Ui.Kind.Primary, height: 44),
        };
        next.MinWidth = 108; next.HorizontalAlignment = HorizontalAlignment.Right;
        next.IsEnabled = !checking;
        var right = new StackPanel { Orientation = Orientation.Horizontal };
        if (step == 3)
        {
            var later = Ui.Button(L("以后再说"), () => { LeaveSpeak(keep: false); speakBefore = null; step = 4; Render(); }, height: 44);
            later.Margin = new Thickness(0, 0, 12, 0); later.MinWidth = 100; later.Background = Palette.Selected;
            right.Children.Add(later);
        }
        right.Children.Add(next);
        var row = Ui.Spread(left, right);
        row.Margin = new Thickness(64, 16, 64, 36);
        return row;
    }

    // MARK: 1 · Ling key

    FrameworkElement KeyStep()
    {
        var open = Ui.Button(L("打开"), () => Process.Start(new ProcessStartInfo("https://chat.ant-ling.com/platform/api") { UseShellExecute = true }), icon: Icons.OpenExternal, height: 36, iconAfter: true);
        open.MinWidth = 0;
        var row = KeyRow("sk-…");
        if (keyBox.Password.Length == 0 && keyStatus.Content is null) ShowCheck();
        keyStatus.Margin = new Thickness(0, 12, 0, 0);
        var second = new StackPanel { Children = { row, keyStatus } };
        var card = StepCard(new StackPanel
        {
            Children =
            {
                Numbered(Disc(1), L("在 Ling 开放平台创建 key"), L("国内直接注册，不用代理；登录后点“创建令牌”"), open),
                Divider(),
                Numbered(Disc(2), L("复制 sk- 开头的 key，回来粘贴"), null, below: second),
            },
        });
        FrameworkElement Benefit(string title, string detail) => new StackPanel { Margin = new Thickness(0, 14, 0, 0), Children = { Ui.Text(title, 14, Palette.Ink), Gap(Ui.Text(detail, 12, Palette.Secondary), 2) } };
        var side = StepCard(new StackPanel
        {
            Children =
            {
                Ui.Text(L("Ling 每月赠送 ¥10 额度"), 16, Palette.Ink, FontWeights.Bold),
                Gap(Ui.Text(L("约够 10–50 小时会议"), 13, Palette.Secondary), 4),
                new Border { Height = 1, Background = Palette.Line, Margin = new Thickness(0, 14, 0, 0) },
                Benefit(L("实时纪要"), L("会中每 45 秒更新")),
                Benefit(L("更准的翻译"), L("人名、术语前后一致")),
                Benefit(L("自然人声"), L("同传约 2 秒出声")),
            },
        }, new Thickness(20, 20, 20, 20));
        return Page(L("接上 Ling"), L("识别、翻译和纪要都靠它，约 1 分钟。"), Columns(card, side));
    }

    // MARK: 1 · 用其他服务 (OnboardingKey.swift › otherEntry)

    /// Another service than Ling is chosen (用不了 Ling？): step 1 asks for its key instead.
    bool Other => app.Settings.AiProvider != "ling";
    /// What the page offers; a custom address is set up in 设置 › AI 服务.
    static readonly string[] Others = ["openrouter", "zenmux"];

    void Switch(string provider)
    {
        keyBox.Clear(); keyStatus.Content = null; hinting = false;
        app.SetAIProvider(provider);
        Render();
    }

    FrameworkElement OtherStep()
    {
        var p = app.Ling.Provider;
        var choices = Ui.Segmented(Others.Select(id => (id, AIProvider.Named(id).Name)), Others.Contains(p.Id) ? p.Id : Others[0],
            v => { if (v != app.Settings.AiProvider) Switch(v); });
        UIElement top = choices;
        if (p.Site is { } site)
        {
            var open = Ui.Button(LF("打开 %@", app.Ling.Config.Name), () => Process.Start(new ProcessStartInfo(site) { UseShellExecute = true }), icon: Icons.OpenExternal, height: 36, iconAfter: true);
            open.MinWidth = 0;
            top = Ui.Spread(choices, open);
        }
        if (keyBox.Password.Length == 0 && keyStatus.Content is null) ShowCheck();
        var row = KeyRow(LF("粘贴 %@ 的 key", app.Ling.Config.Name));
        keyStatus.Margin = new Thickness(0, 12, 0, 0);
        row.Margin = new Thickness(0, 18, 0, 0);
        var card = StepCard(new StackPanel { Children = { top, row, keyStatus } });
        return Page(L("用其他服务"), L("听、纪要和翻译都能用，模型已经选好。"), card);
    }

    /// The key field with its reveal button, and 粘贴并检查.
    DockPanel KeyRow(string placeholder)
    {
        var reveal = Ui.IconButton(Icons.Eye, L("显示 key"), () =>
        {
            var show = keyText.Visibility != Visibility.Visible;
            keyText.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
            keyBox.Visibility = show ? Visibility.Collapsed : Visibility.Visible;
        }, Palette.Secondary, 32, 16);
        Detach(keyBox); Detach(keyText); Detach(keyStatus);
        var hint = Ui.Text(placeholder, 14, Palette.Tertiary, wrap: false);
        hint.IsHitTestVisible = false; hint.VerticalAlignment = VerticalAlignment.Center;
        void Hint() => hint.Visibility = keyBox.Password.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        keyBox.PasswordChanged += (_, _) => Hint();
        Hint();
        var boxes = new Grid { Children = { keyBox, keyText, hint } };
        var inner = new DockPanel();
        DockPanel.SetDock(reveal, Dock.Right);
        inner.Children.Add(reveal); inner.Children.Add(boxes);
        Ui.StyleField(keyBox); Ui.StyleField(keyText);
        var field = Ui.FieldFrame(inner, keyBox);
        field.Padding = new Thickness(12, 0, 4, 0);
        var paste = Ui.Button(L("粘贴并检查"), () =>
        {
            try { if (Clipboard.ContainsText()) keyText.Text = Clipboard.GetText().Trim(); } catch { }
            _ = SaveKey();
        }, Ui.Kind.Primary, height: 40);
        var row = new DockPanel();
        DockPanel.SetDock(paste, Dock.Right);
        paste.Margin = new Thickness(8, 0, 0, 0);
        row.Children.Add(paste); row.Children.Add(field);
        return row;
    }

    static FrameworkElement Gap(FrameworkElement e, double top) { e.Margin = new Thickness(0, top, 0, 0); return e; }

    static void Detach(FrameworkElement e) { if (e.Parent is Panel p) p.Children.Remove(e); else if (e.Parent is ContentControl c) c.Content = null; else if (e.Parent is Decorator d) d.Child = null; }

    void Status(bool? ok, string text)
    {
        var color = ok == true ? Palette.Success : ok == false ? Palette.Danger : Palette.Secondary;
        keyStatus.Content = ok == true ? Tick(text) : Ui.Text(text, 13, color);
    }

    async Task SaveKey()
    {
        var text = keyBox.Password.Trim();
        // 继续 is always allowed once a key is in: a failed check stays in 还差几步 and the settings.
        if (text.Length == 0 && app.Ling.HasKey) { Go(1); return; }
        if (!text.StartsWith("sk-")) { Status(false, L("要粘贴 sk- 开头的那串")); return; }
        // The prefix says whose key it is (SettingsWindow.SaveKey does the same).
        if (AICheck.Owner(text) is { } whose)
        {
            var (owner, management) = whose;
            if (management) { hinting = true; Status(false, L("这是 ZenMux 的管理 key，不能用来调用模型。请粘贴 sk-payg 开头的 key。")); return; }
            if (owner != app.Settings.AiProvider)
            {
                hinting = true;
                var words = Ui.Text(LF("这是 %@ 的 key。", AIProvider.Named(owner).Name), 13, Palette.Danger);
                words.VerticalAlignment = VerticalAlignment.Center;
                keyStatus.Content = Ui.Spread(words, Ui.Button(LF("改用 %@", AIProvider.Named(owner).Name), () =>
                {
                    hinting = false;
                    keyBox.Clear();
                    app.SwitchService(owner, text);
                    Render();
                }, Ui.Kind.Primary, height: 32));
                return;
            }
        }
        hinting = false;
        checking = true; footer.Content = Footer();
        Status(null, L("正在检查…"));
        app.Key.Save(text);
        keyBox.Clear();
        app.Ling.KeyChanged();
        await app.Ling.Check();
        checking = false; footer.Content = Footer();
        ShowCheck();
        if (app.Ling.Health.Passed) { await Task.Delay(600); if (step == 0) Go(1); }
    }

    /// What the last check found, under the key: a tick when it passed (busy too), else where it
    /// broke and the one thing that fixes it, as in the settings.
    void ShowCheck()
    {
        var ling = app.Ling;
        var h = ling.Health;
        if (!ling.HasKey || hinting) return;
        if (h.IsRunning) Status(null, L("正在检查…"));
        else if (h.Passed) Status(true, AIKey.Masked(ling.CurrentKey() ?? "") + " · " + (h.IsBusy ? LF("%@ 现在很忙，key 没问题。开会时会自动重试。", ling.ServiceName) : L("已连接，可以用了")));
        else if (h.At is null) keyStatus.Content = null;
        else keyStatus.Content = AICheckView.Steps(app, () => { keyBox.Clear(); keyStatus.Content = null; keyBox.Focus(); }, recheckInStep: true, compact: true);
    }

    /// A check finished or a meeting request reported back while the key page is open.
    void LingChanged() => Dispatcher.BeginInvoke(() => { if (step == 0 && !checking && keyBox.Password.Length == 0) ShowCheck(); });

    // MARK: 2 · System audio

    readonly ContentControl meterHost = new(), heardHost = new();

    FrameworkElement AudioStep()
    {
        if (tap is null)
        {
            tap = new SystemAudioTap();
            tap.Samples += Heard;
            tap.Start();
            meter.Start();
        }
        Detach(meterHost); Detach(heardHost);
        heardHost.Tag = null;
        Meter();
        var tile = new Border { Width = 44, Height = 44, CornerRadius = new CornerRadius(12), Background = Palette.AccentPale, Margin = new Thickness(0, 0, 16, 0), Child = Ui.Icon(Icons.Speaker, 20, Palette.AccentText) };
        var status = Ui.Row(18, meterHost, heardHost);
        var device = AudioDevice.DefaultName() ?? L("默认扬声器");
        var test = Ui.Button(testing ? L("正在播放…") : L("放一段测试声音"), () => _ = PlayTest(), Ui.Kind.Accent, Icons.Play, 36, iconFill: true);
        test.IsEnabled = !testing;
        var card = StepCard(new StackPanel
        {
            Children =
            {
                Numbered(tile, L("电脑播放的声音"), LF("%@ · 只听声音，不录屏幕", device), status),
                Divider(16),
                Ui.Spread(Ui.Stack(2, Ui.Text(L("没有声音在放？"), 14, Palette.Ink, wrap: false), Ui.Helper(L("放 3 秒测试声音，从默认扬声器出来"))), test),
            },
        });
        // The two sounds side by side: people try speaking first, but this step hears the PC.
        var sources = new Grid { Margin = new Thickness(0, 12, 0, 0) };
        sources.ColumnDefinitions.Add(new ColumnDefinition());
        sources.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
        sources.ColumnDefinitions.Add(new ColumnDefinition());
        var theirs = Source(L("对方的声音"), Ui.Badge(L("这一步")), [L("会议软件"), L("扬声器"), L("知了：字幕和纪要")], on: true);
        var yours = Source(L("你的声音 · 麦克风"), Ui.Badge(L("第 4 步再用"), Palette.Mica, Palette.Secondary), [L("麦克风"), L("同声传译"), L("对方听到译文")], on: false);
        Grid.SetColumn(yours, 2);
        sources.Children.Add(theirs); sources.Children.Add(yours);
        return Page(L("让知了听到电脑里的声音"), L("会议里对方说的话从电脑扬声器放出来，字幕和纪要都从这里来。Windows 上不用授权。"), card, sources);
    }

    /// One of the two sounds: where it goes, outlined in ink when it is this step's.
    static FrameworkElement Source(string title, FrameworkElement badge, string[] flow, bool on)
    {
        var path = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        for (int i = 0; i < flow.Length; i++)
        {
            var last = on && i == flow.Length - 1;
            path.Children.Add(new Border { Background = last ? Palette.Ink : Palette.Mica, CornerRadius = new CornerRadius(6), Padding = new Thickness(7, 1, 7, 2), Margin = new Thickness(0, 0, 0, 4), Child = Ui.Text(flow[i], 12, last ? Brushes.White : Palette.Ink, wrap: false) });
            if (i < flow.Length - 1) path.Children.Add(new TextBlock { Text = "→", FontSize = 12, Foreground = Palette.Secondary, Margin = new Thickness(6, 1, 6, 0) });
        }
        var head = Ui.Row(8, Ui.Text(title, 14, Palette.Ink, Palette.Strong, wrap: false), badge);
        return new Border
        {
            Background = Palette.Surface, CornerRadius = new CornerRadius(14), Padding = new Thickness(16, 12, 16, 10),
            BorderBrush = on ? Palette.Ink : Palette.Line, BorderThickness = new Thickness(on ? 2 : 1),
            Child = new StackPanel { Children = { head, path } },
        };
    }

    void Heard(short[] buf)
    {
        double sum = 0;
        foreach (var s in buf) sum += (double)s * s;
        var rms = buf.Length == 0 ? 0 : Math.Sqrt(sum / buf.Length) / 32768;
        // The loudest buffer since the last bar, not the last one (often a silent fill).
        level = Math.Max(level, rms);
        peak = Math.Max(peak, rms);
    }

    bool testing;

    /// 放一段测试声音: the sample's first seconds through the default speakers. The listening tap
    /// leaves Cicada's own sound out, so a second tap that hears only Cicada feeds the same bars:
    /// they still move only if Windows really hands the PC's sound over.
    async Task PlayTest()
    {
        if (testing || Bundled.Sample() is not { } wav) return;
        testing = true; Render();
        var self = new SystemAudioTap { OnlySelf = true };
        self.Samples += Heard;
        self.Start();
        var player = new System.Media.SoundPlayer(wav);
        try
        {
            player.Play();
            Log.Debug("onboarding: test sound");
            await Task.Delay(3200);
        }
        catch (Exception e) { Log.Debug($"onboarding: test sound failed {e.GetType().Name}"); }
        finally
        {
            player.Stop();
            await Task.Delay(300);
            self.Stop();
            testing = false;
            if (IsLoaded && step == 1) Render();
        }
    }

    /// A few bars of the last moment's loudness, newest on the right, in the accent once there's sound.
    void Meter()
    {
        // A rolling history of the loudness, eased so a word reads as a rise and fall, not one spike.
        Array.Copy(levels, 1, levels, 0, levels.Length - 1);
        levels[^1] = Math.Max(Loudness(level), levels[^2] * 0.7);
        level = 0;
        var bars = new StackPanel { Orientation = Orientation.Horizontal, Height = 22, VerticalAlignment = VerticalAlignment.Center };
        foreach (var v in levels)
            bars.Children.Add(new Rectangle { Width = 3, Height = 3 + v * 19, RadiusX = 1, RadiusY = 1, Margin = new Thickness(0, 0, 3, 0), VerticalAlignment = VerticalAlignment.Bottom, Fill = v > 0.08 ? Palette.Live : Palette.Toggle });
        System.Windows.Automation.AutomationProperties.SetName(bars, L("系统声音"));
        meterHost.Content = bars;
        var heard = peak >= 0.01;
        if (heard && !app.Settings.HeardSystemAudio) { app.Settings.HeardSystemAudio = true; app.Settings.Save(); app.SetupChanged(); }
        if (heardHost.Tag as bool? != heard)
        {
            heardHost.Tag = heard;
            heardHost.Content = heard ? Ui.Row(6, Ui.Icon(Icons.Check, 14, Palette.Ink, stroke: 1.8), Ui.Text(L("已收到声音"), 14, Palette.Ink, wrap: false)) : Ui.Text(L("还没听到声音"), 14, Palette.Secondary, wrap: false);
            footer.Content = Footer();
        }
    }

    /// -50 dBFS (a quiet room) to 0 dBFS on a log scale, so speech sits mid-bar instead of pinning it.
    static double Loudness(double rms) => rms <= 0 ? 0 : Math.Clamp((20 * Math.Log10(rms) + 50) / 50, 0, 1);

    // MARK: 3 · Try it

    FrameworkElement SampleStep()
    {
        var play = Ui.Button(playing ? L("正在播放…") : L("播放示例"), () => _ = PlaySample(), Ui.Kind.Accent, Icons.Play, 40, iconFill: true);
        play.IsEnabled = !playing;
        play.MinWidth = 132;
        var card = StepCard(new StackPanel
        {
            Children =
            {
                Numbered(Disc(1), L("播放示例"), L("一段 9 秒的英文会议"), play),
                Divider(),
                Numbered(Disc(2), L("看右边的纪要窗"), L("字幕和纪要一句句出来；点它不会抢走你正在用的窗口")),
            },
        });
        return Page(L("看看效果"), L("看字幕和纪要怎么出现。纪要窗口不会抢走焦点，也不会出现在屏幕共享里。"), card);
    }

    async Task PlaySample()
    {
        // The notes panel opens along the right edge; keep the wizard's buttons clear of it.
        var area = SystemParameters.WorkArea;
        var room = area.Right - 440 - area.Left;
        Left = Math.Max(area.Left + 8, Math.Min(Left, room - Width));
        playing = true; Render();
        try { await app.PlaySample(); }
        finally
        {
            playing = false;
            if (!app.Settings.SampleSeen) { app.Settings.SampleSeen = true; app.Settings.Save(); app.SetupChanged(); }
            if (IsLoaded) Render();
        }
    }

    // MARK: 4 · Speak into the meeting

    string? cableProgress;

    FrameworkElement SpeakStep()
    {
        var cable = Endpoints.Cable() is not null;
        FrameworkElement cableControl = cable ? Ui.Text(L("已装好"), 14, Palette.Success, wrap: false)
            : cableProgress is { } busy ? Ui.Text(busy, 13, Palette.Secondary, wrap: false)
            : Ui.Button(L("安装"), () => _ = InstallCable(), Ui.Kind.Primary, height: 36);
        var held = app.Speak.State == SpeakEngine.Phase.Recording;
        var key = Ui.Keycap(PushToTalk.Label, big: true);
        if (held) { key.Background = Palette.AccentPale; key.BorderBrush = Palette.Live; }
        FrameworkElement tried = app.Speak.State switch
        {
            SpeakEngine.Phase.Recording => Ui.Text(L("正在听你说 · 松开发送"), 13, Palette.AccentText),
            SpeakEngine.Phase.Translating => Ui.Text(L("正在翻译…"), 13, Palette.Secondary),
            SpeakEngine.Phase.Speaking => Ui.Text(L("正在说给对方听…"), 13, Palette.Secondary),
            SpeakEngine.Phase.Failed => Ui.Text(app.Speak.Problem ?? L("这句没翻译成 · 没有说出去"), 13, Palette.Danger),
            _ when app.Speak.Heard is { } h => Tick(L("对方已听到") + "：" + h),
            _ => new Border(),
        };
        var card = StepCard(new StackPanel
        {
            Children =
            {
                Numbered(Disc(1, cable), L("装一个虚拟麦克风"), L("VB-Cable，免费，Windows 会问一次是否允许"), cableControl, cable ? SpeakerNote() : null),
                Divider(),
                Numbered(Disc(2), L("会议软件里，麦克风选 CABLE Output"), L("Teams、Zoom、腾讯会议都在“音频设置”里")),
                Divider(),
                Numbered(Disc(3), L("按住说一句试试"), L("松开后约 2 秒，对方就会听到译文"), key, tried is Border ? null : tried),
            },
        });
        return Page(L("线上开会时要说外语吗？"), LF("按住%@说话，线上的人听到翻译后的声音。不需要可以跳过。", PushToTalk.Label), card);
    }

    /// After the install: where the computer's sound plays, so nobody thinks Cicada took it.
    FrameworkElement? SpeakerNote() =>
        Endpoints.SpeakerIsCable() ? CableInstaller.SpeakerStrip(this, Render)
        : Endpoints.Default(Endpoints.Flow.Render) is { } d ? Ui.Text(LF("电脑声音照常从 %@ 播放", d.Name), 13, Palette.Secondary) : null;

    void SpeakChanged() => Dispatcher.BeginInvoke(() => { if (step == 3 && IsLoaded) page.Content = SpeakStep(); });

    async Task InstallCable()
    {
        cableProgress = L("正在下载…"); Render();
        var result = await CableInstaller.Install(p => Dispatcher.BeginInvoke(() => { cableProgress = p; Render(); }));
        cableProgress = null;
        Render();
        if (result != CableInstaller.Result.Installed)
            Dialogs.Tell(this, L("虚拟麦克风没装上"), result switch
            {
                CableInstaller.Result.DownloadFailed => L("下载失败，检查网络后再试。"),
                CableInstaller.Result.BadPackage => L("下载到的安装包和预期的不一样，为了安全没有安装。"),
                CableInstaller.Result.Declined => L("需要你在 Windows 的提示里点“是”才能安装。"),
                _ => L("安装没有完成，可以重启电脑后再试。"),
            });
    }

    // MARK: Done · where the icon lives

    /// Text that wraps on the left of a button that keeps its full width (English runs wider).
    static FrameworkElement Beside(FrameworkElement text, FrameworkElement button)
    {
        var d = new DockPanel();
        DockPanel.SetDock(button, Dock.Right);
        button.Margin = new Thickness(12, 0, 0, 0); button.VerticalAlignment = VerticalAlignment.Center;
        text.VerticalAlignment = VerticalAlignment.Center;
        d.Children.Add(button); d.Children.Add(text);
        return d;
    }


    FrameworkElement DoneStep()
    {
        var settings = Ui.Button(L("打开任务栏设置"), () => { try { Process.Start(new ProcessStartInfo("ms-settings:taskbar") { UseShellExecute = true }); } catch { } }, height: 36);
        settings.MinWidth = 0;
        var pin = StepCard(new StackPanel
        {
            Children =
            {
                TrayPicture(),
                Gap(Beside(Ui.Text(L("拖不动？在任务栏设置里打开“知了”"), 13, Palette.Body), settings), 16),
            },
        });
        FrameworkElement Key(string what, string keys) => Gap(Ui.Spread(Ui.Text(what, 14, Palette.Ink, wrap: false), Ui.Keycap(keys)), 14);
        var startup = Ui.Check(L("开机时启动知了"), autoStart, v => autoStart = v);
        startup.Margin = new Thickness(0, 28, 0, 0);
        var keys = StepCard(new StackPanel
        {
            Children =
            {
                Ui.Text(L("在哪儿都能用"), 16, Palette.Ink, FontWeights.Bold),
                Key(L("开始 / 结束听"), Hotkey.Label.Replace('+', ' ')),
                Key(L("按住说话"), PushToTalk.Label),
                startup,
            },
        });
        return Page(L("好了，知了住在任务栏右下角"), L("Windows 会先把新图标收进 ^ 里。拖出来放在时钟旁边，开会时一眼就能看到。"), Columns(pin, keys, 260));
    }

    /// The corner of the taskbar: the ^ overflow with 知了 in it, and a dashed arrow to beside the clock.
    static FrameworkElement TrayPicture()
    {
        var c = new Canvas { Height = 150, ClipToBounds = true };
        var ground = new Border { Width = 412, Height = 150, CornerRadius = new CornerRadius(12), Background = new SolidColorBrush(Color.FromRgb(0xE1, 0xE4, 0xEA)) };
        c.Children.Add(ground);
        var bar = new Border { Width = 412, Height = 40, CornerRadius = new CornerRadius(0, 0, 12, 12), Background = new SolidColorBrush(Color.FromRgb(0xEE, 0xF0, 0xF3)), BorderBrush = new SolidColorBrush(Color.FromRgb(0xD3, 0xD7, 0xDE)), BorderThickness = new Thickness(0, 1, 0, 0) };
        Canvas.SetTop(bar, 110); c.Children.Add(bar);
        FrameworkElement Slot(bool ours, bool ring) => new Border
        {
            Width = 32, Height = 32, CornerRadius = new CornerRadius(7), Background = Brushes.White,
            BorderBrush = ring ? Palette.Live : Brushes.Transparent, BorderThickness = new Thickness(ring ? 1.5 : 0),
            Child = ours ? AppIcon.Small(22) : new Border { Width = 14, Height = 14, CornerRadius = new CornerRadius(3), Background = new SolidColorBrush(Color.FromRgb(0xAE, 0xB3, 0xBF)) },
        };
        var overflow = new Border
        {
            CornerRadius = new CornerRadius(12), Background = Brushes.White, Padding = new Thickness(10, 8, 10, 8),
            Child = new StackPanel { Orientation = Orientation.Horizontal, Children = { Plain(), Gap2(Slot(true, true)), Gap2(Plain()) } },
        };
        static FrameworkElement Plain() => new Border { Width = 32, Height = 32, Child = new Border { Width = 14, Height = 14, CornerRadius = new CornerRadius(3), Background = new SolidColorBrush(Color.FromRgb(0xAE, 0xB3, 0xBF)) } };
        static FrameworkElement Gap2(FrameworkElement e) { e.Margin = new Thickness(8, 0, 0, 0); return e; }
        Canvas.SetLeft(overflow, 176); Canvas.SetTop(overflow, 48); c.Children.Add(overflow);
        var chevron = new Border { Width = 28, Height = 28, CornerRadius = new CornerRadius(6), Background = Brushes.White, Child = Ui.Icon("M6,12 L10,8 L14,12", 12, Palette.Body, stroke: 1.6) };
        Canvas.SetLeft(chevron, 292); Canvas.SetTop(chevron, 116); c.Children.Add(chevron);
        var mine = Slot(true, true);
        Canvas.SetLeft(mine, 326); Canvas.SetTop(mine, 114); c.Children.Add(mine);
        var clock = Ui.Text("14:30", 13, Palette.Ink, wrap: false);
        Canvas.SetLeft(clock, 368); Canvas.SetTop(clock, 121); c.Children.Add(clock);
        var arrow = new System.Windows.Shapes.Path
        {
            Data = Geometry.Parse("M272,72 C312,64 340,70 352,98 M345,92 L352,100 L358,91"), Stroke = Palette.Live, StrokeThickness = 1.6,
            StrokeDashArray = [3, 2.5], StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round,
        };
        c.Children.Add(arrow);
        var holder = new Border { CornerRadius = new CornerRadius(12), ClipToBounds = true, Child = new Viewbox { Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly, Child = new Grid { Width = 412, Height = 150, Children = { c } } } };
        return holder;
    }

    void StopTap()
    {
        meter.Stop();
        tap?.Stop();
        tap = null;
    }
}
