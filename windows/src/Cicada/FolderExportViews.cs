using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using static Cicada.Strings;

namespace Cicada.App;

/// 存到文件夹 (FolderExport.cs): the folder as Explorer names it, the choice of folder, and the
/// record's line under its title. As the Mac's FolderExportViews.swift.
static class FolderExportUi
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct FileInfo
    {
        public IntPtr Icon; public int IconIndex; public uint Attributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string DisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string TypeName;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SHGetFileInfo(string path, uint attributes, ref FileInfo info, uint size, uint flags);
    const uint DisplayNameFlag = 0x200;

    /// Explorer's name for a folder ("文档" for Documents, "Windows (C:)" for a drive); null when it
    /// isn't there.
    static string? ShellName(string path)
    {
        var info = new FileInfo();
        return SHGetFileInfo(path, 0, ref info, (uint)Marshal.SizeOf<FileInfo>(), DisplayNameFlag) != IntPtr.Zero && info.DisplayName is { Length: > 0 } n ? n : null;
    }

    /// "文档 › Cicada".
    public static string ShortPath(string folder) => FolderExportFormat.ShortPath(folder, ShellName);

    /// Not SettingsWindow.OpenFolder: that makes the folder, and on a drive that's gone it would throw.
    public static void Open(string folder)
    {
        if (!Directory.Exists(folder)) return;
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{folder}\"") { UseShellExecute = true });
    }

    public static void Reveal(string file)
    {
        if (File.Exists(file)) Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{file}\"") { UseShellExecute = true });
        else if (Path.GetDirectoryName(file) is { } dir) Open(dir);
    }

    /// Windows 安全中心 › 勒索软件防护, where controlled folder access lets an app through.
    public static void OpenSecurity()
    {
        try { Process.Start(new ProcessStartInfo("windowsdefender://ransomwareprotection") { UseShellExecute = true }); }
        catch (Exception e) { Log.Debug($"folder export: security page not opened {e.GetType().Name}"); }
    }

    /// 存到哪里: an Obsidian vault first (a new Cicada folder in it), then 文档 › Cicada, or any folder.
    public static string? Choose(Window? owner, string? current)
    {
        var options = new List<(string Title, string? Detail, string? Path)>();
        foreach (var v in FolderExportFormat.ObsidianVaults().Take(3))
            options.Add((LF("Obsidian 库「%@」", FolderExportFormat.LastName(v)), L("在库里新建 Cicada 文件夹"), Path.Combine(v, "Cicada")));
        var documents = FolderExportFormat.DocumentsFolder;
        options.Add((ShortPath(documents), null, documents));
        options.Add((L("其他文件夹…"), null, null));
        if (Dialogs.Pick(owner, L("存到哪里"), options.Select(o => (o.Title, o.Detail)).ToList(), L("存到这里")) is not { } i) return null;
        if (options[i].Path is { } chosen) return chosen;
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = L("会后把纪要和文字记录存成 Markdown 到这里") };
        var start = current is not null && Directory.Exists(current) ? current : Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        if (Directory.Exists(start)) dialog.InitialDirectory = start;
        return dialog.ShowDialog(owner) == true ? dialog.FolderName : null;
    }

    /// The record's line under its title: where its file is, or why it isn't there yet. Null when
    /// there is nothing to say.
    public static FrameworkElement? Line(Controller app, Session s)
    {
        var ex = app.FolderExport;
        if (!ex.On || ex.Folder is not { } folder || !ex.Ready(s)) return null;
        var pending = ex.IsPending(s.Id);
        FrameworkElement Grey(string text) => Ui.Text(text, 12, Palette.Tertiary, wrap: false);
        FrameworkElement line;
        if (ex.FileFor(s.Id) is { } file && !pending)
            line = Ui.Row(4, Grey(LF("已存到 %@ ·", ShortPath(folder))), Ui.LinkText(L("在文件资源管理器中显示"), () => Reveal(file), 12));
        else if (pending && ex.Trouble is not null)
            line = Ui.Row(4, Grey(L("没存到文件夹 ·")), Ui.LinkText(L("去设置"), app.ShowFolderSettings, 12));
        else if (pending)
            line = Grey(LF("整理好后存到 %@", ShortPath(folder)));
        else return null;
        line.Margin = new Thickness(0, 8, 0, 0);
        return line;
    }

    /// What the line shows, for MainWindow's PageKey.
    public static string Key(Controller app, string id) =>
        $"{app.FolderExport.On}|{app.FolderExport.FileFor(id)}|{app.FolderExport.IsPending(id)}|{app.FolderExport.Trouble?.Kind}";
}

/// 设置 › 隐私与启动 › 会后存一份 (the Mac has it in 通用, under the records' location, which on
/// Windows is this page).
sealed partial class SettingsWindow
{
    IEnumerable<FrameworkElement> ExportCards()
    {
        var ex = app.FolderExport;
        yield return Label(L("会后存一份"));
        var cards = new List<FrameworkElement>
        {
            Card(null, L("存到文件夹"), L("纪要和文字记录存成 Markdown；文件夹同步到哪，内容就到哪"), Ui.Switch(ex.On, ToggleExport, L("存到文件夹"))),
        };
        if (ex.On && ex.Folder is { } folder)
        {
            var shortPath = FolderExportUi.ShortPath(folder);
            if (ex.Checking) cards.Add(Card(null, LF("正在确认能写入 %@…", shortPath), null, new Border()));
            else if (ex.Trouble is { } problem) cards.Add(ProblemRow(problem, folder, shortPath));
            // Ui.Row spaces only the children it is given.
            var place = new List<UIElement>();
            if (FolderExportFormat.Vault(folder) is not null) place.Add(Ui.Badge(L("Obsidian 库")));
            place.Add(Ui.Button(L("打开"), () => FolderExportUi.Open(folder), height: 32));
            place.Add(Ui.Button(L("更改…"), ChooseExportFolder, height: 32));
            cards.Add(Card(null, L("位置"), shortPath, Ui.Row(8, [.. place])));
            var left = ex.Unwritten.Count;
            if (left > 0) cards.Add(Card(null, L("以前的会议"), LF("还有 %lld 场没存", left), Ui.Button(L("也存一份"), ex.WriteAll, height: 32)));
        }
        yield return Group([.. cards]);
        if (ex.On && ex.State.LastFile is { } name && ex.State.LastAt is { } at)
        {
            var local = at.ToLocalTime();
            var last = Ui.Text(LF("上次存于 %@ · %@", local.ToString(L("M月d日 HH:mm"), Strings.Culture), name), 12, Palette.Tertiary, wrap: false);
            last.TextTrimming = TextTrimming.CharacterEllipsis;
            // Section sets each part's margin: the indent goes on a wrapper.
            yield return new Border { Padding = new Thickness(6, 0, 0, 0), Child = last };
        }
    }

    /// Access denied looks the same whoever said no; inside the folders controlled folder access
    /// protects, Windows 安全中心 is the likely fix.
    FrameworkElement ProblemRow(FolderExporter.Problem problem, string folder, string shortPath)
    {
        var waiting = app.FolderExport.State.Pending.Count;
        var shielded = FolderExportFormat.Protected(folder);
        var (title, detail) = problem.Kind switch
        {
            FolderExporter.Kind.Denied => (LF("没有权限写入 %@", shortPath),
                waiting > 0 ? LF("%lld 场会议没存上，允许后自动补存", waiting)
                : shielded ? L("在 Windows 安全中心里允许知了，或换个文件夹") : L("换个文件夹，或在它的属性里允许写入")),
            FolderExporter.Kind.Missing => (LF("找不到 %@", shortPath), L("接上或换个文件夹后自动补存")),
            _ => (L("没存上"), problem.Message ?? ""),
        };
        var text = Ui.Stack(2, Ui.Text(title, 13, Palette.Ink, FontWeights.SemiBold), Ui.Helper(detail));
        var dock = new DockPanel();
        if (problem.Kind == FolderExporter.Kind.Denied && shielded)
        {
            var open = Ui.Button(L("打开 Windows 安全中心"), FolderExportUi.OpenSecurity, height: 32);
            open.Margin = new Thickness(12, 0, 0, 0);
            open.VerticalAlignment = VerticalAlignment.Center;
            DockPanel.SetDock(open, Dock.Right);
            dock.Children.Add(open);
        }
        dock.Children.Add(text);
        return new Border
        {
            Background = problem.Kind == FolderExporter.Kind.Denied ? Palette.AccentPale : Palette.Mica,
            CornerRadius = new CornerRadius(9), Padding = new Thickness(12, 10, 12, 10), Margin = new Thickness(0, 8, 0, 8), Child = dock,
        };
    }

    void ToggleExport(bool on)
    {
        var ex = app.FolderExport;
        if (!on) ex.TurnOff();
        else if (ex.Folder is { } folder) ex.Choose(folder);
        else ChooseExportFolder();
        Render();
    }

    void ChooseExportFolder()
    {
        if (FolderExportUi.Choose(this, app.FolderExport.Folder) is { } folder) app.FolderExport.Choose(folder);
        Render();
    }

    /// The exporter's state changed: only 隐私与启动 shows it.
    public void ExportChanged() { if (current == "privacy") Render(); }
}
