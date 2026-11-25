using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using static Cicada.Strings;

namespace Cicada.App;

/// A custom service's model once its `/models` listed some (AISettings.swift › ModelPicker): a
/// button that opens the list with a search box on top. A name the service doesn't list can be
/// typed (an alias, a model it hides): 用 X（列表里没有）. Return takes the only match, else what
/// was typed. `sameLabel` is a first choice that clears the value (和翻译模型一样). Without a list
/// the settings show a plain field instead (SettingsWindow.ModelField).
static class ModelPicker
{
    public static FrameworkElement Make(string value, string? sameLabel, IReadOnlyList<string> catalog, string host,
        Action refetch, Action<string> onPick, double width = 260)
    {
        var shown = value.Length > 0 ? value : sameLabel ?? L("选一个");
        var label = Ui.Text(shown, 14, value.Length > 0 ? Palette.Ink : Palette.Secondary, wrap: false);
        label.TextTrimming = TextTrimming.CharacterEllipsis;
        label.HorizontalAlignment = HorizontalAlignment.Left;
        var chevron = Ui.Icon(Icons.Chevron, 14, Palette.Secondary, stroke: 1.8);
        chevron.Margin = new Thickness(8, 0, 0, 0);
        DockPanel.SetDock(chevron, Dock.Right);
        // Ui.Choice's look; its own menu would open beside the popup.
        var button = new Button
        {
            Content = new DockPanel { LastChildFill = true, Children = { chevron, label } }, Width = width, Height = 34,
            Padding = new Thickness(12, 0, 10, 0), Background = Palette.Mica, BorderThickness = new Thickness(0), Cursor = Cursors.Hand,
            HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Center,
            Template = Ui.Template(plain: true, radius: 10, soft: true),
        };
        System.Windows.Automation.AutomationProperties.SetName(button, shown);

        var search = new TextBox();
        var hint = Ui.Text(L("搜索或输入模型"), 13, Palette.Tertiary, wrap: false);
        hint.IsHitTestVisible = false; hint.VerticalAlignment = VerticalAlignment.Center;
        Ui.StyleField(search);
        search.FontSize = 13;
        var field = Ui.FieldFrame(new Grid { Children = { search, hint } }, search);
        field.Height = 32; field.Margin = new Thickness(8, 8, 8, 4);
        var rows = new StackPanel { Margin = new Thickness(4) };
        var count = Ui.Text(LF("%@ 列出 %lld 个模型", host, catalog.Count), 12, Palette.Tertiary, wrap: false);
        count.VerticalAlignment = VerticalAlignment.Center;
        var popup = new Popup { PlacementTarget = button, Placement = PlacementMode.Bottom, StaysOpen = false, AllowsTransparency = true };
        var again = Ui.LinkText(L("重新获取"), () => { popup.IsOpen = false; refetch(); }, 12);
        var footer = Ui.Spread(count, again);
        footer.Margin = new Thickness(12, 6, 12, 8);
        var list = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = 280, Content = rows };
        var body = new DockPanel { Width = Math.Max(width, 320) };
        TextElement.SetFontFamily(body, Palette.Font);
        DockPanel.SetDock(field, Dock.Top);
        DockPanel.SetDock(footer, Dock.Bottom);
        body.Children.Add(field);
        body.Children.Add(footer);
        body.Children.Add(list);
        popup.Child = new Border
        {
            Background = Palette.Surface, BorderBrush = Palette.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10),
            Margin = new Thickness(0, 4, 0, 0), Child = body,
        };

        void Pick(string id)
        {
            popup.IsOpen = false;
            if (id != value) onPick(id);
        }
        List<string> Matches()
        {
            var q = search.Text.Trim();
            return q.Length == 0 ? [.. catalog] : catalog.Where(m => m.Contains(q, StringComparison.OrdinalIgnoreCase)).ToList();
        }
        FrameworkElement Row(string text, bool selected, bool mono, string pick)
        {
            var t = Ui.Text(text, 13, Palette.Ink, wrap: false);
            t.TextTrimming = TextTrimming.CharacterEllipsis;
            if (mono) t.FontFamily = new FontFamily("Cascadia Mono, Consolas");
            var check = Ui.Text("✓", 12, Palette.Ink, wrap: false);
            check.Opacity = selected ? 1 : 0; check.Margin = new Thickness(0, 0, 8, 0);
            var row = new Border
            {
                Background = selected ? Palette.Subtle : Brushes.Transparent, CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 5, 8, 5),
                Cursor = Cursors.Hand, Child = Ui.Row(0, check, t),
            };
            row.MouseEnter += (_, _) => row.Background = Palette.Selected;
            row.MouseLeave += (_, _) => row.Background = selected ? Palette.Subtle : Brushes.Transparent;
            row.MouseLeftButtonUp += (_, _) => Pick(pick);
            return row;
        }
        void Fill()
        {
            hint.Visibility = search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            var q = search.Text.Trim();
            rows.Children.Clear();
            if (q.Length > 0 && !catalog.Contains(q)) rows.Children.Add(Row(LF("用 %@（列表里没有）", q), false, false, q));
            if (sameLabel is not null && q.Length == 0) rows.Children.Add(Row(sameLabel, value.Length == 0, false, ""));
            foreach (var id in Matches()) rows.Children.Add(Row(id, id == value, true, id));
        }
        search.TextChanged += (_, _) => Fill();
        search.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { popup.IsOpen = false; e.Handled = true; }
            if (e.Key != Key.Enter) return;
            e.Handled = true;
            var m = Matches();
            var q = search.Text.Trim();
            if (m.Count == 1) Pick(m[0]); else if (q.Length > 0) Pick(q);
        };
        button.Click += (_, _) =>
        {
            search.Text = "";
            Fill();
            popup.IsOpen = true;
            search.Dispatcher.BeginInvoke(() => search.Focus(), System.Windows.Threading.DispatcherPriority.Input);
        };
        return button;
    }
}
