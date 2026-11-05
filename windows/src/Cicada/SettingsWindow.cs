using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using static Cicada.Strings;

namespace Cicada.App;

/// 设置, as the Mac's settings window with no title bar: the categories as plain words on the left,
/// the chosen one on a white pill, and its page on the right under a big title, the settings in
/// white cards on the grey ground with each control at the right.
sealed class SettingsWindow : Window
{
    readonly Controller app;
    readonly ScrollViewer scroll = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(40, 44, 40, 40) };
    readonly StackPanel nav = new() { Margin = new Thickness(12, 52, 12, 12) };
    readonly Dictionary<string, FrameworkElement> sections = [];
    readonly PasswordBox keyBox = new();
    bool editingKey;
    string current = "ling";

    public SettingsWindow(Controller app)
    {
        this.app = app;
        Title = L("设置") + " · " + L("知了");
        Width = 1000; Height = Math.Min(780, SystemParameters.WorkArea.Height - 24); MinWidth = 760; MinHeight = 480;
        Background = Palette.Page; FontFamily = Palette.Font; Icon = AppIcon.Image;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        System.Windows.Automation.AutomationProperties.SetName(keyBox, L("Ling key"));
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(200) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetColumn(scroll, 1);
        grid.Children.Add(nav); grid.Children.Add(scroll);
        Content = Ui.Frameless(this, grid);
        app.Ling.Changed += OnLingChanged;
        Closed += (_, _) => app.Ling.Changed -= OnLingChanged;
        Render();
    }

    void OnLingChanged() => Dispatcher.BeginInvoke(Render);

    void Render()
    {
        var offset = scroll.VerticalOffset;
        sections.Clear();
        var page = new StackPanel { MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Left };
        Section(page, "ling", L("Ling"), KeyCard(), Group(Card(Icons.Notes, L("纪要和翻译用的模型"), L("3.1 更准；3.0 更快、更省。语音识别固定用 Ming。"),
            Ui.Choice([("Ling-3.1-flash", "Ling-3.1-flash"), ("Ling-3.0-flash", "Ling-3.0-flash")], app.Settings.Model, v => { app.Settings.Model = v; app.Ling.Model = v; Save(); }))));
        Section(page, "lang", L("语言"), Group(
            Card(Icons.Globe, L("翻译成"), null, Ui.Choice(Ui.TargetOptions(), app.Settings.Target, app.SetTarget)),
            Card(null, L("纪要语言"), null, Ui.Choice([("system", L("和字幕一样")), .. Languages.Targets.Select(t => (t.Code, t.Name))], app.Settings.NotesLanguage, v => { app.Settings.NotesLanguage = v; Save(); })),
            Card(null, L("界面语言"), L("重新打开知了后生效"), Ui.Choice([("system", L("跟随系统")), ("zh-Hans", "简体中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어")], app.Settings.UiLanguage, v => { app.Settings.UiLanguage = v; Save(); }))));
        var size = new Slider { Minimum = 18, Maximum = 32, Value = app.Settings.SubtitleSize, Width = 200, IsSnapToTickEnabled = true, TickFrequency = 1, VerticalAlignment = VerticalAlignment.Center };
        System.Windows.Automation.AutomationProperties.SetName(size, L("字幕文字大小"));
        size.ValueChanged += (_, e) => { app.Settings.SubtitleSize = (int)e.NewValue; Save(); };
        Section(page, "listen", L("听的时候"), Group(
            Card(Icons.Subtitles, L("听的时候显示"), null, Ui.Segmented([("notes", L("纪要")), ("subtitles", L("字幕条"))], app.Settings.View, app.SetView)),
            Card(null, L("字幕文字大小"), null, size),
            Card(Icons.Keyboard, L("开始或结束"), app.HotkeyRegistered ? L("在任何程序里都能按") : L("这个快捷键被别的程序占用了"), Keys(Hotkey.Label))));
        Section(page, "speak", L("同声传译"), SpeakCards().ToArray());
        Section(page, "end", L("结束会议"), EndCards());
        Section(page, "privacy", L("隐私与启动"), Group(
            Card(Icons.Eye, L("共享屏幕时让对方看到"), L("关着时，截图和屏幕共享里看不到纪要和字幕"), Ui.Switch(app.Settings.ShowInCapture, app.SetShowInCapture, L("共享屏幕时让对方看到"))),
            Card(Icons.List, L("说话人识别"), L("按声音标出说话人 1、2…，只在这台电脑上处理"), Ui.Switch(app.Settings.SpeakerVoices, v => { app.Settings.SpeakerVoices = v; Save(); }, L("说话人识别"))),
            Card(Icons.Power, L("开机时启动知了"), null, Ui.Switch(AutoStart.Enabled, v => AutoStart.Enabled = v, L("开机时启动知了"))),
            Card(Icons.Folder, L("会议记录存放位置"), $"{Paths.Sessions} · {L("和 Mac 版格式相同")}", Ui.Button(L("打开文件夹"), () => OpenFolder(Paths.Sessions), height: 32))));
        // 卸载 as in Settings › Apps, with the same confirmation; only an installed copy offers it.
        FrameworkElement[] about =
        [
            Card(null, LF("知了 %@", Controller.Version), UpdateDetail(), UpdateControl(), AppIcon.Small(24)),
            Card(null, L("日志"), null, Ui.LinkText(L("打开日志"), () => OpenFolder(Path.GetDirectoryName(Paths.Log)!))),
            .. (!Paths.Dev && File.Exists(Install.Exe) ? new[] { Card(null, L("卸载知了"), L("会议记录默认留着"), Ui.LinkText(L("卸载…"), () => Install.Launch("--uninstall"))) } : []),
        ];
        Section(page, "about", L("关于"), Group(about),
            Credit());
        scroll.Content = page;
        scroll.ScrollToVerticalOffset(shownPage == current ? offset : 0);
        shownPage = current;
        Nav();
    }

    string? shownPage;

    /// What to do with the download: the installer upgrades itself; an older release has only the zip.
    public static string UpdateHint(UpdateChecker.Update u) => u.Setup is not null ? L("安装后自动重新打开") : L("下载后解压，替换旧的知了");

    static FrameworkElement Credit() { var t = Ui.Helper(L("说话人识别用 WeSpeaker 的声纹模型（CC BY 4.0）")); t.Margin = new Thickness(6, 0, 0, 0); return t; }

    /// Opens one category's page (the debug pipe's `show settings about`).
    public void Show(string id) { current = id; Render(); }

    /// An update was found or a check finished: only 关于 shows it.
    public void UpdatesChanged() { if (current == "about") Render(); }

    // The Mac's AppRows version row: what the last check found, and 检查更新 or 下载.
    string? UpdateDetail()
    {
        if (app.Updates.Available is { } u)
            return app.UpdateProgress is { } p ? LF("正在下载 %@：%lld%%", u.Version, (long)(p * 100))
                : app.UpdateFailure is { } f ? LF("没能自动更新：%@", f)
                : LF("有新版本 %@", u.Version) + " · " + UpdateHint(u);
        if (app.UpdateCheck is { } c) return c;
        if (app.Updates.LastChecked is not { } d) return null;
        var local = d.ToLocalTime();
        return LF("上次检查 %@", local.ToString(local.Date == DateTime.Today ? "HH:mm" : L("M月d日 HH:mm"), Strings.Culture));
    }

    FrameworkElement UpdateControl()
    {
        if (app.Updates.Available is not null)
        {
            var install = Ui.Button(app.Updates.Available.Setup is null ? L("下载") : L("安装并重新打开"), app.InstallUpdate, Ui.Kind.Primary, height: 32);
            install.IsEnabled = app.UpdateProgress is null;
            return Ui.Row(12, Ui.LinkText(L("更新说明"), app.OpenReleaseNotes), install);
        }
        var check = Ui.Button(L("检查更新"), () => _ = app.CheckForUpdates(), height: 32);
        check.IsEnabled = app.UpdateCheck != L("正在检查…");
        return check;
    }

    void Nav()
    {
        nav.Children.Clear();
        (string id, string icon, string label)[] items =
        [
            ("ling", Icons.Key, L("Ling")), ("lang", Icons.Globe, L("语言")), ("listen", Icons.Wave, L("听的时候")),
            ("speak", Icons.Mic, L("同声传译")), ("end", Icons.Stop, L("结束会议")), ("privacy", Icons.Shield, L("隐私与启动")), ("about", Icons.Info, L("关于")),
        ];
        foreach (var (id, icon, label) in items)
        {
            var on = id == current;
            var content = new Grid();

            _ = icon;
            content.Children.Add(Ui.Text(label, 14, Palette.Ink, on ? FontWeights.Bold : FontWeights.Normal, wrap: false));
            var b = new Button { HorizontalAlignment = HorizontalAlignment.Stretch, Content = content, Height = 38, Padding = new Thickness(12, 0, 12, 0), HorizontalContentAlignment = HorizontalAlignment.Left, Background = on ? Palette.Surface : Brushes.Transparent, BorderThickness = new Thickness(0), Cursor = System.Windows.Input.Cursors.Hand, Margin = new Thickness(0, 0, 0, 2) };
            b.Template = NavTemplate();
            b.Click += (_, _) => { current = id; Render(); };
            System.Windows.Automation.AutomationProperties.SetName(b, label);
            nav.Children.Add(b);
        }
    }

    static ControlTemplate NavTemplate()
    {
        var t = new ControlTemplate(typeof(Button));
        var border = new FrameworkElementFactory(typeof(Border), "bg");
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(10));
        border.SetBinding(Border.BackgroundProperty, new System.Windows.Data.Binding("Background") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        border.SetBinding(Border.PaddingProperty, new System.Windows.Data.Binding("Padding") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(content);
        t.VisualTree = border;
        var hover = new MultiTrigger();
        hover.Conditions.Add(new Condition(UIElement.IsMouseOverProperty, true));
        hover.Conditions.Add(new Condition(Control.BackgroundProperty, Brushes.Transparent));
        hover.Setters.Add(new Setter(Border.BackgroundProperty, Palette.Selected, "bg"));
        t.Triggers.Add(hover);
        return t;
    }

    /// One category's page: only the chosen one is shown, under its name in big type (and, for
    /// 同声传译, its on/off switch beside it).
    void Section(StackPanel page, string id, string title, params FrameworkElement[] groups)
    {
        if (id != current) return;
        FrameworkElement h = Ui.Text(title, 28, Palette.Ink, FontWeights.Bold);
        if (id == "speak") h = Ui.Spread(h, Ui.Switch(app.Settings.Speak, v => { app.Settings.Speak = v; Save(); }, L("同声传译")));
        h.Margin = new Thickness(0, 0, 0, 20);
        sections[id] = h;
        page.Children.Add(h);
        foreach (var g in groups) { g.Margin = new Thickness(0, 0, 0, 12); page.Children.Add(g); }
    }

    /// A grey label over a group, as the Mac's settings sections.
    static FrameworkElement Label(string text) { var t = Ui.Text(text, 13, Palette.Secondary); t.Margin = new Thickness(6, 8, 0, 0); return t; }

    /// Cards that belong together on one white card, with hairlines between them.
    static FrameworkElement Group(params FrameworkElement[] cards)
    {
        var s = new StackPanel();
        for (int i = 0; i < cards.Length; i++)
            s.Children.Add(new Border { BorderBrush = Palette.Line, BorderThickness = new Thickness(0, i == 0 ? 0 : 1, 0, 0), Margin = new Thickness(20, 0, 20, 0), Child = cards[i] });
        return new Border { Background = Palette.Surface, CornerRadius = new CornerRadius(16), Child = s, Padding = new Thickness(0, 2, 0, 2) };
    }

    /// One setting: icon, name, one grey line, and its control on the right.
    static FrameworkElement Card(string? icon, string title, string? description, FrameworkElement control, FrameworkElement? image = null)
    {
        // No icons: the Mac's rows are words and a control. (`icon` stays for the call sites.)
        _ = icon;
        var dock = new DockPanel { MinHeight = 40, Margin = new Thickness(0, 10, 0, 10) };
        if (image is not null) { image.Margin = new Thickness(0, 0, 14, 0); DockPanel.SetDock(image, Dock.Left); dock.Children.Add(image); }
        control.VerticalAlignment = VerticalAlignment.Center;
        control.Margin = new Thickness(16, 0, 0, 0);
        DockPanel.SetDock(control, Dock.Right);
        dock.Children.Add(control);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(Ui.Text(title, 14, Palette.Ink));
        if (description is not null) { var d = Ui.Helper(description); d.Margin = new Thickness(0, 2, 0, 0); text.Children.Add(d); }
        dock.Children.Add(text);
        return dock;
    }

    string? cableProgress;

    /// 同声传译: the switch, the virtual mic, the two languages and the room's voice.
    /// 结束会议: when a meeting ends by itself (MeetingEnd.cs), as the Mac's settings say it.
    FrameworkElement EndCards()
    {
        var s = app.Settings;
        var cards = new List<FrameworkElement>
        {
            Card(Icons.Stop, L("会议应用挂断后结束"), L("Zoom、腾讯会议、飞书、Teams 等"), Ui.Switch(s.EndWithApp, v => { s.EndWithApp = v; Save(); }, L("会议应用挂断后结束"))),
            Card(null, L("没人说话时"), L("按识别出的话算，背景音乐不算"),
                Ui.Segmented([("prompt", L("提醒后结束")), ("end", L("直接结束")), ("off", L("一直记录"))], s.SilenceEnd, v => { s.SilenceEnd = v; Save(); Render(); })),
        };
        if (s.SilenceEnd != "off")
            cards.Add(Card(null, L("多久算没人说话"), null,
                Ui.Segmented(new[] { 5, 10, 15, 30 }.Select(m => (m.ToString(), LF("%lld 分钟", m))), ((int)s.SilenceMinutes).ToString(), v => { s.SilenceMinutes = double.Parse(v); Save(); })));
        return Group(cards.ToArray());
    }

    IEnumerable<FrameworkElement> SpeakCards()
    {
        var s = app.Settings;
        var cable = Endpoints.Cable() is not null;
        FrameworkElement cableControl = cable
            ? new Border { Background = Palette.Mica, CornerRadius = new CornerRadius(10), Padding = new Thickness(12, 7, 12, 8), Child = Ui.Row(8, Ui.Dot(Palette.Success, 7), Ui.Text(L("VB-Cable 已装好"), 13, Palette.Ink, wrap: false)) }
            : cableProgress is { } busy ? Ui.Text(busy, 13, Palette.Secondary, wrap: false)
            : Ui.Button(L("安装"), () => _ = InstallCable(), Ui.Kind.Primary, height: 32);
        var target = app.Speak.Target;
        var voices = VoiceCatalog.Options(target, app.WindowsVoice.Has(target)).Select(v => (v.Id, v.Id == VoiceCatalog.SystemId ? L("Windows 自带") : $"{v.Name} · {string.Join(" · ", v.Tags.Split(" · ").Select(L))}")).ToList();
        var chosen = s.SpeakVoices.TryGetValue(VoiceCatalog.Key(target), out var c) ? c : VoiceCatalog.DefaultId(target, app.Ling.HasKey);
        var voice = Ui.Row(8,
            Ui.Choice(voices, chosen, v => { s.SpeakVoices[VoiceCatalog.Key(target)] = v; Save(); }, 280),
            Ui.Button(L("试听"), () => _ = app.Preview(target), height: 32));
        var mine = Languages.Sources.FirstOrDefault(x => x.Code == Languages.FromSystem(System.Globalization.CultureInfo.CurrentUICulture.Name))?.Name ?? "";
        yield return Label(L("说话"));
        yield return Group(
            Card(null, L("按住说话"), LF("按住%@说话，对方听到的是翻译后的声音", PushToTalk.Label), Ui.Keycap(PushToTalk.Label, big: true)),
            Card(null, L("我说的语言"), null, Ui.Choice([("system", LF("跟随系统（%@）", mine)), .. Languages.Sources.Select(x => (x.Code, x.Name))], s.SpeakFrom, v => { s.SpeakFrom = v; Save(); Render(); })),
            Card(null, L("对方听到的语言"), s.SpeakTo == "room" ? LF("现在是 %@", Ui.TargetName(target)) : null,
                Ui.Choice([("room", L("对方说的语言")), .. Languages.Targets.Select(t => (t.Code, t.Name))], s.SpeakTo, v => { s.SpeakTo = v; Save(); Render(); })),
            Card(null, LF("对方听到的声音（%@）", Ui.TargetName(target)), null, voice));
        yield return Label(L("麦克风"));
        yield return Group(
            Card(null, L("译文送进会议"), cable ? L("在会议软件里把麦克风选成 CABLE Output") : L("需要装免费的 VB-Cable；装的时候 Windows 会请你确认"), cableControl));
    }

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

    FrameworkElement KeyCard()
    {
        var state = app.Ling.KeyState;
        var key = app.Key.Read();
        string desc = state switch
        {
            KeyState.None => L("还没填 key"),
            KeyState.Checking => L("正在检查…"),
            KeyState.Invalid => L("这个 key 不能用，检查是否复制完整，或重新创建一个"),
            KeyState.Unreachable => L("连不上 Ling，检查网络"),
            _ => $"{AIKey.Masked(key ?? "")} · {L("可以用 · 只加密存在这台电脑上")}",
        };
        FrameworkElement control;
        if (editingKey)
        {
            if (keyBox.Parent is Panel p) p.Children.Remove(keyBox);
            if (keyBox.Parent is Border old) old.Child = null;
            var field = Ui.Field(keyBox); field.Width = 300; field.Height = 34;
            control = Ui.Row(8, field, Ui.Button(L("保存"), () => _ = SaveKey(), Ui.Kind.Primary, height: 34), Ui.Button(L("取消"), () => { editingKey = false; Render(); }, height: 34));
        }
        else
        {
            var change = Ui.Button(key is null ? L("填写") : L("更换"), () => { editingKey = true; keyBox.Clear(); Render(); keyBox.Focus(); }, height: 32);
            control = key is null ? change : Ui.Row(8, change, Ui.Button(L("删除"), () => { app.Key.Remove(); app.Ling.KeyChanged(); }, height: 32));
        }
        var card = Card(Icons.Key, L("Ling key"), desc, control);
        return Group(card);
    }

    async Task SaveKey()
    {
        var text = keyBox.Password.Trim();
        if (!text.StartsWith("sk-")) return;
        if (!app.Key.Save(text)) return;
        editingKey = false;
        app.Ling.KeyChanged();
        Render();
        await app.Ling.Check();
    }

    static FrameworkElement Keys(string combo)
    {
        return Ui.Shortcut(combo);
    }

    void Save() { app.Settings.Save(); app.SettingsChanged(); }

    static void OpenFolder(string path)
    {
        Directory.CreateDirectory(path);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
    }
}
