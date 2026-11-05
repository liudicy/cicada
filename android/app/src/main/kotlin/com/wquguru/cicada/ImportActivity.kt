package com.wquguru.cicada

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.LinearLayout
import cicada.Languages
import cicada.Strings.L

/// 导入录音或视频 (the Mac's FileImport): pick a file, or share one to 知了 from another app, and it
/// becomes a meeting record: transcribed, translated and summarised like one that was heard. It
/// runs in the foreground service, so it goes on with another app in front.
class ImportActivity : Activity() {
    private lateinit var ui: Ui
    private lateinit var content: FrameLayout
    private var shown: String? = null
    /// The meeting this screen started or watched, to open once it's done.
    private var watching: String? = null
    private var unobserve: (() -> Unit)? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ui = Ui(this)
        watching = savedInstanceState?.getString("watching")
        content = FrameLayout(this)
        val body = ui.stack(0, content).apply { setPadding(ui.dp(16), ui.dp(8), ui.dp(16), ui.dp(24)) }
        setContentView(ui.screen(this, L("导入录音或视频"), back = true, ground = Palette.ground, body = body))
        if (savedInstanceState == null) shared(intent)?.let(::start)
    }

    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); shared(intent)?.let(::start) }

    /// The file another app shared (分享到知了).
    private fun shared(intent: Intent?): Uri? {
        if (intent?.action != Intent.ACTION_SEND) return null
        return if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
               else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
    }

    private fun start(uri: Uri) {
        cicada.importFile(this, uri)
        watching = null
        shown = null
        render()
    }

    override fun onResume() { super.onResume(); unobserve = cicada.observe(::render); shown = null; render() }
    override fun onPause() { super.onPause(); unobserve?.invoke(); unobserve = null }
    override fun onSaveInstanceState(out: Bundle) { super.onSaveInstanceState(out); watching?.let { out.putString("watching", it) } }

    private fun render() {
        val app = cicada
        val file = app.importing
        if (file != null) watching = app.listen.sessionId
        val done = watching?.takeIf { file == null }?.let { app.store.get(it) }
        val key = listOf(file?.done?.toInt(), file?.total?.toInt(), done?.id, done?.lines?.size, app.startProblem, app.listen.listening, app.settings.target).joinToString("|")
        if (key == shown) return
        shown = key
        content.removeAllViews()
        val column = ui.stack(12)
        when {
            file != null -> {
                val s = app.listen.sessionId?.let { app.store.get(it) }
                column.addView(ui.card(fileRow(s?.sourceFile ?: "", file.total)).apply {
                    addView(ui.row(8, ui.dot(Palette.accent), ui.text(L("正在转写"), 15f, Palette.ink, bold = true)), ui.lp(top = 18))
                    addView(NotesViews.progress(ui, file), ui.lp(top = 10))
                    addView(ui.helper(L("切到别的 app 也会继续，通知栏里能看进度")), ui.lp(top = 10))
                })
                column.addView(ui.group(listOf(
                    ui.listRow(L("文件里说的"), null, trailing = ui.text(app.listen.spoken?.let { NotesViews.languageName(it) } ?: L("自动识别"), 15f, Palette.secondary), chevron = false),
                    ui.listRow(L("翻译成"), null, trailing = ui.text(NotesViews.languageName(app.settings.targetCode), 15f, Palette.secondary), chevron = false),
                    ui.listRow(L("转完后生成纪要"), null, trailing = ui.text(L("开"), 15f, Palette.secondary), chevron = false))), ui.lp(top = 12))
                column.addView(ui.button(L("在后台继续"), "primary") { finish() }, ui.lp(top = 20))
                column.addView(ui.button(L("停止转写"), "quiet") { app.stopListening() }.apply { background = null }, ui.lp(top = 4))
            }
            done != null -> {
                column.addView(ui.card(fileRow(done.sourceFile ?: "", done.durationSeconds), gap = 16).apply {
                    addView(ui.text(L("转写完成"), 17f, Palette.ink, bold = true), ui.lp(top = 18))
                    addView(ui.helper("${done.lines.size} ${L("句")} · ${L("纪要在会议记录里")}"), ui.lp(top = 4))
                    addView(ui.button(L("查看会议记录"), "primary") {
                        startActivity(Intent(this@ImportActivity, RecordActivity::class.java).putExtra("id", done.id)); finish()
                    }, ui.lp(top = 18))
                })
            }
            else -> {
                val card = ui.card(gap = 14)
                card.addView(ui.row(12, ui.tile(R.drawable.i_import, 52, Palette.ink, android.graphics.Color.WHITE).apply { background = ui.rounded(Palette.ink, 14) },
                    ui.stack(3, ui.text(L("录音、视频都可以"), 17f, Palette.ink, bold = true), ui.helper(L("m4a、mp3、wav、mp4、mov…"))).apply { layoutParams = ui.weight() }))
                card.addView(ui.helper(L("转成一场会议记录：双语文字记录和纪要。也可以在别的 app 里分享到知了。")))
                app.startProblem?.let { card.addView(ui.text(it, 14f, Palette.link)) }
                card.addView(ui.button(L("选择文件"), "primary", R.drawable.i_import) { pick() }.apply { isEnabled = !app.listen.listening })
                column.addView(card)
            }
        }
        content.addView(column)
    }

    private fun fileRow(name: String, seconds: Double) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = ui.rounded(Palette.ground, 20)
        setPadding(ui.dp(14), ui.dp(14), ui.dp(14), ui.dp(14))
        addView(ui.tile(R.drawable.i_pip, 52, Palette.ink, android.graphics.Color.WHITE).apply { background = ui.rounded(Palette.ink, 12) })
        addView(ui.stack(3, ui.text(name, 16f, Palette.ink, bold = true, lines = 2), ui.helper(if (seconds > 0) Languages.clock(seconds) else "")),
                ui.weight().apply { leftMargin = ui.dp(14) })
    }

    private fun pick() {
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
            .putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("audio/*", "video/*"))
        @Suppress("DEPRECATION") startActivityForResult(i, 9)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == 9 && resultCode == RESULT_OK) data?.data?.let(::start)
    }
}
