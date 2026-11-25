// 存到文件夹: the Mac's FolderExportTests. The file name and frontmatter are a contract with the Mac
// and the other ports (Tests/fixtures/folder-export): the same record gives the same bytes.
package cicada.cli

import cicada.*
import java.io.File
import java.time.ZoneId

object FolderExportTests {
    val tests: List<Pair<String, () -> Unit>> = listOf(
        "folderExportFrontmatterBytes" to ::frontmatterBytes,
        "folderExportFileName" to ::fileName,
        "folderExportNames" to ::names,
        "folderExportStems" to ::stems,
        "folderExportEscapes" to ::escapes,
        "folderExportCollisions" to ::collisions,
        "folderExportNamePrecedence" to ::namePrecedence,
        "folderExportIndexRoundTrip" to ::indexRoundTrip,
        "folderExportWaitsForTheFinalNotes" to ::waitsForTheFinalNotes,
    )

    private fun check(ok: Boolean, what: String) { if (!ok) throw AssertionError(what) }
    private fun <T> equal(expected: T, actual: T, what: String) { if (expected != actual) throw AssertionError("$what: expected «$expected», got «$actual»") }

    private val fixtures get() = File(resources, "../Tests/fixtures/folder-export")
    private fun session() = Session.read(File(fixtures, "session.json").readText())!!
    private fun cases() = Json.parseObject(File(fixtures, "cases.json").readText())!!
    private fun zone() = ZoneId.of(cases()["timeZone"].str()!!)
    private fun pairs(key: String) = cases()[key].arr().map { p -> p.arr().map { it.str()!! } }

    private fun frontmatterBytes() {
        val want = File(fixtures, "frontmatter.md").readText()
        equal(want, FolderExportFormat.frontmatter(session(), zone()), "frontmatter")
    }

    private fun fileName() {
        val stem = FolderExportFormat.stem(session(), zone())
        equal(cases()["fileName"].str(), FolderExportFormat.fileName(stem) { false }, "file name")
    }

    private fun names() { for ((from, want) in pairs("names")) equal(want, FolderExportFormat.safeName(from), "safe name of «$from»") }

    private fun stems() {
        val s = session()
        for ((title, want) in pairs("stems")) { s.title = title; equal(want, FolderExportFormat.stem(s, zone()), "stem of «$title»") }
    }

    private fun escapes() { for ((from, want) in pairs("escapes")) equal(want, FolderExportFormat.quote(from), "quote of «$from»") }

    private fun collisions() {
        for (c in cases()["collisions"].arr()) {
            val o = c.obj()!!
            val taken = o["taken"].arr().map { it.str()!! }
            equal(o["want"].str(), FolderExportFormat.fileName(o["stem"].str()!!) { it in taken }, "collision of ${taken.size}")
        }
    }

    /// The name: the user's title, else the notes', else the imported file's, never the display title.
    private fun namePrecedence() {
        val s = session()
        s.renamed = false
        s.title = SessionStore.defaultTitle(s.startedAt)
        equal("产品路线评审", FolderExportFormat.name(s), "the notes' title")
        s.notes = null
        equal("", FolderExportFormat.name(s), "nothing")
        s.sourceFile = "Weekly sync.m4a"
        equal("Weekly sync", FolderExportFormat.name(s), "the file's name")
        check(FolderExportFormat.frontmatter(s).contains("source: \"file\"\nnotes: \"none\""), "an imported file without notes")
    }

    private fun indexRoundTrip() {
        val file = File(Paths.root, "FolderExport.json")
        val i = FolderExportIndex(folder = "content://com.android.externalstorage.documents/tree/primary%3ADocuments%2FCicada")
        i.files["a"] = "2026-11-06 1400 周会.md"; i.uris["a"] = "content://x/document/1"; i.pending.add("b")
        i.lastFile = "2026-11-06 1400 周会.md"; i.lastAt = java.time.Instant.parse("2026-11-06T06:00:00Z")
        i.save(file)
        val back = FolderExportIndex.load(file)
        equal(Json.write(i.toJson()), Json.write(back.toJson()), "index")
        check(FolderExportIndex.load(File(Paths.root, "none.json")).folder.isEmpty(), "no index: an empty one")
    }

    /// Settled means the final notes pass is over: it counts as running from the meeting's start
    /// until finish() is done, and says so when it ends without a key.
    private fun waitsForTheFinalNotes() {
        val store = SessionStore(loadNow = false)
        val ling = LingClient(AIKey(PlainProtector, File(Paths.root, "no-key")))
        val notes = NotesEngine(ling, store)
        val done = mutableListOf<String>()
        notes.finalDone = { done.add(it) }
        val s = store.begin()
        store.append(s.id, TranscriptLine(id = "h1-1", src = "hi", srcLang = "en"))
        notes.begin(s.id)
        check(notes.settling(s.id), "settling while the meeting runs and until finish()")
        store.end(s.id)
        notes.finish()
        check(!notes.settling(s.id), "settled after finish()")
        equal(listOf(s.id), done, "finalDone without a key")
    }
}
