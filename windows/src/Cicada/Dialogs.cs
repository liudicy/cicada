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

    /// A one-line answer: the new text (maybe empty), or null when cancelled.
    public static string? Prompt(Window owner, string title, string value, string? hint, string ok)
    {
        var box = new TextBox { Text = value };
        System.Windows.Automation.AutomationProperties.SetName(box, title);
        var content = new StackPanel { Children = { Ui.Field(box) } };
        if (hint is not null) { var h = Ui.Helper(hint); h.Margin = new Thickness(0, 8, 0, 0); content.Children.Add(h); }
        return Show(owner, title, content, ok, danger: false, box);
    }

    static string? Show(Window owner, string title, FrameworkElement content, string ok, bool danger, TextBox? field, bool single = false)
    {
        string? result = null;
        var dialog = new Window
        {
            Owner = owner, WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent,
            ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false, SizeToContent = SizeToContent.Height, Width = 456 + 32,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, FontFamily = Palette.Font, Title = title,
        };
        void Accept() { result = field?.Text.Trim() ?? ""; dialog.Close(); }
        var primary = Ui.Button(ok, Accept, danger ? Ui.Kind.Danger : Ui.Kind.Primary);
        var cancel = Ui.Button(L("取消"), dialog.Close);
        primary.IsDefault = true; cancel.IsCancel = true;
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
