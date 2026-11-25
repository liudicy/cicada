using System.Runtime.InteropServices;

namespace Cicada.App;

/// 会议室: a microphone as a listening source, 16 kHz mono (Windows converts), handed on as it comes
/// in (DeviceRecorder keeps it all instead). A device pulled out or switched off ends its stream:
/// the room mic is picked again and capture goes on, so the room doesn't go quiet for the rest of
/// the meeting. Ends with "denied" when Windows' microphone privacy switch is off for desktop apps,
/// "none" when no microphone is left.
sealed class MicSource : IAudioSource
{
    readonly Func<Endpoints.Device?> pick;
    Thread? thread;
    volatile bool running;
    public event Action<short[]>? Samples;
    public event Action<string?>? Ended;
    /// The microphone in use.
    public string? DeviceName { get; private set; }

    public MicSource(Func<Endpoints.Device?> pick) { this.pick = pick; }

    public void Start()
    {
        running = true;
        thread = new Thread(Run) { IsBackground = true, Name = "MicSource", Priority = ThreadPriority.AboveNormal };
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
    }

    public void Stop()
    {
        running = false;
        thread?.Join(1000);
    }

    void Run()
    {
        int failures = 0;
        while (running)
        {
            if (pick() is not { } device) { Log.Debug("mic: no microphone"); Ended?.Invoke("none"); return; }
            DeviceName = device.Name;
            var started = DateTime.UtcNow;
            try { Capture(device.Id); return; }
            catch (Exception e) when (e.HResult == unchecked((int)0x80070005))
            {
                Log.Debug("mic: denied by Windows' microphone privacy setting");
                Ended?.Invoke("denied");
                return;
            }
            catch (Exception e)
            {
                // 0x88890004 AUDCLNT_E_DEVICE_INVALIDATED: unplugged, disabled, or its format changed.
                Log.Debug($"mic: {device.Name} stopped 0x{e.HResult:X8}, picking the room mic again");
                failures = DateTime.UtcNow - started > TimeSpan.FromSeconds(10) ? 1 : failures + 1;
                if (failures > 5) { Ended?.Invoke(e.Message); return; }
                Thread.Sleep(300 * failures);
            }
        }
    }

    void Capture(string id)
    {
        IAudioClient? client = null;
        try
        {
            client = Endpoints.Activate(id);
            var fmt = Endpoints.Pcm16(16000);
            // A 1 s buffer, as the system tap's: a capture thread held up a moment loses nothing.
            int hr = client.Initialize(0, Endpoints.AutoConvert, 10_000_000, 0, fmt, IntPtr.Zero);
            Marshal.FreeHGlobal(fmt);
            Marshal.ThrowExceptionForHR(hr);
            var iid = typeof(IAudioCaptureClient).GUID;
            Marshal.ThrowExceptionForHR(client.GetService(ref iid, out var s));
            var cap = (IAudioCaptureClient)s;
            Marshal.ThrowExceptionForHR(client.Start());
            Log.Debug($"mic: capturing {DeviceName}");
            while (running)
            {
                Thread.Sleep(20);
                while (true)
                {
                    Marshal.ThrowExceptionForHR(cap.GetNextPacketSize(out var n));
                    if (n == 0) break;
                    Marshal.ThrowExceptionForHR(cap.GetBuffer(out var data, out var frames, out var flags, out _, out _));
                    var buf = new short[frames];
                    if ((flags & 0x2) == 0) Marshal.Copy(data, buf, 0, (int)frames);
                    cap.ReleaseBuffer(frames);
                    if (frames > 0) Samples?.Invoke(buf);
                }
            }
            client.Stop();
        }
        finally { if (client is not null) Marshal.ReleaseComObject(client); }
    }
}
