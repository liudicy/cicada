// cicada-cli: the Android engines without Android (scripts/cli.sh runs it).
//
//   cicada-cli test                       the unit tests (no network)
//   cicada-cli listen <file.wav> [--target zh-CN] [--speed 1|0] [--notes] [--log]
//       Plays the file into ListenEngine as if the phone were playing it, prints each line as it
//       is recorded, then the record's folder. --notes waits for the final notes and prints them.
//   cicada-cli hear <file.wav> [--target zh-CN]   one file to Ming, raw reply printed
//   cicada-cli segments <file.wav>        where the segmenter cuts
//   cicada-cli roundtrip <session.json>…  reads and writes records, says if a byte changed
//
// Records go to CICADA_HOME (default: a temp folder). The key comes from CICADA_KEY_FILE, else the
// Mac app's dev or release key file; it is never printed.
package cicada.cli

import cicada.*
import java.io.File
import kotlin.system.exitProcess

val resources: File = File(System.getProperty("cicada.resources") ?: "../Resources")

fun loadStrings(ui: String) = Strings.load(ui) { rel ->
    val mac = File(resources, rel)
    val android = File(System.getProperty("cicada.androidStrings") ?: "app/src/main/strings", rel)
    when {
        rel.endsWith("Android.strings") && android.isFile -> android.readText()
        mac.isFile -> mac.readText()
        else -> null
    }
}

fun macKeyFile(): File? = System.getenv("CICADA_KEY_FILE")?.let(::File)
    ?: listOf("LiveSubs Dev", "LiveSubs").map { File(System.getProperty("user.home"), "Library/Application Support/$it/ling-api-key") }.firstOrNull { it.isFile }

fun main(argv: Array<String>) {
    val args = argv.toList()
    if (args.isEmpty()) { println("usage: cicada-cli test|listen|hear|segments|roundtrip …"); exitProcess(2) }
    fun opt(name: String, fallback: String) = args.indexOf(name).let { if (it >= 0 && it + 1 < args.size) args[it + 1] else fallback }
    loadStrings(opt("--ui", "zh-Hans"))
    when (args[0]) {
        "test" -> exitProcess(Tests.run())
        "segments" -> {
            val pcm = Wav.read(File(args[1]).inputStream())
            val list = mutableListOf<Segment>()
            val seg = Segmenter().apply { onSegment = { list.add(it) } }
            var i = 0
            while (i < pcm.size) { seg.feed(pcm.copyOfRange(i, minOf(pcm.size, i + 1600))); i += 1600 }
            seg.flush()
            for (s in list) println("%3d %7.2fs %5.2fs".format(s.index, s.start, s.seconds))
            println("${list.size} segments, ${"%.1f".format(list.sumOf { it.seconds })}s of speech")
        }
        "roundtrip" -> {
            var changed = 0
            for (path in args.drop(1).filter { !it.startsWith("--") }) {
                val original = File(path).readText()
                val session = Session.read(original)
                val written = session?.let { Json.write(it.toJson()) }
                val same = written == original
                if (!same) changed++
                println("${if (same) "same   " else "CHANGED"} $path (${session?.lines?.size ?: 0} lines${if (session?.notes == null) "" else ", notes"})")
                if (!same && args.contains("--diff") && written != null) {
                    val a = original.lines(); val b = written.lines()
                    val at = a.indices.firstOrNull { it >= b.size || a[it] != b[it] } ?: a.size
                    println("  first difference at line ${at + 1}:\n  mac:     ${a.getOrNull(at)}\n  android: ${b.getOrNull(at)}")
                }
            }
            exitProcess(if (changed == 0) 0 else 1)
        }
        "hear" -> {
            val ling = LingClient(AIKey(PlainProtector, macKeyFile()))
            val target = opt("--target", "zh-CN")
            val reply = ling.chat(Translator.hearPrompt(target, null, emptyList()), Translator.hearInstruction(target), Priority.Translate,
                                  maxTokens = 800, timeout = 20.0, model = LingClient.AUDIO_MODEL, audio = Wav.bytes(Wav.read(File(args[1]).inputStream())))
            println(reply)
            println("-> ${Translator.parseHeard(reply, target, null)}")
        }
        "listen" -> {
            Log.echo = args.contains("--log")
            val key = AIKey(PlainProtector, macKeyFile())
            if (key.read() == null) { println("no Ling key (set CICADA_KEY_FILE)"); exitProcess(2) }
            val settings = AppSettings(target = opt("--target", "zh-CN"))
            val ling = LingClient(key)
            val store = SessionStore()
            val notes = NotesEngine(ling, store)
            val engine = ListenEngine(ling, Translator(ling), store, notes, settings)
            val shown = HashMap<String, String>()
            val started = System.currentTimeMillis()
            engine.onChange {
                val id = engine.sessionId ?: return@onChange
                synchronized(shown) {
                    for (l in store.lines(id)) {
                        val text = "${l.src}\n${" ".repeat(17)}→ ${l.dst ?: "…"}"
                        if (shown[l.id] == text) continue
                        val tag = if (shown.containsKey(l.id)) "upd" else "new"
                        shown[l.id] = text
                        println("[%5.1f] %s %s %-5s %s".format((System.currentTimeMillis() - started) / 1000.0, tag, Languages.clock(l.t), l.srcLang, text))
                    }
                }
            }
            val ended = java.util.concurrent.CountDownLatch(1)
            val source = PcmAudioSource(File(args[1]), opt("--speed", "1").toDouble())
            source.onEnded = { ended.countDown() }
            engine.start(source, "file")
            ended.await()
            Thread.sleep(1500)
            engine.stop()
            val id = engine.sessionId!!
            if (args.contains("--notes")) {
                for (i in 0 until 120) { if (store.get(id)?.notes?.final == true) break; Thread.sleep(1000) }
            }
            store.flush()
            val record = store.get(id)
            println("\n${record?.lines?.size ?: 0} lines in ${File(Paths.sessions, id)}")
            record?.notes?.let { n ->
                println("notes${if (n.final) " (final)" else ""}: ${n.title}\n  ${n.summary}")
                for (t in n.topics) println("  ${Languages.clock(t.start)} ${t.title}: ${t.points.joinToString(" / ")}")
                for (t in n.todos) println("  [ ] ${t.text} (${t.owner})")
            }
            exitProcess(0)
        }
        else -> { println("unknown command ${args[0]}"); exitProcess(2) }
    }
}
