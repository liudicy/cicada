package com.wquguru.cicada

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import cicada.FolderExportFormat
import cicada.FolderExportIndex
import cicada.Log
import cicada.Paths
import cicada.Session
import cicada.Strings.L
import cicada.Strings.LF
import java.io.File
import java.time.Instant
import java.util.concurrent.Executors

/// 存到文件夹 (docs/folder-export.md, the Mac's FolderExporter): writes settled meetings as Markdown
/// into the folder the user picked (a SAF tree, held by a persisted grant) and keeps the index of
/// what it wrote. State lives on the main thread; the files are written one at a time on its own
/// thread, through DocumentsContract, since a provider may be slow or remote.
class FolderExporter(private val app: CicadaApp) {
    enum class Problem {
        /// The grant is gone (the user revoked it, or the app was restored without it).
        Denied,
        /// The folder, or the storage it was on, is gone.
        Missing,
        Failed,
    }

    var index: FolderExportIndex; private set
    var problem: Problem? = null; private set
    /// Failed's provider message.
    var problemText: String? = null; private set
    /// Checking a newly chosen folder.
    var checking = false; private set
    /// The folder is an Obsidian vault itself (it has `.obsidian`): the 位置 row says so.
    var vault = false; private set

    private val settings get() = app.settings
    private val store get() = app.store
    private val indexFile = File(Paths.root, "FolderExport.json")
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "FolderExport").apply { isDaemon = true } }
    private var scheduled: Runnable? = null
    /// Told about this problem already (cleared once a write works).
    private var notified = false

    init { index = FolderExportIndex.load(indexFile) }

    val on get() = settings.exportOn && settings.exportFolder.isNotEmpty()
    val tree: Uri? get() = settings.exportFolder.takeIf { it.isNotEmpty() }?.let(Uri::parse)

    /// "Documents › Cicada": the folder and the one it is in, named when it was chosen.
    val shortPath: String get() = settings.exportName.ifEmpty { "Cicada" }

    /// The record's file, when it is written to this folder.
    fun file(id: String): Uri? {
        if (!on || index.folder != settings.exportFolder || index.files[id] == null) return null
        return index.uris[id]?.let(Uri::parse)
    }

    fun isPending(id: String) = on && id in index.pending

    /// Ended, not being imported, with something said.
    fun ready(s: Session) = s.endedAt != null && s.importing != true && s.lines.isNotEmpty() && s.id != store.liveId

    /// Settled records not written to this folder yet.
    val unwritten: List<Session> get() = store.all().filter { ready(it) && index.files[it.id] == null && it.id !in index.pending }

    /// What the screens' keys compare, so they rebuild when any of it changes.
    fun stateKey(): String = listOf(on, settings.exportName, problem, problemText, checking, vault, index.pending.size, index.files.size, index.lastAt, unwritten.size).joinToString("|")

    // MARK: Triggers (main thread)

    /// A meeting ended or an import finished: write it once it is settled.
    fun ended(id: String) {
        if (!on) return
        if (id !in index.pending) index.pending.add(id)
        saveIndex()
        schedule()
    }

    /// A record changed: rewrite it if it was written, or write it if it is waiting.
    fun saved(id: String) {
        if (!on || (index.files[id] == null && id !in index.pending)) return
        if (id !in index.pending) index.pending.add(id)
        schedule()
    }

    /// The final notes pass for a meeting is over (done, failed, or no key).
    fun settled(id: String) { if (on && id in index.pending) schedule() }

    /// 也存一份: every settled record not written yet.
    fun writeAll() {
        if (!on) return
        index.pending.addAll(unwritten.map { it.id })
        saveIndex()
        flush(fromMeeting = false)
    }

    /// At launch (once the records are read) and when the app comes forward: try what is waiting.
    fun retry() {
        if (!on || index.pending.isEmpty() || !store.loaded) return
        schedule(500, fromMeeting = false)
    }

    /// The record is gone from Cicada; its file stays.
    fun deleted(id: String) {
        if (index.files.remove(id) == null && !index.pending.remove(id)) return
        index.uris.remove(id)
        saveIndex()
    }

    // MARK: Choosing the folder

    /// A new folder (its grant already taken), or the same one again: start its index and check it
    /// can be written now, so a problem shows while settings is open, not when a meeting ends.
    fun choose(folder: Uri) {
        val text = folder.toString()
        if (settings.exportFolder.isNotEmpty() && settings.exportFolder != text) release(Uri.parse(settings.exportFolder))
        settings.exportFolder = text
        settings.exportOn = true
        settings.save()
        if (index.folder != text) index = FolderExportIndex(folder = text)
        saveIndex()
        checking = true
        problem = null; problemText = null
        app.changed()
        val resolver = app.contentResolver
        worker.execute {
            val name = Saf.shortPath(resolver, folder)
            val result = Saf.probe(app, folder)
            val isVault = result.problem == null && Saf.children(resolver, folder).containsKey(".obsidian")
            app.main.post {
                if (settings.exportFolder != text) return@post
                checking = false
                problem = result.problem; problemText = result.message
                vault = isVault
                if (name != null) { settings.exportName = name; settings.save() }
                if (problem == null) { notified = false; retry() }
                Log.d("folder export: chose a folder → ${problem ?: "ok"}")
                app.changed()
            }
        }
    }

    fun turnOff() {
        settings.exportOn = false
        settings.save()
        problem = null; problemText = null
        app.changed()
    }

    /// The folder Cicada writes in no longer: its grant goes back (an app holds at most 128 or 512).
    private fun release(old: Uri) {
        try { app.contentResolver.releasePersistableUriPermission(old, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) } catch (_: Exception) {}
    }

    /// The folder in the Files app, if anything opens a folder.
    fun openFolderIntent(): Intent? {
        val t = tree ?: return null
        val doc = DocumentsContract.buildDocumentUriUsingTree(t, DocumentsContract.getTreeDocumentId(t))
        return Intent(Intent.ACTION_VIEW).setDataAndType(doc, Document.MIME_TYPE_DIR)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            .takeIf { it.resolveActivity(app.packageManager) != null }
    }

    /// The record's file in a Markdown viewer, or null when nothing opens text/markdown.
    fun revealIntent(id: String): Intent? {
        val uri = file(id) ?: return null
        return Intent(Intent.ACTION_VIEW).setDataAndType(uri, "text/markdown")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            .takeIf { it.resolveActivity(app.packageManager) != null }
    }

    // MARK: Writing

    private fun schedule(delay: Long = 2000, fromMeeting: Boolean = true) {
        scheduled?.let(app.main::removeCallbacks)
        val work = Runnable { flush(fromMeeting) }
        scheduled = work
        app.main.postDelayed(work, delay)
    }

    private class Job(val id: String, val stem: String, val old: String?, val oldUri: String?, val text: String)

    private sealed class Outcome {
        class Wrote(val id: String, val name: String, val uri: String) : Outcome()
        class Unchanged(val id: String) : Outcome()
        class Stopped(val problem: Problem, val message: String? = null) : Outcome()
    }

    /// Renders what is settled here, writes it on the worker.
    private fun flush(fromMeeting: Boolean) {
        val folder = tree
        if (!on || folder == null || !store.loaded) return
        val text = folder.toString()
        if (index.folder != text) index = FolderExportIndex(folder = text, pending = index.pending)
        val jobs = mutableListOf<Job>()
        for (id in index.pending.toList()) {
            val s = store.get(id) ?: run { index.pending.remove(id); null } ?: continue
            if (!ready(s) || app.notes.settling(id)) continue
            jobs.add(Job(id, FolderExportFormat.stem(s), index.files[id], index.uris[id], FolderExportFormat.document(s)))
        }
        saveIndex()
        if (jobs.isEmpty()) return
        val ours = HashMap(index.files)
        val resolver = app.contentResolver
        worker.execute {
            val outcomes = write(resolver, folder, jobs, ours)
            app.main.post { apply(outcomes, text, fromMeeting) }
        }
    }

    private fun apply(outcomes: List<Outcome>, folder: String, fromMeeting: Boolean) {
        if (index.folder != folder) return
        var stopped: Outcome.Stopped? = null
        for (o in outcomes) when (o) {
            is Outcome.Wrote -> {
                index.files[o.id] = o.name; index.uris[o.id] = o.uri
                index.pending.remove(o.id)
                index.lastFile = o.name; index.lastAt = Instant.now()
            }
            is Outcome.Unchanged -> index.pending.remove(o.id)
            is Outcome.Stopped -> stopped = o
        }
        saveIndex()
        problem = stopped?.problem; problemText = stopped?.message
        Log.d("folder export: ${outcomes.count { it is Outcome.Wrote }} written, ${outcomes.count { it is Outcome.Unchanged }} unchanged${stopped?.let { ", stopped: ${it.problem}" } ?: ""}")
        if (stopped == null) notified = false
        // A lost grant is told once after a meeting (never for 也存一份); a missing folder never.
        if (stopped?.problem == Problem.Denied && fromMeeting && !notified) { notified = true; notifyDenied() }
        app.changed()
    }

    /// On the worker. Stops at the first problem: the rest would fail the same way.
    private fun write(resolver: ContentResolver, folder: Uri, jobs: List<Job>, ours: MutableMap<String, String>): List<Outcome> {
        Saf.access(app, folder)?.let { return listOf(Outcome.Stopped(it)) }
        val out = mutableListOf<Outcome>()
        try {
            // Child queries ignore a selection on most providers: list once, match names here.
            val listing = Saf.children(resolver, folder)
            val parent = Saf.root(folder)
            for (job in jobs) {
                val mine = ours.filterKeys { it != job.id }.values.toSet()
                val name = FolderExportFormat.fileName(job.stem) { c -> c != job.old && (c in mine || c in listing) }
                // The stored URI is a hint; a path-based provider gives a renamed file a new one.
                val existing = job.old?.let { listing[it] }
                val doc: Uri
                if (existing != null && name == job.old) {
                    if (Saf.read(resolver, existing) == job.text) { out.add(Outcome.Unchanged(job.id)); continue }
                    Saf.write(resolver, existing, job.text)
                    doc = existing
                } else if (existing != null) {
                    // A new name moves the file: renamed in place, else written anew and the old one deleted.
                    val renamed = try { DocumentsContract.renameDocument(resolver, existing, name) } catch (e: SecurityException) { throw e } catch (_: Exception) { null }
                    if (renamed != null) {
                        listing.remove(job.old); doc = renamed
                        Saf.write(resolver, doc, job.text)
                    } else {
                        doc = Saf.create(resolver, parent, name)
                        Saf.write(resolver, doc, job.text)
                        try { DocumentsContract.deleteDocument(resolver, existing) } catch (e: SecurityException) { throw e } catch (_: Exception) {}
                        listing.remove(job.old)
                    }
                } else {
                    doc = Saf.create(resolver, parent, name)
                    Saf.write(resolver, doc, job.text)
                }
                // SAF may have named it otherwise (a collision it saw, an extension it added).
                val actual = Saf.displayName(resolver, doc) ?: name
                listing[actual] = doc
                ours[job.id] = actual
                out.add(Outcome.Wrote(job.id, actual, doc.toString()))
            }
        } catch (e: SecurityException) {
            out.add(Outcome.Stopped(Problem.Denied))
        } catch (e: Exception) {
            out.add(if (Saf.displayName(resolver, Saf.root(folder)) == null) Outcome.Stopped(Problem.Missing)
                    else Outcome.Stopped(Problem.Failed, e.message ?: e.javaClass.simpleName))
        }
        return out
    }

    private fun saveIndex() = index.save(indexFile)

    private fun notifyDenied() {
        val nm = app.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, L("存到文件夹"), NotificationManager.IMPORTANCE_DEFAULT))
        val open = PendingIntent.getActivity(app, 20, Intent(app, SettingsActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                                             PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = Notification.Builder(app, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(L("纪要没存到文件夹"))
            .setContentText(LF("知了没有权限写入 %@。点按去设置", shortPath))
            .setStyle(Notification.BigTextStyle().bigText(LF("知了没有权限写入 %@。点按去设置", shortPath)))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        try { nm.notify(NOTIFICATION, n); Log.d("folder export: notified denied") } catch (e: Exception) { Log.d("folder export: notification not shown ${e.javaClass.simpleName}") }
    }

    /// The debug command's view (`export state`): no meeting text, only names and counts.
    fun debugState(): Map<String, Any?> = mapOf(
        "on" to on, "folder" to settings.exportFolder, "short" to shortPath, "problem" to problem?.name, "message" to problemText,
        "checking" to checking, "vault" to vault, "files" to index.files.toSortedMap(), "pending" to index.pending.toList(),
        "unwritten" to unwritten.size, "lastFile" to index.lastFile, "lastAt" to index.lastAt?.toString(),
        "grants" to app.contentResolver.persistedUriPermissions.map { it.uri.toString() },
    )

    companion object {
        const val NOTIFICATION = 3
        private const val CHANNEL = "folder"
    }
}

/// The Storage Access Framework calls 存到文件夹 makes, on the exporter's worker thread.
object Saf {
    class Probe(val problem: FolderExporter.Problem?, val message: String? = null)

    /// The tree's own document.
    fun root(tree: Uri): Uri = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))

    /// The grant first (cheap and certain), then whether the folder still answers.
    fun access(app: CicadaApp, tree: Uri): FolderExporter.Problem? {
        val granted = app.contentResolver.persistedUriPermissions.any { it.uri == tree && it.isWritePermission }
        if (!granted) return FolderExporter.Problem.Denied
        return try {
            if (displayName(app.contentResolver, root(tree)) == null) FolderExporter.Problem.Missing else null
        } catch (_: SecurityException) { FolderExporter.Problem.Denied }
    }

    /// Writes and deletes a hidden file: the check after choosing a folder.
    fun probe(app: CicadaApp, tree: Uri): Probe {
        access(app, tree)?.let { return Probe(it) }
        val r = app.contentResolver
        return try {
            // octet-stream: a provider adds no extension to a name it has no type for.
            val doc = DocumentsContract.createDocument(r, root(tree), "application/octet-stream", ".cicada-check") ?: throw IllegalStateException("not created")
            try { DocumentsContract.deleteDocument(r, doc) } catch (_: Exception) {}
            Probe(null)
        } catch (_: SecurityException) { Probe(FolderExporter.Problem.Denied) }
        catch (e: Exception) { Probe(FolderExporter.Problem.Failed, e.message ?: e.javaClass.simpleName) }
    }

    /// The folder's files by name.
    fun children(r: ContentResolver, tree: Uri): MutableMap<String, Uri> {
        val out = HashMap<String, Uri>()
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        r.query(uri, arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0) ?: continue
                val name = c.getString(1) ?: continue
                out[name] = DocumentsContract.buildDocumentUriUsingTree(tree, id)
            }
        } ?: throw java.io.FileNotFoundException("no listing")
        return out
    }

    /// Null when the provider doesn't answer: the document (or folder) is gone.
    fun displayName(r: ContentResolver, doc: Uri): String? = try {
        r.query(doc, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    } catch (e: SecurityException) { throw e } catch (_: Exception) { null }

    fun create(r: ContentResolver, parent: Uri, name: String): Uri =
        DocumentsContract.createDocument(r, parent, "text/markdown", name) ?: throw java.io.IOException("not created")

    fun read(r: ContentResolver, doc: Uri): String? = try {
        r.openInputStream(doc)?.use { it.readBytes().toString(Charsets.UTF_8) }
    } catch (e: SecurityException) { throw e } catch (_: Exception) { null }

    /// No atomic replace in SAF, so the caller skips unchanged text. "wt" truncates; "w" only for a
    /// provider that rejects "wt" (most providers truncate on "w" too).
    fun write(r: ContentResolver, doc: Uri, text: String) {
        val bytes = text.toByteArray(Charsets.UTF_8)
        val stream = try { r.openOutputStream(doc, "wt") } catch (e: SecurityException) { throw e } catch (_: IllegalArgumentException) { null }
            ?: r.openOutputStream(doc, "w") ?: throw java.io.IOException("not writable")
        stream.use { it.write(bytes) }
    }

    /// "Documents › Cicada": the tree's display name, and its parent's from the document id when
    /// the provider uses paths (external storage: "primary:Documents/Cicada").
    fun shortPath(r: ContentResolver, tree: Uri): String? {
        val name = try { displayName(r, root(tree)) } catch (_: Exception) { null } ?: return null
        val path = DocumentsContract.getTreeDocumentId(tree).substringAfter(':', "")
        val parent = path.trimEnd('/').split('/').dropLast(1).lastOrNull()?.takeIf { it.isNotEmpty() }
        return if (parent != null) "$parent › $name" else name
    }
}
