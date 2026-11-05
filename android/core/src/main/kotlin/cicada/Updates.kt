package cicada

import java.io.File
import java.net.URI

/// Checks GitHub Releases for an Android build newer than the running one, as the Windows
/// UpdateChecker: the app checks at launch, when 首页 comes back once the answer is an hour old,
/// and from a daily job. Failures (offline, rate-limited, 404) are silent. This only finds the
/// update: the browser downloads the APK and the system installer replaces the app (it refuses
/// one signed with another key), so no install permission is needed.
/// `check` blocks: run it off the main thread.
class UpdateChecker(
    /// The running version, three parts ("1.4.0"), from VERSION via versionName.
    val current: String,
    /// When the feed last answered (epoch ms), kept in settings across launches.
    @Volatile var lastChecked: Long? = null,
    private val transport: Transport = UrlTransport,
) {
    class Update(val version: String, val page: String, val apk: String?, val size: Long)

    /// The list, not `releases/latest`: a release that ships only the Mac or Windows has no APK,
    /// so the newest Android release may be further down. The `updatefeed` debug command points
    /// it at another release JSON (a list or one release); a file path or file:// URL works too.
    @Volatile var feed = FEED

    /// The newer release, or null (none, or not checked yet).
    @Volatile var available: Update? = null; private set
    private val listeners = mutableListOf<() -> Unit>()

    fun onChange(listener: () -> Unit) { synchronized(listeners) { listeners.add(listener) } }

    fun checkIfDue(age: Long, now: Long = System.currentTimeMillis()): Boolean = if (due(lastChecked, now, age)) check() else true

    /// False when the feed couldn't be reached or answered with something unexpected. One at a
    /// time: a second caller (检查更新 during the launch check) waits, then asks for itself.
    @Synchronized fun check(): Boolean {
        try {
            val releases = decode(read(feed)) ?: run { Log.d("update: feed unreadable"); return false }
            val newest = newestAndroid(releases)
            lastChecked = System.currentTimeMillis()
            available = newest?.takeIf { isNewer(it.version, current) }
            Log.d("update: checked, latest Android ${newest?.version ?: "none"}, running $current")
            synchronized(listeners) { listeners.toList() }.forEach { it() }
            return true
        } catch (e: Exception) {
            Log.d("update: check failed ${e.javaClass.simpleName}")
            return false
        }
    }

    private fun read(feed: String): String {
        if (feed.startsWith("file:")) return File(URI(feed)).readText()
        if (!feed.contains("://")) return File(feed).readText()
        // GitHub's API refuses requests without a User-Agent.
        val r = transport.send(feed, "GET", null, mapOf("User-Agent" to "Cicada-Android", "Accept" to "application/vnd.github+json"), 20_000)
        if (r.status !in 200..299) throw java.io.IOException("HTTP ${r.status}")
        return r.body
    }

    companion object {
        const val FEED = "https://api.github.com/repos/wquguru/cicada/releases?per_page=20"
        /// 首页 coming back checks once the last answer is this old; the daily job does the rest.
        const val STALE = 3600_000L

        fun due(last: Long?, now: Long, age: Long): Boolean =
            // A clock set back leaves `last` in the future: check rather than wait for it.
            last == null || now - last >= age || last > now

        /// A list of releases, or one release (a feed pointed at `releases/latest`).
        fun decode(text: String): List<Map<String, Any?>>? {
            val v = try { Json.parse(text) } catch (_: Json.ParseException) { return null }
            return when (v) {
                is List<*> -> v.mapNotNull { it.obj() }
                is Map<*, *> -> v.obj()?.takeIf { !it["tag_name"].str().isNullOrEmpty() }?.let { listOf(it) }
                else -> null
            }
        }

        /// The newest published release with an Android APK; one without only carries other platforms.
        fun newestAndroid(releases: List<Map<String, Any?>>): Update? {
            var best: Update? = null
            for (r in releases) {
                if (r["draft"].bool() == true || r["prerelease"].bool() == true) continue
                val apk = r["assets"].arr().mapNotNull { it.obj() }.firstOrNull {
                    val name = it["name"].str() ?: ""
                    name.startsWith("Cicada-") && name.endsWith("-Android.apk")
                } ?: continue
                val u = Update((r["tag_name"].str() ?: continue).trimStart('v'), r["html_url"].str() ?: "",
                               apk["browser_download_url"].str(), apk["size"].num()?.toLong() ?: 0)
                if (best == null || isNewer(u.version, best.version)) best = u
            }
            return best
        }

        /// Dotted numeric versions: "2.10.0" is newer than "2.9.1"; a suffix ("1.4.0-dev") is ignored.
        fun isNewer(a: String, b: String): Boolean {
            fun parts(v: String) = v.substringBefore('-').split('.').map { it.toIntOrNull() ?: 0 }
            val x = parts(a); val y = parts(b)
            for (i in 0 until maxOf(x.size, y.size)) {
                val l = x.getOrElse(i) { 0 }; val r = y.getOrElse(i) { 0 }
                if (l != r) return l > r
            }
            return false
        }
    }
}
