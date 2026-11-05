using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using static Cicada.Strings;

namespace Cicada.App;

/// The window shown while listening: the live notes panel (default) or the subtitle bar. Like the
/// Mac's it never takes focus (the user keeps typing in their meeting app) and stays out of screen
/// captures unless 共享屏幕时让对方看到 is on, which it then says plainly.
sealed class NotesWindow : Window
{
    readonly Controller app;
    readonly DispatcherTimer clock = new() { Interval = TimeSpan.FromSeconds(1) };
    // Hosts kept between renders: the clock redraws only the header, and the body keeps its scroll.
    ContentControl header = new(), bars = new(), live = new(), tabs = new(), footer = new();
    ScrollViewer scroll = new();
    string? builtFor;
    string tab = "notes";
    /// Whether Windows agreed to keep the window out of captures; if not, it says it may be seen.
    bool hiddenFromCapture;
    bool renderQueued, placedSubtitles;
    // Rebuilt only when what they show changes, so a click never lands on a button that a
    // re-render just replaced; the clock and the countdown are text updated in place.
    string? headerKey, tabsKey, barsKey;
    readonly TextBlock clockText = Ui.Text("", 13, Palette.Secondary, wrap: false), dueText = Ui.Text("", 12, Palette.Tertiary, wrap: false);

    public NotesWindow(Controller app)
    {
        this.app = app;
        // Transparent, so it can have the Mac's 16-point corners (Windows' own frame stops at 8). WPF
        // redraws such a window in software, so nothing here animates: the clock is the one redraw a
        // second, and the shadow is plain rings (Ui.Floating), not a blur.
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.CanResizeWithGrip;
        FontFamily = Palette.Font;
        Title = L("知了");
        SourceInitialized += (_, _) =>
        {
            Native.MakeNonActivating(this);
            ApplyCaptureSetting();
        };
        // Drag from anywhere that isn't a control (buttons and links mark the press handled).
        MouseLeftButtonDown += (_, e) => { if (e.ButtonState == MouseButtonState.Pressed) try { DragMove(); } catch { } };
        clock.Tick += (_, _) => Tick();
        IsVisibleChanged += (_, _) => { if (IsVisible) clock.Start(); else clock.Stop(); };
        // The subtitle bar fits its text and grows upward, so its bottom edge stays put.
        SizeChanged += (_, e) =>
        {
            if (!Subtitles || !e.HeightChanged) return;
            if (e.PreviousSize.Height <= 0 || !placedSubtitles) { Top = SystemParameters.WorkArea.Bottom - e.NewSize.Height - 16 + Ui.ShadowRoom; placedSubtitles = true; }
            else Top -= e.NewSize.Height - e.PreviousSize.Height;
        };
        Place();
        Render();
    }

    bool Subtitles => app.Settings.View == "subtitles";

    /// The panel along the right edge, the subtitle bar along the bottom, on the primary work area.
    public void Place()
    {
        var area = SystemParameters.WorkArea;
        if (Subtitles)
        {
            SizeToContent = SizeToContent.Height; MinHeight = 80; MinWidth = 480;
            Width = Math.Min(900, area.Width - 48) + 2 * Ui.ShadowRoom;
            Left = area.Left + (area.Width - Width) / 2; Top = area.Bottom - Math.Max(ActualHeight, MinHeight) - 16 + Ui.ShadowRoom;
            placedSubtitles = ActualHeight > 0;
        }
        else
        {
            SizeToContent = SizeToContent.Manual; MinHeight = 360; MinWidth = 340;
            Width = 400 + 2 * Ui.ShadowRoom; Height = Math.Min(820, area.Height - 32) + 2 * Ui.ShadowRoom;
            Left = area.Right - Width - 16 + Ui.ShadowRoom; Top = area.Top + 16 - Ui.ShadowRoom;
        }
    }

    public void ApplyCaptureSetting()
    {
        var ok = Native.SetCaptureVisible(this, app.Settings.ShowInCapture);
        hiddenFromCapture = ok && !app.Settings.ShowInCapture;
        if (!ok && !app.Settings.ShowInCapture) Log.Debug("notes window: could not hide from capture, shown as visible");
        Render();
    }

    /// Changes come from engine threads: coalesce them into one render on the UI thread.
    public void Refresh()
    {
        if (renderQueued) return;
        renderQueued = true;
        Dispatcher.BeginInvoke(DispatcherPriority.Background, () => { renderQueued = false; Render(); });
    }

    void Collapse()
    {
        Hide();
        app.CollapsedWhileListening();
    }

    void Tick()
    {
        var session = app.Listen.SessionId is { } id ? app.Store.Get(id) : null;
        clockText.Text = app.Listen.Listening && session is not null ? Languages.Clock((DateTimeOffset.Now - session.StartedAt).TotalSeconds) : "";
        dueText.Text = Due() ?? "";
        if (app.Ending is { } p)
        {
            endingDetail.Text = LF("%lld 秒后结束会议并整理纪要", Controller.EndingLeft(p));
            endingNotice.Text = $"{app.EndingTitle(p)} · {LF("%lld 秒后结束", Controller.EndingLeft(p))}";
        }
    }

    ContentControl ending = new();
    string? endingKey;
    readonly TextBlock endingDetail = Ui.Text("", 12, Palette.Secondary);
    readonly TextBlock endingNotice = Ui.Text("", 13, Brushes.White, FontWeights.SemiBold, wrap: false);

    /// 已经 10 分钟没人说话 · 60 秒后结束 (MeetingEndingStrip): what will happen, and 继续记录 / 现在结束.
    /// The window never takes focus, so a click lands on the buttons at once.
    FrameworkElement EndingStrip()
    {
        if (!app.Listen.Listening) return new Border();
        if (app.ConfirmingEnd) return ConfirmEnd();
        if (app.Ending is not { } p) return new Border();
        Detach(endingDetail);
        var buttons = Ui.Row(8, Ui.Button(L("继续记录"), app.KeepRecording, Ui.Kind.Primary, height: 32),
                             Ui.Button(L("现在结束"), () => _ = app.StopListening(), height: 32));
        var stack = Ui.Stack(3, Ui.Text(app.EndingTitle(p), 14, Palette.Ink, FontWeights.Bold), endingDetail);
        buttons.Margin = new Thickness(0, 10, 0, 0);
        stack.Children.Add(buttons);
        Tick();
        return new Border { Background = Palette.AccentPale, CornerRadius = new CornerRadius(12), Padding = new Thickness(14), Margin = new Thickness(12, 0, 12, 8), Child = stack };
    }

    /// 结束这场会议？ (NotesWindow.swift › meetingBar): below the header, away from the 结束 button,
    /// so a double click can't confirm it; no timeout, so it never vanishes under the pointer.
    FrameworkElement ConfirmEnd()
    {
        var stack = Ui.Stack(3, Ui.Text(L("结束这场会议？"), 14, Palette.Ink, FontWeights.Bold), Ui.Text(ConfirmEndDetail(), 12, Palette.Secondary));
        var buttons = Ui.Row(8, Ui.Button(L("继续记录"), app.CancelStop, height: 32),
                             Ui.Button(L("结束会议"), () => _ = app.StopListening(), Ui.Kind.Primary, height: 32));
        buttons.Margin = new Thickness(0, 10, 0, 0);
        stack.Children.Add(buttons);
        return new Border { Background = Palette.AccentPale, CornerRadius = new CornerRadius(12), Padding = new Thickness(14), Margin = new Thickness(12, 0, 12, 8), Child = stack };
    }

    string ConfirmEndDetail()
    {
        var s = app.Listen.SessionId is { } id ? app.Store.Get(id) : null;
        return LF("已记录 %@ · %lld 句。结束后停止收听，并整理一份完整版纪要。",
                  Languages.Clock(s is null ? 0 : (DateTimeOffset.Now - s.StartedAt).TotalSeconds), s?.Lines.Count ?? 0);
    }

    static void Detach(FrameworkElement e) { if (e.Parent is Panel p) p.Children.Remove(e); }

    void Render()
    {
        var mode = Subtitles ? "subtitles" : "notes";
        if (builtFor != mode)
        {
            builtFor = mode; headerKey = tabsKey = barsKey = null;
            header = new ContentControl(); bars = new ContentControl(); ending = new ContentControl(); endingKey = null; live = new ContentControl(); tabs = new ContentControl(); footer = new ContentControl();
            scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(20, 16, 16, 12) };
            Content = Subtitles ? SubtitleFrame() : PanelFrame();
        }
        var key = $"{app.Listen.Listening}|{app.Settings.ShowInCapture}|{hiddenFromCapture}";
        if (key != headerKey) { headerKey = key; header.Content = Header(); }
        Tick();
        if (Subtitles) { live.Content = SubtitleLine(); return; }
        var ek = !app.Listen.Listening ? null : app.ConfirmingEnd ? "confirm" : app.Ending is { } p ? p.Reason.ToString() : null;
        if (ek != endingKey) { endingKey = ek; ending.Content = EndingStrip(); }
        var bk = $"{app.Listen.Problem}|{(app.Listen.Listening && app.Notes.Status is NotesEngine.State.Failed or NotesEngine.State.RateLimited ? app.Notes.Status : null)}|{app.Settings.ShowInCapture}|{hiddenFromCapture}";
        if (bk != barsKey) { barsKey = bk; bars.Content = Bars(); }
        live.Content = LiveCard();
        var count = app.Listen.SessionId is { } sid ? app.Store.Get(sid)?.Lines.Count ?? 0 : 0;
        if ($"{tab}|{count}" != tabsKey) { tabsKey = $"{tab}|{count}"; tabs.Content = TabRow(); }
        footer.Content = Footer();
        var atBottom = scroll.VerticalOffset >= scroll.ScrollableHeight - 4;
        var offset = scroll.VerticalOffset;
        scroll.Content = tab == "transcript" ? Transcript() : NotesBody();
        // The transcript follows new lines while the reader is at its end; otherwise nothing jumps.
        if (tab == "transcript" && atBottom) scroll.ScrollToEnd(); else scroll.ScrollToVerticalOffset(offset);
    }

    // MARK: The panel

    FrameworkElement PanelFrame()
    {
        var dock = new DockPanel();
        void Top(UIElement e) { DockPanel.SetDock(e, Dock.Top); dock.Children.Add(e); }
        // The Mac's layout: the header, 纪要 / 文字记录 as a two-part switch, the notes, and the
        // sentence being said now on a dark card along the bottom, where the eye rests.
        Top(header);
        Top(ending);
        Top(bars);
        tabs.Margin = new Thickness(12, 0, 12, 0);
        Top(tabs);
        DockPanel.SetDock(footer, Dock.Bottom);
        dock.Children.Add(footer);
        live.Margin = new Thickness(12, 8, 12, 0);
        DockPanel.SetDock(live, Dock.Bottom);
        dock.Children.Add(live);
        dock.Children.Add(scroll);
        return Ui.Floating(dock, Palette.Surface);
    }

    FrameworkElement Header()
    {
        var listen = app.Listen;
        var session = listen.SessionId is { } id ? app.Store.Get(id) : null;
        if (Subtitles)
        {
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top };
            buttons.Children.Add(Ui.IconButton(Icons.Notes, L("换成纪要"), () => app.SetView("notes"), Palette.NightText, 32, 16, onDark: true));
            if (listen.Listening)
            {
                var stop = Ui.IconButton("M7,7 H13 V13 H7 Z", L("结束"), app.RequestStop, NightAccent, 32, 14, fill: true, onDark: true);
                stop.Background = new SolidColorBrush(Color.FromArgb(0x1F, 0xFF, 0xFF, 0xFF));
                buttons.Children.Add(Gap(stop, 6));
            }
            else buttons.Children.Add(Gap(Ui.IconButton(Icons.Close, L("收起（继续听）"), Collapse, Palette.NightText, 32, 14, onDark: true), 6));
            return buttons;
        }
        var left = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (listen.Listening && session is not null)
        {
            left.Children.Add(Ui.LiveDot());
            left.Children.Add(Gap(Ui.Text(L("正在听"), 14, Palette.Ink, FontWeights.Bold, wrap: false), 8));
            Detach(clockText);
            clockText.FontSize = 13; clockText.Foreground = Palette.Secondary; clockText.HorizontalAlignment = HorizontalAlignment.Left;
            left.Children.Add(Gap(clockText, 8));
        }
        else
        {
            left.Children.Add(AppIcon.Small(18));
            left.Children.Add(Gap(Ui.Text(L("知了"), 14, Palette.Ink, FontWeights.Bold, wrap: false), 8));
        }
        var right = new StackPanel { Orientation = Orientation.Horizontal };
        right.Children.Add(Ui.IconButton(Icons.Subtitles, L("换成字幕条"), () => app.SetView("subtitles"), Palette.Body, 34, 16));
        var main = listen.Listening
            ? Ui.Button(L("结束"), app.RequestStop, Ui.Kind.Pale, Icons.Stop, 32, iconFill: true)
            : Ui.Button(L("开始听"), () => _ = app.ToggleListening(), Ui.Kind.Accent, Icons.Wave, 32);
        main.MinWidth = 0; main.Padding = new Thickness(12, 0, 12, 0);
        right.Children.Add(Gap(main, 8));
        right.Children.Add(Gap(Ui.IconButton("M5,10 H15", L("收起（继续听）"), Collapse, Palette.Body, 34, 16), 4));
        var row = Ui.Spread(left, right);
        row.Height = 56;
        row.Margin = new Thickness(18, 0, 10, 0);
        return row;
    }

    /// What needs the user: Ling failing, or the window being visible to others.
    FrameworkElement Bars()
    {
        var stack = new StackPanel { Margin = new Thickness(12, 0, 12, 0) };
        void Add(FrameworkElement bar) { bar.Margin = new Thickness(0, 0, 0, 8); stack.Children.Add(bar); }
        switch (app.Listen.Problem)
        {
            case LingException.Kind.Network or LingException.Kind.Timeout or LingException.Kind.Http:
                Add(Ui.InfoBar(Ui.Severity.Error, L("连不上 Ling"), L("这段时间的话没能识别。检查网络后点重试。"),
                    Ui.Button(L("重试"), () => { app.Listen.ClearProblem(); _ = app.Ling.Check(); }, height: 32)));
                break;
            case LingException.Kind.RateLimited:
                Add(Ui.InfoBar(Ui.Severity.Warning, L("Ling 太忙"), L("稍后会自动重试。")));
                break;
            case LingException.Kind.InvalidKey or LingException.Kind.NoKey:
                Add(Ui.InfoBar(Ui.Severity.Error, L("Ling key 无效"), L("去设置里换一个 key。"), Ui.Button(L("打开设置"), app.ShowSettings, height: 32)));
                break;
        }
        // The notes' own trouble (NotesWindow.swift › banner): the last round didn't land.
        if (app.Listen.Listening)
            switch (app.Notes.Status)
            {
                case NotesEngine.State.RateLimited:
                    Add(Ui.InfoBar(Ui.Severity.Warning, null, LF("请求过于频繁，稍后会自动重试。纪要停留在 %@。", NotesCoveredUntil())));
                    break;
                case NotesEngine.State.Failed:
                    Add(Ui.InfoBar(Ui.Severity.Warning, null, L("这轮没整理好，下一轮会自动重试。")));
                    break;
            }
        // Shown to others on purpose: the footer's 对方可见 says so. Not hidden though asked: a warning.
        if (!app.Settings.ShowInCapture && !hiddenFromCapture)
            Add(Ui.InfoBar(Ui.Severity.Warning, null, L("Windows 没能把这个窗口从屏幕共享里藏起来，对方可能看得到。")));
        return stack;
    }

    /// When the last line the notes cover was said, as mm:ss.
    string NotesCoveredUntil()
    {
        var lines = app.Listen.SessionId is { } id ? app.Store.Get(id)?.Lines : null;
        var covered = app.Notes.Notes.Covered;
        return Languages.Clock(lines is not null && covered > 0 && covered <= lines.Count ? lines[covered - 1].T : 0);
    }

    /// The newest line on the Mac's dark card: who in their colour and 正在说 while Ming works on the
    /// next, the original small, its translation large and bold.
    FrameworkElement LiveCard()
    {
        var listen = app.Listen;
        var line = listen.SessionId is { } id ? app.Store.Get(id)?.Lines.LastOrDefault() : null;
        var stack = new StackPanel();
        if (line is null)
        {
            stack.Children.Add(Ui.Text(listen.Listening ? L("等有人说话") : L("点“开始听”，电脑里播放的声音会变成双语字幕和纪要"), 14, Brushes.White, listen.Listening ? FontWeights.Bold : FontWeights.Normal));
            if (listen.Listening) stack.Children.Add(Gap(Ui.Text(L("电脑里一有人声，字幕就出来"), 12, Palette.NightText), 4, top: true));
        }
        else
        {
            var lines = app.Store.Get(listen.SessionId!)?.Lines ?? [];
            var number = app.Settings.SpeakerVoices && line.Speaker == "them" && SpeakerLabels.Numbers(lines).TryGetValue(line.Id, out var n) ? n : (int?)null;
            var who = line.Speaker == "me" ? L("你") : number is { } k ? LF("说话人 %lld", k) : Ui.SpokenName(line.SrcLang);
            var whoRow = Ui.Row(8, Ui.Text(who, 12, NightAccent, wrap: false));
            whoRow.Children.Add(Gap(Ui.Text(listen.Listening && listen.Pending > 0 ? L("正在说") : Languages.Clock(line.T), 12, Palette.NightText, wrap: false), 8));
            stack.Children.Add(whoRow);
            if (line.Dst is not null && line.Dst != line.Src) stack.Children.Add(Gap(Ui.Text(line.Src, 13, NightBody), 6, top: true));
            stack.Children.Add(Gap(Ui.Text(line.Dst ?? line.Src, 16, Brushes.White, FontWeights.Bold), 6, top: true));
        }
        return new Border { Background = Palette.Night, CornerRadius = new CornerRadius(14), Padding = new Thickness(16, 14, 16, 14), Child = stack, MinHeight = 96 };
    }

    /// Text on the dark card: the accent lifted for contrast, and the original a light grey.
    static readonly SolidColorBrush NightAccent = new(Color.FromRgb(0xFF, 0x8A, 0x5C)), NightBody = new(Color.FromRgb(0xD9, 0xDC, 0xE1));

    FrameworkElement TabRow()
    {
        var count = app.Listen.SessionId is { } id ? app.Store.Get(id)?.Lines.Count ?? 0 : 0;
        return Ui.Segmented([("notes", L("纪要")), ("transcript", count > 0 ? $"{L("文字记录")} {count}" : L("文字记录"))], tab, t => { tab = t; Render(); }, fill: true, height: 30);
    }

    string? Due()
    {
        if (app.Notes.Status == NotesEngine.State.Updating && !app.Notes.Notes.IsEmpty) return L("正在整理纪要…");
        if (app.Notes.NextUpdate is { } next && app.Listen.Listening)
            return LF("%@ 秒后更新", Math.Max(1, (int)Math.Ceiling((next - DateTime.UtcNow).TotalSeconds)));
        return null;
    }

    FrameworkElement NotesBody()
    {
        var notes = app.Notes.Notes;
        var body = new StackPanel();
        if (notes.IsEmpty)
        {
            var (title, hint) = app.Notes.Status switch
            {
                NotesEngine.State.Updating => (L("正在整理纪要…"), ""),
                NotesEngine.State.NoKey => (L("生成纪要需要 API key"), ""),
                NotesEngine.State.InvalidKey => (L("这个 key 无效，请检查是否复制完整，或重新创建一个"), ""),
                _ => app.Listen.Listening ? (L("纪要会在会议进行中自动生成"), "") : ("", ""),
            };
            var empty = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 48, 0, 0) };
            if (title.Length > 0) { var t = Ui.Text(title, 14, Palette.Body); t.TextAlignment = TextAlignment.Center; empty.Children.Add(t); }
            if (hint.Length > 0) { var h = Ui.Text(hint, 13, Palette.Secondary); h.TextAlignment = TextAlignment.Center; empty.Children.Add(Gap(h, 4, top: true)); }
            body.Children.Add(empty);
            return body;
        }
        if (notes.Title is { Length: > 0 } title2) body.Children.Add(Ui.Text(title2, 18, Palette.Ink, FontWeights.Bold));
        if (notes.Summary.Length > 0) { var sum = Ui.Text(notes.Summary, 14, Palette.Body); sum.LineHeight = 24; body.Children.Add(Gap(sum, 8, top: true)); }
        for (int i = 0; i < notes.Topics.Count; i++)
        {
            var topic = notes.Topics[i];
            var time = Ui.Text(Languages.Clock(topic.Start), 12, Palette.AccentText, wrap: false);
            time.Width = 40; time.Margin = new Thickness(0, 2, 0, 0); time.VerticalAlignment = VerticalAlignment.Top;
            var head = Ui.Row(8, Ui.Text(topic.Title, 15, Palette.Ink));
            if (app.Listen.Listening && i == notes.Topics.Count - 1) head.Children.Add(Gap(Ui.Badge(L("正在讲")), 8));
            var points = new StackPanel { Children = { head } };
            foreach (var p in topic.Points) points.Children.Add(Gap(Ui.Text(p, 13, Palette.Secondary), 4, top: true));
            var dock = new DockPanel();
            DockPanel.SetDock(time, Dock.Left);
            dock.Children.Add(time); dock.Children.Add(points);
            body.Children.Add(Gap(dock, 18, top: true));
        }
        if (notes.Conclusions.Count > 0)
        {
            body.Children.Add(Gap(Ui.Text(L("结论"), 13, Palette.Secondary), 18, top: true));
            foreach (var c in notes.Conclusions) body.Children.Add(Gap(Bullet(c.Text), 4, top: true));
        }
        if (notes.Todos.Count > 0)
        {
            body.Children.Add(Gap(Ui.Text(L("待办"), 13, Palette.Secondary), 18, top: true));
            foreach (var todo in notes.Todos) body.Children.Add(Gap(Todo(todo), 6, top: true));
        }
        return body;
    }

    FrameworkElement Transcript()
    {
        var lines = app.Listen.SessionId is { } id ? app.Store.Get(id)?.Lines ?? [] : [];
        var body = new StackPanel();
        // Stored as they arrive (the notes count them); shown in time order, so a sentence I said
        // sits between the other side's, which come back from Ming a little later.
        foreach (var (l, who, ink) in Speakers(lines, app.Settings.SpeakerVoices)) body.Children.Add(TranscriptRow(l, who, ink));
        return body;
    }

    /// Lines in time order with who said them, named only where the speaker changes (as chat apps
    /// do): 你 for what I said into the meeting, 说话人 N once voices are told apart.
    internal static IEnumerable<(TranscriptLine line, string? who, Brush? ink)> Speakers(IReadOnlyList<TranscriptLine> lines, bool voices)
    {
        var numbers = voices ? SpeakerLabels.Numbers(lines) : [];
        string? last = null;
        foreach (var l in lines.OrderBy(x => x.T))
        {
            var key = l.Speaker == "me" ? "me" : numbers.TryGetValue(l.Id, out var n) ? $"n{n}" : "them";
            string? who = null; Brush? ink = null;
            if (key != last)
            {
                if (key == "me") { who = L("你"); ink = Palette.AccentText; }
                else if (numbers.TryGetValue(l.Id, out var m)) { who = LF("说话人 %lld", m); ink = Palette.Speaker(m); }
                else if (numbers.Count > 0) { who = L("未识别"); ink = Palette.Tertiary; }
            }
            last = key;
            yield return (l, who, ink);
        }
    }

    /// One line of the transcript as on the Mac: who (in their colour) and when, the original in
    /// grey, the translation in ink.
    internal static FrameworkElement TranscriptRow(TranscriptLine l, string? who = null, Brush? ink = null)
    {
        var text = new StackPanel { Margin = new Thickness(0, who is null ? 0 : 6, 0, 12) };
        var head = Ui.Row(8, Ui.Text(Languages.Clock(l.T), 12, Palette.Tertiary, wrap: false));
        if (who is not null) head.Children.Insert(0, Ui.Text(who, 12, ink ?? Palette.Secondary, wrap: false));
        if (head.Children.Count > 1) ((FrameworkElement)head.Children[1]).Margin = new Thickness(8, 0, 0, 0);
        text.Children.Add(head);
        var translated = !string.IsNullOrEmpty(l.Dst) && l.Dst != l.Src;
        text.Children.Add(Gap(Ui.Text(l.Src, translated ? 13 : 15, translated ? Palette.Secondary : Palette.Ink), 3, top: true));
        if (translated) text.Children.Add(Gap(Ui.Text(l.Dst!, 15, Palette.Ink), 2, top: true));
        return text;
    }

    /// Who can see this window, and when the notes change next.
    FrameworkElement Footer()
    {
        var visible = app.Settings.ShowInCapture || !hiddenFromCapture;
        FrameworkElement left = Ui.Row(6, Ui.Icon(visible ? Icons.Eye : Icons.EyeOff, 15, Palette.Secondary),
            Ui.Text(visible ? L("共享屏幕时对方看得到") : L("屏幕共享里看不到"), 12, Palette.Secondary, wrap: false));
        Detach(dueText);
        dueText.FontSize = 12; dueText.Foreground = Palette.Secondary; dueText.VerticalAlignment = VerticalAlignment.Center;
        FrameworkElement right = app.Settings.ShowInCapture ? Ui.Badge(L("对方可见")) : dueText;
        var row = Ui.Spread(left, right);
        row.Height = 40;
        row.Margin = new Thickness(18, 0, 14, 2);
        return row;
    }

    // MARK: The subtitle bar

    FrameworkElement SubtitleFrame()
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(header, 1);
        header.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(live);
        grid.Children.Add(header);
        return Ui.Floating(new Border { Padding = new Thickness(22, 14, 14, 16), Child = grid }, new SolidColorBrush(Color.FromArgb(0xF2, 0x1B, 0x1D, 0x22)), 16, dark: true);
    }

    /// The bar as on the Mac: who and the original on one small line, the translation big and bold.
    FrameworkElement SubtitleLine()
    {
        var listen = app.Listen;
        var session = listen.SessionId is { } id ? app.Store.Get(id) : null;
        var line = session?.Lines.LastOrDefault();
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) };
        // Asked to end: the one time the bar carries buttons, as the panel's card does.
        if (listen.Listening && app.ConfirmingEnd)
        {
            text.Children.Add(Ui.Text(L("结束这场会议？"), 15, Brushes.White, FontWeights.Bold));
            text.Children.Add(Gap(Ui.Text(ConfirmEndDetail(), 12, Palette.NightText), 2, top: true));
            // On the dark bar the ink button would vanish: 结束会议 takes the 结束 button's pale look.
            var buttons = Ui.Row(8, Ui.Button(L("继续记录"), app.CancelStop, height: 32), Ui.Button(L("结束会议"), () => _ = app.StopListening(), Ui.Kind.Pale, Icons.Stop, 32, iconFill: true));
            buttons.Margin = new Thickness(0, 8, 0, 0);
            text.Children.Add(buttons);
            return text;
        }
        // The subtitle bar has no room for buttons: it says what will happen (the Mac's notice).
        if (listen.Listening && app.Ending is not null)
        {
            Detach(endingNotice);
            endingNotice.Foreground = new SolidColorBrush(Color.FromRgb(0xF4, 0xA5, 0x8C));
            endingNotice.Margin = new Thickness(0, 0, 0, 4);
            text.Children.Add(endingNotice);
            Tick();
        }
        if (line is null)
            text.Children.Add(Ui.Text(listen.Listening ? L("等有人说话") : L("点“开始听”，电脑里播放的声音会变成双语字幕和纪要"), 15, Palette.NightText));
        else
        {
            var number = app.Settings.SpeakerVoices && line.Speaker == "them" && SpeakerLabels.Numbers(session!.Lines).TryGetValue(line.Id, out var n) ? n : (int?)null;
            var who = line.Speaker == "me" ? L("你") : number is { } k ? LF("说话人 %lld", k) : null;
            var top = new TextBlock { FontFamily = Palette.Font, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis, Foreground = Palette.NightText };
            if (who is not null) top.Inlines.Add(new System.Windows.Documents.Run(who + "  ") { Foreground = NightAccent });
            if (line.Dst is not null && line.Dst != line.Src) top.Inlines.Add(new System.Windows.Documents.Run(line.Src));
            if (top.Inlines.Count > 0) text.Children.Add(top);
            text.Children.Add(Gap(Ui.Text(line.Dst ?? line.Src, app.Settings.SubtitleSize, Brushes.White, FontWeights.Bold), 4, top: true));
        }
        return text;
    }

    // MARK: Bits

    static T Gap<T>(T e, double size, bool top = false) where T : FrameworkElement
    {
        e.Margin = top ? new Thickness(0, size, 0, 0) : new Thickness(size, 0, 0, 0);
        return e;
    }

    static FrameworkElement Bullet(string text)
    {
        var dock = new DockPanel();
        var dot = Ui.Text("·", 14, Palette.Body, wrap: false);
        dot.Width = 12;
        DockPanel.SetDock(dot, Dock.Left);
        dock.Children.Add(dot);
        dock.Children.Add(Ui.Text(text, 14, Palette.Body));
        return dock;
    }

    /// A to-do: an empty box (notes are read-only here), the task, and who has it.
    internal static FrameworkElement Todo(NoteItem todo)
    {
        var dock = new DockPanel();
        var box = new Border { Width = 16, Height = 16, BorderBrush = Palette.Secondary, BorderThickness = new Thickness(1.5), CornerRadius = new CornerRadius(3), Margin = new Thickness(0, 2, 10, 0), VerticalAlignment = VerticalAlignment.Top };
        DockPanel.SetDock(box, Dock.Left);
        dock.Children.Add(box);
        var text = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 14, FontFamily = Palette.Font, Foreground = Palette.Ink };
        text.Inlines.Add(new System.Windows.Documents.Run(todo.Text));
        if (todo.Owner is { Length: > 0 } owner) text.Inlines.Add(new System.Windows.Documents.Run($" · {owner}") { Foreground = Palette.Secondary });
        dock.Children.Add(text);
        return dock;
    }
}
