namespace Cicada;

/// Where listening gets its sound: 16 kHz mono Int16, pushed from any thread. On Windows the
/// process loopback tap (everything the PC plays except Cicada); in tests and the CLI, a file.
public interface IAudioSource
{
    event Action<short[]>? Samples;
    /// Fires once when the source can't go on (device gone, file finished).
    event Action<string?>? Ended;
    void Start();
    void Stop();
}

/// Plays a WAV into listening, in real time or as fast as it can (`speed` 0).
public sealed class FileAudioSource(string path, double speed = 1) : IAudioSource
{
    CancellationTokenSource? cts;
    public event Action<short[]>? Samples;
    public event Action<string?>? Ended;

    public void Start()
    {
        cts = new CancellationTokenSource();
        var token = cts.Token;
        var pcm = Wav.Read(path);
        Task.Run(async () =>
        {
            const int chunk = Segmenter.Rate / 10; // 100 ms, like a capture callback
            var started = DateTime.UtcNow;
            for (int i = 0; i < pcm.Length && !token.IsCancellationRequested; i += chunk)
            {
                Samples?.Invoke(pcm[i..Math.Min(pcm.Length, i + chunk)]);
                if (speed > 0)
                {
                    var due = started + TimeSpan.FromSeconds((i + chunk) / (double)Segmenter.Rate / speed);
                    var wait = due - DateTime.UtcNow;
                    if (wait > TimeSpan.Zero) await Task.Delay(wait, CancellationToken.None);
                }
            }
            // A second of silence so the last sentence's pause is heard.
            Samples?.Invoke(new short[Segmenter.Rate]);
            Ended?.Invoke(null);
        });
    }

    public void Stop() => cts?.Cancel();
}

public static class Wav
{
    public static byte[] Bytes(short[] pcm, int rate = Segmenter.Rate)
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

    /// A PCM16 WAV of any rate and channel count, as 16 kHz mono.
    public static short[] Read(string path)
    {
        using var r = new BinaryReader(File.OpenRead(path));
        if (new string(r.ReadChars(4)) != "RIFF") throw new InvalidDataException("not a WAV");
        r.ReadInt32();
        if (new string(r.ReadChars(4)) != "WAVE") throw new InvalidDataException("not a WAV");
        int channels = 1, rate = 16000, bits = 16;
        while (r.BaseStream.Position < r.BaseStream.Length)
        {
            var id = new string(r.ReadChars(4));
            int size = r.ReadInt32();
            if (id == "fmt ")
            {
                var format = r.ReadInt16(); channels = r.ReadInt16(); rate = r.ReadInt32();
                r.ReadInt32(); r.ReadInt16(); bits = r.ReadInt16();
                if (size > 16) r.ReadBytes(size - 16);
                if ((format != 1 && format != unchecked((short)0xFFFE)) || bits != 16) throw new InvalidDataException("only 16-bit PCM WAV");
            }
            else if (id == "data")
            {
                int frames = size / 2 / channels;
                var mono = new double[frames];
                for (int f = 0; f < frames; f++)
                {
                    double sum = 0;
                    for (int c = 0; c < channels; c++) sum += r.ReadInt16();
                    mono[f] = sum / channels;
                }
                return Resample(mono, rate);
            }
            else r.ReadBytes(size + (size & 1));
        }
        throw new InvalidDataException("no data chunk");
    }

    /// Linear interpolation after a box average: plenty for speech going to a recognizer.
    public static short[] Resample(double[] mono, int rate)
    {
        if (rate == Segmenter.Rate) return mono.Select(x => (short)Math.Clamp(x, short.MinValue, short.MaxValue)).ToArray();
        int window = Math.Max(1, rate / Segmenter.Rate);
        int count = (int)((long)mono.Length * Segmenter.Rate / rate);
        var output = new short[count];
        for (int i = 0; i < count; i++)
        {
            int start = (int)((long)i * rate / Segmenter.Rate), stop = Math.Min(mono.Length, start + window);
            double sum = 0;
            for (int j = start; j < stop; j++) sum += mono[j];
            output[i] = (short)Math.Clamp(sum / Math.Max(1, stop - start), short.MinValue, short.MaxValue);
        }
        return output;
    }
}
