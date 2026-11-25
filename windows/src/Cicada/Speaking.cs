using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;

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

/// Hold the talk key (right Ctrl unless changed) to talk, anywhere. RegisterHotKey can't see a key
/// being let go, so this is a low-level keyboard hook. A modifier talk key is passed on to other
/// apps and only counts held alone: another key pressed meanwhile (Ctrl C) ends the press as
/// Interrupted. Any other talk key (Caps Lock, F13…) is kept from them. (Alt can't be one: released
/// alone it opens the window's menu, and right Alt is AltGr on many keyboards.)
sealed class PushToTalk : IDisposable
{
    /// The key in use, read by every label that names it.
    public static TalkKey.Key Current { get; set; } = TalkKey.Named(null);
    public static string Label => Strings.L(Current.Label);
    const int WhKeyboardLl = 13, WmKeyDown = 0x100, WmKeyUp = 0x101, WmSysKeyDown = 0x104, WmSysKeyUp = 0x105;
    readonly HookProc proc; // held, or the GC collects it and Windows calls freed memory
    readonly IntPtr hook;
    bool down, combo;
    public event Action? Pressed, Released, Interrupted;
    /// Choosing a new talk key: the next key pressed comes here (its virtual-key code) and until
    /// then no key reaches any app. Whoever sets it clears it when the choosing ends.
    public Action<int>? Capture;

    // 同声传译 on: with it off a Caps Lock or F5 talk key goes on working as itself.
    readonly Func<bool> enabled;

    public PushToTalk(Func<bool> enabled)
    {
        this.enabled = enabled;
        proc = Hook;
        hook = SetWindowsHookEx(WhKeyboardLl, proc, GetModuleHandle(null), 0);
        Log.Debug($"push to talk: {(hook == IntPtr.Zero ? "hook failed" : "ready")} {Current.Name}");
    }

    IntPtr Hook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0)
        {
            var vk = Marshal.ReadInt32(lParam);
            var msg = wParam.ToInt32();
            bool isDown = msg is WmKeyDown or WmSysKeyDown, isUp = msg is WmKeyUp or WmSysKeyUp;
            if (Capture is { } capture)
            {
                if (isDown) { Capture = null; capture(vk); }
                return 1;
            }
            var key = Current;
            if (!enabled()) { down = false; return CallNextHookEx(hook, code, wParam, lParam); }
            if (vk == key.Vk)
            {
                if (isDown && !down) { down = true; combo = false; Pressed?.Invoke(); }
                else if (isUp && down) { down = false; if (!combo) Released?.Invoke(); }
                if (!key.Modifier) return 1;
            }
            else if (isDown && down && key.Modifier && !combo) { combo = true; Interrupted?.Invoke(); }
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
    /// 电脑没声了？ in onboarding and settings: shown while the cable holds the speaker, one button
    /// gives a real speaker back.
    public static FrameworkElement SpeakerStrip(Window owner, Action changed)
    {
        var text = new StackPanel { Children = { Ui.Text(Strings.L("电脑没声了？"), 14, Palette.Ink), Ui.Text(Strings.L("Windows 把播放设备改成了 CABLE Input"), 13, Palette.WarnIcon) } };
        var strip = Ui.Spread(text, Ui.Button(Strings.L("恢复声音"), () =>
        {
            if (!Endpoints.RestoreSpeaker()) Dialogs.Tell(owner, Strings.L("自动恢复失败"), Strings.L("请去 Windows 声音设置，把输出设备改回你的耳机或扬声器"));
            changed();
        }, Ui.Kind.Primary, height: 32));
        return new Border { Background = Palette.WarnBg, CornerRadius = new CornerRadius(10), Padding = new Thickness(12, 8, 8, 8), Child = strip };
    }

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
        // Windows may hand the new cable the default speaker and mic (CableDefaults): remember them.
        var before = Endpoints.Defaults();
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
            if (Endpoints.Cable() is not null) { Log.Debug("cable: endpoint ready"); await GiveBackDefaults(before); return Result.Installed; }
            await Task.Delay(500);
        }
        return Result.Failed;
    }

    /// Windows switches the default a moment after the endpoint appears, not always at once: look
    /// for a few seconds.
    internal static async Task GiveBackDefaults(Dictionary<string, string> before)
    {
        for (int i = 0; i < 8; i++)
        {
            var cables = Endpoints.CableIds();
            foreach (var (key, id) in CableDefaults.Restore(before, Endpoints.Defaults(), cables.Contains))
                Log.Debug($"cable: default {key} given back {Endpoints.SetDefault(id, int.Parse(key[2..]))}");
            await Task.Delay(500);
        }
    }
}
