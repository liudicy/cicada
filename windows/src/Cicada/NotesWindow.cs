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
        clock.Tick += (_, _) => { Tick(); Pulse(); };
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
        if (app.Ending is not { } p)
        {
            return new Border();
        }
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
            ask = new ContentControl(); toast = new ContentControl(); askKey = toastKey = null;
            scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(20, 16, 16, 12) };
            Content = Subtitles ? SubtitleFrame() : PanelFrame();
        }
        var key = $"{app.Listen.Listening}|{app.MicOn}|{app.Settings.ShowInCapture}|{hiddenFromCapture}";
        if (key != headerKey) { headerKey = key; header.Content = Header(); }
        Tick();
        if (Subtitles) { live.Content = SubtitleLine(); return; }
        var ek = !app.Listen.Listening ? null : app.ConfirmingEnd ? "confirm" : app.Ending is { } p ? p.Reason.ToString() : null;
        if (ek != endingKey) { endingKey = ek; ending.Content = EndingStrip(); }
        var bk = $"{app.Listen.Problem}|{app.Listen.ProblemStatus}|{(app.Listen.Listening && app.Notes.Status is NotesEngine.State.Failed or NotesEngine.State.RateLimited or NotesEngine.State.Unreachable or NotesEngine.State.Updating ? app.Notes.Status : null)}|{app.Ling.Health.Failure?.Why}|{app.Settings.AiProvider}|{app.CanSwitchToLing}|{app.Translator.GoogleOff && app.Translator.SentencesUntranslated}|{app.Settings.ShowInCapture}|{hiddenFromCapture}";
        if (bk != barsKey) { barsKey = bk; bars.Content = Bars(); }
        var asking = app.Listen.SessionId is { } aid && !app.Settings.ShowInCapture ? app.Fixes.Asking(aid) : null;
        var ak = asking is { } a0 ? $"{a0.Line.Id}|{a0.Fix}|{a0.Of}" : null;
        if (ak != askKey) { askKey = ak; ask.Content = AskCard(asking); }
        var tk = app.Fixes.Toast is { } t0 ? $"{t0.Id}|{app.Fixes.CanUndo}" : null;
        if (tk != toastKey) { toastKey = tk; toast.Content = FixViews.Toast(app.Fixes); }
        live.Content = LiveCard();
        var count = app.Listen.SessionId is { } sid ? app.Store.Get(sid)?.Lines.Count ?? 0 : 0;
        if ($"{tab}|{count}" != tabsKey) { tabsKey = $"{tab}|{count}"; tabs.Content = TabRow(); }
        footer.Content = Footer();
        var atBottom = scroll.VerticalOffset >= scroll.ScrollableHeight - 4;
        var offset = scroll.VerticalOffset;
        soundBars.Clear();
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
        // 这样改对吗？ above both tabs: the window opens on 纪要, where a card in the transcript
        // would never be seen.
        Top(ask);
        tabs.Margin = new Thickness(12, 0, 12, 0);
        Top(tabs);
        DockPanel.SetDock(footer, Dock.Bottom);
        dock.Children.Add(footer);
        live.Margin = new Thickness(12, 8, 12, 0);
        DockPanel.SetDock(live, Dock.Bottom);
        dock.Children.Add(live);
        // The last fix decision with 撤销, just above the sentence being said.
        toast.HorizontalAlignment = HorizontalAlignment.Center;
        toast.Margin = new Thickness(12, 8, 12, 0);
        DockPanel.SetDock(toast, Dock.Bottom);
        dock.Children.Add(toast);
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
                // 打开麦克风 (the Mac's bar has it while editing; this bar takes clicks anyway).
                var mic = Ui.IconButton(Icons.Mic, app.MicOn ? L("关闭麦克风") : L("打开麦克风"), () => app.SetMic(!app.MicOn),
                                        app.MicOn ? NightAccent : Palette.NightText, 32, 15, onDark: true);
                if (app.MicOn) mic.Background = new SolidColorBrush(Color.FromArgb(0x33, 0xE8, 0x55, 0x2B));
                buttons.Children.Add(Gap(mic, 6));
                var stop = Ui.IconButton("M7,7 H13 V13 H7 Z", L("结束"), app.RequestStop, NightAccent, 32, 14, fill: true, onDark: true);
                stop.Background = new SolidColorBrush(Color.FromArgb(0x1F, 0xFF, 0xFF, 0xFF));
                buttons.Children.Add(Gap(stop, 6));
            }
            else buttons.Children.Add(Gap(Ui.IconButton(Icons.Close, L("收起（继续听）"), Collapse, Palette.NightText, 32, 14, onDark: true), 6));
            return buttons;
        }
        var left = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        FrameworkElement? listening = null;
        if (listen.Listening && session is not null)
        {
            left.Children.Add(Ui.LiveDot());
            left.Children.Add(listening = Gap(Ui.Text(L("正在听"), 14, Palette.Ink, FontWeights.Bold, wrap: false), 8));
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
        if (listen.Listening)
        {
            // The Mac's header buttons are 12 pt: at 14 the English "Turn off mic" and "End" pushed
            // 收起 out of the window.
            Snug(main);
            right.Children.Add(Gap(Snug(TrayFlyout.MicButton(app, panel: false)), 8));
        }
        right.Children.Add(Gap(main, 8));
        right.Children.Add(Gap(Ui.IconButton("M5,10 H15", L("收起（继续听）"), Collapse, Palette.Body, 34, 16), 4));
        // The buttons are docked first so a long status in a wide language clips the clock, never 收起.
        var row = new DockPanel { LastChildFill = false };
        DockPanel.SetDock(right, Dock.Right); DockPanel.SetDock(left, Dock.Left);
        row.Children.Add(right); row.Children.Add(left);
        left.ClipToBounds = true;
        // Too narrow for the word and the clock (English with the mic button): the live dot and
        // the clock say it on their own.
        if (listening is not null)
            row.SizeChanged += (_, e) =>
            {
                listening.Visibility = Visibility.Visible;
                left.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
                right.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
                if (left.DesiredSize.Width + right.DesiredSize.Width > e.NewSize.Width) listening.Visibility = Visibility.Collapsed;
            };
        row.Height = 56;
        row.Margin = new Thickness(18, 0, 10, 0);
        return row;
    }

    /// What needs the user: the AI service failing, or the window being visible to others.
    FrameworkElement Bars()
    {
        var stack = new StackPanel { Margin = new Thickness(12, 0, 12, 0) };
        void Add(FrameworkElement bar) { bar.Margin = new Thickness(0, 0, 0, 8); stack.Children.Add(bar); }
        // AI trouble is one status line each (NotesWindow.swift › banner): a dot, what waits for
        // what · what still works, at most one action. The service hears the meeting here, so its
        // failing stops the subtitles as well: hearing's line comes first and the notes' own lines
        // only add what it doesn't already say.
        (string, Action)? useLing = app.CanSwitchToLing ? (L("改用 Ling"), app.SwitchToLing) : null;
        var problem = app.Listen.Problem;
        if (problem is { } p)
        {
            var ling = app.Ling;
            var (title, body, settings) = ListenEngine.Words(p, app.Listen.ProblemStatus, ServiceLabel(), ling.HearName);
            var text = (title is null ? body : title.TrimEnd('。', '.') + " · " + body).TrimEnd('。', '.');
            // Can't reach it: picks up by itself once it answers; the proxy hint is in 设置 › AI 服务.
            if (p is LingException.Kind.Network or LingException.Kind.Timeout) Add(Ui.StatusLine(Ui.Tone.Waiting, text, useLing));
            // Busy or erring (a 5xx): it passes by itself, nothing to press.
            else if (p == LingException.Kind.RateLimited || ListenEngine.IsServerError(p, app.Listen.ProblemStatus)) Add(Ui.StatusLine(Ui.Tone.Waiting, text));
            else if (settings) Add(Ui.StatusLine(Ui.Tone.NeedsYou, text, (p is LingException.Kind.InvalidKey or LingException.Kind.NoKey ? L("换 key") : L("设置"), app.ShowAISettings)));
            // Anything else (a garbled reply, Ling's 400) also picks up by itself; 重试 asks now.
            else Add(Ui.StatusLine(Ui.Tone.Waiting, text, (L("重试"), () => { app.Listen.ClearProblem(); _ = app.Ling.Check(); })));
        }
        var unreachable = app.Ling.Health.Failure?.Why == AICheck.Reason.Unreachable;
        // 语音和文字只发给你的服务, and finished sentences go untranslated: it picks up by itself, and
        // no 改用 Ling (that would send the meeting elsewhere). When hearing failed, its line says so.
        var notesWait = app.Notes.Status is NotesEngine.State.Unreachable or NotesEngine.State.Updating && unreachable;
        var stalled = problem is null && app.Listen.Listening && app.Translator.GoogleOff && app.Translator.SentencesUntranslated;
        if (stalled)
            Add(Ui.StatusLine(Ui.Tone.Waiting, notesWait ? LF("译文和纪要等 %@ 恢复 · 字幕先显示原文", ServiceLabel())
                                                          : LF("译文等 %@ 恢复 · 字幕先显示原文", ServiceLabel())));
        if (app.Listen.Listening)
            switch (app.Notes.Status)
            {
                // Hearing goes ahead of the notes, so it is usually still fine: unless its line says otherwise.
                case NotesEngine.State.RateLimited when problem is null:
                    Add(Ui.StatusLine(Ui.Tone.Waiting, LF("%@ 很忙 · 纪要稍后补上，字幕照常", ServiceLabel())));
                    break;
                // Both: the notes' own request failed, and the service doesn't answer anything; notes that
                // only timed out while translations still came back retry on the next round. The retry
                // that follows (Updating) hangs as long as a timeout: the line stays meanwhile. When
                // hearing can't reach it either, its line above says so already.
                case NotesEngine.State.Unreachable or NotesEngine.State.Updating when unreachable && !stalled:
                    if (problem is not (LingException.Kind.Network or LingException.Kind.Timeout))
                    {
                        // A hear model served at another address still brings subtitles.
                        var until = NotesCoveredUntil();
                        var text = !app.Ling.Config.HearElsewhere ? LF("字幕和纪要等 %@ 恢复 · 连上后自动继续", ServiceLabel())
                            : until > 0 ? LF("纪要等 %@ 恢复 · 停在 %@，字幕照常", ServiceLabel(), Languages.Clock(until))
                                        : LF("纪要等 %@ 恢复 · 字幕照常", ServiceLabel());
                        Add(Ui.StatusLine(Ui.Tone.Waiting, text, useLing));
                    }
                    break;
                case NotesEngine.State.Failed:
                    Add(Ui.StatusLine(Ui.Tone.Info, L("这轮纪要没写好 · 下轮自动补上")));
                    break;
            }
        // Shown to others on purpose: the footer's 对方可见 says so. Not hidden though asked: a warning.
        if (!app.Settings.ShowInCapture && !hiddenFromCapture)
            Add(Ui.InfoBar(Ui.Severity.Warning, null, L("Windows 没能把这个窗口从屏幕共享里藏起来，对方可能看得到。")));
        return stack;
    }

    string ServiceLabel() => app.Ling.ServiceLabel;

    /// When the last line the notes cover was said (0: nothing covered yet).
    double NotesCoveredUntil()
    {
        var lines = app.Listen.SessionId is { } id ? app.Store.Get(id)?.Lines : null;
        var covered = app.Notes.Notes.Covered;
        return lines is not null && covered > 0 && covered <= lines.Count ? lines[covered - 1].T : 0;
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
            var who = line.Speaker == "me" ? L("你 · 同传") : number is { } k ? LF("说话人 %lld", k) : Ui.SpokenName(line.SrcLang);
            var whoRow = Ui.Row(8, Ui.Text(who, 12, NightAccent, wrap: false));
            whoRow.Children.Add(Gap(Ui.Text(listen.Listening && listen.Pending > 0 ? L("正在说") : Languages.Clock(line.T), 12, Palette.NightText, wrap: false), 8));
            stack.Children.Add(whoRow);
            if (line.Dst is not null && line.Dst != line.Src) stack.Children.Add(Gap(Ui.Text(line.Shown, 13, NightBody), 6, top: true));
            stack.Children.Add(Gap(Ui.Text(line.Dst ?? line.Shown, 16, Brushes.White, FontWeights.Bold), 6, top: true));
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
            var heard = app.Listen.SessionId is { } id ? app.Store.Get(id)?.Lines.Count ?? 0 : 0;
            var status = app.Notes.Status;
            // NotesWindow.swift › notesPane: while listening the placeholder stays up after lines
            // arrive, until a request is actually out (the first waits for a few lines or 20 s);
            // a key problem says so instead.
            var keyProblem = status is NotesEngine.State.NoKey or NotesEngine.State.InvalidKey;
            if (app.Listen.Listening && !keyProblem && !(status == NotesEngine.State.Updating && heard > 0)) return Listening(heard);
            var (title, hint) = status switch
            {
                NotesEngine.State.Updating => (L("正在整理纪要…"), ""),
                NotesEngine.State.NoKey => (L("生成纪要需要 API key"), ""),
                NotesEngine.State.InvalidKey => (L("这个 key 无效，请检查是否复制完整，或重新创建一个"), ""),
                _ => ("", ""),
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

    // MARK: Listening, no notes asked for yet (NotesViews.swift › NotesListeningView)

    // Stepped once a second by the clock, like Ui.LiveDot: this window is redrawn in software, so a
    // WPF animation would redraw it every frame. Holds only what the current render shows.
    readonly List<ScaleTransform> soundBars = [];
    readonly SolidColorBrush skeleton = new(SkeletonBase);
    int beat;
    static readonly Color SkeletonBase = Color.FromRgb(0xEE, 0xF0, 0xF3), SkeletonLight = Color.FromRgb(0xF7, 0xF8, 0xFA);
    // The Mac's placeholder grey, its accentPale at 70% on white, and its chip fill.
    static readonly SolidColorBrush Placeholder = Frozen(0xB8, 0xBD, 0xC6), ListeningRow = Frozen(0xFE, 0xF1, 0xEC), ChipFill = Frozen(0xF2, 0xF3, 0xF5);
    // How tall each sound bar stands, step by step; each bar runs two steps ahead of the one before.
    static readonly double[] levels = [0.35, 0.7, 1, 0.6, 0.3, 0.85, 0.5];

    static SolidColorBrush Frozen(byte r, byte g, byte b) { var x = new SolidColorBrush(Color.FromRgb(r, g, b)); x.Freeze(); return x; }

    void Pulse()
    {
        if (soundBars.Count == 0) return;
        beat++;
        for (int i = 0; i < soundBars.Count; i++) soundBars[i].ScaleY = levels[(beat + i * 2) % levels.Length];
        skeleton.Color = beat % 2 == 0 ? SkeletonBase : SkeletonLight;
    }

    /// One quiet status row, then the notes' own shape waiting to be filled, so the first version
    /// lands where the reader is already looking.
    FrameworkElement Listening(int heard)
    {
        var body = new StackPanel { Margin = new Thickness(0, 4, 0, 0) };
        var bars = new StackPanel { Orientation = Orientation.Horizontal, Height = 22, VerticalAlignment = VerticalAlignment.Center };
        for (int i = 0; i < 4; i++)
        {
            var scale = new ScaleTransform(1, levels[(beat + i * 2) % levels.Length]);
            soundBars.Add(scale);
            bars.Children.Add(new System.Windows.Shapes.Rectangle
            {
                Width = 3, Height = 22, RadiusX = 1.5, RadiusY = 1.5, Fill = Palette.Live, Margin = new Thickness(i == 0 ? 0 : 3, 0, 0, 0),
                RenderTransform = scale, RenderTransformOrigin = new Point(0.5, 0.5),
            });
        }
        var status = new DockPanel();
        DockPanel.SetDock(bars, Dock.Left);
        status.Children.Add(bars);
        if (heard > 0)
        {
            var count = Ui.Text(LF("已听到 %lld 句", heard), 12, Palette.Tertiary, wrap: false);
            count.VerticalAlignment = VerticalAlignment.Center; count.Margin = new Thickness(12, 0, 0, 0);
            DockPanel.SetDock(count, Dock.Right);
            status.Children.Add(count);
        }
        var say = Ui.Text(L("有人开口后，约半分钟出第一版"), 13, Palette.Ink);
        say.VerticalAlignment = VerticalAlignment.Center; say.Margin = new Thickness(12, 0, 0, 0);
        status.Children.Add(say);
        body.Children.Add(new Border { Background = ListeningRow, CornerRadius = new CornerRadius(12), Padding = new Thickness(14, 12, 14, 12), Child = status });

        var summary = Ui.Stack(10, Ui.Text(L("总结"), 15, Placeholder, FontWeights.Bold), SkeletonBar(0.94, 10), SkeletonBar(0.8, 10), SkeletonBar(0.56, 10));
        body.Children.Add(Gap(summary, 22, top: true));
        var later = TopicSlot("--:--", [0.4, 0.76]);
        later.Opacity = 0.6;
        var topics = Ui.Stack(12, Ui.Text(L("议题"), 15, Placeholder, FontWeights.Bold), TopicSlot("00:00", [0.52, 0.88, 0.7]), later);
        body.Children.Add(Gap(topics, 22, top: true));

        // Wraps: the English chips don't fit one line in a narrow window.
        var chips = new WrapPanel { Margin = new Thickness(0, 26, 0, 0) };
        var lead = Ui.Text(L("会整理出"), 12, Palette.Tertiary, wrap: false);
        lead.Margin = new Thickness(0, 4, 6, 10);
        chips.Children.Add(lead);
        foreach (var t in new[] { L("结论"), L("待办"), L("人名和术语"), L("鱼骨图") })
            chips.Children.Add(new Border { Background = ChipFill, CornerRadius = new CornerRadius(11), Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(0, 0, 6, 6), Child = Ui.Text(t, 12, Palette.Secondary, wrap: false) });
        body.Children.Add(chips);
        return body;
    }

    /// A placeholder line `fraction` of the width across, pulsing with the clock.
    FrameworkElement SkeletonBar(double fraction, double height)
    {
        var grid = new Grid { Height = height };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(fraction, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1 - fraction, GridUnitType.Star) });
        grid.Children.Add(new Border { Background = skeleton, CornerRadius = new CornerRadius(Math.Min(6, height / 2)) });
        return grid;
    }

    /// A topic still to come: its time, then a heading and points as bars, in a dashed outline.
    FrameworkElement TopicSlot(string time, double[] lines)
    {
        var bars = new StackPanel();
        for (int i = 0; i < lines.Length; i++) bars.Children.Add(Gap(SkeletonBar(lines[i], i == 0 ? 11 : 8), i == 0 ? 0 : 8, top: true));
        var clock = Ui.Text(time, 12, Placeholder, wrap: false);
        clock.VerticalAlignment = VerticalAlignment.Top; clock.Margin = new Thickness(0, -2, 12, 0);
        clock.Typography.NumeralAlignment = FontNumeralAlignment.Tabular;
        var dock = new DockPanel { Margin = new Thickness(14) };
        DockPanel.SetDock(clock, Dock.Left);
        dock.Children.Add(clock); dock.Children.Add(bars);
        var grid = new Grid();
        // Dash lengths are in stroke widths: the Mac's 5 / 4 points at 1.5.
        grid.Children.Add(new System.Windows.Shapes.Rectangle { Stroke = Palette.Line, StrokeThickness = 1.5, StrokeDashArray = new DoubleCollection { 5 / 1.5, 4 / 1.5 }, RadiusX = 12, RadiusY = 12 });
        grid.Children.Add(dock);
        return grid;
    }

    FrameworkElement Transcript()
    {
        var lines = app.Listen.SessionId is { } id ? app.Store.Get(id)?.Lines ?? [] : [];
        var body = new StackPanel();
        // Stored as they arrive (the notes count them); shown in time order, so a sentence I said
        // sits between the other side's, which come back from Ming a little later.
        var sid = app.Listen.SessionId;
        var latest = lines.Count > 0 ? lines[^1].Id : null;
        foreach (var (l, who, ink, place) in Speakers(lines, app.Settings.SpeakerVoices))
            body.Children.Add(TranscriptRow(l, who, ink, place, revert: sid is null ? null : f => app.Fixes.Revert(f, l.Id, sid), open: l.Id == latest && app.Listen.Listening));
        return body;
    }

    /// Lines in time order with who said them, named only where the speaker changes (as chat apps
    /// do): 你 for what I said into the meeting, 说话人 N once voices are told apart. A meeting that
    /// heard the PC and the room says 现场 / 线上 where that changes too (`place`).
    internal static IEnumerable<(TranscriptLine line, string? who, Brush? ink, bool place)> Speakers(IReadOnlyList<TranscriptLine> lines, bool voices)
    {
        var numbers = voices ? SpeakerLabels.Numbers(lines) : [];
        var both = Places.HeardBoth(lines);
        string? last = null;
        foreach (var l in lines.OrderBy(x => x.T))
        {
            var key = l.Speaker == "me" ? "me" : (numbers.TryGetValue(l.Id, out var n) ? $"n{n}" : "them") + (both ? "|" + l.Via : "");
            string? who = null; Brush? ink = null;
            var place = false;
            if (key != last)
            {
                place = both && l.Speaker != "me";
                if (key == "me") { who = L("你"); ink = Palette.AccentText; }
                else if (numbers.TryGetValue(l.Id, out var m)) { who = LF("说话人 %lld", m); ink = Palette.Speaker(m); }
                else if (numbers.Count > 0 && l.Via != "room") { who = L("未识别"); ink = Palette.Tertiary; }  // the room side tells no voices apart
            }
            last = key;
            yield return (l, who, ink, place);
        }
    }

    /// One line of the transcript as on the Mac: who (in their colour) and when, the original in
    /// grey, the translation in ink. With `play` (a record with its recording) the time is a link
    /// that plays from there; it is tagged "time" so the player can light it.
    /// 改正听错的词: the fixed words are underlined; pointing at the line (or `open`, the line being
    /// said: hover in a window that never takes focus isn't to be counted on) shows what each was
    /// heard as with 改回 (`revert`), and 改这句… (`edit`, the meeting record). `editor` takes the
    /// original's place while the line is being rewritten.
    internal static FrameworkElement TranscriptRow(TranscriptLine l, string? who = null, Brush? ink = null, bool place = false, Action<double>? play = null,
        Action<LineFix>? revert = null, bool open = false, Action? edit = null, FrameworkElement? editor = null,
        IReadOnlyList<string>? terms = null, bool found = false)
    {
        var text = new StackPanel { Margin = new Thickness(0, who is null && !place ? 0 : 6, 0, 12), Background = Brushes.Transparent };
        var time = Ui.Text(Languages.Clock(l.T), 12, play is null ? Palette.Tertiary : Palette.TimeLink, wrap: false);
        if (play is not null)
        {
            time.Tag = "time";
            time.Cursor = System.Windows.Input.Cursors.Hand;
            time.ToolTip = L("从这里播放");
            time.MouseLeftButtonDown += (_, e) => { e.Handled = true; play(l.T); };
            time.MouseEnter += (_, _) => time.TextDecorations = TextDecorations.Underline;
            time.MouseLeave += (_, _) => time.TextDecorations = null;
            System.Windows.Automation.AutomationProperties.SetName(time, L("从这里播放") + " " + time.Text);
        }
        var head = Ui.Row(8, time);
        if (place) head.Children.Insert(0, PlaceTag(l));
        if (who is not null) head.Children.Insert(0, l.Speaker == "me" ? MeTag(who, ink) : Ui.Text(who, 12, ink ?? Palette.Secondary, wrap: false));
        for (int i = 1; i < head.Children.Count; i++) ((FrameworkElement)head.Children[i]).Margin = new Thickness(i == 1 && place && who is not null ? 6 : 8, 0, 0, 0);
        text.Children.Add(head);
        var translated = !string.IsNullOrEmpty(l.Dst) && l.Dst != l.Src && l.Dst != l.Shown;
        if (editor is not null)
        {
            text.Children.Add(Gap(editor, 3, top: true));
            return text;
        }
        // `terms`: the records' search marks what it found (`found`: the match being looked at).
        terms ??= [];
        text.Children.Add(Gap(FixViews.Mark(FixViews.LineText(l, translated ? 13 : 15, translated ? Palette.Secondary : Palette.Ink), terms, found), 3, top: true));
        if (translated) text.Children.Add(Gap(FixViews.Mark(Ui.Text(l.Dst!, 15, Palette.Ink), terms, found), 2, top: true));
        var hasFixes = revert is not null && (l.Fixes ?? []).Any(f => f.Applied);
        if (hasFixes || edit is not null)
        {
            var words = FixViews.FixedWords(l, revert ?? (_ => { }), edit);
            words.Visibility = open && hasFixes ? Visibility.Visible : Visibility.Collapsed;
            text.Children.Add(words);
            if (!open)
            {
                text.MouseEnter += (_, _) => words.Visibility = Visibility.Visible;
                text.MouseLeave += (_, _) => words.Visibility = Visibility.Collapsed;
            }
        }
        return text;
    }

    /// Your own line (SpeakerViews.swift › MeTag): said with the talk key, so what the other side
    /// heard was its translation; 你 and an outlined 同传.
    static FrameworkElement MeTag(string who, Brush? ink)
    {
        var tag = Ui.Row(5, Ui.Text(who, 12, ink ?? Palette.AccentText, FontWeights.SemiBold, wrap: false), new Border
        {
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x73, 0xE8, 0x55, 0x2B)), BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(4), Padding = new Thickness(5, 0, 5, 1), VerticalAlignment = VerticalAlignment.Center,
            Child = Ui.Text(L("同传"), 10, Palette.AccentText, wrap: false),
        });
        tag.ToolTip = L("按住说话键说的，对方听到的是译文");
        return tag;
    }

    /// 现场 / 线上 (SpeakerViews.swift › PlaceTag): the room's filled, the PC's outlined.
    internal static FrameworkElement PlaceTag(TranscriptLine l)
    {
        var room = l.Via == "room";
        return new Border
        {
            Background = room ? Palette.Mica : Brushes.Transparent, BorderBrush = room ? Brushes.Transparent : Palette.Line, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(4), Padding = new Thickness(5, 0, 5, 1), VerticalAlignment = VerticalAlignment.Center,
            Child = Ui.Text(Places.Place(l), 11, Palette.Secondary, wrap: false),
            ToolTip = room ? L("会议室的麦克风听到的") : L("电脑里放出来的"),
        };
    }

    // 改正听错的词: the card and the toast, rebuilt only when what they show changes.
    ContentControl ask = new(), toast = new();
    string? askKey, toastKey;

    /// 这样改对吗？ for the first name waiting. Not while the window is shown to the other side
    /// (共享屏幕时让对方看到): names wait for after the meeting then.
    FrameworkElement? AskCard((TranscriptLine Line, LineFix Fix, int Position, int Of)? asking)
    {
        if (asking is not { } a || app.Listen.SessionId is not { } id) return null;
        var card = FixViews.ConfirmCard(a.Line, a.Fix, a.Of, yes => app.Fixes.Answer(a.Fix, yes, id), () => app.Fixes.Later(a.Fix, id));
        card.Margin = new Thickness(12, 0, 12, 8);
        return card;
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
            var who = line.Speaker == "me" ? L("你 · 同传") : number is { } k ? LF("说话人 %lld", k) : null;
            var top = new TextBlock { FontFamily = Palette.Font, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis, Foreground = Palette.NightText };
            if (who is not null) top.Inlines.Add(new System.Windows.Documents.Run(who + "  ") { Foreground = NightAccent });
            if (line.Dst is not null && line.Dst != line.Src) top.Inlines.Add(new System.Windows.Documents.Run(line.Shown));
            if (top.Inlines.Count > 0) text.Children.Add(top);
            text.Children.Add(Gap(Ui.Text(line.Dst ?? line.Shown, app.Settings.SubtitleSize, Brushes.White, FontWeights.Bold), 4, top: true));
        }
        return text;
    }

    // MARK: Bits

    static T Gap<T>(T e, double size, bool top = false) where T : FrameworkElement
    {
        e.Margin = top ? new Thickness(0, size, 0, 0) : new Thickness(size, 0, 0, 0);
        return e;
    }

    /// A header button at the Mac's size: 13 px label, 10 px sides.
    static Button Snug(Button b)
    {
        b.Padding = new Thickness(10, 0, 10, 0);
        if (b.Content is StackPanel { Children: var kids })
            foreach (var t in kids.OfType<TextBlock>()) { t.FontSize = 13; t.Margin = new Thickness(t.Margin.Left > 0 ? 6 : 0, 0, 0, 0); }
        return b;
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
        if (todo.OwnerShown is { } owner) text.Inlines.Add(new System.Windows.Documents.Run($" · {owner}") { Foreground = Palette.Secondary });
        dock.Children.Add(text);
        return dock;
    }
}
