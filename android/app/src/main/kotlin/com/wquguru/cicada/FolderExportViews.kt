package com.wquguru.cicada

import android.app.Activity
import android.content.Intent
import android.provider.DocumentsContract
import android.view.View
import android.widget.LinearLayout
import cicada.Log
import cicada.Session
import cicada.Strings
import cicada.Strings.L
import cicada.Strings.LF

/// 设置 › 会后存一份 and the record's line under its title (the Mac's FolderExportViews.swift).
/// There is no default folder on a phone: the system's folder picker chooses, and its grant is kept.
object FolderExportViews {
    const val PICK = 41

    /// The section: label, card, and the grey 上次存于 line under it.
    fun section(activity: Activity, ui: Ui, page: LinearLayout) {
        val ex = activity.cicada.folderExport
        page.addView(ui.sectionLabel(L("会后存一份")))
        val rows = mutableListOf<View>(ui.switchRow(L("存到文件夹"), L("纪要和文字记录存成 Markdown；文件夹同步到哪，内容就到哪"), ex.on) { on ->
            when {
                !on -> ex.turnOff()
                // A folder chosen before whose grant still holds: on again, as on the Mac.
                ex.tree?.let { t -> activity.contentResolver.persistedUriPermissions.any { it.uri == t && it.isWritePermission } } == true -> ex.choose(ex.tree!!)
                else -> pick(activity)
            }
        })
        if (ex.on) {
            if (ex.checking) rows.add(ui.listRow(LF("正在确认能写入 %@…", ex.shortPath), chevron = false))
            else ex.problem?.let { rows.add(problemRow(activity, ui, it)) }
            val buttons = ui.row(4).apply {
                if (ex.vault) addView(ui.badge(L("Obsidian 库"), fg = Palette.body, bg = Palette.ground))
                ex.openFolderIntent()?.let { open -> addView(ui.textButton(L("打开")) { activity.startActivity(open) }) }
                addView(ui.textButton(L("更改…")) { pick(activity) })
            }
            rows.add(ui.listRow(L("位置"), ex.shortPath, trailing = buttons, chevron = false))
            val left = ex.unwritten.size
            if (left > 0) rows.add(ui.listRow(L("以前的会议"), LF("还有 %lld 场没存", left), trailing = ui.textButton(L("也存一份")) { ex.writeAll() }, chevron = false))
        }
        page.addView(ui.group(rows))
        val last = ex.index.lastFile
        val at = ex.index.lastAt
        if (ex.on && last != null && at != null) {
            val pattern = android.text.format.DateFormat.getBestDateTimePattern(Strings.locale, "MMMdHHmm")
            val time = java.time.format.DateTimeFormatter.ofPattern(pattern, Strings.locale).withZone(java.time.ZoneId.systemDefault()).format(at)
            page.addView(ui.helper(LF("上次存于 %@ · %@", time, last), Palette.tertiary).apply {
                maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
                setPadding(ui.dp(16), ui.dp(6), ui.dp(16), 0)
            })
        }
    }

    /// A lost grant and a folder that is gone look the same from here: 找不到, and 重新选.
    private fun problemRow(activity: Activity, ui: Ui, problem: FolderExporter.Problem): View {
        val ex = activity.cicada.folderExport
        val box = ui.stack(2).apply { setPadding(ui.dp(12), ui.dp(10), ui.dp(12), ui.dp(10)) }
        val texts = ui.stack(2)
        when (problem) {
            FolderExporter.Problem.Failed -> {
                texts.addView(ui.text(L("没存上"), 15f, Palette.ink, bold = true))
                ex.problemText?.let { texts.addView(ui.helper(it).apply { maxLines = 2 }) }
            }
            else -> {
                texts.addView(ui.text(LF("找不到 %@", ex.shortPath), 15f, Palette.ink, bold = true))
                if (problem == FolderExporter.Problem.Missing) texts.addView(ui.helper(L("接上或换个文件夹后自动补存")))
            }
        }
        val line = ui.row(8, texts.apply { layoutParams = ui.weight() }, ui.textButton(L("重新选")) { pick(activity) })
        box.addView(line)
        box.background = ui.rounded(if (problem == FolderExporter.Problem.Denied) Palette.accentPale else Palette.ground, 12)
        return LinearLayout(activity).apply {
            setPadding(ui.dp(10), ui.dp(8), ui.dp(10), ui.dp(8))
            addView(box, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        }
    }

    /// The system's folder picker, starting at Documents (or the folder in use).
    fun pick(activity: Activity) {
        val start = activity.cicada.folderExport.tree?.let { DocumentsContract.buildDocumentUriUsingTree(it, DocumentsContract.getTreeDocumentId(it)) }
            ?: DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", "primary:Documents")
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
            .putExtra(DocumentsContract.EXTRA_INITIAL_URI, start)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, PICK)
        } catch (e: Exception) { Log.d("folder export: no folder picker ${e.javaClass.simpleName}") }
    }

    /// The picker's answer: the grant kept, the folder chosen. Cancelled: the switch stays (or goes back) off.
    fun picked(activity: Activity, resultCode: Int, data: Intent?) {
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { activity.cicada.changed(); return }
        try {
            activity.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        } catch (e: Exception) { Log.d("folder export: grant not kept ${e.javaClass.simpleName}") }
        activity.cicada.folderExport.choose(uri)
    }

    /// The record's grey line: where its file is, or why it isn't there yet. Null when there is
    /// nothing to say (off, or the record isn't settled).
    fun recordLine(activity: Activity, ui: Ui, s: Session): View? {
        val ex = activity.cicada.folderExport
        if (!ex.on || !ex.ready(s)) return null
        fun note(text: String) = ui.text(text, 12f, Palette.tertiary, lines = 1)
        fun link(text: String, run: () -> Unit) = ui.text(text, 12f, Palette.link, bold = true, lines = 1).apply {
            setPadding(ui.dp(4), ui.dp(8), ui.dp(4), ui.dp(8))
            ui.tappable(this, 8, onClick = run)
        }
        val pending = ex.isPending(s.id)
        val row = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL; gravity = android.view.Gravity.CENTER_VERTICAL }
        when {
            !pending && ex.file(s.id) != null -> {
                val reveal = ex.revealIntent(s.id)
                // Nothing opens Markdown here: the line ends at the folder.
                row.addView(note(LF("已存到 %@ ·", ex.shortPath).let { if (reveal == null) it.removeSuffix("·").trimEnd() else it }))
                if (reveal != null) row.addView(link(L("打开")) {
                    try { activity.startActivity(reveal) } catch (e: Exception) { Log.d("folder export: reveal failed ${e.javaClass.simpleName}") }
                })
            }
            pending && ex.problem != null -> {
                row.addView(note(L("没存到文件夹 ·")))
                row.addView(link(L("去设置")) { activity.startActivity(Intent(activity, SettingsActivity::class.java)) })
            }
            pending -> row.addView(note(LF("整理好后存到 %@", ex.shortPath)))
            else -> return null
        }
        return row
    }
}
