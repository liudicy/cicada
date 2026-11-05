using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Cicada;

/// Turns the key into bytes on disk and back. Windows uses DPAPI (the current user only); the
/// plain one is for the Mac-side CLI and tests.
public interface IKeyProtector
{
    string Tag { get; }
    byte[] Protect(byte[] data);
    byte[] Unprotect(byte[] data);
}

public sealed class PlainProtector : IKeyProtector
{
    public string Tag => "plain";
    public byte[] Protect(byte[] data) => data;
    public byte[] Unprotect(byte[] data) => data;
}

/// The user's Ling key, only ever in the `ling-api-key` file under the app folder (as on the Mac):
/// never in settings, the registry, logs or exports. On Windows the file holds DPAPI-sealed bytes,
/// "dpapi:" + base64, readable only by this Windows user.
public sealed class AIKey(IKeyProtector protector, string? file = null)
{
    /// The CLI reads the Mac app's key file in place; the app always uses Paths.KeyFile.
    string File_ => file ?? Paths.KeyFile;

    string? cached;
    bool loaded;

    public string? Read()
    {
        if (loaded) return cached;
        loaded = true;
        try
        {
            if (!File.Exists(File_)) return cached = null;
            var text = File.ReadAllText(File_).Trim();
            if (text.StartsWith("dpapi:"))
                text = Encoding.UTF8.GetString(protector.Unprotect(Convert.FromBase64String(text["dpapi:".Length..])));
            cached = text.Length == 0 ? null : text.Trim();
        }
        catch (Exception e)
        {
            Log.Debug($"ai key: read failed {e.GetType().Name}");
            cached = null;
        }
        return cached;
    }

    public bool Save(string key)
    {
        key = key.Trim();
        try
        {
            Directory.CreateDirectory(Paths.Root);
            var body = protector.Tag == "plain" ? key
                : "dpapi:" + Convert.ToBase64String(protector.Protect(Encoding.UTF8.GetBytes(key)));
            File.WriteAllText(File_, body);
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(File_, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            cached = key; loaded = true;
            return true;
        }
        catch (Exception e)
        {
            Log.Debug($"ai key: save failed {e.GetType().Name}");
            return false;
        }
    }

    public void Remove()
    {
        try { File.Delete(File_); } catch { }
        cached = null; loaded = true;
    }

    /// "sk-••••••••••••3f9a" for display.
    public static string Masked(string key) => key.Length <= 8 ? "sk-…" : key[..3] + new string('•', 12) + key[^4..];
}

public enum Priority { Speak = 0, Translate = 1, Notes = 2 }

public enum KeyState { None, Unchecked, Checking, Ok, Invalid, Unreachable }

public sealed class LingException(LingException.Kind kind, int status = 0) : Exception(kind == Kind.Http ? $"http{status}" : kind.ToString())
{
    public enum Kind { NoKey, InvalidKey, RateLimited, Hijacked, Timeout, Http, Network, Parse }
    public Kind Failure { get; } = kind;
}

/// Ling (ant-ling.com), OpenAI-compatible. One instance for the app: the account allows about 2
/// requests per second across every model, so request *starts* go through one gate (≥ 0.6 s apart,
/// overlapping is fine) in priority order. Two gateway quirks shape every call (see Ling.swift):
/// thinking is always disabled, and the content goes in the system message with a fixed user
/// instruction, because a question-like user message gets a search essay back; such replies are dropped.
public sealed class LingClient
{
    public static readonly Uri Base = new("https://api.ant-ling.com/v1/");
    public const string DefaultModel = "Ling-3.1-flash";
    public const string AudioModel = "Ming-3.0-audio-flash";
    // Search essays (Ling.swift), and the canned refusal some audio prompts get.
    static readonly string[] HijackPrefixes = ["根据现有检索证据", "暂未找到足够可靠的信息", "根据检索", "作为一个人工智能语言模型"];

    readonly AIKey key;
    readonly HttpClient http;
    public string Model { get; set; } = DefaultModel;
    public KeyState KeyState { get; private set; }
    public DateTimeOffset? RateLimitedAt { get; private set; }
    public event Action? Changed;

    public LingClient(AIKey key, HttpMessageHandler? handler = null)
    {
        this.key = key;
        http = handler is null ? new HttpClient() : new HttpClient(handler);
        http.Timeout = Timeout.InfiniteTimeSpan; // per request below
        http.DefaultRequestHeaders.UserAgent.ParseAdd("Cicada-Windows/0.1");
        KeyState = key.Read() is null ? KeyState.None : KeyState.Unchecked;
    }

    public bool HasKey => key.Read() is not null;
    public bool Usable => HasKey && KeyState != KeyState.Invalid;

    public void KeyChanged()
    {
        KeyState = key.Read() is null ? KeyState.None : KeyState.Unchecked;
        Changed?.Invoke();
    }

    /// A tiny request that says whether the key works (and how fast).
    public async Task<(KeyState state, double seconds)> Check()
    {
        KeyState = KeyState.Checking; Changed?.Invoke();
        var started = DateTime.UtcNow;
        try
        {
            await Chat("Reply with OK.", "Reply.", Priority.Speak, maxTokens: 5, timeout: 10, model: "Ling-3.0-tiny");
            KeyState = KeyState.Ok;
        }
        catch (LingException e) when (e.Failure is LingException.Kind.InvalidKey or LingException.Kind.NoKey)
        {
            KeyState = e.Failure == LingException.Kind.NoKey ? KeyState.None : KeyState.Invalid;
        }
        catch (LingException e) when (e.Failure == LingException.Kind.RateLimited)
        {
            KeyState = KeyState.Ok; // a busy key is still a good key
        }
        catch
        {
            KeyState = KeyState.Unreachable;
        }
        Changed?.Invoke();
        return (KeyState, (DateTime.UtcNow - started).TotalSeconds);
    }

    /// One chat completion. `content` goes in the system message, `instruction` is the fixed user
    /// message, `audio` (a WAV) goes before it for Ming. Notes retry 429s with backoff; the rest
    /// fail fast so the caller can fall back.
    public async Task<string> Chat(string content, string instruction, Priority priority, bool json = false,
        int maxTokens = 1024, double timeout = 30, string? model = null, byte[]? audio = null, CancellationToken cancel = default)
    {
        var k = key.Read() ?? throw new LingException(LingException.Kind.NoKey);
        if (KeyState == KeyState.Invalid) throw new LingException(LingException.Kind.InvalidKey);
        JsonNode user = audio is null ? JsonValue.Create(instruction)! : new JsonArray(
            new JsonObject { ["type"] = "audio_url", ["audio_url"] = new JsonObject { ["url"] = "data:audio/wav;base64," + Convert.ToBase64String(audio) } },
            new JsonObject { ["type"] = "text", ["text"] = instruction });
        var body = new JsonObject
        {
            ["model"] = model ?? Model,
            ["messages"] = new JsonArray(
                new JsonObject { ["role"] = "system", ["content"] = content },
                new JsonObject { ["role"] = "user", ["content"] = user }),
            ["max_tokens"] = maxTokens,
            ["temperature"] = 0.2,
            ["thinking"] = new JsonObject { ["type"] = "disabled" },
            ["stream"] = false,
        };
        if (json) body["response_format"] = new JsonObject { ["type"] = "json_object" };
        var payload = body.ToJsonString();

        // Notes can wait; heard audio gets one retry, since on Windows a lost reply loses the words
        // (on the Mac recognition is local and only the translation is lost); the rest fail fast.
        int attempts = priority == Priority.Notes ? 4 : audio is not null ? 2 : 1;
        double delay = 1;
        for (int attempt = 1; ; attempt++)
        {
            var queued = DateTime.UtcNow;
            await Acquire(priority, cancel);
            var started = DateTime.UtcNow;
            if ((started - queued).TotalSeconds > 1) Log.Debug($"ling: {priority} waited {(started - queued).TotalMilliseconds:F0} ms at the gate");
            try
            {
                var root = await Post("chat/completions", payload, k, timeout, cancel);
                var choice = root["choices"]?[0];
                var text = choice?["message"]?["content"]?.GetValue<string>() ?? throw new LingException(LingException.Kind.Parse);
                var finish = choice?["finish_reason"]?.GetValue<string>();
                var trimmed = text.Trim();
                if (finish is null || HijackPrefixes.Any(trimmed.StartsWith))
                {
                    Log.Debug($"ling: {priority} search-style reply dropped");
                    throw new LingException(LingException.Kind.Hijacked);
                }
                var usage = root["usage"];
                Log.Debug($"ling: {priority} ok {(int)(DateTime.UtcNow - started).TotalMilliseconds} ms tokens={usage?["prompt_tokens"]}/{usage?["completion_tokens"]}");
                if (RateLimitedAt is not null) { RateLimitedAt = null; Changed?.Invoke(); }
                return trimmed;
            }
            catch (LingException e) when (e.Failure == LingException.Kind.RateLimited)
            {
                if (attempt >= attempts) { RateLimitedAt = DateTimeOffset.Now; Changed?.Invoke(); throw; }
                var wait = delay + Random.Shared.NextDouble() * 0.5;
                Log.Debug($"ling: {priority} 429, retry in {wait:F1} s");
                await Task.Delay(TimeSpan.FromSeconds(wait), cancel);
                delay *= 2;
            }
        }
    }

    public const string VoiceModel = "Ming-3.0-tts-0.5B";

    /// Ming's voice for `text`: raw 24 kHz mono 16-bit PCM, chunk by chunk as it streams (SSE).
    /// `languageId` is Ming's `language_id`, needed for ja, ko, de, fr and es. Ling.swift › speech.
    public async IAsyncEnumerable<byte[]> Speech(string text, string voice, string? languageId = null,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancel = default)
    {
        var k = key.Read() ?? throw new LingException(LingException.Kind.NoKey);
        if (KeyState == KeyState.Invalid) throw new LingException(LingException.Kind.InvalidKey);
        var body = new JsonObject
        {
            ["model"] = VoiceModel, ["input"] = text, ["voice"] = voice,
            ["response_format"] = "pcm", ["sample_rate"] = 24000, ["stream"] = true, ["stream_format"] = "sse",
        };
        if (languageId is not null) body["language_id"] = languageId;
        await Acquire(Priority.Speak, cancel);
        var started = DateTime.UtcNow;
        using var req = new HttpRequestMessage(HttpMethod.Post, new Uri(Base, "audio/speech"))
        {
            Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json"),
        };
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", k);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        cts.CancelAfter(TimeSpan.FromSeconds(20));
        HttpResponseMessage res;
        try { res = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token); }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested) { throw new LingException(LingException.Kind.Timeout); }
        catch (HttpRequestException e) { Log.Debug($"ling: voice network error {e.HttpRequestError}"); throw new LingException(LingException.Kind.Network); }
        using (res)
        {
            switch (res.StatusCode)
            {
                case HttpStatusCode.OK: break;
                case HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden:
                    if (KeyState != KeyState.Invalid) { KeyState = KeyState.Invalid; Changed?.Invoke(); }
                    throw new LingException(LingException.Kind.InvalidKey);
                case HttpStatusCode.TooManyRequests: throw new LingException(LingException.Kind.RateLimited);
                default: Log.Debug($"ling: voice HTTP {(int)res.StatusCode}"); throw new LingException(LingException.Kind.Http, (int)res.StatusCode);
            }
            using var reader = new StreamReader(await res.Content.ReadAsStreamAsync(cts.Token));
            int chunks = 0;
            while (true)
            {
                string? line;
                try { line = await reader.ReadLineAsync(cts.Token); }
                catch (OperationCanceledException) when (!cancel.IsCancellationRequested) { throw new LingException(LingException.Kind.Timeout); }
                if (line is null) break;
                var pcm = SpeechChunk(line, out var done);
                if (done) break;
                if (pcm is null) continue;
                if (chunks++ == 0) Log.Debug($"ling: Speak first audio {(int)(DateTime.UtcNow - started).TotalMilliseconds} ms");
                yield return pcm;
            }
        }
    }

    /// One SSE line of Ming's voice stream: the PCM it carries, or `done` at the end.
    public static byte[]? SpeechChunk(string line, out bool done)
    {
        done = false;
        if (!line.StartsWith("data:")) return null;
        JsonNode? obj;
        try { obj = JsonNode.Parse(line[5..]); } catch (JsonException) { return null; }
        if (obj?["type"]?.GetValue<string>() == "speech.audio.done") { done = true; return null; }
        if (obj?["audio"]?.GetValue<string>() is not { Length: > 0 } b64) return null;
        try { return Convert.FromBase64String(b64); } catch (FormatException) { return null; }
    }

    async Task<JsonNode> Post(string path, string payload, string k, double timeout, CancellationToken cancel)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, new Uri(Base, path))
        {
            Content = new StringContent(payload, Encoding.UTF8, "application/json"),
        };
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", k);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        cts.CancelAfter(TimeSpan.FromSeconds(timeout));
        HttpResponseMessage res;
        try { res = await http.SendAsync(req, cts.Token); }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested) { throw new LingException(LingException.Kind.Timeout); }
        catch (HttpRequestException e)
        {
            Log.Debug($"ling: network error {e.HttpRequestError}");
            throw new LingException(LingException.Kind.Network);
        }
        using (res)
        {
            switch (res.StatusCode)
            {
                case HttpStatusCode.OK: break;
                case HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden:
                    if (KeyState != KeyState.Invalid) { KeyState = KeyState.Invalid; Changed?.Invoke(); }
                    throw new LingException(LingException.Kind.InvalidKey);
                case HttpStatusCode.TooManyRequests: throw new LingException(LingException.Kind.RateLimited);
                default:
                    Log.Debug($"ling: HTTP {(int)res.StatusCode}");
                    throw new LingException(LingException.Kind.Http, (int)res.StatusCode);
            }
            try
            {
                var text = await res.Content.ReadAsStringAsync(cts.Token);
                return JsonNode.Parse(text) ?? throw new LingException(LingException.Kind.Parse);
            }
            catch (OperationCanceledException) when (!cancel.IsCancellationRequested) { throw new LingException(LingException.Kind.Timeout); }
            catch (JsonException) { throw new LingException(LingException.Kind.Parse); }
        }
    }

    // Start gate: request starts ≥ 0.6 s apart, the most urgent waiting one first.

    public static double Spacing { get; set; } = 0.6;
    readonly object gate = new();
    DateTime lastStart = DateTime.MinValue;
    readonly List<(Priority priority, long seq, TaskCompletionSource ready)> waiting = [];
    long seq;
    bool pumping;

    Task Acquire(Priority priority, CancellationToken cancel)
    {
        lock (gate)
        {
            if (waiting.Count == 0 && (DateTime.UtcNow - lastStart).TotalSeconds >= Spacing)
            {
                lastStart = DateTime.UtcNow;
                return Task.CompletedTask;
            }
            var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            waiting.Add((priority, ++seq, ready));
            if (!pumping) { pumping = true; _ = Pump(); }
            return ready.Task.WaitAsync(cancel);
        }
    }

    async Task Pump()
    {
        while (true)
        {
            double wait;
            lock (gate) wait = Math.Max(0, Spacing - (DateTime.UtcNow - lastStart).TotalSeconds);
            if (wait > 0) await Task.Delay(TimeSpan.FromSeconds(wait));
            lock (gate)
            {
                if (waiting.Count == 0) { pumping = false; return; }
                var next = waiting.MinBy(w => ((int)w.priority, w.seq));
                waiting.Remove(next);
                lastStart = DateTime.UtcNow;
                next.ready.TrySetResult();
            }
        }
    }
}
