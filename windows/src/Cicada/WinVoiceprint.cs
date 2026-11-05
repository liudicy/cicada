using Windows.AI.MachineLearning;

namespace Cicada.App;

/// The voiceprint model on Windows' built-in Windows ML (no runtime to ship). Loaded on first use
/// from inside the exe; one inference at a time, about 0.15 s for a 5 s line.
sealed class WinVoiceprint : IVoiceprint
{
    readonly object one = new();
    LearningModelSession? session;
    bool failed;

    public float[]? Embed(short[] samples)
    {
        var feats = Fbank.Features(samples);
        if (feats is null) return null;
        lock (one)
        {
            if (session is null && !failed) Load();
            if (session is null) return null;
            try
            {
                var binding = new LearningModelBinding(session);
                binding.Bind("feats", TensorFloat.CreateFromArray([1, feats.Length / Fbank.Bins, Fbank.Bins], feats));
                var result = session.Evaluate(binding, "");
                var v = ((TensorFloat)result.Outputs["embs"]).GetAsVectorView().ToArray();
                var norm = MathF.Sqrt(v.Sum(x => x * x));
                if (norm <= 0) return null;
                for (int i = 0; i < v.Length; i++) v[i] /= norm;
                return v;
            }
            catch (Exception e) { Log.Debug($"voiceprint: failed {e.GetType().Name}"); return null; }
        }
    }

    void Load()
    {
        try
        {
            var started = DateTime.UtcNow;
            using var res = typeof(WinVoiceprint).Assembly.GetManifestResourceStream("voiceprint.onnx") ?? throw new FileNotFoundException("voiceprint.onnx");
            var bytes = new byte[res.Length];
            res.ReadExactly(bytes);
            // Written through a DataWriter: a .NET stream wrapper would close the WinRT stream with it.
            var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            using (var w = new Windows.Storage.Streams.DataWriter(stream.GetOutputStreamAt(0)))
            {
                w.WriteBytes(bytes);
                w.StoreAsync().AsTask().Wait();
                w.FlushAsync().AsTask().Wait();
                w.DetachStream();
            }
            stream.Seek(0);
            var model = LearningModel.LoadFromStream(Windows.Storage.Streams.RandomAccessStreamReference.CreateFromStream(stream));
            session = new LearningModelSession(model, new LearningModelDevice(LearningModelDeviceKind.Cpu));
            Log.Debug($"voiceprint: model ready in {(DateTime.UtcNow - started).TotalMilliseconds:F0} ms");
        }
        catch (Exception e) { failed = true; Log.Debug($"voiceprint: model failed to load {e.GetType().Name}: {e.Message}"); }
    }
}
