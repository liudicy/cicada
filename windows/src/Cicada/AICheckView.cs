using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using static Cicada.Strings;

namespace Cicada.App;

/// The AI service's check, step by step (AICheck; the Mac's AICheckView.swift): settings and the
/// onboarding show the same list. Every step that ran shows its result; the one that failed says
/// why in one line and offers the one thing that fixes it (one dark button, at most one other).
static class AICheckView
{
    static readonly SolidColorBrush OkPale = Frozen(0xE3, 0xF1, 0xE8);

    static SolidColorBrush Frozen(byte r, byte g, byte b) { var x = new SolidColorBrush(Color.FromRgb(r, g, b)); x.Freeze(); return x; }

    /// `changeKey` opens the key field (settings: 更换; onboarding: back to pasting). The settings
    /// have 重新检查 beside the key already; the onboarding needs it in the failed step. `compact`
    /// (the onboarding, under two numbered rows): only the steps that have a result.
    public static FrameworkElement Steps(Controller app, Action changeKey, bool recheckInStep, bool compact = false)
    {
        var ling = app.Ling;
        var check = ling.Health;
        var list = new StackPanel();
        var steps = check.Steps.Where(s => !compact || s.State.Kind is not (AICheck.Kind.Skipped or AICheck.Kind.Untested)).ToList();
        for (int i = 0; i < steps.Count; i++)
        {
            var row = Row(app, check, steps[i].Id, steps[i].State, changeKey, recheckInStep);
            list.Children.Add(new Border { BorderBrush = Palette.Line, BorderThickness = new Thickness(0, i == 0 ? 0 : 1, 0, 0), Child = row });
        }
        return list;
    }

    static FrameworkElement Row(Controller app, AICheck check, AICheck.StepId id, AICheck.State state, Action changeKey, bool recheckInStep)
    {
        var ling = app.Ling;
        var c = ling.Config;
        var quiet = state.Kind is AICheck.Kind.Skipped or AICheck.Kind.Untested;
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(Ui.Text(AICheck.Title(id, ling.ServiceHost), 14, quiet ? Palette.Tertiary : Palette.Ink));
        string? sub = state.Kind == AICheck.Kind.Ok && id == AICheck.StepId.Text ? c.TextModel
            : state.Kind == AICheck.Kind.Ok && id == AICheck.StepId.Hear ? c.HearModel
            : state.Kind == AICheck.Kind.Untested && check.Passed ? L("开会用过一次后确认")
            : null;
        if (sub is not null) { var s = Ui.Text(sub, 12, Palette.Tertiary); s.Margin = new Thickness(0, 2, 0, 0); text.Children.Add(s); }
        if (state.Kind is AICheck.Kind.Fail or AICheck.Kind.Busy) Problem(app, check, text, changeKey, recheckInStep);

        var dock = new DockPanel { Margin = new Thickness(0, 10, 0, 10) };
        var disc = Disc(state.Kind);
        disc.Margin = new Thickness(0, 1, 12, 0);
        DockPanel.SetDock(disc, Dock.Left);
        dock.Children.Add(disc);
        if (state is { Kind: AICheck.Kind.Ok, Seconds: { } sec })
        {
            var t = Ui.Text(LF("%@ 秒", sec.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture)), 12, Palette.Tertiary, wrap: false);
            t.VerticalAlignment = VerticalAlignment.Top; t.Margin = new Thickness(12, 2, 0, 0);
            DockPanel.SetDock(t, Dock.Right);
            dock.Children.Add(t);
        }
        dock.Children.Add(text);
        return dock;
    }

    /// Why it failed, the proxy box when the network is the trouble, and what fixes it.
    static void Problem(Controller app, AICheck check, StackPanel into, Action changeKey, bool recheckInStep)
    {
        var ling = app.Ling;
        // A hear model at its own address: the one it couldn't reach is that one.
        var host = check.Failure?.Step == AICheck.StepId.Hear ? ling.HearHost : ling.ServiceHost;
        if (check.Message(ling.ServiceLabel, host, ling.Config.TextModel, ling.HearName) is { } why)
        {
            var t = Ui.Text(why, 13, check.Failure is null ? Palette.WarnIcon : Palette.Danger);
            t.Margin = new Thickness(0, 4, 0, 0);
            into.Children.Add(t);
        }
        if (check.ProxyLine(ling.ServiceLabel, ling.ServiceHost) is { } proxy)
            into.Children.Add(new Border { Background = Palette.Mica, CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 7, 10, 7), Margin = new Thickness(0, 6, 0, 0), Child = Ui.Text(proxy, 13, Palette.Body) });
        var acts = Actions(app, check, changeKey, recheckInStep);
        if (acts.Count == 0) return;
        var row = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        for (int i = 0; i < acts.Count; i++)
        {
            var b = Ui.Button(acts[i].Title, acts[i].Run, i == 0 ? Ui.Kind.Primary : Ui.Kind.Standard, height: 30);
            b.Margin = new Thickness(0, 0, 8, 0);
            row.Children.Add(b);
        }
        into.Children.Add(row);
    }

    /// One primary fix and at most one other.
    static List<(string Title, Action Run)> Actions(Controller app, AICheck check, Action changeKey, bool recheckInStep)
    {
        if (check.Failure is not { } f) return [];
        var ling = app.Ling;
        var p = ling.Provider;
        var recheck = recheckInStep ? new List<(string, Action)> { (L("重新检查"), () => _ = ling.Check()) } : [];
        switch (f.Why)
        {
            case AICheck.Reason.Unreachable:
                // A proxy has nothing to do with a server on this PC or the local network.
                if (AIProvider.IsNearby(ling.ServiceHost)) return recheck;
                return [(L("怎么设置代理"), () => Open(AICheck.HelpUrl)), .. recheck];
            case AICheck.Reason.InvalidKey or AICheck.Reason.MgmtKey:
                return p.Site is { } site ? [(L("更换 key"), changeKey), (LF("打开 %@", ling.ServiceName), () => Open(site))] : [(L("更换 key"), changeKey)];
            case AICheck.Reason.NoCredit:
                return [(L("去充值"), () => Open(TopUp(p))), .. recheck];
            case AICheck.Reason.NoModel or AICheck.Reason.Deaf:
                var step = f.Why == AICheck.Reason.Deaf ? AICheck.StepId.Hear : AICheck.StepId.Text;
                return ling.Recommended(step) is { } rec ? [(LF("换成推荐的 %@", rec), () => app.UseRecommended(step))] : recheck;
            case AICheck.Reason.ServerError:
                return recheck;
            default:
                return [];
        }
    }

    /// Where to add money: OpenRouter's credits page, else the service's own site.
    public static string TopUp(AIProvider p) => p.Id == "openrouter" ? "https://openrouter.ai/settings/credits" : p.Site ?? "https://zenmux.ai";

    public static void Open(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception e) { Log.Debug($"ai: open failed {e.GetType().Name}"); }
    }

    /// The round mark before a step: a tick, a cross, "!" for busy, "…" while running, "–" for the rest.
    static FrameworkElement Disc(AICheck.Kind kind)
    {
        var (bg, fg) = kind switch
        {
            AICheck.Kind.Ok => (OkPale, Palette.Success),
            AICheck.Kind.Fail => (Palette.ErrorBg, Palette.Danger),
            AICheck.Kind.Busy => (Palette.WarnBg, Palette.WarnIcon),
            AICheck.Kind.Running => (Palette.AccentPale, Palette.AccentText),
            _ => (Palette.Subtle, Palette.Tertiary),
        };
        var g = new Grid { Width = 20, Height = 20, VerticalAlignment = VerticalAlignment.Top };
        g.Children.Add(new System.Windows.Shapes.Ellipse { Fill = bg });
        FrameworkElement mark = kind switch
        {
            AICheck.Kind.Ok => Ui.Icon(Icons.Check, 12, fg, stroke: 2),
            AICheck.Kind.Fail => Ui.Icon(Icons.Close, 10, fg, stroke: 2),
            _ => Ui.Text(kind switch { AICheck.Kind.Busy => "!", AICheck.Kind.Running => "…", _ => "–" }, 11, fg, FontWeights.Bold, wrap: false),
        };
        mark.HorizontalAlignment = HorizontalAlignment.Center; mark.VerticalAlignment = VerticalAlignment.Center;
        g.Children.Add(mark);
        return g;
    }

    /// All passed, in one line: "已连接 · 文字 1.8 秒 · 听 2.1 秒", or when the newest evidence came
    /// from a meeting, "正常 · 12 分钟前开会时用过". Null otherwise.
    public static string? Summary(AICheck check)
    {
        if (!check.Passed || check.IsBusy) return null;
        if (check.Passive && check.At is { } at) return L("正常") + " · " + LF("%@ 开会时用过", AICheck.Ago(at, DateTimeOffset.Now));
        var parts = new List<string> { L("已连接") };
        static string S(double s) => s.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture);
        if (check[AICheck.StepId.Text].Seconds is { } t) parts.Add(LF("文字 %@ 秒", S(t)));
        if (check[AICheck.StepId.Hear].Seconds is { } h) parts.Add(LF("听 %@ 秒", S(h)));
        return string.Join(" · ", parts);
    }

    /// The settings' status line, named after the step that failed: a missing model is not a connection problem.
    public static string? Status(AICheck check) => check.IsRunning ? L("正在检查…")
        : check.Failure is { Why: not AICheck.Reason.Busy } f ? f.Step switch
        {
            AICheck.StepId.Reach => L("暂时连不上"),
            AICheck.StepId.Key => L("这个 key 用不了"),
            AICheck.StepId.Text => L("模型用不了"),
            _ => L("听不了声音"),
        }
        : null;
}
