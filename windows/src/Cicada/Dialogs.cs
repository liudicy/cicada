using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using static Cicada.Strings;

namespace Cicada.App;

/// Windows 11 ContentDialogs: a title, a line or a field, and two equal buttons on a grey band,
/// primary first. Enter takes the primary button, Esc cancels.
static class Dialogs
{
    /// Asks before something that can't be undone. True when the user agreed.
    public static bool Confirm(Window owner, string title, string body, string ok, bool danger)
    {
        var text = Ui.Text(body, 14, Palette.Body);
        return Show(owner, title, text, ok, danger, null) is not null;
    }

    /// Something to know, with one button.
    public static void Tell(Window owner, string title, string body) => Show(owner, title, Ui.Text(body, 14, Palette.Body), L("知道了"), danger: false, null, single: true);

    /// Two ways on, both named (开始听 blocked: 换成推荐的并开始 / 打开设置): 1 for `primary`, 2 for
    /// `other`, 0 when closed. No `primary`: just `other` and 取消. No owner: the screen's centre.
    /// `retry` makes `primary` work in place (重新检查并开始): the dialog stays with 正在检查… on the
    /// button, then closes as 1 when it returns null, or shows the body it returns and waits again.
    public static int Choose(Window? owner, string title, string body, string? primary, string other, Func<Task<string?>>? retry = null)
    {
        int chosen = 0;
        var text = Ui.Text(body, 14, Palette.Body);
        if (primary is null) return Show(owner, title, text, other, danger: false, null) is null ? 0 : 2;
        var second = Ui.Button(other, () => { chosen = 2; Window.GetWindow(text)?.Close(); });
        var r = Show(owner, title, text, primary, danger: false, null, secondary: second,
            work: retry is null ? null : async () => { if (await retry() is not { } again) return true; text.Text = again; return false; });
        return r is not null ? 1 : chosen;
    }

    /// A one-line answer: the new text (maybe empty), or null when cancelled.
    public static string? Prompt(Window owner, string title, string value, string? hint, string ok)
    {
        var box = new TextBox { Text = value };
        System.Windows.Automation.AutomationProperties.SetName(box, title);
        var content = new StackPanel { Children = { Ui.Field(box) } };
        if (hint is not null) { var h = Ui.Helper(hint); h.Margin = new Thickness(0, 8, 0, 0); content.Children.Add(h); }
        return Show(owner, title, content, ok, danger: false, box);
    }

    /// One of a few options, each a bordered row (the Mac's FolderChoice): its index, or null when
    /// cancelled. The first is chosen to start with.
    public static int? Pick(Window? owner, string title, IReadOnlyList<(string Title, string? Detail)> options, string ok)
    {
        int pick = 0;
        var list = new StackPanel();
        var rows = new List<Border>();
        void Restyle()
        {
            for (int i = 0; i < rows.Count; i++)
            {
                rows[i].BorderBrush = i == pick ? Palette.Ink : Palette.Line;
                rows[i].BorderThickness = new Thickness(i == pick ? 1.5 : 1);
            }
        }
        for (int i = 0; i < options.Count; i++)
        {
            var index = i;
            var text = options[i].Detail is { } d ? Ui.Stack(2, Ui.Text(options[i].Title, 13, Palette.Ink), Ui.Helper(d)) : Ui.Stack(2, Ui.Text(options[i].Title, 13, Palette.Ink));
            var row = new Border { CornerRadius = new CornerRadius(9), Padding = new Thickness(12, 10, 12, 10), Margin = new Thickness(0, 0, 0, 8), Background = Palette.Surface, Cursor = Cursors.Hand, Child = text };
            // Down, and handled: the dialog drags itself on a press, which would swallow the release.
            row.MouseLeftButtonDown += (_, e) => { pick = index; Restyle(); e.Handled = true; };
            System.Windows.Automation.AutomationProperties.SetName(row, options[i].Title);
            rows.Add(row);
            list.Children.Add(row);
        }
        Restyle();
        return Show(owner, title, list, ok, danger: false, null) is null ? null : pick;
    }

    static string? Show(Window? owner, string title, FrameworkElement content, string ok, bool danger, TextBox? field, bool single = false, Button? secondary = null, Func<Task<bool>>? work = null)
    {
        string? result = null;
        var dialog = new Window
        {
            Owner = owner, WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent,
            ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false, SizeToContent = SizeToContent.Height, Width = 456 + 32,
            WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner, Topmost = owner is null, FontFamily = Palette.Font, Title = title,
        };
        Button? primary = null, cancel = null;
        async void Accept()
        {
            if (work is not null)
            {
                var label = ((StackPanel)primary!.Content).Children.OfType<TextBlock>().First();
                primary.IsEnabled = cancel!.IsEnabled = false;
                label.Text = L("正在检查…");
                var done = await work();
                label.Text = ok;
                primary.IsEnabled = cancel.IsEnabled = true;
                if (!done) { primary.Focus(); return; }
            }
            result = field?.Text.Trim() ?? "";
            dialog.Close();
        }
        primary = Ui.Button(ok, Accept, danger ? Ui.Kind.Danger : Ui.Kind.Primary);
        cancel = secondary ?? Ui.Button(L("取消"), dialog.Close);
        // A named second way on isn't 取消: Esc just closes.
        primary.IsDefault = true; cancel.IsCancel = secondary is null;
        if (secondary is not null) dialog.KeyDown += (_, e) => { if (e.Key == Key.Escape) dialog.Close(); };
        var buttons = new Grid();
        buttons.ColumnDefinitions.Add(new ColumnDefinition());
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(8) });
        buttons.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetColumn(primary, 2);
        buttons.Children.Add(primary);
        if (single) { primary.IsCancel = true; Grid.SetColumn(primary, 0); Grid.SetColumnSpan(primary, 3); } else buttons.Children.Add(cancel);
        var heading = Ui.Text(title, 20, Palette.Ink, FontWeights.Bold);
        content.Margin = new Thickness(0, 12, 0, 0);
        dialog.Content = new Border
        {
            Margin = new Thickness(16), Background = Palette.Surface, BorderBrush = Palette.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(16),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 32, ShadowDepth = 8, Opacity = 0.25 },
            Child = new StackPanel
            {
                Children =
                {
                    new Border { Padding = new Thickness(24, 24, 24, 24), Child = new StackPanel { Children = { heading, content } } },
                    new Border { Padding = new Thickness(24, 0, 24, 24), Child = buttons },
                },
            },
        };
        dialog.MouseLeftButtonDown += (_, e) => { if (e.ButtonState == MouseButtonState.Pressed) try { dialog.DragMove(); } catch { } };
        dialog.Loaded += (_, _) => { if (field is not null) { field.Focus(); field.SelectAll(); } else primary.Focus(); };
        dialog.ShowDialog();
        return result;
    }
}
