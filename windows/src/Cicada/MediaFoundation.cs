using System.Runtime.InteropServices;

namespace Cicada.App;

/// 保存会议录音 with Windows' own AAC encoder (Media Foundation's sink writer): no package, nothing
/// to install. The COM calls go through the vtables by slot (the interfaces are long and only a
/// few methods are used), so each `Slot` number below is that method's place in its interface.
unsafe sealed class MediaFoundationAudio : IAudioFiles
{
    // The Mac's recordings are AAC mono at ~32 kbps. Windows 11 encodes 16 kHz at 32 kbps; the
    // encoder's documentation promises only 44.1/48 kHz from 96 kbps, so a PC that refuses gets
    // those, the 16 kHz upsampled by three.
    static readonly (int Rate, uint Bytes)[] Formats = [(16000, 4000), (48000, 4000), (16000, 12000), (48000, 12000)];
    static readonly Lazy<bool> Started = new(() =>
    {
        int hr = MFStartup(0x00020070, 0);
        if (hr != 0) Log.Debug($"audio: Media Foundation unavailable 0x{hr:X8}");
        return hr == 0;
    });
    /// The format the encoder took last time, so later meetings don't try again.
    static (int Rate, uint Bytes)? chosen;

    public IAudioWriter? Open(string path)
    {
        if (!Started.Value) return null;
        foreach (var f in chosen is { } c ? new[] { c } : Formats)
        {
            try
            {
                var w = AacWriter.Create(path, f.Rate, f.Bytes);
                if (chosen is null) Log.Debug($"audio: AAC {f.Rate} Hz, {f.Bytes * 8 / 1000} kbps");
                chosen = f;
                return w;
            }
            catch (Exception e)
            {
                Log.Debug($"audio: AAC {f.Rate} Hz {f.Bytes * 8 / 1000} kbps refused 0x{e.HResult:X8}");
                try { File.Delete(path); } catch { }
            }
        }
        return null;
    }

    /// The ADTS frames into an MP4 track as they are: no re-encoding, so an hour takes a moment.
    public bool Rewrap(string from, string to, double? until)
    {
        if (!Started.Value) return false;
        try
        {
            var file = File.ReadAllBytes(from);
            if (Adts.Read(file) is not { } config) { Log.Debug("audio: rewrap found no AAC frames"); return false; }
            var frames = Adts.Frames(file);
            if (until is { } u) frames = frames.Take((int)Math.Ceiling(u * config.Rate / 1024)).ToList();
            if (frames.Count == 0) return false;
            Write(file, frames, config, to);
            return true;
        }
        catch (Exception e) { Log.Debug($"audio: rewrap failed 0x{e.HResult:X8} {e.Message}"); }
        return false;
    }

    static void Write(byte[] file, List<Adts.Frame> frames, Adts.Config config, string to)
    {
        IntPtr type = 0, writer = 0, attrs = 0;
        try
        {
            long bytes = frames.Sum(f => (long)f.Length);
            double seconds = frames.Count * 1024.0 / config.Rate;
            Check(MFCreateMediaType(out type), "type");
            AacType(type, config.Rate, (uint)(bytes / seconds), (uint)config.Channels);
            SetUInt32(type, PayloadType, 0);
            SetUInt32(type, ProfileLevel, 0x29);
            // HEAACWAVEINFO after its WAVEFORMATEX: raw frames (payload 0), then the AudioSpecificConfig.
            var info = new byte[12 + config.SpecificConfig.Length];
            info[2] = 0x29;
            config.SpecificConfig.CopyTo(info, 12);
            Check(SetBlob(type, UserData, info), "user data");
            Check(MFCreateAttributes(out attrs, 2), "attributes");
            SetGuid(attrs, ContainerType, ContainerMpeg4);
            SetUInt32(attrs, DisableThrottling, 1);
            Check(MFCreateSinkWriterFromURL(to, 0, attrs, out writer), "create");
            uint stream;
            Check(AddStream(writer, type, &stream), "add stream");
            Check(BeginWriting(writer), "begin");
            long duration = 1024L * 10_000_000 / config.Rate;
            for (int i = 0; i < frames.Count; i++)
            {
                IntPtr buffer = 0, sample = 0;
                try
                {
                    var f = frames[i];
                    Check(MFCreateMemoryBuffer((uint)f.Length, out buffer), "buffer");
                    byte* data;
                    uint max, current;
                    Check(Lock(buffer, &data, &max, &current), "lock");
                    file.AsSpan(f.Offset, f.Length).CopyTo(new Span<byte>(data, f.Length));
                    Unlock(buffer);
                    Check(SetCurrentLength(buffer, (uint)f.Length), "length");
                    Check(MFCreateSample(out sample), "sample");
                    Check(AddBuffer(sample, buffer), "add buffer");
                    Check(SetSampleTime(sample, i * 1024L * 10_000_000 / config.Rate), "time");
                    Check(SetSampleDuration(sample, duration), "duration");
                    Check(WriteSample(writer, stream, sample), "write");
                }
                finally
                {
                    if (sample != 0) Release(sample);
                    if (buffer != 0) Release(buffer);
                }
            }
            Check(FinalizeWriter(writer), "finalize");
        }
        finally
        {
            foreach (var p in new[] { type, writer, attrs }) if (p != 0) Release(p);
        }
    }

    static void AacType(IntPtr t, int rate, uint bytes, uint channels = 1)
    {
        SetGuid(t, MajorType, MediaTypeAudio); SetGuid(t, Subtype, FormatAac);
        SetUInt32(t, BitsPerSample, 16); SetUInt32(t, SamplesPerSecond, (uint)rate);
        SetUInt32(t, NumChannels, channels); SetUInt32(t, AvgBytesPerSecond, bytes);
    }

    /// One meeting's ADTS file, 16 kHz mono in.
    sealed class AacWriter : IAudioWriter
    {
        IntPtr writer;
        readonly uint stream;
        readonly int rate;
        long frames;
        short previous;

        AacWriter(IntPtr writer, uint stream, int rate) { this.writer = writer; this.stream = stream; this.rate = rate; }

        public static AacWriter Create(string path, int rate, uint bytes)
        {
            IntPtr attrs = 0, output = 0, input = 0, writer = 0;
            try
            {
                Check(MFCreateAttributes(out attrs, 1), "attributes");
                SetGuid(attrs, ContainerType, ContainerAdts);
                Check(MFCreateSinkWriterFromURL(path, 0, attrs, out writer), "create");
                Check(MFCreateMediaType(out output), "output type");
                AacType(output, rate, bytes);
                uint stream;
                Check(AddStream(writer, output, &stream), "add stream");
                Check(MFCreateMediaType(out input), "input type");
                SetGuid(input, MajorType, MediaTypeAudio); SetGuid(input, Subtype, FormatPcm);
                SetUInt32(input, BitsPerSample, 16); SetUInt32(input, SamplesPerSecond, (uint)rate);
                SetUInt32(input, NumChannels, 1); SetUInt32(input, BlockAlignment, 2);
                SetUInt32(input, AvgBytesPerSecond, (uint)rate * 2);
                Check(SetInputMediaType(writer, stream, input, 0), "input");
                Check(BeginWriting(writer), "begin");
                var w = new AacWriter(writer, stream, rate);
                writer = 0;
                return w;
            }
            finally
            {
                foreach (var p in new[] { attrs, output, input, writer }) if (p != 0) Release(p);
            }
        }

        public void Write(ReadOnlySpan<short> pcm)
        {
            if (writer == 0 || pcm.IsEmpty) return;
            int factor = rate / Segmenter.Rate;
            int count = pcm.Length * factor;
            IntPtr buffer = 0, sample = 0;
            try
            {
                Check(MFCreateMemoryBuffer((uint)count * 2, out buffer), "buffer");
                byte* data;
                uint max, current;
                Check(Lock(buffer, &data, &max, &current), "lock");
                var o = (short*)data;
                if (factor == 1) pcm.CopyTo(new Span<short>(o, count));
                else
                    // Straight lines between the 16 kHz samples: the encoder's low-pass does the rest.
                    for (int i = 0, j = 0; i < pcm.Length; i++)
                    {
                        int a = previous, b = pcm[i];
                        for (int k = 1; k <= factor; k++) o[j++] = (short)(a + (b - a) * k / factor);
                        previous = pcm[i];
                    }
                Unlock(buffer);
                Check(SetCurrentLength(buffer, (uint)count * 2), "length");
                Check(MFCreateSample(out sample), "sample");
                Check(AddBuffer(sample, buffer), "add buffer");
                Check(SetSampleTime(sample, frames * 10_000_000 / rate), "time");
                Check(SetSampleDuration(sample, (long)count * 10_000_000 / rate), "duration");
                Check(WriteSample(writer, stream, sample), "write");
                frames += count;
            }
            finally
            {
                if (sample != 0) Release(sample);
                if (buffer != 0) Release(buffer);
            }
        }

        public void Close()
        {
            var w = writer;
            writer = 0;
            if (w == 0) return;
            try { Check(FinalizeWriter(w), "finalize"); }
            finally { Release(w); }
        }
    }

    static void Check(int hr, string what)
    {
        if (hr < 0) throw new COMException(what, hr);
    }

    // MARK: COM by vtable slot

    static void* Slot(IntPtr p, int i) => (*(void***)p)[i];
    static uint Release(IntPtr p) => ((delegate* unmanaged[Stdcall]<IntPtr, uint>)Slot(p, 2))(p);

    // IMFAttributes (IMFMediaType and IMFSample start with it)
    static int SetBlob(IntPtr a, Guid key, byte[] blob)
    {
        fixed (byte* p = blob) return ((delegate* unmanaged[Stdcall]<IntPtr, Guid*, byte*, uint, int>)Slot(a, 26))(a, &key, p, (uint)blob.Length);
    }
    static int SetUInt32(IntPtr a, Guid key, uint v) => ((delegate* unmanaged[Stdcall]<IntPtr, Guid*, uint, int>)Slot(a, 21))(a, &key, v);
    static int SetGuid(IntPtr a, Guid key, Guid v) => ((delegate* unmanaged[Stdcall]<IntPtr, Guid*, Guid*, int>)Slot(a, 24))(a, &key, &v);

    // IMFSample
    static int SetSampleTime(IntPtr s, long t) => ((delegate* unmanaged[Stdcall]<IntPtr, long, int>)Slot(s, 36))(s, t);
    static int SetSampleDuration(IntPtr s, long d) => ((delegate* unmanaged[Stdcall]<IntPtr, long, int>)Slot(s, 38))(s, d);
    static int AddBuffer(IntPtr s, IntPtr b) => ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, int>)Slot(s, 42))(s, b);

    // IMFMediaBuffer
    static int Lock(IntPtr b, byte** data, uint* max, uint* current) => ((delegate* unmanaged[Stdcall]<IntPtr, byte**, uint*, uint*, int>)Slot(b, 3))(b, data, max, current);
    static int Unlock(IntPtr b) => ((delegate* unmanaged[Stdcall]<IntPtr, int>)Slot(b, 4))(b);
    static int SetCurrentLength(IntPtr b, uint n) => ((delegate* unmanaged[Stdcall]<IntPtr, uint, int>)Slot(b, 6))(b, n);

    // IMFSinkWriter
    static int AddStream(IntPtr w, IntPtr type, uint* index) => ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint*, int>)Slot(w, 3))(w, type, index);
    static int SetInputMediaType(IntPtr w, uint index, IntPtr type, IntPtr parameters) => ((delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr, IntPtr, int>)Slot(w, 4))(w, index, type, parameters);
    static int BeginWriting(IntPtr w) => ((delegate* unmanaged[Stdcall]<IntPtr, int>)Slot(w, 5))(w);
    static int WriteSample(IntPtr w, uint index, IntPtr sample) => ((delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr, int>)Slot(w, 6))(w, index, sample);
    static int FinalizeWriter(IntPtr w) => ((delegate* unmanaged[Stdcall]<IntPtr, int>)Slot(w, 11))(w);


    static readonly Guid MajorType = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    static readonly Guid Subtype = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    static readonly Guid NumChannels = new("37e48bf5-645e-4c5b-89de-ada9e29b696a");
    static readonly Guid SamplesPerSecond = new("5faeeae7-0290-4c31-9e8a-c534f68d9dba");
    static readonly Guid BitsPerSample = new("f2deb57f-40fa-4764-aa33-ed4f2d1ff669");
    static readonly Guid AvgBytesPerSecond = new("1aab75c8-cfef-451c-ab95-ac034b8e1731");
    static readonly Guid BlockAlignment = new("322de230-9eeb-43bd-ab7a-ff412251541d");
    static readonly Guid PayloadType = new("bfbabe79-7434-4d1c-94f0-72a3b9e17188");
    static readonly Guid ProfileLevel = new("7632f0e6-9538-4d61-acda-ea29c8c14456");
    static readonly Guid UserData = new("b6bc765f-4c3b-40a4-bd51-2535b66fe09d");
    static readonly Guid MediaTypeAudio = new("73647561-0000-0010-8000-00aa00389b71");
    static readonly Guid FormatPcm = new("00000001-0000-0010-8000-00aa00389b71");
    static readonly Guid FormatAac = new("00001610-0000-0010-8000-00aa00389b71");
    static readonly Guid ContainerType = new("150ff23f-4abc-478b-ac4f-e1916fba1cca");
    static readonly Guid ContainerAdts = new("132fd27d-0f02-43de-a301-38fbbbb3834e");
    static readonly Guid ContainerMpeg4 = new("dc6cd05d-b9d0-40ef-bd35-fa622c1ab28a");
    static readonly Guid DisableThrottling = new("08b845d8-2b74-4afe-9d53-be16d2d5ae4f");

    [DllImport("mfplat.dll")] static extern int MFStartup(uint version, uint flags);
    [DllImport("mfplat.dll")] static extern int MFCreateAttributes(out IntPtr attributes, uint size);
    [DllImport("mfplat.dll")] static extern int MFCreateMediaType(out IntPtr type);
    [DllImport("mfplat.dll")] static extern int MFCreateSample(out IntPtr sample);
    [DllImport("mfplat.dll")] static extern int MFCreateMemoryBuffer(uint max, out IntPtr buffer);
    [DllImport("mfreadwrite.dll", CharSet = CharSet.Unicode)] static extern int MFCreateSinkWriterFromURL(string url, IntPtr byteStream, IntPtr attributes, out IntPtr writer);
}
