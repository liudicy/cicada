using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http;
using System.Runtime.InteropServices;

namespace Cicada.App;

/// Windows' own voice (OneCore), for when Ming's can't speak: always there, no key needed.
sealed class WindowsVoice : ISystemVoice
{
    public async Task<(byte[] pcm, int rate)?> Speak(string text, string language)
    {
        try
        {
            using var synth = new Windows.Media.SpeechSynthesis.SpeechSynthesizer();
            var head = VoiceCatalog.Key(language);
            var voice = Windows.Media.SpeechSynthesis.SpeechSynthesizer.AllVoices
                .Where(v => v.Language.StartsWith(language, StringComparison.OrdinalIgnoreCase) || v.Language.StartsWith(head, StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(v => v.Language.Equals(language, StringComparison.OrdinalIgnoreCase)).FirstOrDefault();
            // No voice for the language: say nothing rather than read it in another language's voice.
            if (voice is null) { Log.Debug($"windows voice: none for {language}"); return null; }
            synth.Voice = voice;
            using var stream = await synth.SynthesizeTextToStreamAsync(text);
            var bytes = new byte[stream.Size];
            using (var reader = new Windows.Storage.Streams.DataReader(stream.GetInputStreamAt(0)))
            {
                await reader.LoadAsync((uint)stream.Size);
                reader.ReadBytes(bytes);
            }
            return Pcm(bytes);
        }
        catch (Exception e) { Log.Debug($"windows voice: failed {e.GetType().Name}"); return null; }
    }

    public bool Has(string language)
    {
        try
        {
            var head = VoiceCatalog.Key(language);
            return Windows.Media.SpeechSynthesis.SpeechSynthesizer.AllVoices.Any(v => v.Language.StartsWith(head, StringComparison.OrdinalIgnoreCase));
        }
        catch { return false; }
    }

    /// The PCM inside a 16-bit WAV, mixed to mono, at its own rate.
    static (byte[], int)? Pcm(byte[] wav)
    {
        if (wav.Length < 44) return null;
        int i = 12, channels = 1, rate = 16000;
        while (i + 8 <= wav.Length)
        {
            var id = System.Text.Encoding.ASCII.GetString(wav, i, 4);
            int size = BitConverter.ToInt32(wav, i + 4);
            if (id == "fmt ") { channels = BitConverter.ToInt16(wav, i + 10); rate = BitConverter.ToInt32(wav, i + 12); }
            else if (id == "data")
            {
                size = Math.Min(size, wav.Length - i - 8);
                int frames = size / 2 / channels;
                var mono = new byte[frames * 2];
                for (int f = 0; f < frames; f++)
                {
                    int sum = 0;
                    for (int c = 0; c < channels; c++) sum += BitConverter.ToInt16(wav, i + 8 + (f * channels + c) * 2);
                    BitConverter.GetBytes((short)(sum / channels)).CopyTo(mono, f * 2);
                }
                return (mono, rate);
            }
            i += 8 + size + (size & 1);
        }
        return null;
    }
}

/// Hold right Ctrl to talk, anywhere. RegisterHotKey can't see a key being let go, so this is a
/// low-level keyboard hook; it only watches right Ctrl and never swallows it. (Right Alt is AltGr
/// on many keyboards, and a lone Alt opens app menus when released.)
sealed class PushToTalk : IDisposable
{
    public static string Label => Strings.L("右 Ctrl");
    const int WhKeyboardLl = 13, WmKeyDown = 0x100, WmKeyUp = 0x101, WmSysKeyDown = 0x104, WmSysKeyUp = 0x105, VkRControl = 0xA3;
    readonly HookProc proc; // held, or the GC collects it and Windows calls freed memory
    readonly IntPtr hook;
    bool down;
    public event Action? Pressed, Released;

    public PushToTalk()
    {
        proc = Hook;
        hook = SetWindowsHookEx(WhKeyboardLl, proc, GetModuleHandle(null), 0);
        Log.Debug($"push to talk: {(hook == IntPtr.Zero ? "hook failed" : "ready")}");
    }

    IntPtr Hook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && Marshal.ReadInt32(lParam) == VkRControl)
        {
            var msg = wParam.ToInt32();
            if ((msg == WmKeyDown || msg == WmSysKeyDown) && !down) { down = true; Pressed?.Invoke(); }
            else if ((msg == WmKeyUp || msg == WmSysKeyUp) && down) { down = false; Released?.Invoke(); }
        }
        return CallNextHookEx(hook, code, wParam, lParam);
    }

    public void Dispose() { if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook); }

    delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string? name);
}

/// Installs VB-Cable: VB-Audio's own package, downloaded when the user asks, checked against the
/// pinned SHA-256 before anything runs, then its installer with Windows' admin prompt.
static class CableInstaller
{
    public enum Result { Installed, DownloadFailed, BadPackage, Declined, Failed }

    public static async Task<Result> Install(Action<string> progress)
    {
        progress(Strings.L("正在下载…"));
        byte[] zip;
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(3) };
            zip = await http.GetByteArrayAsync(VirtualCable.PackageUrl);
        }
        catch (Exception e) { Log.Debug($"cable: download failed {e.GetType().Name}"); return Result.DownloadFailed; }
        if (!VirtualCable.Verify(zip)) { Log.Debug("cable: package hash mismatch, not run"); return Result.BadPackage; }
        var dir = Path.Combine(Path.GetTempPath(), "cicada-vbcable");
        try
        {
            if (Directory.Exists(dir)) Directory.Delete(dir, true);
            using (var ms = new MemoryStream(zip)) ZipFile.ExtractToDirectory(ms, dir);
        }
        catch (Exception e) { Log.Debug($"cable: extract failed {e.GetType().Name}"); return Result.Failed; }
        progress(Strings.L("正在安装…"));
        // The x64 installer also puts the ARM64 driver on Windows on ARM.
        var setup = Path.Combine(dir, Environment.Is64BitOperatingSystem ? "VBCABLE_Setup_x64.exe" : "VBCABLE_Setup.exe");
        try
        {
            using var p = Process.Start(new ProcessStartInfo(setup, "-i -h") { UseShellExecute = true, Verb = "runas", WorkingDirectory = dir });
            if (p is null) return Result.Failed;
            await p.WaitForExitAsync();
            Log.Debug($"cable: setup exited {p.ExitCode}");
        }
        catch (System.ComponentModel.Win32Exception e) when (e.NativeErrorCode == 1223) { return Result.Declined; }
        catch (Exception e) { Log.Debug($"cable: setup failed {e.GetType().Name}"); return Result.Failed; }
        for (int i = 0; i < 40; i++)
        {
            if (Endpoints.Cable() is not null) { Log.Debug("cable: endpoint ready"); return Result.Installed; }
            await Task.Delay(500);
        }
        return Result.Failed;
    }
}
