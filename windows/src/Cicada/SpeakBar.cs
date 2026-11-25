using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using static Cicada.Strings;

namespace Cicada.App;

/// The pill while I speak: the key, a level, 正在听你说 while it's held, then what I said and what
/// the room heard, or why nothing went out. Like the notes panel it never takes focus and stays out of
/// screen captures; it sits above the taskbar (above the subtitle bar when that is showing).
sealed class SpeakBar : Window
{
    readonly Controller app;
    readonly ContentControl body = new();
    readonly DispatcherTimer hide = new() { Interval = TimeSpan.FromSeconds(4) };

    public SpeakBar(Controller app)
    {
        this.app = app;
        WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent; Topmost = true; ShowInTaskbar = false; ShowActivated = false;
        ResizeMode = ResizeMode.NoResize; SizeToContent = SizeToContent.WidthAndHeight; MaxWidth = 600 + 2 * Ui.ShadowRoom; FontFamily = Palette.Font; Title = L("知了");
        SourceInitialized += (_, _) =>
        {
            Native.MakeNonActivating(this);
            Native.SetCaptureVisible(this, app.Settings.ShowInCapture);
        };
        Content = Ui.Floating(new Border { Padding = new Thickness(8, 8, 18, 8), Child = body, MinHeight = 44 }, new SolidColorBrush(Color.FromArgb(0xF2, 0x15, 0x17, 0x1C)), 22, dark: true);
        SizeChanged += (_, _) => Place();
        hide.Tick += (_, _) => { hide.Stop(); Hide(); };
    }

    void Place()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Left + (area.Width - ActualWidth) / 2;
        var above = app.Settings.View == "subtitles" && app.NotesVisible ? 150 : 16;
        Top = area.Bottom - ActualHeight - above + Ui.ShadowRoom;
        // Centred, it would sit over the notes panel's live card on a small screen: centre it in the
        // wider free side instead, if it fits there.
        if (app.NotesBounds is { } n && new Rect(Left, Top, ActualWidth, ActualHeight).IntersectsWith(n))
        {
            double leftRoom = n.Left - area.Left, rightRoom = area.Right - n.Right;
            if (leftRoom >= rightRoom && leftRoom >= ActualWidth) Left = area.Left + (leftRoom - ActualWidth) / 2;
            else if (rightRoom >= ActualWidth) Left = n.Right + (rightRoom - ActualWidth) / 2;
        }
    }

    public void Refresh()
    {
        var s = app.Speak;
        hide.Stop();
        FrameworkElement content;
        var target = Ui.Text(LF("对方听到 %@", Ui.TargetName(s.Target)), 13, Palette.NightText, wrap: false);
        switch (s.State)
        {
            case SpeakEngine.Phase.Recording:
                content = Ui.Row(12, Key(true), Interpreted(), Wave(), Ui.Text(L("正在听你说 · 松开发送"), 14, Brushes.White, FontWeights.Bold, wrap: false), target);
                break;
            case SpeakEngine.Phase.Translating:
                content = Ui.Row(12, Key(false), Interpreted(), Ui.Text(L("正在翻译…"), 14, Brushes.White, FontWeights.Bold, wrap: false), target);
                break;
            case SpeakEngine.Phase.Speaking or SpeakEngine.Phase.Idle when s.Heard is not null:
                var said = new StackPanel { VerticalAlignment = VerticalAlignment.Center, MaxWidth = 480 };
                if (s.Said is not null) said.Children.Add(Ui.Text(s.Said, 12, Palette.NightText));
                said.Children.Add(Gap(Ui.Text(s.Heard!, 15, Brushes.White, FontWeights.Bold), s.Said is null ? 0 : 2));
                var done = Ui.Text(s.State == SpeakEngine.Phase.Speaking ? L("正在说给对方听…") : L("对方已听到"), 12, Palette.NightText, wrap: false);
                content = Fill(Ui.Row(12, Key(false), Interpreted()), said, done);
                if (s.State == SpeakEngine.Phase.Idle) hide.Start();
                break;
            case SpeakEngine.Phase.Failed:
                var why = Ui.Text(s.Problem ?? L("这句没翻译成 · 没有说出去"), 14, new SolidColorBrush(Color.FromRgb(0xFF, 0x9B, 0x78)), FontWeights.Bold);
                why.MaxWidth = 480;
                content = Ui.Row(12, Key(false), why);
                hide.Start();
                break;
            default:
                Hide();
                return;
        }
        body.Content = content;
        if (!IsVisible) Show();
        Place();
    }

    /// 右 Ctrl as a pill: the accent while held, a dim one after.
    static FrameworkElement Key(bool held) => new Border
    {
        CornerRadius = new CornerRadius(14), Padding = new Thickness(11, 4, 11, 5), VerticalAlignment = VerticalAlignment.Center,
        Background = held ? Palette.Live : new SolidColorBrush(Color.FromArgb(0x26, 0xFF, 0xFF, 0xFF)),
        Child = Ui.Text(PushToTalk.Label, 13, Brushes.White, FontWeights.Bold, wrap: false),
    };

    /// 同传, outlined like the notes' MeTag: what goes out is the translation, as the Mac's subtitle
    /// bar says with 同传 · 你在说….
    static FrameworkElement Interpreted() => new Border
    {
        BorderBrush = new SolidColorBrush(Color.FromArgb(0x99, 0xFF, 0x8A, 0x5C)), BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(4), Padding = new Thickness(5, 0, 5, 1), VerticalAlignment = VerticalAlignment.Center,
        Child = Ui.Text(L("同传"), 11, new SolidColorBrush(Color.FromRgb(0xFF, 0x8A, 0x5C)), wrap: false),
    };

    /// A still level mark: an animated one would redraw this software-rendered window every frame.
    static FrameworkElement Wave()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        foreach (var h in new[] { 6.0, 11, 16, 12, 16, 8 })
            row.Children.Add(new System.Windows.Shapes.Rectangle { Width = 2.5, Height = h, RadiusX = 1, RadiusY = 1, Fill = Palette.Live, Margin = new Thickness(0, 0, 2.5, 0), VerticalAlignment = VerticalAlignment.Center });
        return row;
    }

    /// The key, then what was said taking whatever width is left, then the status at the right: in a
    /// plain row a long sentence pushed the status out past the bar's edge.
    static FrameworkElement Fill(FrameworkElement key, FrameworkElement said, FrameworkElement status)
    {
        var dock = new DockPanel { LastChildFill = true };
        foreach (var (e, side) in new[] { (key, Dock.Left), (status, Dock.Right) })
        {
            e.VerticalAlignment = VerticalAlignment.Center;
            DockPanel.SetDock(e, side);
            dock.Children.Add(e);
        }
        key.Margin = new Thickness(0, 0, 12, 0); status.Margin = new Thickness(12, 0, 0, 0);
        dock.Children.Add(said);
        return dock;
    }

    static FrameworkElement Gap(FrameworkElement e, double top) { e.Margin = new Thickness(0, top, 0, 0); return e; }
}
