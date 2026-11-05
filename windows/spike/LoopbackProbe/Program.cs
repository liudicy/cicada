// M0 spike: can Windows give us "everything the PC plays, except Cicada itself", the way the
// Core Audio process tap does on the Mac? Captures with WASAPI process loopback while this process
// plays a 1 kHz tone of its own, then checks the tone is absent from the capture (and, with
// --include-self, present: proof the check works). Writes 16 kHz mono Int16 WAV, the format the
// Windows AudioRouter will hand to Ming.
//
//   LoopbackProbe.exe [seconds] [--include-self] [--no-tone] [--out capture.wav]
//
// Needs Windows 10 2004 (build 19041) or later.
using System.Runtime.InteropServices;

static class Program
{
    const int Rate = 16000;
    const double ToneHz = 1000, ToneAmp = 0.3;

    static int Main(string[] args)
    {
        int seconds = 15;
        bool includeSelf = args.Contains("--include-self"), tone = !args.Contains("--no-tone");
        string output = "capture.wav";
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--out" && i + 1 < args.Length) output = args[++i];
            else if (int.TryParse(args[i], out var s)) seconds = s;
        }
        Console.WriteLine($"Windows {Environment.OSVersion.Version}, {RuntimeInformation.OSArchitecture}, process {RuntimeInformation.ProcessArchitecture}");
        if (Environment.OSVersion.Version.Build < 19041) { Console.WriteLine("Process loopback needs build 19041 or later."); return 2; }

        GCHandle? toneHandle = tone ? Tone.Start() : null;
        Console.WriteLine(tone ? "Playing a quiet 1 kHz tone from this process (should NOT be captured)." : "No self tone.");
        Console.WriteLine($"Mode: {(includeSelf ? "include this process only (control run)" : "everything except this process")}");
        Console.WriteLine($"Play something now (e.g. sample.m4a in Media Player). Capturing {seconds} s...");

        short[] pcm;
        try { pcm = Loopback.Capture(seconds, includeSelf); }
        catch (Exception e) { Console.WriteLine($"FAILED: {e.Message} (0x{e.HResult:X8})"); return 1; }
        finally { if (toneHandle is { } h) Tone.Stop(h); }

        Wav.Write(output, pcm, Rate);
        var (rms, toneLevel) = Analysis.Run(pcm, Rate, ToneHz, ToneAmp);
        Console.WriteLine($"Wrote {output}: {pcm.Length / (double)Rate:F1} s, RMS {rms:F4} ({(rms >= 0.01 ? "sound captured" : "near silence")})");
        if (tone)
        {
            bool leaked = toneLevel > 0.1;
            Console.WriteLine($"Self tone in capture: {toneLevel:P0} of what was played -> {(leaked ? "PRESENT" : "absent")}");
            bool pass = includeSelf ? leaked : !leaked;
            Console.WriteLine(pass ? "PASS" : "FAIL: " + (includeSelf ? "control run should hear the tone" : "Cicada would hear itself"));
            return pass ? 0 : 3;
        }
        return 0;
    }
}

/// WASAPI process loopback: ActivateAudioInterfaceAsync on the virtual loopback device, with
/// this process's tree excluded (or, for the control run, the only one included).
static class Loopback
{
    const string LoopbackDevice = "VAD\\Process_Loopback";
    const int SharedMode = 0;
    const uint StreamLoopback = 0x00020000, StreamEventCallback = 0x00040000,
               AutoConvertPcm = 0x80000000, SrcDefaultQuality = 0x08000000;
    const uint BufferSilent = 0x2;

    public static short[] Capture(int seconds, bool includeSelf)
    {
        var client = Activate((uint)Environment.ProcessId, includeSelf ? 0 : 1);
        // Process loopback has no mix format (GetMixFormat is E_NOTIMPL): ask for what Ming wants
        // and let Windows convert; fall back to 48 kHz stereo and convert ourselves.
        (int rate, int channels)[] tries = [(16000, 1), (48000, 2), (44100, 2)];
        int rate = 0, channels = 0, hr = -1;
        foreach (var (r, c) in tries)
        {
            var fmt = WaveFormat.Pcm16(r, c);
            var p = Marshal.AllocHGlobal(Marshal.SizeOf<WaveFormat>());
            Marshal.StructureToPtr(fmt, p, false);
            hr = client.Initialize(SharedMode, StreamLoopback | StreamEventCallback | AutoConvertPcm | SrcDefaultQuality,
                                   200_000, 0, p, IntPtr.Zero);
            Marshal.FreeHGlobal(p);
            Console.WriteLine($"  Initialize {r} Hz x{c}: 0x{hr:X8}");
            if (hr == 0) { rate = r; channels = c; break; }
            client = Activate((uint)Environment.ProcessId, includeSelf ? 0 : 1); // a failed Initialize spoils the client
        }
        Marshal.ThrowExceptionForHR(hr);

        using var ready = new AutoResetEvent(false);
        Marshal.ThrowExceptionForHR(client.SetEventHandle(ready.SafeWaitHandle.DangerousGetHandle()));
        var iid = typeof(IAudioCaptureClient).GUID;
        Marshal.ThrowExceptionForHR(client.GetService(ref iid, out var service));
        var capture = (IAudioCaptureClient)service;
        Marshal.ThrowExceptionForHR(client.Start());

        var raw = new List<short>();
        var end = DateTime.UtcNow.AddSeconds(seconds);
        long frames = 0;
        while (DateTime.UtcNow < end)
        {
            ready.WaitOne(100); // no events while nothing plays; keep the clock running
            while (capture.GetNextPacketSize(out var packet) == 0 && packet > 0)
            {
                Marshal.ThrowExceptionForHR(capture.GetBuffer(out var data, out var n, out var flags, out _, out _));
                int count = (int)n * channels;
                if ((flags & BufferSilent) != 0) raw.AddRange(new short[count]);
                else { var buf = new short[count]; Marshal.Copy(data, buf, 0, count); raw.AddRange(buf); }
                capture.ReleaseBuffer(n);
                frames += n;
            }
        }
        client.Stop();
        Console.WriteLine($"  captured {frames} frames at {rate} Hz x{channels}");
        // Loopback only delivers packets while something plays, so pad to wall-clock length is
        // not attempted: the WAV holds what was heard, back to back.
        return Resample.ToMono16k(raw.ToArray(), rate, channels);
    }

    static IAudioClient Activate(uint pid, int mode)
    {
        var p = new ActivationParams { ActivationType = 1, TargetProcessId = pid, ProcessLoopbackMode = mode };
        int size = Marshal.SizeOf<ActivationParams>();
        var blob = Marshal.AllocHGlobal(size);
        Marshal.StructureToPtr(p, blob, false);
        var variant = new PropVariantBlob { vt = 65 /* VT_BLOB */, cbSize = (uint)size, pBlobData = blob };
        var handler = new Completion();
        var iid = typeof(IAudioClient).GUID;
        try
        {
            Marshal.ThrowExceptionForHR(ActivateAudioInterfaceAsync(LoopbackDevice, ref iid, ref variant, handler, out var op));
            if (!handler.Done.Wait(5000)) throw new TimeoutException("activation did not complete");
            Marshal.ThrowExceptionForHR(op.GetActivateResult(out var hr, out var iface));
            Marshal.ThrowExceptionForHR(hr);
            return (IAudioClient)iface;
        }
        finally { Marshal.FreeHGlobal(blob); }
    }

    [DllImport("Mmdevapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    static extern int ActivateAudioInterfaceAsync(string path, ref Guid riid, ref PropVariantBlob activationParams,
        IActivateAudioInterfaceCompletionHandler handler, out IActivateAudioInterfaceAsyncOperation op);

    // The handler must be agile or activation fails with E_ILLEGAL_METHOD_CALL.
    [ComVisible(true)]
    sealed class Completion : IActivateAudioInterfaceCompletionHandler, IAgileObject
    {
        public readonly ManualResetEventSlim Done = new(false);
        public int ActivateCompleted(IActivateAudioInterfaceAsyncOperation op) { Done.Set(); return 0; }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ActivationParams { public int ActivationType; public uint TargetProcessId; public int ProcessLoopbackMode; }

    [StructLayout(LayoutKind.Explicit)]
    struct PropVariantBlob
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public uint cbSize;
        [FieldOffset(16)] public IntPtr pBlobData;
    }
}

[StructLayout(LayoutKind.Sequential, Pack = 2)]
struct WaveFormat
{
    public ushort wFormatTag, nChannels; public uint nSamplesPerSec, nAvgBytesPerSec;
    public ushort nBlockAlign, wBitsPerSample, cbSize;
    public static WaveFormat Pcm16(int rate, int channels) => new()
    {
        wFormatTag = 1, nChannels = (ushort)channels, nSamplesPerSec = (uint)rate,
        nBlockAlign = (ushort)(channels * 2), nAvgBytesPerSec = (uint)(rate * channels * 2), wBitsPerSample = 16,
    };
}

[ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioClient
{
    [PreserveSig] int Initialize(int shareMode, uint streamFlags, long bufferDuration, long periodicity, IntPtr format, IntPtr sessionGuid);
    [PreserveSig] int GetBufferSize(out uint frames);
    [PreserveSig] int GetStreamLatency(out long latency);
    [PreserveSig] int GetCurrentPadding(out uint padding);
    [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
    [PreserveSig] int GetMixFormat(out IntPtr format);
    [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
    [PreserveSig] int Start();
    [PreserveSig] int Stop();
    [PreserveSig] int Reset();
    [PreserveSig] int SetEventHandle(IntPtr handle);
    [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
}

[ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioCaptureClient
{
    [PreserveSig] int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devicePosition, out ulong qpcPosition);
    [PreserveSig] int ReleaseBuffer(uint frames);
    [PreserveSig] int GetNextPacketSize(out uint frames);
}

[ComImport, Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IActivateAudioInterfaceAsyncOperation
{
    [PreserveSig] int GetActivateResult(out int hr, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
}

[ComImport, Guid("41D949AB-9862-444A-80F6-C261334DA5EB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IActivateAudioInterfaceCompletionHandler
{
    [PreserveSig] int ActivateCompleted(IActivateAudioInterfaceAsyncOperation op);
}

[ComImport, Guid("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAgileObject { }

/// A looping tone played by this process through winmm, so the excluded tree makes a sound.
static class Tone
{
    const uint SndAsync = 0x1, SndMemory = 0x4, SndLoop = 0x8;

    public static GCHandle Start()
    {
        const int rate = 16000;
        var samples = new short[rate]; // 1 s, a whole number of cycles so the loop has no click
        for (int i = 0; i < samples.Length; i++)
            samples[i] = (short)(Math.Sin(2 * Math.PI * 1000 * i / rate) * 0.3 * short.MaxValue);
        var handle = GCHandle.Alloc(Wav.Bytes(samples, rate), GCHandleType.Pinned); // must outlive async playback
        PlaySound(handle.AddrOfPinnedObject(), IntPtr.Zero, SndAsync | SndMemory | SndLoop);
        Thread.Sleep(300);
        return handle;
    }

    public static void Stop(GCHandle handle) { PlaySound(IntPtr.Zero, IntPtr.Zero, 0); handle.Free(); }

    [DllImport("winmm.dll")] static extern bool PlaySound(IntPtr sound, IntPtr module, uint flags);
}

static class Resample
{
    public static short[] ToMono16k(short[] interleaved, int rate, int channels)
    {
        int frames = interleaved.Length / channels;
        var mono = new double[frames];
        for (int f = 0; f < frames; f++)
        {
            double sum = 0;
            for (int c = 0; c < channels; c++) sum += interleaved[f * channels + c];
            mono[f] = sum / channels;
        }
        if (rate == 16000) return mono.Select(x => (short)x).ToArray();
        // Spike-grade resampling: box-average then linear interpolation; the app will use Media Foundation.
        int window = Math.Max(1, rate / 16000);
        int outCount = (int)((long)frames * 16000 / rate);
        var output = new short[outCount];
        for (int i = 0; i < outCount; i++)
        {
            double pos = (double)i * rate / 16000;
            int start = (int)pos, stop = Math.Min(frames, start + window);
            double sum = 0; for (int j = start; j < stop; j++) sum += mono[j];
            output[i] = (short)(sum / Math.Max(1, stop - start));
        }
        return output;
    }
}

static class Analysis
{
    /// Overall RMS (0–1) and the 1 kHz tone's amplitude relative to what was played, from
    /// Goertzel over 100 ms blocks, taking the loudest-tone block's median to ignore gaps.
    public static (double rms, double toneLevel) Run(short[] pcm, int rate, double hz, double playedAmp)
    {
        if (pcm.Length == 0) return (0, 0);
        double sq = 0; foreach (var s in pcm) sq += (double)s * s;
        double rms = Math.Sqrt(sq / pcm.Length) / 32768;
        int n = rate / 10;
        var levels = new List<double>();
        double k = 2 * Math.Cos(2 * Math.PI * hz / rate);
        for (int b = 0; b + n <= pcm.Length; b += n)
        {
            double s1 = 0, s2 = 0;
            for (int i = 0; i < n; i++) { double s0 = pcm[b + i] / 32768.0 + k * s1 - s2; s2 = s1; s1 = s0; }
            double power = s1 * s1 + s2 * s2 - k * s1 * s2;
            levels.Add(2 * Math.Sqrt(power) / n / playedAmp);
        }
        levels.Sort();
        return (rms, levels.Count == 0 ? 0 : levels[levels.Count / 2]);
    }
}

static class Wav
{
    public static byte[] Bytes(short[] pcm, int rate)
    {
        using var ms = new MemoryStream();
        using var w = new BinaryWriter(ms);
        w.Write("RIFF"u8); w.Write(36 + pcm.Length * 2); w.Write("WAVEfmt "u8); w.Write(16);
        w.Write((short)1); w.Write((short)1); w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16);
        w.Write("data"u8); w.Write(pcm.Length * 2);
        foreach (var s in pcm) w.Write(s);
        w.Flush();
        return ms.ToArray();
    }

    public static void Write(string path, short[] pcm, int rate) => File.WriteAllBytes(path, Bytes(pcm, rate));
}
