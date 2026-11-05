using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

namespace Cicada.App;

/// The release build installed for this user only, so nothing asks for admin rights: the exe in
/// %LOCALAPPDATA%\Programs\Cicada, a Start menu shortcut, the Run key for 开机时启动知了 and an
/// entry in Settings › Apps whose 卸载 runs `Cicada.exe --uninstall`. The windows are SetupWindow.
static class Install
{
    public static string Folder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Cicada");
    public static string Exe => Path.Combine(Folder, "Cicada.exe");
    const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Cicada";
    /// The release build's single-instance mutex (Program.Main).
    public const string Mutex = "com.wquguru.cicada";

    /// The installed version, from Settings › Apps' entry (the exe's own version resource isn't
    /// written when the app is built on the Mac). Null when nothing is installed.
    public static string? InstalledVersion()
    {
        if (!File.Exists(Exe)) return null;
        try { using var k = Registry.CurrentUser.OpenSubKey(UninstallKey); return k?.GetValue("DisplayVersion") as string ?? "0"; }
        catch { return "0"; }
    }

    /// The running Cicada (installed, or an old copy from a zip), through its pipe: null when none.
    public static bool? Listening() => DebugServer.Send("setup status") is { } reply ? reply.Contains("\"listening\":true") : null;

    /// Asks the running Cicada to quit (it ends a meeting first and saves it), and waits until it has.
    static void QuitRunning()
    {
        if (DebugServer.Send("setup quit") is null && !Running()) return;
        using var m = new Mutex(false, Mutex);
        try { if (!m.WaitOne(TimeSpan.FromSeconds(30))) throw new IOException("Cicada didn't quit"); }
        catch (AbandonedMutexException) { }
        m.ReleaseMutex();
        Log.Debug("setup: the running copy quit");
    }

    static bool Running()
    {
        using var m = new Mutex(false, Mutex);
        try { if (!m.WaitOne(0)) return true; }
        catch (AbandonedMutexException) { }
        m.ReleaseMutex();
        return false;
    }

    /// Copies this exe in, then registers it. `step` reports 1–3 as each part is done. First install:
    /// the two choices. An upgrade (`choices` null) keeps the shortcut and autostart as they were.
    public static void Run((bool StartMenu, bool AutoStart)? choices, Action<int> step)
    {
        var self = Environment.ProcessPath ?? throw new IOException("no exe path");
        Directory.CreateDirectory(Folder);
        // Copied beside the old one first, so a full disk or a scanner holding the file leaves the
        // installed copy as it was.
        var next = Exe + ".new";
        File.Copy(self, next, overwrite: true);
        QuitRunning();
        for (int i = 0; ; i++)
        {
            try { File.Move(next, Exe, overwrite: true); break; }
            catch (IOException) when (i < 20) { Thread.Sleep(250); } // the old process is still letting go of it
            catch (UnauthorizedAccessException) when (i < 20) { Thread.Sleep(250); }
        }
        step(1);
        var hadShortcut = Shortcuts().Any(File.Exists);
        if (choices?.StartMenu ?? hadShortcut) Shortcut(); else foreach (var f in Shortcuts()) File.Delete(f);
        step(2);
        // A copy from a zip may have left the Run key pointing into Downloads: point it here.
        AutoStart.Set(Exe, choices?.AutoStart ?? AutoStart.Enabled);
        Register();
        step(3);
        Log.Debug($"setup: installed {Controller.Version}");
    }

    public static void Launch(string flag)
    {
        try { Process.Start(new ProcessStartInfo(Exe, flag) { UseShellExecute = false, WorkingDirectory = Folder }); }
        catch (Exception e) { Log.Debug($"setup: launch failed {e.GetType().Name}"); }
    }

    /// Removes the app; the records, settings and key too unless `keepRecords`. The folder itself
    /// goes once this process has exited (a running exe can't delete itself): RemoveFolderLater.
    public static void Uninstall(bool keepRecords)
    {
        QuitRunning();
        AutoStart.Set(Exe, false);
        foreach (var f in Shortcuts()) try { File.Delete(f); } catch { }
        try { Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, throwOnMissingSubKey: false); } catch { }
        if (!keepRecords) try { Directory.Delete(Paths.Root, recursive: true); } catch (Exception e) { Log.Debug($"setup: records not removed {e.GetType().Name}"); }
        Log.Debug($"setup: uninstalled, records {(keepRecords ? "kept" : "removed")}");
    }

    /// A hidden cmd that waits for this process to go, then deletes the install folder.
    public static void RemoveFolderLater()
    {
        if (!Directory.Exists(Folder)) return;
        var script = $"ping -n 3 127.0.0.1 >nul & rmdir /s /q \"{Folder}\"";
        try
        {
            Process.Start(new ProcessStartInfo("cmd.exe", $"/d /c \"{script}\"")
            {
                UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetTempPath(),
            });
        }
        catch (Exception e) { Log.Debug($"setup: folder removal failed {e.GetType().Name}"); }
    }

    static IEnumerable<string> Shortcuts()
    {
        var menu = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
        return SetupPlan.ShortcutNames.Select(n => Path.Combine(menu, n + ".lnk"));
    }

    static void Shortcut()
    {
        foreach (var f in Shortcuts()) File.Delete(f);
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), SetupPlan.ShortcutName(Strings.Language) + ".lnk");
        var link = (IShellLinkW)new ShellLink();
        try
        {
            link.SetPath(Exe);
            link.SetWorkingDirectory(Folder);
            link.SetIconLocation(Exe, 0);
            link.SetDescription(SetupPlan.DisplayName);
            ((System.Runtime.InteropServices.ComTypes.IPersistFile)link).Save(path, true);
        }
        finally { Marshal.FinalReleaseComObject(link); }
    }

    /// Settings › Apps: no 修改 or 修复, just 卸载.
    static void Register()
    {
        using var k = Registry.CurrentUser.CreateSubKey(UninstallKey);
        k.SetValue("DisplayName", SetupPlan.DisplayName);
        k.SetValue("DisplayVersion", Controller.Version);
        k.SetValue("Publisher", "wquguru");
        k.SetValue("DisplayIcon", $"{Exe},0");
        k.SetValue("InstallLocation", Folder);
        k.SetValue("UninstallString", $"\"{Exe}\" --uninstall");
        k.SetValue("QuietUninstallString", $"\"{Exe}\" --uninstall");
        k.SetValue("URLInfoAbout", "https://cicada.indaloop.app");
        k.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"));
        k.SetValue("EstimatedSize", (int)(new FileInfo(Exe).Length / 1024), RegistryValueKind.DWord);
        k.SetValue("NoModify", 1, RegistryValueKind.DWord);
        k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")] class ShellLink { }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
    interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int size, IntPtr data, int flags);
        void GetIDList(out IntPtr list);
        void SetIDList(IntPtr list);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, int size);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder dir, int size);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder args, int size);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short key);
        void SetHotkey(short key);
        void GetShowCmd(out int cmd);
        void SetShowCmd(int cmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int size, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, int reserved);
        void Resolve(IntPtr hwnd, int flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
    }
}
