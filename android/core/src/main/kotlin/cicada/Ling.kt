package cicada

import java.io.File
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.util.Base64

/// Turns the key into bytes on disk and back. Android wraps it with a Keystore key (this app
/// only); the plain one is for the CLI and tests.
interface KeyProtector {
    val tag: String
    fun protect(data: ByteArray): ByteArray
    fun unprotect(data: ByteArray): ByteArray
}

object PlainProtector : KeyProtector {
    override val tag = "plain"
    override fun protect(data: ByteArray) = data
    override fun unprotect(data: ByteArray) = data
}

/// The user's Ling key, only ever in the `ling-api-key` file in the app's private folder (as on
/// the Mac): never in settings, logs or exports. On Android the file holds "keystore:" + base64
/// of the Keystore-sealed bytes.
class AIKey(private val protector: KeyProtector, private val file: File? = null) {
    private val path get() = file ?: Paths.keyFile
    private var cached: String? = null
    private var loaded = false

    @Synchronized fun read(): String? {
        if (loaded) return cached
        loaded = true
        cached = try {
            if (!path.isFile) null else {
                var text = path.readText().trim()
                if (text.startsWith("keystore:"))
                    text = String(protector.unprotect(Base64.getDecoder().decode(text.removePrefix("keystore:"))), Charsets.UTF_8)
                text.trim().ifEmpty { null }
            }
        } catch (e: Exception) {
            Log.d("ai key: read failed ${e.javaClass.simpleName}")
            null
        }
        return cached
    }

    @Synchronized fun save(key: String): Boolean {
        val k = key.trim()
        return try {
            path.parentFile?.mkdirs()
            val body = if (protector.tag == "plain") k else "keystore:" + Base64.getEncoder().encodeToString(protector.protect(k.toByteArray()))
            path.writeText(body)
            path.setReadable(false, false); path.setReadable(true, true)
            path.setWritable(false, false); path.setWritable(true, true)
            cached = k; loaded = true
            true
        } catch (e: Exception) {
            Log.d("ai key: save failed ${e.javaClass.simpleName}")
            false
        }
    }

    @Synchronized fun remove() {
        path.delete()
        cached = null; loaded = true
    }

    /// Reads the file again (a dev build's key pushed in with adb).
    @Synchronized fun reload() { loaded = false }

    companion object {
        /// "sk-••••••••••••3f9a" for display.
        fun masked(key: String) = if (key.length <= 8) "sk-…" else key.take(3) + "•".repeat(12) + key.takeLast(4)
    }
}

enum class Priority { Speak, Translate, Notes }

enum class KeyState { None, Unchecked, Checking, Ok, Invalid, Unreachable }

class LingException(val kind: Kind, val status: Int = 0) : Exception(if (kind == Kind.Http) "http$status" else kind.name) {
    enum class Kind { NoKey, InvalidKey, RateLimited, Hijacked, Timeout, Http, Network, Parse }
}

/// How requests leave the app: HttpURLConnection, or a fake in tests.
interface Transport {
    class Response(val status: Int, val body: String)
    /// Throws SocketTimeoutException on a timeout and IOException when the network fails.
    fun send(url: String, method: String, body: String?, headers: Map<String, String>, timeoutMs: Int): Response
}

object UrlTransport : Transport {
    override fun send(url: String, method: String, body: String?, headers: Map<String, String>, timeoutMs: Int): Transport.Response {
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            c.requestMethod = method
            c.connectTimeout = minOf(timeoutMs, 10_000)
            c.readTimeout = timeoutMs
            headers.forEach { (k, v) -> c.setRequestProperty(k, v) }
            if (body != null) {
                c.doOutput = true
                c.outputStream.use { it.write(body.toByteArray()) }
            }
            val status = c.responseCode
            val stream = if (status in 200..299) c.inputStream else c.errorStream
            val text = stream?.use { it.readBytes().toString(Charsets.UTF_8) } ?: ""
            return Transport.Response(status, text)
        } finally { c.disconnect() }
    }
}

/// Ling (ant-ling.com), OpenAI-compatible. One instance for the app: the account allows about 2
/// requests per second across every model, so request *starts* go through one gate (≥ 0.6 s apart,
/// overlapping is fine) in priority order. Two gateway quirks shape every call (see Ling.swift):
/// thinking is always disabled, and the content goes in the system message with a fixed user
/// instruction, because a question-like user message gets a search essay back; such replies are dropped.
/// Calls block: run them off the main thread.
class LingClient(private val key: AIKey, private val transport: Transport = UrlTransport) {
    companion object {
        const val BASE = "https://api.ant-ling.com/v1/"
        const val DEFAULT_MODEL = "Ling-3.1-flash"
        const val AUDIO_MODEL = "Ming-3.0-audio-flash"
        // Search essays (Ling.swift), and the canned refusal some audio prompts get.
        private val HIJACK_PREFIXES = listOf("根据现有检索证据", "暂未找到足够可靠的信息", "根据检索", "作为一个人工智能语言模型")
        @Volatile var spacing = 0.6
    }

    @Volatile var model = DEFAULT_MODEL
    @Volatile var keyState = if (key.read() == null) KeyState.None else KeyState.Unchecked; private set
    @Volatile var rateLimitedAt: Long? = null; private set
    private val listeners = mutableListOf<() -> Unit>()

    fun onChange(listener: () -> Unit) { synchronized(listeners) { listeners.add(listener) } }
    private fun changed() { synchronized(listeners) { listeners.toList() }.forEach { it() } }

    val hasKey get() = key.read() != null
    val usable get() = hasKey && keyState != KeyState.Invalid

    fun keyChanged() {
        keyState = if (key.read() == null) KeyState.None else KeyState.Unchecked
        changed()
    }

    /// A tiny request that says whether the key works.
    fun check(): KeyState {
        keyState = KeyState.Checking; changed()
        keyState = try {
            chat("Reply with OK.", "Reply.", Priority.Speak, maxTokens = 5, timeout = 10.0, model = "Ling-3.0-tiny")
            KeyState.Ok
        } catch (e: LingException) {
            when (e.kind) {
                LingException.Kind.NoKey -> KeyState.None
                LingException.Kind.InvalidKey -> KeyState.Invalid
                LingException.Kind.RateLimited -> KeyState.Ok // a busy key is still a good key
                else -> KeyState.Unreachable
            }
        } catch (_: Exception) { KeyState.Unreachable }
        changed()
        return keyState
    }

    /// One chat completion. `content` goes in the system message, `instruction` is the fixed user
    /// message, `audio` (of `audioType`) goes before it for Ming. Notes retry 429s with backoff; heard audio
    /// gets one retry (a lost reply loses the words); the rest fail fast so the caller can fall back.
    fun chat(
        content: String, instruction: String, priority: Priority, json: Boolean = false,
        maxTokens: Int = 1024, timeout: Double = 30.0, model: String? = null, audio: ByteArray? = null,
        audioType: String = "audio/wav",
    ): String {
        val k = key.read() ?: throw LingException(LingException.Kind.NoKey)
        if (keyState == KeyState.Invalid) throw LingException(LingException.Kind.InvalidKey)
        val user: Any = if (audio == null) instruction else listOf(
            mapOf("type" to "audio_url", "audio_url" to mapOf("url" to "data:$audioType;base64," + Base64.getEncoder().encodeToString(audio))),
            mapOf("type" to "text", "text" to instruction),
        )
        val body = linkedMapOf<String, Any?>(
            "model" to (model ?: this.model),
            "messages" to listOf(mapOf("role" to "system", "content" to content), mapOf("role" to "user", "content" to user)),
            "max_tokens" to maxTokens,
            "temperature" to 0.2,
            "thinking" to mapOf("type" to "disabled"),
            "stream" to false,
        )
        if (json) body["response_format"] = mapOf("type" to "json_object")
        val payload = Json.write(body, pretty = false)

        val attempts = if (priority == Priority.Notes) 4 else if (audio != null) 2 else 1
        var delay = 1.0
        var attempt = 1
        while (true) {
            acquire(priority)
            val started = System.nanoTime()
            try {
                val root = post("chat/completions", payload, k, timeout)
                val choice = root["choices"].arr().firstOrNull().obj()
                val text = choice?.get("message").obj()?.get("content").str() ?: throw LingException(LingException.Kind.Parse)
                val finish = choice?.get("finish_reason").str()
                val trimmed = text.trim()
                if (finish == null || HIJACK_PREFIXES.any { trimmed.startsWith(it) }) {
                    Log.d("ling: $priority search-style reply dropped")
                    throw LingException(LingException.Kind.Hijacked)
                }
                val usage = root["usage"].obj()
                Log.d("ling: $priority ok ${(System.nanoTime() - started) / 1_000_000} ms tokens=${usage?.get("prompt_tokens")}/${usage?.get("completion_tokens")}")
                if (rateLimitedAt != null) { rateLimitedAt = null; changed() }
                return trimmed
            } catch (e: LingException) {
                if (e.kind != LingException.Kind.RateLimited) throw e
                if (attempt >= attempts) { rateLimitedAt = System.currentTimeMillis(); changed(); throw e }
                val wait = delay + Math.random() * 0.5
                Log.d("ling: $priority 429, retry in ${"%.1f".format(wait)} s")
                Thread.sleep((wait * 1000).toLong())
                delay *= 2
                attempt++
            }
        }
    }

    private fun post(path: String, payload: String, k: String, timeout: Double): Map<String, Any?> {
        val res = try {
            transport.send(BASE + path, "POST", payload, mapOf(
                "Authorization" to "Bearer $k", "Content-Type" to "application/json", "User-Agent" to "Cicada-Android/0.1",
            ), (timeout * 1000).toInt())
        } catch (_: SocketTimeoutException) {
            throw LingException(LingException.Kind.Timeout)
        } catch (e: java.io.IOException) {
            Log.d("ling: network error ${e.javaClass.simpleName}")
            throw LingException(LingException.Kind.Network)
        }
        when (res.status) {
            200 -> {}
            401, 403 -> {
                if (keyState != KeyState.Invalid) { keyState = KeyState.Invalid; changed() }
                throw LingException(LingException.Kind.InvalidKey)
            }
            429 -> throw LingException(LingException.Kind.RateLimited)
            else -> {
                Log.d("ling: HTTP ${res.status}")
                throw LingException(LingException.Kind.Http, res.status)
            }
        }
        return try { Json.parse(res.body).obj() } catch (_: Json.ParseException) { null } ?: throw LingException(LingException.Kind.Parse)
    }

    // Start gate: request starts ≥ `spacing` apart, the most urgent waiting one first.

    private class Ticket(val priority: Priority, val seq: Long)
    private val gate = Object()
    private val waiting = mutableListOf<Ticket>()
    private var lastStart = 0L
    private var seq = 0L

    private fun acquire(priority: Priority) {
        synchronized(gate) {
            val me = Ticket(priority, ++seq)
            waiting.add(me)
            try {
                while (true) {
                    val head = waiting.minWith(compareBy<Ticket>({ it.priority.ordinal }, { it.seq }))
                    val wait = (spacing * 1000).toLong() - (System.currentTimeMillis() - lastStart)
                    if (head === me && wait <= 0) {
                        waiting.remove(me)
                        lastStart = System.currentTimeMillis()
                        gate.notifyAll()
                        return
                    }
                    gate.wait(if (head === me) wait else 0)
                }
            } catch (e: InterruptedException) {
                waiting.remove(me); gate.notifyAll(); throw e
            }
        }
    }
}
