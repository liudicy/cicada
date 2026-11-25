package cicada

import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/// 存到文件夹: the file a settled meeting becomes (docs/folder-export.md, the Mac's
/// FolderExport.swift). The name and frontmatter are a contract with the Mac and the other ports
/// (Tests/fixtures/folder-export); the body is 导出 Markdown's. The app writes it through SAF.
object FolderExportFormat {
    /// The record's own name: what the user called it, else the notes' title, else the imported
    /// file's name. Never displayTitle, which is localized and carries a date.
    fun name(s: Session): String {
        if (s.renamed ?: !s.title.startsWith("会议 ")) return s.title
        s.notes?.title?.takeIf { it.isNotEmpty() }?.let { return it }
        // Swift's deletingPathExtension: ".hidden" keeps its name.
        s.sourceFile?.let { f -> val dot = f.lastIndexOf('.'); return if (dot > 0) f.substring(0, dot) else f }
        return ""
    }

    private val banned = "/\\:*?\"<>|#^[]".codePoints().toArray().toSet()

    /// A name every system accepts and a vault can link to: no path, wildcard or link characters,
    /// at most 120 UTF-8 bytes (vaults sync between systems, so the union of their rules). By code
    /// point, so an emoji is never cut in half.
    fun safeName(name: String): String {
        val spaced = StringBuilder()
        name.codePoints().forEach { cp -> if (cp in banned || cp < 0x20) spaced.append(' ') else spaced.appendCodePoint(cp) }
        var out = trim(spaced.split(Regex("[\\s\\p{Z}]+")).filter { it.isNotEmpty() }.joinToString(" "))
        if (out.toByteArray(Charsets.UTF_8).size > 120) {
            val cut = StringBuilder()
            var bytes = 0
            for (cp in out.codePoints().toArray()) {
                bytes += String(Character.toChars(cp)).toByteArray(Charsets.UTF_8).size
                if (bytes > 120) break
                cut.appendCodePoint(cp)
            }
            out = trim(cut.toString())
        }
        return out
    }

    private fun trim(s: String) = s.trim { it == ' ' || it == '.' }

    fun stem(s: Session, zone: ZoneId = ZoneId.systemDefault()): String {
        val date = format(s.startedAt, "yyyy-MM-dd HHmm", zone)
        val safe = safeName(name(s))
        return if (safe.isEmpty()) date else "$date $safe"
    }

    /// `stem.md`, or `stem 2.md`, `stem 3.md`… when a name is taken.
    fun fileName(stem: String, taken: (String) -> Boolean): String {
        var n = 1
        while (true) {
            val name = if (n == 1) "$stem.md" else "$stem $n.md"
            if (!taken(name)) return name
            n++
        }
    }

    /// A JSON-style double-quoted string, which YAML reads as is. Not Json.write's: that escapes "/"
    /// as the Mac's JSONEncoder does, and the frontmatter keeps it.
    fun quote(s: String): String {
        val b = StringBuilder("\"")
        s.codePoints().forEach { cp ->
            when {
                cp == '\\'.code -> b.append("\\\\")
                cp == '"'.code -> b.append("\\\"")
                cp == '\n'.code -> b.append("\\n")
                cp == '\r'.code -> b.append("\\r")
                cp == '\t'.code -> b.append("\\t")
                cp < 0x20 -> b.append(String.format(Locale.ROOT, "\\u%04x", cp))
                else -> b.appendCodePoint(cp)
            }
        }
        return b.append('"').toString()
    }

    private fun byCodePoint(a: String, b: String): Int {
        val x = a.codePoints().toArray(); val y = b.codePoints().toArray()
        for (i in 0 until minOf(x.size, y.size)) if (x[i] != y[i]) return x[i].compareTo(y[i])
        return x.size.compareTo(y.size)
    }

    fun frontmatter(s: Session, zone: ZoneId = ZoneId.systemDefault()): String {
        val ended = s.endedAt ?: s.startedAt
        val languages = s.lines.map { it.srcLang }.distinct().sortedWith(::byCodePoint)
        val notes = s.notes?.let { if (it.isEmpty) "none" else if (it.final) "final" else "draft" } ?: "none"
        val minutes = maxOf(0L, (ended.toEpochMilli() - s.startedAt.toEpochMilli()) / 60_000)
        return "---\n" +
            "cicada: 1\n" +
            "id: ${quote(s.id)}\n" +
            "title: ${quote(name(s))}\n" +
            "started: ${quote(format(s.startedAt, "yyyy-MM-dd'T'HH:mm:ssxxx", zone))}\n" +
            "ended: ${quote(format(ended, "yyyy-MM-dd'T'HH:mm:ssxxx", zone))}\n" +
            "minutes: $minutes\n" +
            "languages: [${languages.joinToString(", ") { quote(it) }}]\n" +
            "source: ${quote(if (s.sourceFile == null) "meeting" else "file")}\n" +
            "notes: ${quote(notes)}\n" +
            "tags: [\"cicada\"]\n" +
            "---\n"
    }

    fun document(s: Session): String = frontmatter(s) + TranscriptExport.markdown(s)

    private fun format(at: Instant, pattern: String, zone: ZoneId) =
        DateTimeFormatter.ofPattern(pattern, Locale.ROOT).withZone(zone).format(at)
}

/// What 存到文件夹 wrote, next to the records (FolderExport.json, as on the Mac): the folder (here a
/// SAF tree URI), each record's file name, and the records still to write. `uris` is Android's own:
/// each file's document URI, a hint only (a path-based provider changes it on rename).
class FolderExportIndex(
    var folder: String = "",
    val files: MutableMap<String, String> = mutableMapOf(),
    val uris: MutableMap<String, String> = mutableMapOf(),
    val pending: MutableList<String> = mutableListOf(),
    var lastFile: String? = null,
    var lastAt: Instant? = null,
) {
    fun toJson(): Map<String, Any?> = mapOf(
        "folder" to folder, "files" to files.toSortedMap(), "uris" to uris.toSortedMap(), "pending" to pending.toList(),
        "lastFile" to lastFile, "lastAt" to lastAt?.let(Iso8601::write),
    )

    fun save(file: File) {
        try {
            val tmp = File(file.path + ".tmp")
            tmp.writeText(Json.write(toJson(), slashes = false))
            if (!tmp.renameTo(file)) { file.delete(); tmp.renameTo(file) }
        } catch (e: Exception) { Log.d("folder export: index not saved ${e.javaClass.simpleName}") }
    }

    companion object {
        fun from(o: Map<String, Any?>) = FolderExportIndex(
            folder = o["folder"].str() ?: "",
            files = strings(o["files"]), uris = strings(o["uris"]),
            pending = o["pending"].arr().mapNotNull { it.str() }.toMutableList(),
            lastFile = o["lastFile"].str(), lastAt = Iso8601.read(o["lastAt"].str()),
        )

        fun load(file: File): FolderExportIndex =
            try { if (file.isFile) Json.parseObject(file.readText())?.let(::from) else null } catch (_: Exception) { null } ?: FolderExportIndex()

        private fun strings(v: Any?): MutableMap<String, String> =
            v.obj()?.mapNotNull { (k, x) -> x.str()?.let { k to it } }?.toMap(mutableMapOf()) ?: mutableMapOf()
    }
}
