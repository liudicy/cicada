using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using static Cicada.Strings;

namespace Cicada.App;

/// Install, upgrade and uninstall (Install.cs does the work), in onboarding's look: the logo, a big
/// heading with one grey line, one white card, the action bottom right. Installing has one button
/// and two ticks; once done the installed copy opens onboarding, so there's no "finished" page.
sealed class SetupWindow : Window
{
    public enum Mode { Install, Upgrade, Uninstall }
    enum Phase { Ask, Working, Failed, Done }

    readonly Mode mode;
    readonly string? from;
    Phase phase;
    int done;
    string? error;
    bool startMenu = true, autoStart = true, keepRecords = true;
    /// The running Cicada is listening: an upgrade waits, an uninstall says it ends the meeting.
    bool busy;
    readonly ContentControl body = new();
    readonly DispatcherTimer poll = new() { Interval = TimeSpan.FromSeconds(2) };

    /// Runs the window as the whole process (no tray, no engines) and returns the exit code.
    public static int Run(Mode mode)
    {
        var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
#pragma warning disable WPF0001
        app.ThemeMode = ThemeMode.Light;
#pragma warning restore WPF0001
        app.DispatcherUnhandledException += (_, e) => { Log.Debug($"setup: unhandled {e.Exception.GetType().Name}: {e.Exception.Message}"); e.Handled = true; };
        // An upgrade or uninstall speaks the language the user picked; a first install the system's.
        var ui = AppSettings.Load().UiLanguage;
        Strings.Load(Bundled.Strings, ui == "system" ? null : ui);
        Log.Debug($"setup: {mode} {Controller.Version} from {Environment.ProcessPath}");
        return app.Run(new SetupWindow(mode, Install.InstalledVersion()));
    }

    SetupWindow(Mode mode, string? from)
    {
        this.mode = mode;
        this.from = from;
        Title = mode == Mode.Uninstall ? L("卸载知了") : L("安装知了");
        Width = mode == Mode.Uninstall ? 520 : 600; SizeToContent = SizeToContent.Height; ResizeMode = ResizeMode.CanMinimize;
        Background = Palette.Page; FontFamily = Palette.Font; Icon = AppIcon.Image;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Content = Ui.Frameless(this, body, resizable: false, captionHeight: 24, close: () => { if (phase != Phase.Working) Close(); });
        poll.Tick += (_, _) => Poll();
        Loaded += (_, _) => { Poll(); poll.Start(); };
        Closed += (_, _) => { poll.Stop(); if (mode == Mode.Uninstall && phase == Phase.Done) Install.RemoveFolderLater(); };
        Render();
    }

    void Poll()
    {
        if (phase != Phase.Ask || mode == Mode.Install) return;
        var now = Install.Listening() == true;
        if (now != busy) { busy = now; Render(); }
    }

    void Render() => body.Content = mode == Mode.Uninstall ? UninstallPage() : InstallPage();

    FrameworkElement InstallPage()
    {
        var upgrade = mode == Mode.Upgrade;
        if (phase is Phase.Working)
            return Page(upgrade ? L("正在更新…") : L("正在装…"), L("马上就好。"), Card(Progress()), null);
        if (phase is Phase.Failed)
            return Page(upgrade ? L("没更新成功") : L("没装好"), L("知了没有改动，可以再试一次。"),
                Ui.InfoBar(Ui.Severity.Error, null, error ?? ""), Footer(null, Ui.Button(L("再试一次"), Start, Ui.Kind.Primary, height: 44)));
        if (upgrade)
        {
            var later = Ui.Button(L("以后再说"), Close, height: 44);
            var go = Ui.Button(busy ? L("开完会再更新") : L("更新"), Start, Ui.Kind.Primary, height: 44);
            go.IsEnabled = !busy;
            return Page(L("更新知了"), LF("从 %@ 更新到 %@。会议记录、设置和 Ling key 都不动。", from ?? "", Controller.Version), null,
                Footer(Ui.Text(busy ? L("知了正在听，这场会议结束后再更新") : L("知了会先退出，更新完自己再打开"), 13, Palette.Secondary), later, go));
        }
        var autoStartHelp = Ui.Helper(L("开会前不用再找它"));
        autoStartHelp.Margin = new Thickness(28, 4, 0, 0);
        var where = Ui.Text(LF("装在 %@", Install.Folder), 13, Palette.Secondary, wrap: false);
        where.TextTrimming = TextTrimming.CharacterEllipsis; where.ToolTip = Install.Folder;
        return Page(L("把知了装到这台电脑"), L("装好后在开始菜单和任务栏右下角找到它。不需要管理员权限。"),
            Card(Ui.Stack(16, Ui.Check(L("在开始菜单里放一个入口"), startMenu, v => startMenu = v),
                Ui.Stack(0, Ui.Check(L("开机时启动知了"), autoStart, v => autoStart = v), autoStartHelp))),
            Footer(Ui.Row(8, Ui.Icon(Icons.Lock, 14, Palette.Secondary), where), Ui.Button(L("安装"), Start, Ui.Kind.Primary, height: 44)));
    }

    FrameworkElement UninstallPage()
    {
        if (phase is Phase.Done)
            return Page(L("知了已经卸载"), keepRecords ? LF("会议记录留在 %@。", Paths.Root) : L("会议记录和设置也删掉了。"), null,
                Footer(null, Ui.Button(L("知道了"), Close, Ui.Kind.Primary, height: 44)), logo: true);
        if (phase is Phase.Working) return Page(L("正在卸载…"), L("马上就好。"), null, null);
        int count = 0;
        try { if (Directory.Exists(Paths.Sessions)) count = Directory.GetDirectories(Paths.Sessions).Length; } catch { }
        var keepHelp = Ui.Helper(L("以后再装知了还能看到；也能拷给 Mac 版"));
        keepHelp.Margin = new Thickness(28, 4, 0, 0);
        var card = Card(Ui.Stack(0, Ui.Check(LF("留下会议记录（%@ 场）", count), keepRecords, v => keepRecords = v), keepHelp));
        var cancel = Ui.Button(L("取消"), Close, height: 44);
        var go = Ui.Button(busy ? L("结束会议并卸载") : L("卸载"), Start, Ui.Kind.Danger, height: 44);
        return Page(L("卸载知了？"), L("开始菜单入口、开机启动和知了本身都会删掉。"),
            phase is Phase.Failed ? Ui.Stack(12, Ui.InfoBar(Ui.Severity.Error, null, error ?? ""), card) : card,
            Footer(busy ? Ui.Text(L("知了正在听：先存好这场会议再卸载"), 13, Palette.Secondary) : null, cancel, go), logo: false);
    }

    void Start()
    {
        phase = Phase.Working; done = 0; error = null;
        Render();
        var choices = mode == Mode.Install ? (startMenu, autoStart) : ((bool, bool)?)null;
        var keep = keepRecords;
        Task.Run(() =>
        {
            if (mode == Mode.Uninstall) Install.Uninstall(keep);
            else Install.Run(choices, n => Dispatcher.BeginInvoke(() => { done = n; Render(); }));
        }).ContinueWith(t => Dispatcher.BeginInvoke(async () =>
        {
            if (t.Exception?.InnerException is { } e)
            {
                Log.Debug($"setup: failed {e.GetType().Name}: {e.Message}");
                error = Reason(e);
                phase = Phase.Failed;
                Render();
                return;
            }
            if (mode == Mode.Uninstall) { phase = Phase.Done; Render(); return; }
            // Let the last tick show, then the installed copy takes over (onboarding, or a toast).
            await Task.Delay(500);
            Install.Launch(mode == Mode.Install ? "--installed" : "--updated");
            Close();
        }));
    }

    static string Reason(Exception e) => e switch
    {
        IOException io when (io.HResult & 0xFFFF) is 112 or 39 => L("磁盘空间不够。腾出一些空间后再试。"),
        UnauthorizedAccessException or IOException => L("文件被占用或被杀毒软件拦住了。过一会儿再试。"),
        _ => e.Message,
    };

    FrameworkElement Progress()
    {
        string[] steps = [L("复制知了"), L("在开始菜单里放入口"), L("登记到“设置 › 应用”，以后从那里卸载")];
        var bar = new Grid { Height = 4, Margin = new Thickness(0, 0, 0, 18) };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(done, 0.15), GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(steps.Length - Math.Min(done, steps.Length), GridUnitType.Star) });
        var track = new Border { Background = Palette.Line, CornerRadius = new CornerRadius(2) };
        Grid.SetColumnSpan(track, 2);
        bar.Children.Add(track);
        bar.Children.Add(new Border { Background = Palette.Ink, CornerRadius = new CornerRadius(2) });
        var list = new StackPanel();
        list.Children.Add(bar);
        for (int i = 0; i < steps.Length; i++)
        {
            FrameworkElement lead = i < done ? Ui.Icon(Icons.Check, 14, Palette.Success, stroke: 1.8)
                : new Ellipse { Width = 8, Height = 8, Fill = i == done ? Palette.Ink : Palette.Line, Margin = new Thickness(3), VerticalAlignment = VerticalAlignment.Center };
            var row = Ui.Row(10, lead, Ui.Text(steps[i], 14, i <= done ? Palette.Ink : Palette.Secondary, wrap: false));
            row.Margin = new Thickness(0, i == 0 ? 0 : 10, 0, 0);
            list.Children.Add(row);
        }
        return list;
    }

    static Border Card(UIElement child) => new()
    {
        Background = Brushes.White, CornerRadius = new CornerRadius(18), Padding = new Thickness(22, 20, 22, 20), Child = child,
    };

    static FrameworkElement Footer(UIElement? left, params Button[] buttons)
    {
        var right = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        foreach (var b in buttons) { b.MinWidth = 96; b.Margin = new Thickness(8, 0, 0, 0); right.Children.Add(b); }
        var dock = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(right, Dock.Right);
        dock.Children.Add(right);
        if (left is FrameworkElement l) { l.VerticalAlignment = VerticalAlignment.Center; l.Margin = new Thickness(0, 0, 16, 0); dock.Children.Add(l); }
        return dock;
    }

    static FrameworkElement Page(string title, string text, UIElement? card, FrameworkElement? footer, bool logo = true)
    {
        var s = new StackPanel { Margin = new Thickness(40, 36, 40, 32) };
        if (logo) { var icon = AppIcon.Small(48); icon.HorizontalAlignment = HorizontalAlignment.Left; icon.Margin = new Thickness(0, 0, 0, 18); s.Children.Add(icon); }
        s.Children.Add(Ui.Text(title, 26, Palette.Ink, FontWeights.Bold));
        var p = Ui.Text(text, 14, Palette.Secondary);
        p.Margin = new Thickness(0, 8, 0, 0); p.LineHeight = 22;
        s.Children.Add(p);
        if (card is FrameworkElement c) { c.Margin = new Thickness(0, 22, 0, 0); s.Children.Add(c); }
        if (footer is not null) { footer.Margin = new Thickness(0, 26, 0, 0); s.Children.Add(footer); }
        return s;
    }
}
