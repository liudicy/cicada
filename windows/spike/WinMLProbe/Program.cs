// usage: WinMLProbe <model.onnx> <ref.json> <feats dir>
// Loads the model with Windows.AI.MachineLearning, embeds each fixture's features, and prints the
// cosine to the Mac's onnxruntime embedding and the time per clip.
using System.Diagnostics;
using System.Text.Json;
using Windows.AI.MachineLearning;

var model = LearningModel.LoadFromFilePath(Path.GetFullPath(args[0]));
Console.WriteLine($"loaded: inputs {string.Join(",", model.InputFeatures.Select(f => f.Name))}, outputs {string.Join(",", model.OutputFeatures.Select(f => f.Name))}");
foreach (var f in model.InputFeatures.OfType<TensorFeatureDescriptor>()) Console.WriteLine($"  {f.Name} shape [{string.Join(",", f.Shape)}]");
var session = new LearningModelSession(model, new LearningModelDevice(LearningModelDeviceKind.Cpu));
var refs = JsonDocument.Parse(File.ReadAllText(args[1])).RootElement;
foreach (var clip in refs.EnumerateObject())
{
    int frames = clip.Value.GetProperty("frames").GetInt32();
    var raw = File.ReadAllBytes(Path.Combine(args[2], clip.Name + ".feats.bin"));
    var feats = new float[raw.Length / 4];
    Buffer.BlockCopy(raw, 0, feats, 0, raw.Length);
    float[] emb = [];
    var times = new List<double>();
    for (int run = 0; run < 4; run++)
    {
        var sw = Stopwatch.StartNew();
        var binding = new LearningModelBinding(session);
        binding.Bind("feats", TensorFloat.CreateFromArray([1, frames, 80], feats));
        var result = await session.EvaluateAsync(binding, "");
        emb = ((TensorFloat)result.Outputs["embs"]).GetAsVectorView().ToArray();
        times.Add(sw.Elapsed.TotalMilliseconds);
    }
    var norm = MathF.Sqrt(emb.Sum(x => x * x));
    var reference = clip.Value.GetProperty("emb").EnumerateArray().Select(x => x.GetSingle()).ToArray();
    var cos = emb.Zip(reference, (a, b) => a / norm * b).Sum();
    Console.WriteLine($"{clip.Name}: {frames / 100.0:F1} s of speech, cosine to Mac {cos:F5}, first {times[0]:F0} ms, then {times.Skip(1).Average():F0} ms");
}
