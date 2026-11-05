using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using static Cicada.Strings;

namespace Cicada.App;

/// Cicada's palette on Windows 11 shapes: the Mac's ground, ink and one orange for "live", plus the
/// Fluent roles (strokes, subtle fills, info bars). Orange text and fills use darker shades of the
/// accent so they pass 4.5:1; #E8552B itself is only for the live dot.
static class Palette
{
    static SolidColorBrush B(uint rgb) { var x = new SolidColorBrush(Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb)); x.Freeze(); return x; }
    public static readonly SolidColorBrush Mica = B(0xF3F4F6);
    public static readonly SolidColorBrush Surface = B(0xFFFFFF);
    public static readonly SolidColorBrush SurfaceAlt = B(0xF7F8FA);
    public static readonly SolidColorBrush Subtle = B(0xF0F1F3);
    public static readonly SolidColorBrush Selected = B(0xE6E8EB);
    public static readonly SolidColorBrush Stroke = B(0xE3E5E8);
    public static readonly SolidColorBrush Line = B(0xE4E6EA);
    public static readonly SolidColorBrush StrokeSoft = B(0xEEF0F2);
    public static readonly SolidColorBrush ControlStroke = B(0xD5D8DD);
    public static readonly SolidColorBrush Ink = B(0x15171C);
    public static readonly SolidColorBrush Body = B(0x3D414A);
    public static readonly SolidColorBrush Secondary = B(0x5A5F6B);
    public static readonly SolidColorBrush Tertiary = B(0x6B7080);
    public static readonly SolidColorBrush Live = B(0xE8552B);
    public static readonly SolidColorBrush AccentFill = B(0xC9441D);
    public static readonly SolidColorBrush AccentPale = B(0xFDEBE4);
    public static readonly SolidColorBrush AccentText = B(0xA8370F);
    public static readonly SolidColorBrush Success = B(0x0F7B3F);
    public static readonly SolidColorBrush Danger = B(0xC42B1C);
    public static readonly SolidColorBrush ErrorBg = B(0xFDECEA);
    public static readonly SolidColorBrush ErrorStroke = B(0xF3CBC4);
    public static readonly SolidColorBrush WarnBg = B(0xFFF6E5);
    public static readonly SolidColorBrush WarnStroke = B(0xF1DDB0);
    public static readonly SolidColorBrush WarnIcon = B(0x9D5D00);
    public static readonly SolidColorBrush Night = B(0x15171C);
    public static readonly SolidColorBrush Toggle = B(0xD9DBE0);
    public static readonly SolidColorBrush FieldLine = B(0xD1D4D9);
    /// The Mac's ground for windows (onboarding, settings), a shade lighter than the panels' fill.
    public static readonly SolidColorBrush Page = B(0xF7F8FA);
    /// The Mac's pale error and warning washes.
    public static readonly SolidColorBrush NightText = B(0xB4B9C2);
    /// 说话人 1, 2, 3… cycling after four (the Mac's SpeakerColor): not the accent (live, and 你),
    /// distinct in lightness, all ≥ 4.5:1 on white.
    static readonly SolidColorBrush[] inks = [B(0x0F7B6C), B(0x7A4CC2), B(0xB03A7A), B(0x8A5A00)];
    public static SolidColorBrush Speaker(int n) => inks[(Math.Max(1, n) - 1) % inks.Length];
    public static readonly FontFamily Font = new("Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI, Yu Gothic UI, Malgun Gothic");
    /// Two weights only. Microsoft YaHei UI, which draws all the Chinese, has Regular and Bold and
    /// nothing between: a semibold label renders Bold and the window reads black and cramped. So
    /// levels come from size and grey, and Bold is for headings and the one main button.
    public static readonly FontWeight Strong = FontWeights.Bold;
}

/// Stroke icons on a 20×20 grid (Fluent's outline style), drawn with Ui.Icon.
static class Icons
{
    public const string Close = "M5,5 L15,15 M15,5 L5,15";
    public const string Subtitles = "M4.5,4.5 H15.5 A2,2 0 0 1 17.5,6.5 V13.5 A2,2 0 0 1 15.5,15.5 H4.5 A2,2 0 0 1 2.5,13.5 V6.5 A2,2 0 0 1 4.5,4.5 Z M6,11.5 H9 M11,11.5 H14 M6,8.5 H14";
    public const string Notes = "M5.5,2.5 H11.5 L15,6 V17.5 H5.5 Z M11.5,2.5 V6 H15 M8,10 H13 M8,13 H13";
    public const string Stop = "M6.5,4 H13.5 A2.5,2.5 0 0 1 16,6.5 V13.5 A2.5,2.5 0 0 1 13.5,16 H6.5 A2.5,2.5 0 0 1 4,13.5 V6.5 A2.5,2.5 0 0 1 6.5,4 Z";
    public const string Play = "M6.5,4.5 L15.5,10 L6.5,15.5 Z";
    public const string Gear = "M12.5,10 A2.5,2.5 0 1 1 7.5,10 A2.5,2.5 0 1 1 12.5,10 Z M10,2.5 V4.5 M10,15.5 V17.5 M2.5,10 H4.5 M15.5,10 H17.5 M4.7,4.7 L6.1,6.1 M13.9,13.9 L15.3,15.3 M4.7,15.3 L6.1,13.9 M13.9,6.1 L15.3,4.7";
    public const string Search = "M14.5,9 A5.5,5.5 0 1 1 3.5,9 A5.5,5.5 0 1 1 14.5,9 Z M13,13 L17,17";
    public const string Export = "M10,3 V13 M6,7 L10,3 L14,7 M4,12 V16.5 H16 V12";
    public const string Pencil = "M13.5,3.5 L16.5,6.5 L7,16 H4 V13 Z";
    public const string Trash = "M4,6 H16 M8,6 V4 H12 V6 M5.5,6 L6.5,17 H13.5 L14.5,6";
    public const string Copy = "M8.5,7 H14.5 A1.5,1.5 0 0 1 16,8.5 V14.5 A1.5,1.5 0 0 1 14.5,16 H8.5 A1.5,1.5 0 0 1 7,14.5 V8.5 A1.5,1.5 0 0 1 8.5,7 Z M4,13 V5.5 A1.5,1.5 0 0 1 5.5,4 H13";
    public const string EyeOff = "M3,3 L17,17 M6.5,6.6 C4.6,7.8 3,10 3,10 C3,10 5.8,15 10,15 C11.3,15 12.5,14.6 13.5,14 M9,5.1 C9.3,5.1 9.7,5 10,5 C14.2,5 17,10 17,10 C17,10 16.4,11.1 15.3,12.3";
    public const string Eye = "M2.5,10 C2.5,10 5.3,5 10,5 C14.7,5 17.5,10 17.5,10 C17.5,10 14.7,15 10,15 C5.3,15 2.5,10 2.5,10 Z M12.2,10 A2.2,2.2 0 1 1 7.8,10 A2.2,2.2 0 1 1 12.2,10 Z";
    public const string Key = "M10.5,12 A3.5,3.5 0 1 1 3.5,12 A3.5,3.5 0 1 1 10.5,12 Z M9.5,9.5 L16,3 M13.5,5.5 L15.5,7.5";
    public const string Speaker = "M3.5,8 H6.5 L10.5,4.5 V15.5 L6.5,12 H3.5 Z M13.5,7.5 A3.5,3.5 0 0 1 13.5,12.5 M15.5,5.5 A6,6 0 0 1 15.5,14.5";
    public const string Globe = "M17,10 A7,7 0 1 1 3,10 A7,7 0 1 1 17,10 Z M3,10 H17 M10,3 C12,5 12.8,7.5 12.8,10 C12.8,12.5 12,15 10,17 C8,15 7.2,12.5 7.2,10 C7.2,7.5 8,5 10,3 Z";
    public const string Power = "M10,3 V10 M6,5.5 A6,6 0 1 0 14,5.5";
    public const string List = "M7,5.5 H16 M7,10 H16 M7,14.5 H16 M3.5,5.5 H4 M3.5,10 H4 M3.5,14.5 H4";
    public const string Wave = "M3,10 H4 M6,7 V13 M9,4.5 V15.5 M12,7 V13 M15,8.5 V11.5 M17,10 H17.5";
    public const string Shield = "M10,2.5 L16,5 V9.5 C16,13.5 13.3,16.2 10,17.5 C6.7,16.2 4,13.5 4,9.5 V5 Z";
    public const string Folder = "M2.5,5.5 H7.5 L9,7.5 H17.5 V16 H2.5 Z";
    public const string Keyboard = "M4,5.5 H16 A1.5,1.5 0 0 1 17.5,7 V13 A1.5,1.5 0 0 1 16,14.5 H4 A1.5,1.5 0 0 1 2.5,13 V7 A1.5,1.5 0 0 1 4,5.5 Z M5.5,8.5 H6.5 M8.5,8.5 H9.5 M11.5,8.5 H12.5 M6.5,11.5 H13.5";
    public const string Chevron = "M6,8 L10,12 L14,8";
    public const string Check = "M4.5,10.5 L8,14 L15.5,6";
    public const string Info = "M17,10 A7,7 0 1 1 3,10 A7,7 0 1 1 17,10 Z M10,9 V14 M10,6.5 V7";
    public const string Mic = "M10,2.5 A2.5,2.5 0 0 1 12.5,5 V10 A2.5,2.5 0 0 1 7.5,10 V5 A2.5,2.5 0 0 1 10,2.5 Z M5,9.5 A5,5 0 0 0 15,9.5 M10,14.5 V17.5";
    public const string Lock = "M5.5,9 H14.5 V16.5 H5.5 Z M7.5,9 V6.5 A2.5,2.5 0 0 1 12.5,6.5 V9";
    public const string Arrow = "M4,10 H15.5 M11,5.5 L15.5,10 L11,14.5";
    public const string OpenExternal = "M8,4 H4.5 V15.5 H16 V12 M11,3.5 H16.5 V9 M16.5,3.5 L9,11";
}

static class Ui
{
    public static TextBlock Text(string text, double size = 14, Brush? color = null, FontWeight? weight = null, bool wrap = true) => new()
    {
        Text = text, FontSize = size, Foreground = color ?? Palette.Ink, FontWeight = weight ?? FontWeights.Normal,
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
        FontFamily = Palette.Font,
    };

    // The Mac's headings are bold, not semibold: they carry the page.
    public static TextBlock Heading(string text, double size = 15) => Text(text, size, Palette.Ink, FontWeights.Bold);
    public static TextBlock Helper(string text) => Text(text, 12, Palette.Secondary);

    /// A 20×20 stroke icon, or a filled one, scaled to `size`.
    public static FrameworkElement Icon(string data, double size = 16, Brush? color = null, bool fill = false, double stroke = 1.5)
    {
        var path = new System.Windows.Shapes.Path { Data = Geometry.Parse(data), StrokeLineJoin = PenLineJoin.Round, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
        if (fill) path.Fill = color ?? Palette.Ink;
        else { path.Stroke = color ?? Palette.Ink; path.StrokeThickness = stroke; }
        var canvas = new Canvas { Width = 20, Height = 20 };
        canvas.Children.Add(path);
        return new Viewbox { Width = size, Height = size, Child = canvas, VerticalAlignment = VerticalAlignment.Center };
    }

    public static StackPanel Stack(double gap, params UIElement[] children)
    {
        var s = new StackPanel();
        foreach (var c in children)
        {
            if (c is FrameworkElement f && s.Children.Count > 0) f.Margin = new Thickness(f.Margin.Left, f.Margin.Top + gap, f.Margin.Right, f.Margin.Bottom);
            s.Children.Add(c);
        }
        return s;
    }

    public static StackPanel Row(double gap, params UIElement[] children)
    {
        var s = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var c in children)
        {
            if (c is FrameworkElement f && s.Children.Count > 0) f.Margin = new Thickness(f.Margin.Left + gap, f.Margin.Top, f.Margin.Right, f.Margin.Bottom);
            if (c is FrameworkElement v) v.VerticalAlignment = VerticalAlignment.Center;
            s.Children.Add(c);
        }
        return s;
    }

    /// A row whose last child sits at the right edge: [left…] ··· [right].
    public static DockPanel Spread(UIElement left, UIElement right)
    {
        var d = new DockPanel { LastChildFill = false };
        DockPanel.SetDock(left, Dock.Left); DockPanel.SetDock(right, Dock.Right);
        d.Children.Add(left); d.Children.Add(right);
        return d;
    }

    public enum Kind { Standard, Primary, Accent, Subtle, Danger, Pale }

    /// The Mac's buttons (Views.swift › SoftButton and friends): Standard is a soft grey fill with no
    /// border, Primary ink, Accent live orange (开始听 only), Subtle no fill until hover, Danger red,
    /// Pale the 结束 pill. Corners 10, or 12 on the big ones; filled labels bold, the rest regular.
    public static Button Button(string label, Action onClick, Kind kind = Kind.Standard, string? icon = null, double height = 36, bool iconFill = false, bool iconAfter = false)
    {
        var (bg, fg) = kind switch
        {
            Kind.Primary => (Palette.Ink, Brushes.White),
            Kind.Accent => (Palette.AccentFill, Brushes.White),
            Kind.Danger => (Palette.Danger, Brushes.White),
            Kind.Pale => (Palette.AccentPale, Palette.AccentText),
            Kind.Subtle => ((Brush)Brushes.Transparent, (Brush)Palette.Ink),
            _ => (Palette.Mica, Palette.Ink),
        };
        var content = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        var glyph = icon is null ? null : Icon(icon, height >= 48 ? 20 : iconAfter ? 14 : 16, fg, iconFill, stroke: iconAfter ? 1.8 : 1.5);
        if (glyph is not null && !iconAfter) content.Children.Add(glyph);
        var text = new TextBlock { Text = label, FontSize = height >= 48 ? 16 : 14, FontWeight = kind is Kind.Primary or Kind.Accent or Kind.Danger ? FontWeights.Bold : FontWeights.Normal, FontFamily = Palette.Font, VerticalAlignment = VerticalAlignment.Center, Foreground = fg };
        if (glyph is not null && !iconAfter) text.Margin = new Thickness(8, 0, 0, 0);
        content.Children.Add(text);
        if (glyph is not null && iconAfter) { glyph.Margin = new Thickness(8, 0, 0, 0); content.Children.Add(glyph); }
        var b = new Button
        {
            Content = content, Foreground = fg, Background = bg, BorderThickness = new Thickness(0),
            Height = height, Padding = new Thickness(16, 0, 16, 0), Cursor = Cursors.Hand, MinWidth = height >= 36 ? 72 : 0,
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Center,
        };
        b.Template = Template(kind is Kind.Standard or Kind.Subtle, radius: height >= 44 ? 12 : 10, soft: kind == Kind.Standard);
        b.Click += (_, _) => onClick();
        AutomationName(b, label);
        return b;
    }

    /// A square icon-only button with a tooltip and an accessible name.
    public static Button IconButton(string icon, string name, Action onClick, Brush? color = null, double size = 40, double iconSize = 16, bool fill = false, bool onDark = false)
    {
        var b = new Button
        {
            Content = Icon(icon, iconSize, color ?? Palette.Body, fill), Width = size, Height = size, Background = Brushes.Transparent,
            BorderThickness = new Thickness(0), Cursor = Cursors.Hand, ToolTip = name,
        };
        b.Template = Template(plain: true, onDark: onDark, radius: 10);
        b.Click += (_, _) => onClick();
        AutomationName(b, name);
        return b;
    }

    static void AutomationName(UIElement e, string name) => System.Windows.Automation.AutomationProperties.SetName(e, name);

    /// Rounded, no Windows 7 chrome. Plain buttons get a grey wash on hover; filled ones dim a little.
    static ControlTemplate Template(bool plain, bool onDark = false, Type? target = null, double radius = 10, bool soft = false)
    {
        var t = new ControlTemplate(target ?? typeof(Button));
        var border = new FrameworkElementFactory(typeof(Border), "bg");
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(radius));
        border.SetBinding(Border.BackgroundProperty, new System.Windows.Data.Binding("Background") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        border.SetBinding(Border.BorderBrushProperty, new System.Windows.Data.Binding("BorderBrush") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        border.SetBinding(Border.BorderThicknessProperty, new System.Windows.Data.Binding("BorderThickness") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        border.SetBinding(Border.PaddingProperty, new System.Windows.Data.Binding("Padding") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetValue(ContentPresenter.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        content.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(content);
        t.VisualTree = border;
        var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        var pressed = new Trigger { Property = ButtonBase.IsPressedProperty, Value = true };
        if (plain)
        {
            // A soft button darkens to the line grey; a subtle one gets the ground's fill.
            var wash = onDark ? new SolidColorBrush(Color.FromArgb(0x26, 0xFF, 0xFF, 0xFF)) : soft ? Palette.Line : (Brush)Palette.Mica;
            hover.Setters.Add(new Setter(Border.BackgroundProperty, wash, "bg"));
            pressed.Setters.Add(new Setter(Border.BackgroundProperty, onDark ? new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF)) : Palette.Line, "bg"));
        }
        else
        {
            hover.Setters.Add(new Setter(UIElement.OpacityProperty, 0.9));
            pressed.Setters.Add(new Setter(UIElement.OpacityProperty, 0.8));
        }
        var disabled = new Trigger { Property = UIElement.IsEnabledProperty, Value = false };
        disabled.Setters.Add(new Setter(UIElement.OpacityProperty, 0.45));
        t.Triggers.Add(hover); t.Triggers.Add(pressed); t.Triggers.Add(disabled);
        return t;
    }

    /// A text link in the accent's text shade. Acts on press and marks it handled, so the notes
    /// window doesn't start a drag instead.
    public static TextBlock LinkText(string label, Action onClick, double size = 13)
    {
        var t = Text(label, size, Palette.AccentText, wrap: false);
        t.Cursor = Cursors.Hand;
        t.MouseLeftButtonDown += (_, e) => { e.Handled = true; onClick(); };
        t.MouseEnter += (_, _) => t.TextDecorations = TextDecorations.Underline;
        t.MouseLeave += (_, _) => t.TextDecorations = null;
        return t;
    }

    public static FrameworkElement Dot(Brush color, double size = 8) => new Ellipse { Width = size, Height = size, Fill = color, VerticalAlignment = VerticalAlignment.Center };

    /// The live dot, dimming and brightening once a second while listening. Not a WPF animation:
    /// the notes panel and subtitle bar are transparent, shadowed windows that WPF redraws in
    /// software, and an animation redraws them every frame (3.5 cores in a VM, starving the very
    /// audio being listened to). One step a second costs one redraw a second.
    public static FrameworkElement LiveDot(double size = 8)
    {
        var dot = new Ellipse { Width = size, Height = size, Fill = Palette.Live, VerticalAlignment = VerticalAlignment.Center };
        dot.Loaded += (_, _) => { liveDots.Add(dot); blink.Start(); };
        dot.Unloaded += (_, _) => { liveDots.Remove(dot); if (liveDots.Count == 0) blink.Stop(); };
        return dot;
    }

    static readonly HashSet<Ellipse> liveDots = [];
    static bool dim;
    static readonly System.Windows.Threading.DispatcherTimer blink = MakeBlink();

    static System.Windows.Threading.DispatcherTimer MakeBlink()
    {
        var t = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        t.Tick += (_, _) => { dim = !dim; foreach (var d in liveDots) d.Opacity = dim ? 0.4 : 1; };
        return t;
    }

    /// A small pill: 对方可见 and the like.
    public static Border Badge(string text, Brush? bg = null, Brush? fg = null) => new()
    {
        Background = bg ?? Palette.AccentPale, CornerRadius = new CornerRadius(9), Padding = new Thickness(9, 3, 9, 4), VerticalAlignment = VerticalAlignment.Center,
        Child = Text(text, 12, fg ?? Palette.AccentText, wrap: false),
    };

    /// Room around a floating window's card for its shadow.
    public const double ShadowRoom = 14;

    /// A floating window's surface as on the Mac: 16-point corners and a soft shadow. The shadow is
    /// a few translucent rings, not a blur effect: a blur is redrawn in software on every change.
    public static FrameworkElement Floating(UIElement content, Brush background, double radius = 16, bool dark = false)
    {
        var grid = new Grid { Margin = new Thickness(ShadowRoom - 6, ShadowRoom - 4, ShadowRoom - 6, ShadowRoom - 8) };
        double[] alphas = dark ? [0.05, 0.07, 0.10, 0.14] : [0.015, 0.025, 0.04, 0.06];
        for (int i = 0; i < alphas.Length; i++)
        {
            var spread = alphas.Length - i;
            grid.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(radius + spread), Margin = new Thickness(-spread + 6, -spread + 4 + 1, -spread + 6, -spread + 8 - 3),
                Background = new SolidColorBrush(Color.FromArgb((byte)(alphas[i] * 255), 0, 0, 0)),
            });
        }
        grid.Children.Add(new Border
        {
            Background = background, CornerRadius = new CornerRadius(radius), Margin = new Thickness(6, 4, 6, 8),
            BorderBrush = dark ? new SolidColorBrush(Color.FromArgb(0x14, 0xFF, 0xFF, 0xFF)) : Palette.Line, BorderThickness = new Thickness(1),
            Child = content,
        });
        return grid;
    }

    public static Border Card(UIElement child, Thickness? padding = null, Brush? bg = null) => new()
    {
        Background = bg ?? Palette.Surface, BorderBrush = Palette.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(16),
        Padding = padding ?? new Thickness(20), Child = child,
    };

    /// The design's check box: an ink box, not the theme's blue one; still a CheckBox for keys and readers.
    public static CheckBox Check(string label, bool on, Action<bool> changed)
    {
        var box = new Border { Width = 18, Height = 18, CornerRadius = new CornerRadius(4) };
        void Paint(bool v)
        {
            box.Background = v ? Palette.Ink : Palette.Surface;
            box.BorderBrush = v ? Palette.Ink : Palette.Secondary;
            box.BorderThickness = new Thickness(v ? 0 : 1.5);
            box.Child = v ? Icon(Icons.Check, 14, Brushes.White, stroke: 2.2) : null;
        }
        Paint(on);
        var c = new CheckBox
        {
            IsChecked = on, Content = Row(10, box, Text(label, 14, Palette.Ink, wrap: false)),
            Template = new ControlTemplate(typeof(CheckBox)) { VisualTree = new FrameworkElementFactory(typeof(ContentPresenter)) }, Cursor = Cursors.Hand,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        AutomationName(c, label);
        c.Click += (_, _) => { var v = c.IsChecked == true; Paint(v); changed(v); };
        return c;
    }

    public enum Severity { Error, Warning }

    /// Fluent's InfoBar: an icon, a bold title, one line of body, and up to one action.
    public static Border InfoBar(Severity severity, string? title, string body, UIElement? action = null)
    {
        var error = severity == Severity.Error;
        var icon = new Grid { Width = 18, Height = 18, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 1, 0, 0) };
        icon.Children.Add(new Ellipse { Fill = error ? Palette.Danger : Palette.WarnIcon });
        icon.Children.Add(Icon(error ? "M7,7 L13,13 M13,7 L7,13" : "M10,5.5 V11 M10,14 V14.5", 18, Brushes.White, stroke: 1.8));
        var text = new StackPanel { Margin = new Thickness(10, 0, 8, 0) };
        if (title is not null) text.Children.Add(Text(title, 14, Palette.Ink, FontWeights.Bold));
        var bodyText = Text(body, 13, Palette.Body);
        if (title is not null) bodyText.Margin = new Thickness(0, 2, 0, 0);
        text.Children.Add(bodyText);
        var dock = new DockPanel();
        DockPanel.SetDock(icon, Dock.Left);
        dock.Children.Add(icon);
        if (action is TextBlock link) { link.Margin = new Thickness(0, 6, 0, 0); link.HorizontalAlignment = HorizontalAlignment.Left; text.Children.Add(link); }
        else if (action is FrameworkElement a) { DockPanel.SetDock(a, Dock.Right); a.VerticalAlignment = VerticalAlignment.Top; dock.Children.Add(a); }
        dock.Children.Add(text);
        return new Border
        {
            Background = error ? Palette.ErrorBg : Palette.WarnBg, BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(12), Padding = new Thickness(14, 12, 12, 12), Child = dock,
        };
    }

    /// The Mac's switch: an ink track when on, a grey one when off, a white knob; no 开/关 beside it.
    public static FrameworkElement Switch(bool on, Action<bool> changed, string name)
    {
        var knob = new Ellipse { Width = 18, Height = 18, Fill = Brushes.White, Stroke = new SolidColorBrush(Color.FromArgb(0x1A, 0, 0, 0)), StrokeThickness = 0.5 };
        var track = new Border { Width = 38, Height = 22, CornerRadius = new CornerRadius(11), Child = knob, Padding = new Thickness(2) };
        void Paint(bool v)
        {
            track.Background = v ? Palette.Ink : Palette.Toggle;
            knob.HorizontalAlignment = v ? HorizontalAlignment.Right : HorizontalAlignment.Left;
        }
        Paint(on);
        var toggle = new ToggleButton { IsChecked = on, Content = track, Background = Brushes.Transparent, BorderThickness = new Thickness(0), Cursor = Cursors.Hand, Padding = new Thickness(0), VerticalAlignment = VerticalAlignment.Center };
        toggle.Template = Template(plain: false, target: typeof(ToggleButton), radius: 11);
        toggle.Click += (_, _) => { var v = toggle.IsChecked == true; Paint(v); changed(v); };
        AutomationName(toggle, name);
        return toggle;
    }

    /// A segmented control: one choice of a few, the chosen one raised on a grey track.
    /// No blur on the raised one (the notes panel redraws in software): a white fill and a hairline.
    /// `fill` spreads the options over the full width in equal parts, as the notes panel's 纪要 / 文字记录.
    public static FrameworkElement Segmented(IEnumerable<(string value, string label)> options, string selected, Action<string> changed, bool fill = false, double height = 30)
    {
        var track = new Border { Background = Palette.Mica, CornerRadius = new CornerRadius(10), Padding = new Thickness(3) };
        Panel row = fill ? new UniformGrid { Rows = 1 } : new StackPanel { Orientation = Orientation.Horizontal };
        track.Child = row;
        var buttons = new List<(Button b, string v)>();
        void Paint(string v)
        {
            foreach (var (b, value) in buttons)
            {
                var on = value == v;
                b.Background = on ? Palette.Surface : Brushes.Transparent;
                b.BorderBrush = on ? Palette.Line : Brushes.Transparent;
                ((TextBlock)b.Content).Foreground = on ? Palette.Ink : Palette.Secondary;
            }
        }
        foreach (var (value, label) in options)
        {
            var b = new Button { Content = Text(label, 13, Palette.Body, wrap: false), Height = height, HorizontalAlignment = fill ? HorizontalAlignment.Stretch : HorizontalAlignment.Left, Padding = new Thickness(14, 0, 14, 0), BorderThickness = new Thickness(1), Cursor = Cursors.Hand, HorizontalContentAlignment = HorizontalAlignment.Center };
            b.Template = Template(plain: false, radius: 8);
            b.Click += (_, _) => { Paint(value); changed(value); };
            buttons.Add((b, value));
            row.Children.Add(b);
        }
        Paint(selected);
        return track;
    }

    /// Pivot-style tabs: text with an ink underline on the chosen one.
    public static FrameworkElement Tabs(IEnumerable<(string value, string label)> options, string selected, Action<string> changed, double size = 14)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (value, label) in options)
        {
            var on = value == selected;
            var text = Text(label, size, on ? Palette.Ink : Palette.Secondary, wrap: false);
            var underline = new Border { Height = 2, CornerRadius = new CornerRadius(1), Background = on ? Palette.Ink : Brushes.Transparent, Margin = new Thickness(0, 8, 0, 0) };
            var stack = new StackPanel { Children = { text, underline } };
            var b = new Button { Content = stack, Padding = new Thickness(0, 8, 0, 0), Margin = new Thickness(0, 0, 24, 0), Background = Brushes.Transparent, BorderThickness = new Thickness(0), Cursor = Cursors.Hand };
            b.Template = Template(plain: false, radius: 0);
            b.Click += (_, _) => changed(value);
            row.Children.Add(b);
        }
        return row;
    }

    /// A pop-up button, as the Mac's pickers: the chosen value on a soft fill with a chevron, and a
    /// menu of the choices, the chosen one checked. (Windows' own combo box looks out of place here.)
    public static Button Choice(IEnumerable<(string value, string label)> options, string selected, Action<string> changed, double width = 200)
    {
        var list = options.ToList();
        var label = Text(list.FirstOrDefault(o => o.value == selected).label ?? "", 14, Palette.Ink, wrap: false);
        var chevron = Icon(Icons.Chevron, 14, Palette.Secondary, stroke: 1.8);
        var dock = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(chevron, Dock.Right);
        chevron.Margin = new Thickness(8, 0, 0, 0);
        label.HorizontalAlignment = HorizontalAlignment.Left;
        dock.Children.Add(chevron); dock.Children.Add(label);
        var b = new Button
        {
            Content = dock, Width = width, Height = 34, Padding = new Thickness(12, 0, 10, 0), Background = Palette.Mica, BorderThickness = new Thickness(0),
            Cursor = Cursors.Hand, HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Center,
        };
        b.Template = Template(plain: true, radius: 10, soft: true);
        var current = selected;
        b.Click += (_, _) =>
        {
            var menu = new ContextMenu { PlacementTarget = b, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom, FontFamily = Palette.Font, MinWidth = width };
            foreach (var (value, text) in list)
            {
                var item = new MenuItem { Header = text, IsCheckable = true, IsChecked = value == current };
                item.Click += (_, _) => { current = value; label.Text = text; changed(value); };
                menu.Items.Add(item);
            }
            menu.IsOpen = true;
        };
        AutomationName(b, label.Text);
        return b;
    }

    /// A text field as on the Mac: white, 10-point corners, a light line, generous padding.
    public static Border Field(Control box) => FieldFrame(StyleField(box), box);

    /// The frame alone, around anything (a field with a button inside it); `focus` lights it.
    public static Border FieldFrame(UIElement child, Control? focus = null)
    {
        var border = new Border { Background = Brushes.White, BorderBrush = Palette.FieldLine, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Height = 40, Padding = new Thickness(12, 0, 12, 0), Child = child };
        if (focus is not null)
        {
            focus.GotKeyboardFocus += (_, _) => border.BorderBrush = Palette.Ink;
            focus.LostKeyboardFocus += (_, _) => border.BorderBrush = Palette.FieldLine;
        }
        return border;
    }

    /// The text control itself, without Windows' frame.
    public static Control StyleField(Control box)
    {
        box.BorderThickness = new Thickness(0);
        box.Background = Brushes.Transparent;
        box.FontSize = 14;
        box.FontFamily = Palette.Font;
        box.Padding = new Thickness(0);
        box.VerticalContentAlignment = VerticalAlignment.Center;
        box.FocusVisualStyle = null;
        var host = new FrameworkElementFactory(typeof(ScrollViewer), "PART_ContentHost");
        host.SetValue(ScrollViewer.VerticalAlignmentProperty, VerticalAlignment.Center);
        box.Template = new ControlTemplate(box.GetType()) { VisualTree = host };
        return box;
    }

    /// A key as printed on the keyboard (右 Ctrl, Ctrl Alt L): white, a hairline, a thicker bottom
    /// edge. `big` is the one the user is asked to press.
    public static Border Keycap(string label, bool big = false) => new()
    {
        Background = Brushes.White, BorderBrush = Palette.ControlStroke, BorderThickness = new Thickness(1, 1, 1, big ? 3 : 2),
        CornerRadius = new CornerRadius(big ? 9 : 6), Padding = big ? new Thickness(18, 8, 18, 7) : new Thickness(7, 2, 7, 2), VerticalAlignment = VerticalAlignment.Center,
        Child = Text(label, big ? 15 : 12, Palette.Ink, big ? FontWeights.Bold : FontWeights.Normal, wrap: false),
    };

    /// Shortcut text ("Ctrl+Alt+L") as keycaps: Ctrl Alt L.
    public static Border Shortcut(string keys) => Keycap(keys.Replace('+', ' '));

    /// A window without Windows' title bar, as the Mac's: the content runs to the top edge and only
    /// the three caption buttons stay, drawn by us at the top right. WindowChrome keeps what the
    /// system frame gave: dragging by the top strip, snap, resizing at the edges, and on Windows 11
    /// DWM's rounded corners and shadow (a one-pixel glass frame).
    public static FrameworkElement Frameless(Window w, FrameworkElement content, bool resizable = true, double captionHeight = 44, Action? close = null)
    {
        System.Windows.Shell.WindowChrome.SetWindowChrome(w, new System.Windows.Shell.WindowChrome
        {
            CaptionHeight = captionHeight, ResizeBorderThickness = resizable ? new Thickness(6) : new Thickness(0),
            GlassFrameThickness = new Thickness(0, 0, 0, 1), CornerRadius = new CornerRadius(0), UseAeroCaptionButtons = false,
        });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top };
        Button Caption(string glyph, string name, Action act, bool danger = false)
        {
            var b = new Button
            {
                Content = Icon(glyph, 16, Palette.Body, stroke: 1), Width = 46, Height = 36, Background = Brushes.Transparent, BorderThickness = new Thickness(0),
                ToolTip = name, Focusable = false,
            };
            var t = new ControlTemplate(typeof(Button));
            var bg = new FrameworkElementFactory(typeof(Border), "bg");
            bg.SetBinding(Border.BackgroundProperty, new System.Windows.Data.Binding("Background") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
            var cp = new FrameworkElementFactory(typeof(ContentPresenter));
            cp.SetValue(ContentPresenter.HorizontalAlignmentProperty, HorizontalAlignment.Center);
            cp.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
            bg.AppendChild(cp);
            t.VisualTree = bg;
            var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
            hover.Setters.Add(new Setter(Border.BackgroundProperty, danger ? Palette.Danger : new SolidColorBrush(Color.FromArgb(0x0F, 0, 0, 0)), "bg"));
            t.Triggers.Add(hover);
            b.Template = t;
            if (danger) { b.MouseEnter += (_, _) => b.Content = Icon(glyph, 16, Brushes.White, stroke: 1); b.MouseLeave += (_, _) => b.Content = Icon(glyph, 16, Palette.Body, stroke: 1); }
            b.Click += (_, _) => act();
            System.Windows.Shell.WindowChrome.SetIsHitTestVisibleInChrome(b, true);
            AutomationName(b, name);
            return b;
        }
        buttons.Children.Add(Caption("M5,10 H15", L("最小化"), () => w.WindowState = WindowState.Minimized));
        if (resizable)
            buttons.Children.Add(Caption("M5.5,5.5 H14.5 V14.5 H5.5 Z", L("最大化"), () => w.WindowState = w.WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized));
        buttons.Children.Add(Caption(Icons.Close, L("关闭"), close ?? w.Close, danger: true));
        var root = new Grid { Children = { content, buttons } };
        // Maximized, Windows puts the frame's invisible border off screen; keep the content inside.
        void Fit() => root.Margin = w.WindowState == WindowState.Maximized ? new Thickness(7) : new Thickness(0);
        w.StateChanged += (_, _) => Fit();
        return root;
    }

    public static IEnumerable<(string, string)> TargetOptions() =>
        [("system", LF("跟随系统（%@）", Languages.Targets.FirstOrDefault(t => t.Code == Languages.FromSystem(System.Globalization.CultureInfo.CurrentUICulture.Name))?.Name ?? "")),
         .. Languages.Targets.Select(t => (t.Code, t.Name))];

    public static string TargetName(string code) => Languages.Targets.FirstOrDefault(t => t.Code == code)?.Name ?? code;

    /// The name of a spoken language as people write it ("English", "日本語").
    public static string SpokenName(string? code)
    {
        if (code is null) return "";
        var head = code.Split('-')[0];
        return Languages.Sources.FirstOrDefault(s => s.Code.Split('-')[0] == head)?.Name ?? code;
    }
}

static class AppIcon
{
    public static readonly System.Windows.Media.Imaging.BitmapFrame? Image = Load();

    static System.Windows.Media.Imaging.BitmapFrame? Load()
    {
        try { return System.Windows.Media.Imaging.BitmapFrame.Create(new Uri("pack://application:,,,/cicada.ico")); }
        catch { return null; }
    }

    /// The icon at `size`, from the .ico's largest frame (its first is 16 px and blurs when scaled up).
    public static Image Small(double size = 16) { var i = new Image { Source = size > 20 ? Large ?? Image : Image, Width = size, Height = size, VerticalAlignment = VerticalAlignment.Center }; RenderOptions.SetBitmapScalingMode(i, BitmapScalingMode.HighQuality); return i; }

    static readonly System.Windows.Media.Imaging.BitmapSource? Large = LoadLarge();

    static System.Windows.Media.Imaging.BitmapSource? LoadLarge()
    {
        try
        {
            var d = System.Windows.Media.Imaging.BitmapDecoder.Create(new Uri("pack://application:,,,/cicada.ico"), System.Windows.Media.Imaging.BitmapCreateOptions.None, System.Windows.Media.Imaging.BitmapCacheOption.OnLoad);
            return d.Frames.OrderByDescending(f => f.PixelWidth).First();
        }
        catch { return null; }
    }
}
