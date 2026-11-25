using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using static Cicada.Strings;

namespace Cicada.App;

/// 分享…: a meeting as a link on cicada.indaloop.app (the Mac's ShareSheet). Settings, then the
/// server's review, then the link (and its password) or what the review stopped. A meeting already
/// shared opens on its link. Drawn in the chrome of Dialogs, its content swapped per step.
sealed class ShareDialog : Window
{
    enum Step { Settings, Working, Blocked, Done, Failed }

    readonly Controller app;
    readonly Session session;
    readonly ContentControl body = new();
    Step step = Step.Settings;
    ShareScope scope = ShareScope.Notes;
    int days = 7;
    bool names, usePassword, summaryInPreview, dropNotes, confirmRevoke, showOptions;
    string password = SharePassword.Make();
    readonly HashSet<int> removed = [];
    List<ShareHit> hits = [];
    List<int> kept = [];
    ShareRecord? record;
    int? views;
    string? copied, failure;

    bool HasNotes => session.Notes is { IsEmpty: false };

    /// The open one, for the debug pipe (`sharesheet`).
    public static ShareDialog? Current { get; private set; }

    public ShareDialog(Controller app, Session session, Window? owner)
    {
        this.app = app;
        this.session = session;
        Owner = owner;
        WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize; ShowInTaskbar = false; SizeToContent = SizeToContent.Height; Width = 456 + 32;
        WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;
        FontFamily = Palette.Font; Title = L("分享这场会议");
        Content = new Border
        {
            Margin = new Thickness(16), Background = Palette.Surface, BorderBrush = Palette.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(16),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 32, ShadowDepth = 8, Opacity = 0.25 },
            Padding = new Thickness(24), Child = body,
        };
        MouseLeftButtonDown += (_, e) => { if (e.ButtonState == MouseButtonState.Pressed && e.OriginalSource is not TextBox) try { DragMove(); } catch { } };
        KeyDown += (_, e) => { if (e.Key == Key.Escape && step != Step.Working) Close(); };
        if (!HasNotes) scope = ShareScope.Full;
        if (app.Sharing.Store.Read(session.Id) is { } r && r.ExpiresAt > DateTimeOffset.Now) { record = r; step = Step.Done; LoadViews(r); }
        Loaded += (_, _) => Current = this;
        Closed += (_, _) => { if (Current == this) Current = null; };
        Render();
    }

    void Render()
    {
        body.Content = step switch
        {
            Step.Settings => SettingsView(),
            Step.Working => Working(),
            Step.Blocked => BlockedView(),
            Step.Done => DoneView(record!),
            _ => FailedView(),
        };
    }

    // MARK: Settings

    UIElement SettingsView()
    {
        var p = new StackPanel();
        p.Children.Add(Header(L("分享这场会议")));
        p.Children.Add(Gap(Ui.Text(L("内容"), 12, Palette.Secondary, FontWeights.SemiBold), 16));
        p.Children.Add(Gap(Radio(L("只分享纪要"), scope == ShareScope.Notes, HasNotes, () => scope = ShareScope.Notes), 6));
        p.Children.Add(Gap(Radio(L("纪要和双语全文"), scope == ShareScope.Full, true, () => scope = ShareScope.Full), 6));
        Button? make = null;
        if (showOptions)
        {
            p.Children.Add(Gap(Row(L("用密码保护"), Ui.Switch(usePassword, v => { usePassword = v; Render(); }, L("用密码保护"))), 16));
            if (usePassword)
            {
                var box = new TextBox { Text = password, FontFamily = new FontFamily("Cascadia Mono, Consolas") };
                System.Windows.Automation.AutomationProperties.SetName(box, L("用密码保护"));
                box.TextChanged += (_, _) => { password = box.Text; if (make is not null) make.IsEnabled = password.Trim().Length >= 6; };
                var again = Ui.Button(L("换一个"), () => { password = SharePassword.Make(); Render(); }, height: 34);
                again.MinWidth = 0; again.Margin = new Thickness(8, 0, 0, 0);
                var grid = new DockPanel();
                DockPanel.SetDock(again, Dock.Right);
                grid.Children.Add(again); grid.Children.Add(Ui.Field(box));
                p.Children.Add(Gap(grid, 8));
            }
            p.Children.Add(Gap(Row(L("有效期"), Ui.Choice([("7", L("7 天")), ("30", L("30 天")), ("365", L("1 年"))], days.ToString(), v => days = int.Parse(v), width: 140)), 12));
            p.Children.Add(Gap(Row(L("显示说话人名字"), Ui.Switch(names, v => names = v, L("显示说话人名字"))), 12));
            if (!usePassword && HasNotes)
                p.Children.Add(Gap(Row(L("预览卡显示摘要"), Ui.Switch(summaryInPreview, v => summaryInPreview = v, L("预览卡显示摘要"))), 12));
        }
        else
        {
            // The choices already made, in one line; 更改 opens them in place.
            var change = Ui.Button(L("更改"), () => { showOptions = true; Render(); }, height: 28);
            change.MinWidth = 0; change.Padding = new Thickness(12, 0, 12, 0); change.Margin = new Thickness(8, 0, 0, 0);
            var line = Ui.Text(Summary, 13, Palette.Secondary, wrap: false);
            line.TextTrimming = TextTrimming.CharacterEllipsis; line.VerticalAlignment = VerticalAlignment.Center;
            var d = new DockPanel();
            DockPanel.SetDock(change, Dock.Right);
            d.Children.Add(change); d.Children.Add(line);
            p.Children.Add(Gap(d, 16));
        }
        if (!usePassword) p.Children.Add(Gap(Ui.Helper(L("内容将上传至 cicada.indaloop.app，拿到链接的人都能看。")), 16));
        make = Ui.Button(L("生成并复制"), Go, Ui.Kind.Primary);
        make.IsDefault = true;
        make.IsEnabled = !usePassword || password.Trim().Length >= 6;
        p.Children.Add(Gap(Buttons(Ui.Button(L("取消"), Close), make), 24));
        return p;
    }

    string Summary => string.Join(" · ",
        usePassword ? L("密码保护") : L("无密码"),
        days == 365 ? L("1 年有效") : LF("%lld 天有效", days),
        names ? L("显示名字") : L("不显示名字"));

    /// Takes the dialog's settings from the debug pipe: `sharesheet <id>[,full][,pw][,names][,30][,more][,go]`
    /// (more presses 更改); on the done step, `copy`, `copylink` and `copypw` press 复制 and its menu's items.
    public void Debug(IReadOnlyCollection<string> p)
    {
        if (step == Step.Done && record is { } r)
        {
            if (p.Contains("menu")) { copyMenu?.Invoke(); return; }
            if (p.Contains("copy")) Copy(MessageOf(r), "all");
            else if (p.Contains("copylink")) Copy(r.Url, "link");
            else if (p.Contains("copypw") && r.Password is { } pw) Copy(pw, "password");
            Render();
            return;
        }
        if (step != Step.Settings) return;
        if (p.Contains("more")) showOptions = true;
        if (p.Contains("full")) scope = ShareScope.Full;
        if (p.Contains("pw")) usePassword = true;
        if (p.Contains("names")) names = true;
        if (p.Contains("30")) days = 30;
        if (p.Contains("365")) days = 365;
        Render();
        if (p.Contains("go")) Go();
    }

    /// Debug: the blocked step's 去掉这些内容后分享.
    public void DebugLeaveOut() { if (step == Step.Blocked && LeftAfterRemoving()) LeaveOut(); }

    public string StepName => step.ToString().ToLowerInvariant();

    async void Go()
    {
        step = Step.Working;
        Render();
        var o = new ShareOptions
        {
            Scope = scope, Days = days, Names = names, Password = usePassword ? password.Trim() : null,
            SummaryInPreview = !usePassword && summaryInPreview, Removed = [.. removed], DropNotes = dropNotes,
        };
        switch (await app.Sharing.Share(session, o))
        {
            case ShareOutcome.Shared s:
                record = s.Record;
                Copy(MessageOf(s.Record), "all");
                views = 0;
                step = Step.Done;
                break;
            case ShareOutcome.Blocked b:
                hits = b.Hits; kept = b.Kept;
                step = Step.Blocked;
                break;
            case ShareOutcome.Failed f:
                failure = Message(f.Code);
                step = Step.Failed;
                break;
        }
        if (IsLoaded) Render();
    }

    UIElement Working()
    {
        var p = new StackPanel();
        p.Children.Add(Header(L("分享这场会议")));
        var bar = new ProgressBar { IsIndeterminate = true, Height = 6, Width = 120, Foreground = Palette.Ink, Background = Palette.Subtle, BorderThickness = new Thickness(0) };
        var row = Ui.Row(10, bar, Ui.Text(L("正在检查有没有敏感内容…"), 13, Palette.Secondary));
        row.HorizontalAlignment = HorizontalAlignment.Center;
        p.Children.Add(new Border { MinHeight = 96, Child = row, Padding = new Thickness(0, 36, 0, 36) });
        return p;
    }

    // MARK: Blocked

    UIElement BlockedView()
    {
        var p = new StackPanel();
        p.Children.Add(Ui.Row(8, Ui.Icon(Icons.Warning, 18, Palette.AccentText), Ui.Text(L("检测到潜在敏感内容"), 20, Palette.Ink, FontWeights.Bold)));
        p.Children.Add(Gap(Ui.Text(L("链接尚未生成。请先核对以下内容："), 12, Palette.Secondary), 8));
        foreach (var h in hits.Take(5)) p.Children.Add(Gap(HitRow(h), 8));
        if (hits.Count > 5) p.Children.Add(Gap(Ui.Text(LF("还有 %lld 处", hits.Count - 5), 12, Palette.Secondary), 8));
        var leftover = LeftAfterRemoving();
        p.Children.Add(Gap(Ui.Helper(leftover ? L("去掉后再检查一次；你的记录不会改动。") : L("去掉这些内容后就没有可分享的了。")), 14));
        var back = Ui.Button(L("返回修改"), () => { step = Step.Settings; Render(); });
        if (leftover)
        {
            var go = Ui.Button(L("去掉这些内容后分享"), LeaveOut, Ui.Kind.Primary);
            go.IsDefault = true;
            p.Children.Add(Gap(Buttons(back, go), 24));
        }
        else p.Children.Add(Gap(Buttons(back), 24));
        return p;
    }

    void LeaveOut()
    {
        removed.UnionWith(ShareHit.RecordLines(hits, kept));
        if (hits.Any(h => h.Part == "notes")) dropNotes = true;
        Go();
    }

    /// Would anything be left to share once the flagged parts are out? (A notes-only share whose
    /// notes were flagged has nothing; the server would refuse an empty document.)
    bool LeftAfterRemoving()
    {
        var notesLeft = HasNotes && !dropNotes && !hits.Any(h => h.Part == "notes");
        if (scope != ShareScope.Full) return notesLeft;
        var gone = new HashSet<int>(removed);
        gone.UnionWith(ShareHit.RecordLines(hits, kept));
        return notesLeft || Enumerable.Range(0, session.Lines.Count).Any(i => !gone.Contains(i) && session.Lines[i].Src.Length > 0);
    }

    FrameworkElement HitRow(ShareHit h)
    {
        // A list in the reader's language (the Mac's ListFormatter): 、 in Chinese and Japanese, ", " otherwise.
        var what = string.Join(Strings.Culture.TwoLetterISOLanguageName is "zh" or "ja" ? "、" : ", ", h.Questions.Select(Category));
        string place, quote;
        if (h.Part == "notes")
        {
            place = L("纪要");
            quote = session.Notes?.Summary ?? "";
        }
        else
        {
            var lines = ShareHit.RecordLines([h], kept).Order().ToList();
            var a = lines.Count > 0 ? Languages.Clock(session.Lines[lines[0]].T) : "";
            var b = lines.Count > 0 ? Languages.Clock(session.Lines[lines[^1]].T) : "";
            place = a == b ? a : $"{a}–{b}";
            quote = lines.Count > 0 ? session.Lines[lines[0]].Src : "";
        }
        var q = Ui.Text(quote, 12, Palette.Secondary);
        q.MaxHeight = 36; q.TextTrimming = TextTrimming.CharacterEllipsis;
        return new Border
        {
            Background = Palette.AccentPale, CornerRadius = new CornerRadius(8), Padding = new Thickness(10),
            Child = new StackPanel { Children = { Ui.Text($"{what} · {place}", 12, Palette.Ink, FontWeights.SemiBold), Gap(q, 3) } },
        };
    }

    static string Category(string q) => q switch
    {
        "credential" => L("密码或密钥"),
        "confidential" => L("未公开的公司信息"),
        "crossborder" => L("不宜跨境传输的信息"),
        "personal" => L("个人身份信息"),
        "harmful" => L("违法或危险内容"),
        _ => q,
    };

    // MARK: Done

    UIElement DoneView(ShareRecord r)
    {
        var p = new StackPanel();
        p.Children.Add(Header(copied == "all" ? (r.Password is null ? L("链接已复制") : L("链接和密码已复制")) : L("已分享")));
        p.Children.Add(Gap(Link(r), 16));
        p.Children.Add(Gap(Ui.Text(Status(r), 12, Palette.Secondary), 12));
        p.Children.Add(Gap(new Border { Height = 1, Background = Palette.Line }, 16));
        if (confirmRevoke)
        {
            p.Children.Add(Gap(Ui.Text(L("取消后链接立即失效"), 13, Palette.Ink, FontWeights.SemiBold), 16));
            p.Children.Add(Gap(Ui.Helper(L("已查看过的人可能留有副本。")), 4));
            Button? stop = null;
            stop = Ui.Button(L("取消分享"), async () =>
            {
                stop!.IsEnabled = false;
                if (await app.Sharing.Revoke(r, session.Id)) { Log.Debug("share: revoked from the dialog"); Close(); }
                else { failure = Message("network"); step = Step.Failed; Render(); }
            }, Ui.Kind.Danger);
            p.Children.Add(Gap(Buttons(Ui.Button(L("暂不取消"), () => { confirmRevoke = false; Render(); }), stop), 12));
        }
        else
        {
            var done = Ui.Button(L("完成"), Close, Ui.Kind.Primary);
            done.IsDefault = true;
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var stop = Ui.Button(L("取消分享"), () => { confirmRevoke = true; Render(); }, Ui.Kind.Subtle);
            var open = Ui.Button(L("在浏览器中打开"), () => Controller.Open(r.Url));
            open.Margin = new Thickness(0, 0, 8, 0);
            Grid.SetColumn(open, 2); Grid.SetColumn(done, 3);
            row.Children.Add(stop); row.Children.Add(open); row.Children.Add(done);
            p.Children.Add(Gap(row, 16));
        }
        return p;
    }

    /// The link and, under it, the password in one grey box; beside it one 复制 that copies both as
    /// one message, its arrow either alone for whoever sends them apart (the Mac's Menu with a
    /// primary action). Without a password it is a plain button.
    FrameworkElement Link(ShareRecord r)
    {
        TextBox Value(string text, Brush color) => new()
        {
            Text = text, IsReadOnly = true, BorderThickness = new Thickness(0), Background = Brushes.Transparent, FontSize = 12,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"), Foreground = color, Padding = new Thickness(0), MinHeight = 0,
        };
        var lines = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        lines.Children.Add(Value(r.Url, Palette.Ink));
        if (r.Password is { } pw) lines.Children.Add(Gap(Value(LF("密码：%@", pw), Palette.Secondary), 4));
        var box = new Border { Background = Palette.Subtle, CornerRadius = new CornerRadius(6), Padding = new Thickness(6, 7, 8, 7), Child = lines, MinHeight = 32 };
        var label = copied is null ? L("复制") : L("已复制");
        void All() { Copy(MessageOf(r), "all"); Render(); }
        FrameworkElement copy;
        if (r.Password is { } p)
        {
            (copy, copyMenu) = Ui.SplitButton(label, All, [
                (L("只复制链接"), () => { Copy(r.Url, "link"); Render(); }),
                (L("只复制密码"), () => { Copy(p, "password"); Render(); }),
            ]);
        }
        else
        {
            var b = Ui.Button(label, All, height: 32);
            b.MinWidth = 0;
            copy = b;
            copyMenu = null;
        }
        copy.Margin = new Thickness(8, 0, 0, 0);
        copy.VerticalAlignment = VerticalAlignment.Center;
        var d = new DockPanel();
        DockPanel.SetDock(copy, Dock.Right);
        d.Children.Add(copy); d.Children.Add(box);
        return d;
    }

    Action? copyMenu;

    string MessageOf(ShareRecord r) => r.Message(SessionStore.DisplayTitle(session), DateTimeOffset.Now);

    string Status(ShareRecord r)
    {
        var expiry = LF("%lld 天后失效", r.DaysLeft(DateTimeOffset.Now));
        return views is { } v ? expiry + " · " + LF("打开 %lld 次", v) : expiry;
    }

    async void LoadViews(ShareRecord r)
    {
        var stats = await app.Sharing.StatsOf([r.Id]);
        if (!stats.TryGetValue(r.Id, out var s)) return;
        if (s.State != "live") { app.Sharing.Store.Remove(session.Id); record = null; step = Step.Settings; }
        else views = s.Views;
        if (IsLoaded || step == Step.Settings) Render();
    }

    void Copy(string text, string what)
    {
        try { Clipboard.SetText(text); copied = what; }
        catch (Exception e) { Log.Debug($"share: copy failed {e.GetType().Name}"); }
    }

    // MARK: Failed

    UIElement FailedView()
    {
        var p = new StackPanel();
        p.Children.Add(Header(L("没有分享出去")));
        p.Children.Add(Gap(Ui.Text(failure ?? "", 14, Palette.Body), 12));
        var retry = Ui.Button(L("重试"), Go, Ui.Kind.Primary);
        retry.IsDefault = true;
        p.Children.Add(Gap(Buttons(Ui.Button(L("关闭"), Close), retry), 24));
        return p;
    }

    static string Message(string code) => code switch
    {
        "rate_limited" or "too_many_shares" => L("分享得太频繁了，请稍后再试。"),
        "review_unavailable" => L("敏感内容检查暂时不可用，没有检查就不会分享。请稍后再试。"),
        "sharing_off" => L("分享功能暂时关闭了。"),
        "update_required" => L("请先更新知了。"),
        "too_large" => L("这场会议太长，可以只分享纪要。"),
        "bad_document" => L("这场会议没有可分享的内容。"),
        "network" => L("连不上 cicada.indaloop.app，请检查网络。"),
        _ => L("服务器出了问题，请稍后再试。"),
    };

    // MARK: Parts

    UIElement Header(string title)
    {
        var sub = Ui.Text(SessionStore.DisplayTitle(session), 12, Palette.Secondary, wrap: false);
        return new StackPanel { Children = { Ui.Text(title, 20, Palette.Ink, FontWeights.Bold), Gap(sub, 4) } };
    }

    static FrameworkElement Row(string title, FrameworkElement control) => Ui.Spread(Ui.Text(title, 14, Palette.Ink), control);

    static RadioButton Radio(string label, bool on, bool enabled, Action chosen)
    {
        var r = new RadioButton
        {
            Content = Ui.Text(label, 14, enabled ? Palette.Ink : Palette.Tertiary), IsChecked = on, IsEnabled = enabled, GroupName = "share-scope",
            VerticalContentAlignment = VerticalAlignment.Center, Cursor = Cursors.Hand,
        };
        r.Checked += (_, _) => chosen();
        return r;
    }

    /// Equal buttons on one row, the last (primary) on the right, as Dialogs.
    static Grid Buttons(params Button[] buttons)
    {
        var g = new Grid();
        for (int i = 0; i < buttons.Length; i++)
        {
            if (i > 0) g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(8) });
            g.ColumnDefinitions.Add(new ColumnDefinition());
            Grid.SetColumn(buttons[i], i * 2);
            g.Children.Add(buttons[i]);
        }
        return g;
    }

    static T Gap<T>(T e, double top) where T : FrameworkElement { e.Margin = new Thickness(e.Margin.Left, top, e.Margin.Right, e.Margin.Bottom); return e; }
}
