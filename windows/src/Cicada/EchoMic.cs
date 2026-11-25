using System.Runtime.InteropServices;

namespace Cicada.App;

/// The talk key's microphone through Windows' echo cancellation (VoiceMic.swift on the Mac): a
/// WASAPI capture stream in the communications category, so the endpoint's AEC (its driver's, or
/// Windows 11's Voice Clarity) takes the meeting playing on the speakers out of what I say. From
/// build 22621 the AEC is pointed at those speakers; from 22000 the stream says which effects run
/// (`EchoCancel.InEffect`). Records at 16 kHz mono until Stop, like DeviceRecorder.
///
/// EchoCancelled is true only when the stream lists an AEC that is on: then SpeakEngine skips the
/// echo drop. Otherwise (Windows 10, a driver without AEC, a virtual mic) the press is the plain
/// mic's and is dropped as before when the meeting played through it.
sealed class EchoMic
{
    readonly string id;
    readonly string? reference;
    readonly List<short> samples = [];
    Thread? thread;
    volatile bool running;
    /// "denied" (Windows' microphone privacy switch), or why the stream wouldn't open.
    public string? Error { get; private set; }
    public bool EchoCancelled { get; private set; }
    /// For the log: what Windows said about echo cancellation on this stream.
    public string Detail { get; private set; } = "";

    /// `reference`: the render endpoint the meeting plays on; null leaves the choice to Windows.
    public EchoMic(string id, string? reference) { this.id = id; this.reference = reference; }

    public void Start()
    {
        running = true;
        var ready = new ManualResetEventSlim();
        thread = new Thread(() => Run(ready)) { IsBackground = true, Name = "EchoMic" };
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
        ready.Wait(2000);
    }

    public short[] Stop()
    {
        running = false;
        thread?.Join(1500);
        lock (samples) return [.. samples];
    }

    void Run(ManualResetEventSlim ready)
    {
        IAudioClient? client = null;
        try
        {
            client = Endpoints.Activate(id);
            // Before Initialize: the category picks the endpoint's communications processing.
            // Options stay 0: RAW would turn off the very processing wanted here.
            var props = new AudioClientProperties { cbSize = 16, bIsOffload = 0, eCategory = 3 /* AudioCategory_Communications */, Options = 0 };
            Marshal.ThrowExceptionForHR(((IAudioClient2)client).SetClientProperties(ref props));
            var fmt = Endpoints.Pcm16(16000);
            int hr = client.Initialize(0, Endpoints.AutoConvert, 2_000_000, 0, fmt, IntPtr.Zero);
            Marshal.FreeHGlobal(fmt);
            Marshal.ThrowExceptionForHR(hr);
            var notes = new List<string>();
            // The speakers the meeting plays on as the AEC's reference (22621+). E_NOINTERFACE: no
            // AEC here, or one that picks its own reference; neither is an error.
            var iid = typeof(IAcousticEchoCancellationControl).GUID;
            if (client.GetService(ref iid, out var c) == 0 && c is IAcousticEchoCancellationControl control)
            {
                var set = control.SetEchoCancellationRenderEndpoint(reference);
                if (set != 0 && reference is not null) set = control.SetEchoCancellationRenderEndpoint(null);
                notes.Add(set == 0 ? $"reference {(reference is null ? "Windows' choice" : "the speakers")}" : $"reference failed 0x{set:X8}");
            }
            else notes.Add("no reference control");
            var effects = Effects(client, notes);
            EchoCancelled = EchoCancel.InEffect(effects);
            notes.Insert(0, effects is null ? "no effects list" : $"effects [{string.Join(", ", effects.Select(Name))}]");
            Detail = string.Join(", ", notes);
            iid = typeof(IAudioCaptureClient).GUID;
            Marshal.ThrowExceptionForHR(client.GetService(ref iid, out var s));
            var cap = (IAudioCaptureClient)s;
            Marshal.ThrowExceptionForHR(client.Start());
            ready.Set();
            while (running)
            {
                Thread.Sleep(10);
                while (cap.GetNextPacketSize(out var n) == 0 && n > 0)
                {
                    if (cap.GetBuffer(out var data, out var frames, out var flags, out _, out _) != 0) break;
                    var buf = new short[frames];
                    if ((flags & 0x2) == 0) Marshal.Copy(data, buf, 0, (int)frames);
                    cap.ReleaseBuffer(frames);
                    lock (samples) samples.AddRange(buf);
                }
            }
            client.Stop();
        }
        catch (Exception e)
        {
            // 0x80070005: Windows' microphone privacy switch is off for desktop apps.
            Error = e.HResult == unchecked((int)0x80070005) ? "denied" : $"0x{e.HResult:X8}";
            EchoCancelled = false;
            Log.Debug($"echo mic: failed 0x{e.HResult:X8}");
            ready.Set();
        }
        finally { if (client is not null) Marshal.ReleaseComObject(client); }
    }

    /// The stream's effects (22000+), with an AEC that is off but may be set turned on first; null
    /// when Windows can't list them.
    static List<EchoCancel.AudioEffect>? Effects(IAudioClient client, List<string> notes)
    {
        var iid = typeof(IAudioEffectsManager).GUID;
        if (client.GetService(ref iid, out var o) != 0 || o is not IAudioEffectsManager manager) return null;
        var list = Read(manager);
        if (list is not null && EchoCancel.CanTurnOn(list))
        {
            var hr = manager.SetAudioEffectState(EchoCancel.Effect, 1 /* AUDIO_EFFECT_STATE_ON */);
            notes.Add(hr == 0 ? "turned AEC on" : $"AEC on failed 0x{hr:X8}");
            list = Read(manager);
        }
        return list;
    }

    static List<EchoCancel.AudioEffect>? Read(IAudioEffectsManager manager)
    {
        if (manager.GetAudioEffects(out var p, out var n) != 0) return null;
        var list = new List<EchoCancel.AudioEffect>();
        try
        {
            // AUDIO_EFFECT: GUID id, BOOL canSetState, AUDIO_EFFECT_STATE state: 24 bytes.
            for (int i = 0; i < n; i++)
            {
                var e = Marshal.PtrToStructure<AudioEffect>(p + i * Marshal.SizeOf<AudioEffect>());
                list.Add(new(e.id, e.canSetState != 0, e.state == 1));
            }
        }
        finally { if (p != IntPtr.Zero) Marshal.FreeCoTaskMem(p); }
        return list;
    }

    static string Name(EchoCancel.AudioEffect e) =>
        (e.Id == EchoCancel.Effect ? "AEC" : e.Id.ToString()[..8]) + (e.On ? " on" : " off");

    // MARK: COM (audioclient.h, Windows SDK 10.0.22621). Nested so they can't meet other declarations.

    [StructLayout(LayoutKind.Sequential)]
    struct AudioClientProperties { public uint cbSize; public int bIsOffload; public int eCategory; public int Options; }

    [StructLayout(LayoutKind.Sequential)]
    struct AudioEffect { public Guid id; public int canSetState; public int state; }

    /// IAudioClient's methods again, in order: a ComImport interface doesn't inherit vtable slots.
    [ComImport, Guid("726778CD-F60A-4eda-82DE-E47610CD78AA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient2
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
        [PreserveSig] int IsOffloadCapable(int category, out int capable);
        [PreserveSig] int SetClientProperties(ref AudioClientProperties properties);
        [PreserveSig] int GetBufferSizeLimits(IntPtr format, int eventDriven, out long min, out long max);
    }

    [ComImport, Guid("f4ae25b5-aaa3-437d-b6b3-dbbe2d0e9549"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAcousticEchoCancellationControl
    {
        [PreserveSig] int SetEchoCancellationRenderEndpoint([MarshalAs(UnmanagedType.LPWStr)] string? endpointId);
    }

    [ComImport, Guid("4460B3AE-4B44-4527-8676-7548A8ACD260"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEffectsManager
    {
        [PreserveSig] int RegisterAudioEffectsChangedNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterAudioEffectsChangedNotificationCallback(IntPtr client);
        [PreserveSig] int GetAudioEffects(out IntPtr effects, out uint count);
        [PreserveSig] int SetAudioEffectState(Guid effectId, int state);
    }
}
