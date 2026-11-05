using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace Cicada.App;

/// Win32 bits WPF doesn't expose: windows that never take focus and stay out of screen captures,
/// and DPAPI for the key file.
static class Native
{
    const int GWL_EXSTYLE = -20;
    const long WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x00000080, WS_EX_TOPMOST = 0x00000008;
    const int WM_MOUSEACTIVATE = 0x0021, MA_NOACTIVATE = 3;
    const uint WDA_NONE = 0, WDA_EXCLUDEFROMCAPTURE = 0x11;

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
    [DllImport("user32.dll")] static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);
    [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(int processId);

    /// A second launch has the foreground (the user just opened it); this lets the running Cicada
    /// bring its records window forward instead of flashing in the taskbar behind other windows.
    public static void LetOthersTakeForeground() => AllowSetForegroundWindow(-1 /* ASFW_ANY */);

    /// Makes a window like the Mac's non-activating panel: clicks and drags work, but the app the
    /// user is in keeps the keyboard focus, and the window isn't in Alt+Tab or the taskbar.
    public static void MakeNonActivating(Window window)
    {
        var hwnd = new WindowInteropHelper(window).EnsureHandle();
        var ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64();
        SetWindowLongPtr(hwnd, GWL_EXSTYLE, new IntPtr(ex | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST));
        HwndSource.FromHwnd(hwnd)?.AddHook((IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled) =>
        {
            if (msg == WM_MOUSEACTIVATE) { handled = true; return new IntPtr(MA_NOACTIVATE); }
            return IntPtr.Zero;
        });
    }

    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    [DllImport("dwmapi.dll")] static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins margins);
    [StructLayout(LayoutKind.Sequential)] struct Margins { public int Left, Right, Top, Bottom; }

    /// A frameless window drawn by DWM: Windows 11's rounded corners and soft shadow, composited on
    /// the GPU. (A transparent WPF window would have to draw its own shadow, in software, on every
    /// change.) On Windows 10 the corners stay square.
    public static void UseSystemFrame(Window window, bool dark = false)
    {
        var hwnd = new WindowInteropHelper(window).EnsureHandle();
        int round = 2; // DWMWCP_ROUND
        DwmSetWindowAttribute(hwnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, ref round, sizeof(int));
        int on = dark ? 1 : 0;
        DwmSetWindowAttribute(hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, ref on, sizeof(int));
        // A one-pixel frame margin is what gives a frameless window DWM's shadow.
        var m = new Margins { Left = 0, Right = 0, Top = 1, Bottom = 0 };
        DwmExtendFrameIntoClientArea(hwnd, ref m);
    }

    /// Out of screenshots and screen sharing (Windows 10 2004+), unless the user lets the other side see it.
    public static bool SetCaptureVisible(Window window, bool visible)
    {
        var hwnd = new WindowInteropHelper(window).EnsureHandle();
        var ok = SetWindowDisplayAffinity(hwnd, visible ? WDA_NONE : WDA_EXCLUDEFROMCAPTURE);
        if (!ok) Log.Debug($"window: display affinity failed {Marshal.GetLastWin32Error()}");
        return ok;
    }
}

/// DPAPI, current user: the key file can only be opened by this Windows account.
sealed class DpapiProtector : IKeyProtector
{
    public string Tag => "dpapi";

    [StructLayout(LayoutKind.Sequential)]
    struct Blob { public int cbData; public IntPtr pbData; }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CryptProtectData(ref Blob input, string? description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CryptUnprotectData(ref Blob input, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr mem);

    const int CRYPTPROTECT_UI_FORBIDDEN = 0x1;

    public byte[] Protect(byte[] data) => Run(data, protect: true);
    public byte[] Unprotect(byte[] data) => Run(data, protect: false);

    static byte[] Run(byte[] data, bool protect)
    {
        var handle = GCHandle.Alloc(data, GCHandleType.Pinned);
        try
        {
            var input = new Blob { cbData = data.Length, pbData = handle.AddrOfPinnedObject() };
            bool ok = protect
                ? CryptProtectData(ref input, "Cicada Ling key", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, CRYPTPROTECT_UI_FORBIDDEN, out var output)
                : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, CRYPTPROTECT_UI_FORBIDDEN, out output);
            if (!ok) throw new InvalidOperationException($"DPAPI failed {Marshal.GetLastWin32Error()}");
            var result = new byte[output.cbData];
            Marshal.Copy(output.pbData, result, 0, output.cbData);
            LocalFree(output.pbData);
            return result;
        }
        finally { handle.Free(); }
    }
}
