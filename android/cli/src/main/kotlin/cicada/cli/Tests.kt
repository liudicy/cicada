// Unit tests for the engines: `scripts/test.sh` (cicada-cli test). The Windows suite's cases, plus
// byte-for-byte checks of the Mac's JSON format. A failed check throws and the runner reports it.
// No network: LingClient runs against a fake transport.
package cicada.cli

import cicada.*
import java.io.File
import java.time.Instant
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin

object Tests {
    fun run(): Int {
        val home = File(System.getProperty("java.io.tmpdir"), "cicada-tests-${ProcessHandle.current().pid()}")
        Paths.root = home
        Paths.log = File(home, "debug.log")
        home.mkdirs()
        val tests: List<Pair<String, () -> Unit>> = listOf(
            "sessionJsonMatchesTheMac" to ::sessionJsonMatchesTheMac,
            "readsAMacRecordAndWritesItBackByteForByte" to ::readsAMacRecord,
            "keepsTheMacsImportAndRoomFields" to ::keepsTheMacsImportAndRoomFields,
            "jsonEdgeCases" to ::jsonEdgeCases,
            "findsTheNewestAndroidRelease" to ::findsTheNewestAndroidRelease,
            "updateCheckIsSilentAndDue" to ::updateCheckIsSilentAndDue,
            "renamesLikeTheMac" to ::renamesLikeTheMac,
            "theLiveMeetingCantBeDeleted" to ::theLiveMeetingCantBeDeleted,
            "followSystemLikeTheMac" to ::followSystemLikeTheMac,
            "anUntranslatedSentenceIsNeitherSentNorRecorded" to ::anUntranslatedSentenceIsNeitherSentNorRecorded,
            "storeSavesAndDropsEmptyMeetings" to ::storeSavesAndDropsEmptyMeetings,
            "closesInterruptedMeetings" to ::closesInterruptedMeetings,
            "exportsLikeTheMac" to ::exportsLikeTheMac,
            "namesAVoiceLikeTheMac" to ::namesAVoiceLikeTheMac,
            "displayTitle" to ::displayTitle,
            "parsesMingReplies" to ::parsesMingReplies,
            "dropsNoise" to ::dropsNoise,
            "speaksOnlyTranslations" to ::speaksOnlyTranslations,
            "hangUpEndsAfterTheGrace" to ::hangUpEndsAfterTheGrace,
            "rejoiningWithinTheGraceKeepsGoing" to ::rejoiningWithinTheGraceKeepsGoing,
            "speechDoesNotCancelAHangUp" to ::speechDoesNotCancelAHangUp,
            "keepGoingForgetsTheHangUp" to ::keepGoingForgetsTheHangUp,
            "silencePromptsThenEnds" to ::silencePromptsThenEnds,
            "wordsCancelTheSilencePrompt" to ::wordsCancelTheSilencePrompt,
            "silenceEndModeEndsAtOnceAndOffNever" to ::silenceEndModeEndsAtOnceAndOffNever,
            "silenceDoesNotCountDuringACall" to ::silenceDoesNotCountDuringACall,
            "nothingSaidStopsQuietlyAfterTheSilence" to ::nothingSaidStopsQuietlyAfterTheSilence,
            "nothingSaidKeepsListening" to ::nothingSaidKeepsListening,
            "endsAtTheGivenTime" to ::endsAtTheGivenTime,
            "holdToSayAndEchoGate" to ::holdToSayAndEchoGate,
            "normalizesLanguages" to ::normalizesLanguages,
            "cleansTranslations" to ::cleansTranslations,
            "joinsCutSentences" to ::joinsCutSentences,
            "segmentsOnPauses" to ::segmentsOnPauses,
            "cutsLongSpeechAtItsQuietestMoment" to ::cutsLongSpeech,
            "ignoresClicks" to ::ignoresClicks,
            "wavRoundTrip" to ::wavRoundTrip,
            "parsesNotes" to ::parsesNotes,
            "keepsEarliestTimes" to ::keepsEarliestTimes,
            "notesPromptIsTheMacs" to ::notesPromptIsTheMacs,
            "loadsTheMacsTranslations" to ::loadsTheMacsTranslations,
            "keyFileIsPrivate" to ::keyFileIsPrivate,
            "lingRequestShape" to ::lingRequestShape,
            "lingDropsHijackedAndRefusedReplies" to ::lingDropsHijacked,
            "lingRetriesAudioOnceWhenBusy" to ::lingRetriesAudioOnce,
            "lingMarksABadKey" to ::lingMarksABadKey,
            "lingGateSpacesStartsAndServesPriorityFirst" to ::lingGate,
            "listenEngineEndToEndWithAFakeMing" to ::listenEndToEnd,
        )
        var passed = 0; var failed = 0
        for ((name, test) in tests) {
            try { test(); passed++ } catch (e: Throwable) { failed++; println("FAIL $name: ${e.message ?: e.javaClass.simpleName}") }
        }
        home.deleteRecursively()
        println("$passed passed, $failed failed")
        return if (failed == 0) 0 else 1
    }

    private fun check(ok: Boolean, what: String) { if (!ok) throw AssertionError(what) }
    private fun <T> equal(expected: T, actual: T, what: String) { if (expected != actual) throw AssertionError("$what: expected «$expected», got «$actual»") }

    // MARK: Records

    fun sessionJsonMatchesTheMac() {
        val s = Session(id = "20261103-101611", title = "会议 11月3日 10:16", startedAt = Instant.parse("2026-11-03T15:16:11Z"),
                        lines = mutableListOf(TranscriptLine(id = "h1-1", t = 2.7636849899291995, src = "你好/世界", srcLang = "zh-CN", dstLang = "en")))
        val json = Json.write(s.toJson())
        check(json.contains("\"startedAt\" : \"2026-11-03T15:16:11Z\""), "dates are whole-second ISO-8601 UTC")
        check(json.contains("你好\\/世界"), "Chinese as it is, slashes escaped like JSONEncoder")
        check(!json.contains("\"dst\""), "nil optionals are left out")
        check(!json.contains("endedAt") && !json.contains("notes"), "absent fields stay absent")
        check(json.contains("2.7636849899291995"), "doubles keep full precision")
        check(json.startsWith("{\n  \"hasAudio\" : false,\n  \"id\" : "), "sorted keys, Swift's spacing")
    }

    private val MAC = """
{
  "endedAt" : "2026-11-02T15:24:12Z",
  "hasAudio" : true,
  "id" : "20261102-101639",
  "lines" : [
    {
      "dst" : "Hello \/ \"hi\"",
      "dstLang" : "en",
      "id" : "h1-1",
      "speaker" : "them",
      "src" : "你好",
      "srcLang" : "zh-CN",
      "t" : 2.5,
      "voice" : 1
    }
  ],
  "notes" : {
    "conclusions" : [

    ],
    "covered" : 1,
    "final" : true,
    "summary" : "总结",
    "terms" : [
      {
        "heard" : [

        ],
        "name" : "鸟哥",
        "note" : "分享者"
      }
    ],
    "title" : "标题",
    "todos" : [
      {
        "owner" : "你",
        "support" : 3,
        "t" : 202.4,
        "text" : "记录"
      }
    ],
    "topics" : [
      {
        "pointTimes" : [
          12.4,
          null
        ],
        "points" : [
          "a",
          "b"
        ],
        "start" : 0,
        "summary" : "s",
        "title" : "t"
      }
    ],
    "updatedAt" : "2026-11-02T15:24:40Z"
  },
  "startedAt" : "2026-11-02T15:16:39Z",
  "title" : "会议 11月2日 10:16",
  "voiceNames" : {
    "1" : "Emma"
  }
}""".trimStart()

    fun readsAMacRecord() {
        val s = Session.read(MAC)!!
        equal(1, s.lines.size, "lines")
        equal(1, s.lines[0].voice, "voice")
        equal("Hello / \"hi\"", s.lines[0].dst, "escapes read")
        equal("Emma", s.voiceNames!!["1"], "voice names")
        equal(12.4, s.notes!!.topics[0].pointTime(0), "point time")
        equal(null, s.notes!!.topics[0].pointTime(1), "missing point time")
        equal(MAC, Json.write(s.toJson()), "written back byte for byte")
    }

    /// A Mac record of an imported file heard partly in the room: Android writes it back whole.
    fun keepsTheMacsImportAndRoomFields() {
        val mac = MAC.replace("  \"id\" : \"20261102-101639\",\n", "  \"id\" : \"20261102-101639\",\n  \"importing\" : true,\n")
            .replace("  \"startedAt\"", "  \"room\" : true,\n  \"sourceFile\" : \"周会.m4a\",\n  \"sourcePath\" : \"\\/Users\\/me\\/周会.m4a\",\n  \"startedAt\"")
        check(mac.contains("\"room\"") && mac.contains("\"importing\""), "test record has the fields")
        val s = Session.read(mac)!!
        equal("周会.m4a", s.sourceFile, "source file")
        equal("/Users/me/周会.m4a", s.sourcePath, "source path")
        equal(true, s.importing, "importing"); equal(true, s.room, "room")
        equal(mac, Json.write(s.toJson()), "written back byte for byte")
        val untitled = Session.read(mac.replace("\"title\" : \"标题\",\n", ""))!!
        equal("周会", SessionStore.displayTitle(untitled), "an imported file is known by its name until the notes name it")
    }

    fun renamesLikeTheMac() {
        val store = SessionStore(loadNow = false)
        val s = store.begin(Instant.parse("2026-03-01T01:00:00Z"))
        store.append(s.id, TranscriptLine(id = "h1-1", src = "hi", srcLang = "en", dstLang = "zh-CN"))
        store.setNotes(s.id, MeetingNotes(title = "路线评审", summary = "x"))
        val auto = SessionStore.displayTitle(s)
        store.rename(s.id, auto)
        check(s.renamed != true, "saving the title already shown is no rename")
        store.rename(s.id, "  我的会 ")
        equal("我的会", s.title, "trimmed"); equal(true, s.renamed, "renamed")
        store.rename(s.id, "")
        equal(false, s.renamed, "emptied goes back to the automatic title")
        equal(auto, SessionStore.displayTitle(s), "the notes' name again")
        check(s.title.startsWith("会议 "), "the stored default title")
        store.end(s.id)
    }

    fun theLiveMeetingCantBeDeleted() {
        val store = SessionStore(loadNow = false)
        val s = store.begin(Instant.parse("2026-03-02T01:00:00Z"))
        store.append(s.id, TranscriptLine(id = "h1-1", src = "hi", srcLang = "en", dstLang = "zh-CN"))
        equal(s.id, store.liveId, "live")
        store.delete(s.id)
        check(store.get(s.id) != null, "kept while listening")
        store.end(s.id)
        equal(null, store.liveId, "not live once ended")
        store.delete(s.id)
        check(store.get(s.id) == null && !File(Paths.sessions, s.id).exists(), "deleted once ended")
        val empty = store.begin(Instant.parse("2026-03-02T02:00:00Z"))
        store.end(empty.id)
        check(store.get(empty.id) == null, "an empty live meeting is still dropped when it ends")
    }

    /// The Mac's LanguagesTests for followSystemTarget / myLanguage.
    fun followSystemLikeTheMac() {
        equal("zh-CN", Languages.myLanguage(listOf("en-US", "zh-Hans-CN")), "Chinese when the list has it")
        equal("ja", Languages.myLanguage(listOf("ja-JP", "en-US")), "else the first")
        equal("zh-CN", Languages.fromSystem("zh-Hans-HK"), "the script decides")
        equal("zh-TW", Languages.fromSystem("zh-HK"), "a region without a script")
        val zhEn = listOf("zh-Hans-CN", "en-US")
        equal("zh-CN", Languages.followSystemTarget("en", zhEn), "English into my language")
        equal("en", Languages.followSystemTarget("zh-CN", zhEn), "my language into the next system one")
        equal("en", Languages.followSystemTarget("zh-CN", listOf("zh-Hans-CN")), "only Chinese: English")
        equal("zh-CN", Languages.followSystemTarget("en", listOf("en-US")), "only English: Chinese")
        equal("zh-CN", Languages.followSystemTarget(null, zhEn), "not known yet: my language")
        val old = AppSettings.systemLanguages
        try {
            AppSettings.systemLanguages = { zhEn }
            val follow = AppSettings()
            equal("zh-CN", follow.targetCode, "my language"); equal("en", follow.targetFor("zh-CN"), "follows")
            equal("zh-CN", follow.notesCode, "notes in my language")
            equal("zh-CN", AppSettings(target = "zh-CN").targetFor("zh-CN"), "a chosen language stays")
        } finally { AppSettings.systemLanguages = old }
    }

    fun jsonEdgeCases() {
        equal("3", Json.number(3.0), "whole doubles without .0")
        equal("0.0001", Json.number(0.0001), "small doubles without an exponent")
        equal("-1.5", Json.number(-1.5), "negative")
        val parsed = Json.parse("""{"a":[1,2.5,"x中\n",true,null,{}],"b":-3e2}""").obj()!!
        equal(2.5, parsed["a"].arr()[1], "double")
        equal(1L, parsed["a"].arr()[0], "integer")
        equal("x中\n", parsed["a"].arr()[2], "unicode and newline escapes")
        equal(-300.0, parsed["b"], "exponent")
        equal("{\"a\":[1,2.5,\"x中\\n\",true,null,{}],\"b\":-300}", Json.write(parsed, pretty = false), "compact")
        check(try { Json.parse("{\"a\":1,}"); false } catch (_: Json.ParseException) { true }, "trailing comma rejected")
        equal(null, Json.parseObject("not json"), "garbage")
    }

    fun storeSavesAndDropsEmptyMeetings() {
        val store = SessionStore()
        val empty = store.begin(Instant.parse("2026-01-01T01:00:00Z"))
        store.end(empty.id)
        check(store.get(empty.id) == null && !File(Paths.sessions, empty.id).exists(), "an empty meeting is removed")
        val s = store.begin(Instant.parse("2026-01-01T02:00:00Z"))
        store.append(s.id, TranscriptLine(id = "h1-1", src = "hi", srcLang = "en", dstLang = "zh-CN"))
        store.end(s.id)
        val file = File(Paths.sessions, "${s.id}/session.json")
        check(file.isFile, "record written on end")
        equal(1, Session.read(file.readText())!!.lines.size, "line saved")
        check(SessionStore().get(s.id) != null, "loaded again")
        check(s.title.startsWith("会议 "), "default title is the Mac's Chinese form")
        val md = SessionStore.markdown(store.get(s.id)!!)
        check(md.contains("**[00:00] 对方**  \nhi\n"), "markdown export")
    }

    /// Markdown, SRT and Word as the Mac writes them; speaker numbers only once two voices
    /// have said enough, and a name the user gives shows in them.
    fun exportsLikeTheMac() {
        val them = (1..5).flatMap { i ->
            listOf(TranscriptLine(id = "a$i", t = i * 10.0, speaker = "them", src = "we should ship it now", dst = "我们现在就该发布", voice = 1),
                   TranscriptLine(id = "b$i", t = i * 10.0 + 5, speaker = "them", src = "not before the freeze", dst = "封版前不行", voice = 2))
        }
        val s = Session(id = "20260103-040506", title = "会议 1月3日 04:05", startedAt = Instant.parse("2026-01-03T04:05:06Z"),
                        lines = (them + TranscriptLine(id = "m1", t = 61.0, speaker = "me", src = "好的", dst = "OK")).toMutableList())
        s.endedAt = Instant.parse("2026-01-03T04:07:06Z")
        val numbers = SpeakerLabels.numbers(s.lines)
        equal(1, numbers["a1"], "first voice to say five lines is 1")
        equal(2, numbers["b5"], "second is 2")
        equal(emptyMap<String, Int>(), SpeakerLabels.numbers(s.lines.filter { it.voice != 2 }), "one voice stays 对方")
        s.voiceNames = mapOf("2" to "Ken")
        val md = TranscriptExport.markdown(s)
        check(md.contains("**[00:10] 说话人 1**  \nwe should ship it now\n> 我们现在就该发布\n"), "markdown speaker number")
        check(md.contains("**[00:15] Ken**"), "markdown speaker name")
        check(md.contains("**[01:01] 你**  \n好的\n> OK\n"), "markdown me")
        val srt = TranscriptExport.srt(s)
        check(srt.startsWith("1\n00:00:10,000 --> 00:00:15,000\nwe should ship it now\n我们现在就该发布\n\n2\n"), "srt cue")
        check(srt.contains("11\n00:01:01,000 --> 00:01:05,000\n好的\nOK\n"), "srt last cue ends 4 s on")
        val docx = TranscriptExport.docx(s)
        val names = java.util.zip.ZipInputStream(docx.inputStream()).use { z -> generateSequence { z.nextEntry?.name }.toList() }
        equal(listOf("[Content_Types].xml", "_rels/.rels", "word/document.xml"), names, "docx parts")
        val doc = java.util.zip.ZipInputStream(docx.inputStream()).use { z -> while (z.nextEntry?.name != "word/document.xml") {}; z.readBytes().toString(Charsets.UTF_8) }
        check(doc.contains(">[00:15] Ken<") && doc.contains(">我们现在就该发布<"), "docx text")
        SpeakerLabels.voices = false
        check(TranscriptExport.markdown(s).contains("**[00:15] 对方**"), "说话人识别 off: no numbers")
        SpeakerLabels.voices = true
    }

    fun namesAVoiceLikeTheMac() {
        val store = SessionStore()
        val s = store.begin(Instant.parse("2026-01-04T02:00:00Z"))
        store.append(s.id, TranscriptLine(id = "h1-1", src = "hi there everyone", voice = 3))
        store.setVoiceName(s.id, 3, " Maya ")
        equal(mapOf("3" to "Maya"), store.get(s.id)!!.voiceNames, "trimmed, by voice id")
        store.setVoiceName(s.id, 3, null)
        equal(emptyMap<String, String>(), store.get(s.id)!!.voiceNames, "null drops it")
    }

    fun closesInterruptedMeetings() {
        val s = Session(id = "20260102-030405", title = "会议 1月2日 03:04", startedAt = Instant.parse("2026-01-02T03:04:05Z"),
                        lines = mutableListOf(TranscriptLine(id = "h1-1", t = 12.0, src = "hi", srcLang = "en", dstLang = "zh-CN")))
        File(Paths.sessions, s.id).mkdirs()
        File(Paths.sessions, "${s.id}/session.json").writeText(Json.write(s.toJson()))
        val loaded = SessionStore().get(s.id)!!
        equal(Instant.parse("2026-01-02T03:04:22Z"), loaded.endedAt, "ends 5 s after its last line")
        check(File(Paths.sessions, "${s.id}/session.json").readText().contains("\"endedAt\""), "saved")
    }

    fun displayTitle() {
        val s = Session(title = "会议 1月1日 10:00", startedAt = Instant.now(), notes = MeetingNotes(title = "路线评审", summary = "x"))
        check(SessionStore.displayTitle(s).endsWith(" 路线评审"), "notes' name after the date")
        s.renamed = true; s.title = "我的会"
        equal("我的会", SessionStore.displayTitle(s), "the user's title wins")
    }

    // MARK: Hearing

    fun parsesMingReplies() {
        val h = Translator.parseHeard("LANG: en\nORIGINAL: Hello there.\nTRANSLATION: 你好。", "zh-CN", null)!!
        equal("en", h.lang, "lang"); equal("Hello there.", h.original, "original"); equal("你好。", h.translation, "translation")
        equal(null, Translator.parseHeard("作为一个人工智能语言模型，这个问题超出我目前的学习范围了", "zh-CN", null), "no labelled lines")
        equal(null, Translator.parseHeard("LANG: en\nORIGINAL: NONE\nTRANSLATION: 无", "zh-CN", null), "no speech")
        equal(null, Translator.parseHeard("LANG: en\nORIGINAL: ...\nTRANSLATION: …", "zh-CN", null), "punctuation only")
        val same = Translator.parseHeard("LANG: zh\nORIGINAL: 好的\nTRANSLATION: OK", "zh-CN", "en")!!
        equal("zh-CN", same.lang, "zh normalized"); equal("好的", same.translation, "already in the target: kept as is")
        val wrong = Translator.parseHeard("LANG: en\nORIGINAL: Hi\nTRANSLATION: Hi again", "zh-CN", null)!!
        equal(null, wrong.translation, "a translation not in Chinese is dropped for the text translator")
        equal("ja", Translator.parseHeard("lang: ja-JP\noriginal: はい\ntranslation: 是", "zh-CN", null)!!.lang, "labels in any case")
    }

    // Same cases as the Windows and Linux ports' noise tests.
    fun dropsNoise() {
        for (o in listOf("嗯。", "Mm.", "uh, um", "呃呃呃呃呃", "嗯，嗯，嗯，嗯，嗯，嗯，嗯，嗯，嗯，嗯，嗯，嗯。", "滴答".repeat(50),
                         "hmmmm", "うーん", "음…", "喂？", "No no no no no no",
                         "（无语音内容）", "[Music]", "♪♪", "这段音频是一段旋律，没有说话声。", "There is no speech in this audio."))
            check(Translator.isNoise(o), "noise: $o")
        for (o in listOf("嗯，好的。", "OK.", "Oh no, it crashed.", "对", "对对对", "谢谢谢谢", "喂喂，能听到吗？", "No, no, no.",
                         "えーと、来週の件ですが", "あの人です", "Okay, let's move on to the quarterly numbers.", "（笑）好的"))
            check(!Translator.isNoise(o), "kept: $o")
        val long = "我们今天讨论一下这个季度的数字和下个季度的计划安排"
        check(Translator.isNoise(long, 1.0), "more than anyone says in a second")
        check(!Translator.isNoise(long, 4.0), "said in four seconds")
        equal(null, Translator.parseHeard("LANG: zh-CN\nORIGINAL: 嗯，嗯，嗯，嗯，嗯，嗯。\nTRANSLATION: 嗯，嗯，嗯，嗯，嗯，嗯。", "zh-CN", null), "hold music")
        equal(800, Translator.hearTokens(0.0), "unknown length"); equal(380, Translator.hearTokens(8.0), "a full segment")
        equal(800, Translator.hearTokens(30.0), "capped")
    }

    fun normalizesLanguages() {
        equal("zh-CN", Languages.normalize("zh-Hans", "en"), "zh-Hans")
        equal("zh-TW", Languages.normalize("zh-TW", "en"), "zh-TW")
        equal("zh-CN", Languages.normalize("cmn", "en"), "cmn")
        equal("en", Languages.normalize("en-US", "ja"), "en-US")
        equal("ja", Languages.normalize("", "ja"), "empty falls back")
        equal("zh-TW", Languages.fromSystem("zh-Hant-HK"), "system zh-Hant")
        equal("zh-CN", Languages.fromSystem("zh-CN"), "system zh-CN")
        equal("en", Languages.fromSystem("en-GB"), "system en")
        equal("Simplified Chinese", Languages.englishName("zh-CN"), "english name")
        equal("Japanese", Languages.englishName("ja"), "english name ja")
        equal("01:05", Languages.clock(65.9), "clock"); equal("1:00:01", Languages.clock(3601.0), "clock hours")
    }

    fun cleansTranslations() {
        equal("你好", Translator.cleanTranslation("Translation: 你好", "zh-CN"), "label stripped")
        equal("你好", Translator.cleanTranslation("“你好”", "zh-CN"), "wrapping quotes")
        equal("Hello", Translator.cleanTranslation("Here is the translation:\nHello", "en"), "remark line dropped")
        equal(null, Translator.cleanTranslation("请提供需要翻译的字幕内容", "en"), "a request for input is not a translation")
        equal(null, Translator.cleanTranslation("Hello", "zh-CN"), "wrong script")
        equal("Done.", Translator.cleanTranslation("<think>x</think>Done.", "en"), "leaked reasoning")
    }

    fun joinsCutSentences() {
        val last = TranscriptLine(src = "We finished the migration and", srcLang = "en")
        check(ListenEngine.continues(last, 0.2, Heard("en", "the error rate dropped.", null)), "mid-sentence cut joins")
        check(!ListenEngine.continues(last, 1.5, Heard("en", "next", null)), "a long gap doesn't")
        check(!ListenEngine.continues(TranscriptLine(src = "Done.", srcLang = "en"), 0.1, Heard("en", "Next", null)), "after a full stop doesn't")
        check(!ListenEngine.continues(last, 0.1, Heard("ja", "はい", null)), "another language doesn't")
        equal("我们完成了迁移", ListenEngine.join("我们完成了", "迁移", "zh-CN"), "CJK joins without a space")
        equal("a b", ListenEngine.join("a ", " b", "en"), "others with one space")
    }

    // MARK: Segmenter

    private fun tone(seconds: Double, amp: Double = 0.3) = ShortArray((seconds * 16000).toInt()) { (sin(2 * PI * 300 * it / 16000) * amp * 32767).toInt().toShort() }
    private fun silence(seconds: Double) = ShortArray((seconds * 16000).toInt())
    private fun concat(vararg parts: ShortArray): ShortArray = parts.fold(ShortArray(0)) { a, b -> a + b }

    private fun cut(vararg parts: ShortArray): List<Segment> {
        val list = mutableListOf<Segment>()
        val seg = Segmenter().apply { onSegment = { list.add(it) } }
        for (p in parts) { var i = 0; while (i < p.size) { seg.feed(p.copyOfRange(i, minOf(p.size, i + 1600))); i += 1600 } }
        seg.flush()
        return list
    }

    fun segmentsOnPauses() {
        val list = cut(silence(0.5), tone(2.0), silence(1.0), tone(1.5), silence(1.0))
        equal(2, list.size, "two stretches")
        check(abs(list[0].start - 0.35) < 0.05, "starts just before the speech (pre-roll), got ${list[0].start}")
        check(abs(list[1].start - 3.35) < 0.05, "second start, got ${list[1].start}")
        check(list[0].seconds in 2.1..2.4, "length with lead-in and tail, got ${list[0].seconds}")
    }

    fun cutsLongSpeech() {
        // After a first short stretch: 7 s of speech, a 0.3 s dip (shorter than a pause), 4 s
        // more: one cut, at the dip.
        val list = cut(tone(1.0), silence(1.0), tone(7.0), tone(0.3, 0.004), tone(4.0), silence(1.0))
        equal(3, list.size, "the first, then the long one split in two")
        check(list[1].seconds in 6.9..7.4, "cut inside the dip, got ${list[1].seconds}")
        check(list.all { it.seconds <= 8.0 }, "no segment over 8 s")
        check(abs(list[2].start - (list[1].start + list[1].seconds)) < 0.001, "the rest carries on without a gap")
    }

    fun ignoresClicks() {
        equal(0, cut(silence(1.0), tone(0.1), silence(1.0)).size, "under 0.25 s of sound is not speech")
        equal(0, cut(tone(3.0, 0.002)).size, "below the gate is silence")
    }

    fun wavRoundTrip() {
        val pcm = tone(0.5)
        check(Wav.read(Wav.bytes(pcm).inputStream()).contentEquals(pcm), "16 kHz mono reads back exactly")
        equal(16000, Wav.resample(DoubleArray(48000), 48000).size, "48 kHz to 16 kHz")
    }

    // MARK: Notes

    fun parsesNotes() {
        val reply = """
        ```json
        {"title": "“发布评审”", "summary": "讨论发布。",
         "topics": [{"start": 0, "title": "进展", "summary": "一句", "points": [{"text": "迁移完成", "evidence": ["L2"]}, "旧格式要点", {"text": "", "evidence": []}],
                     "fishbone": {"question": "为何延期", "branches": [{"label": "测试", "detail": "x", "t": 3, "evidence": ["L1"]}, {"label": "设计", "detail": "y", "evidence": ["L9"]}]}}],
         "conclusions": [{"text": "周五上线", "evidence": ["L1", "L2", "L99"]}],
         "todos": [{"text": "发说明", "owner": "", "evidence": ["L2"]}],
         "terms": [{"name": "Stripe", "note": "支付", "heard": ["Stripe", "Strip"]}]}
        ```
        """
        val n = NotesEngine.parse(reply, listOf(1.0, 5.0), 0.0)!!
        equal("发布评审", n.title, "title quotes trimmed")
        equal(2, n.topics[0].points.size, "empty points dropped, plain strings kept")
        equal(5.0, n.topics[0].pointTime(0), "point time from evidence")
        equal(null, n.topics[0].pointTime(1), "no evidence, no time")
        equal(2, n.topics[0].fishbone!!.branches.size, "fishbone kept")
        equal(0, n.topics[0].fishbone!!.branches[1].support, "evidence beyond the transcript doesn't count")
        equal(2, n.conclusions[0].support, "support counts real lines")
        equal(null, n.todos[0].owner, "empty owner is none")
        equal("Strip", n.terms[0].heard.joinToString(","), "the correct spelling isn't a mishearing")
        equal(null, NotesEngine.parse("not json", emptyList(), 0.0), "garbage")
        equal(null, NotesEngine.parse("{}", emptyList(), 0.0), "empty notes")
    }

    fun keepsEarliestTimes() {
        val old = MeetingNotes(topics = mutableListOf(NoteTopic(title = "t", points = mutableListOf("a"), pointTimes = mutableListOf(3.0))),
                               todos = mutableListOf(NoteItem(text = "x", t = 2.0)))
        val next = MeetingNotes(topics = mutableListOf(NoteTopic(title = "t", points = mutableListOf("a", "b"), pointTimes = mutableListOf(9.0, null))),
                                todos = mutableListOf(NoteItem(text = "x", t = 8.0)))
        NotesEngine.carryTimes(old, next)
        equal(3.0, next.topics[0].pointTime(0), "a point keeps when it was first heard")
        equal(2.0, next.todos[0].t, "to-dos too")
    }

    fun notesPromptIsTheMacs() {
        val lines = listOf(TranscriptLine(t = 1.0, src = "你好", speaker = "them"), TranscriptLine(t = 65.0, src = "我来说", speaker = "me"))
        val p = NotesEngine.prompt(MeetingNotes(), lines, 0, "Simplified Chinese", final = false)
        check(p.startsWith("You keep notes for a meeting that is still going on. Update them with the new lines.\nWrite the notes in Simplified Chinese. Return JSON only.\n"), "opening")
        check(p.contains("[L1 00:01 对方] 你好\n[L2 01:05 你] 我来说"), "transcript lines")
        check(p.contains("These are the first lines: make one topic."), "first update")
        check(p.endsWith("No markdown, no text outside the JSON."), "ending")
        val f = NotesEngine.prompt(MeetingNotes(), lines, 0, "English", final = true)
        check(f.contains("This meeting ran 01:04: use at most 1 topic."), "final topic limit")
        check(NotesEngine.written(MeetingNotes(summary = "讨论发布 Stripe"), "Simplified Chinese"), "Chinese notes")
        check(!NotesEngine.written(MeetingNotes(summary = "We talked"), "Simplified Chinese"), "English isn't Chinese")
    }

    // MARK: Strings

    fun loadsTheMacsTranslations() {
        loadStrings("en")
        equal("Live notes", Strings.L("实时纪要"), "an English string")
        equal("没有这条", Strings.L("没有这条"), "missing keys show the Chinese")
        loadStrings("zh-Hans")
        equal("实时纪要", Strings.L("实时纪要"), "Chinese is the key")
        val t = Strings.parse("/* c */\n\"a \\\"b\\\"\" = \"x\\ny\";\n// line\n\"%@ 分钟\" = \"%@ min\";")
        equal("x\ny", t["a \"b\""], "escapes")
        equal("%@ min", t["%@ 分钟"], "placeholders kept")
        equal("3 分钟", Strings.LF("%@ 分钟", 3), "LF fills %@")
    }

    fun keyFileIsPrivate() {
        val key = AIKey(PlainProtector)
        check(key.save("sk-test-0000000000"), "saved")
        val mode = java.nio.file.Files.getPosixFilePermissions(Paths.keyFile.toPath())
        equal("rw-------", java.nio.file.attribute.PosixFilePermissions.toString(mode), "0600")
        check(!Paths.settings.exists() || !Paths.settings.readText().contains("sk-"), "never in settings")
        equal("sk-••••••••••••0000", AIKey.masked("sk-test-0000000000"), "masked")
    }

    // MARK: Ling

    private class Fake(val respond: (String) -> Transport.Response) : Transport {
        val calls = mutableListOf<Pair<Long, String>>()
        override fun send(url: String, method: String, body: String?, headers: Map<String, String>, timeoutMs: Int): Transport.Response {
            synchronized(calls) { calls.add(System.currentTimeMillis() to (body ?: "")) }
            return respond(body ?: "")
        }
    }

    private fun reply(content: String, finish: String? = "stop") = Transport.Response(200, Json.write(mapOf(
        "choices" to listOf(mapOf("message" to mapOf("content" to content), "finish_reason" to finish)),
        "usage" to mapOf("prompt_tokens" to 1, "completion_tokens" to 1),
    ), pretty = false))

    private fun client(fake: Fake): LingClient {
        val key = AIKey(PlainProtector)
        key.save("sk-test-0000000000")
        return LingClient(key, fake)
    }

    private fun content(body: String, i: Int) = Json.parse(body).obj()!!["messages"].arr()[i].obj()!!["content"]

    fun lingRequestShape() {
        val fake = Fake { reply("ok") }
        client(fake).chat("the content", "Translate.", Priority.Translate, model = LingClient.AUDIO_MODEL, audio = byteArrayOf(1, 2, 3))
        val body = Json.parse(fake.calls[0].second).obj()!!
        equal("disabled", body["thinking"].obj()!!["type"], "thinking disabled")
        equal("system", body["messages"].arr()[0].obj()!!["role"], "content in the system message")
        equal("the content", content(fake.calls[0].second, 0), "content")
        val user = content(fake.calls[0].second, 1).arr()
        equal("audio_url", user[0].obj()!!["type"], "audio first")
        equal("data:audio/wav;base64,AQID", user[0].obj()!!["audio_url"].obj()!!["url"], "WAV as a data URL")
        equal("Translate.", user[1].obj()!!["text"], "fixed instruction last")
        client(fake).chat("c", "i", Priority.Translate, model = LingClient.AUDIO_MODEL, audio = byteArrayOf(1, 2, 3), audioType = "audio/aac")
        equal("data:audio/aac;base64,AQID", content(fake.calls[1].second, 1).arr()[0].obj()!!["audio_url"].obj()!!["url"], "AAC keeps its type")
    }

    fun lingDropsHijacked() {
        for ((r, finish) in listOf("根据现有检索证据，……" to "stop", "作为一个人工智能语言模型，这个问题超出……" to "stop", "fine" to null)) {
            val ling = client(Fake { reply(r, finish) })
            try { ling.chat("c", "i", Priority.Translate); throw AssertionError("accepted «$r»") }
            catch (e: LingException) { equal(LingException.Kind.Hijacked, e.kind, "dropped as hijacked") }
        }
    }

    fun lingRetriesAudioOnce() {
        val calls = AtomicInteger()
        val ling = client(Fake { if (calls.incrementAndGet() == 1) Transport.Response(429, "") else reply("LANG: en\nORIGINAL: Hi.\nTRANSLATION: 嗨。") })
        val r = ling.chat("c", "i", Priority.Translate, model = LingClient.AUDIO_MODEL, audio = byteArrayOf(1))
        check(r.contains("ORIGINAL: Hi."), "second attempt answered")
        equal(2, calls.get(), "one retry")
        val text = client(Fake { Transport.Response(429, "") })
        try { text.chat("c", "i", Priority.Translate); throw AssertionError("text translation retried") }
        catch (e: LingException) { equal(LingException.Kind.RateLimited, e.kind, "text fails fast") }
    }

    fun lingMarksABadKey() {
        val ling = client(Fake { Transport.Response(401, "") })
        try { ling.chat("c", "i", Priority.Translate) } catch (e: LingException) { equal(LingException.Kind.InvalidKey, e.kind, "401") }
        equal(KeyState.Invalid, ling.keyState, "key state")
        check(!ling.usable, "no longer usable")
    }

    fun lingGate() {
        val old = LingClient.spacing
        LingClient.spacing = 0.2
        try {
            val fake = Fake { reply("ok") }
            val ling = client(fake)
            val a = thread { ling.chat("first", "i", Priority.Notes) }
            Thread.sleep(20)
            // Queued while the gate is closed: the translation goes before the earlier notes call.
            val b = thread { ling.chat("notes", "i", Priority.Notes) }
            Thread.sleep(20)
            val c = thread { ling.chat("translate", "i", Priority.Translate) }
            a.join(); b.join(); c.join()
            val order = fake.calls.map { content(it.second, 0) }
            equal("first,translate,notes", order.joinToString(","), "priority order")
            for (i in 1 until fake.calls.size) check(fake.calls[i].first - fake.calls[i - 1].first >= 180, "starts spaced")
        } finally { LingClient.spacing = old }
    }

    fun listenEndToEnd() {
        // Two stretches of "speech", told apart by length (1 s, then 1.6 s); the fake Ming answers
        // the first one slower, and lines still come out in order.
        val fake = Fake { body ->
            if (body.contains("Ming-3.0-audio-flash")) {
                val url = content(body, 1).arr()[0].obj()!!["audio_url"].obj()!!["url"] as String
                val first = url.length < 60_000
                if (first) Thread.sleep(400)
                reply(if (first) "LANG: en\nORIGINAL: First one.\nTRANSLATION: 第一句。" else "LANG: en\nORIGINAL: Second one.\nTRANSLATION: 第二句。")
            } else reply("{}")
        }
        val old = LingClient.spacing
        LingClient.spacing = 0.05
        try {
            val ling = client(fake)
            val store = SessionStore()
            val notes = NotesEngine(ling, store)
            val engine = ListenEngine(ling, Translator(ling), store, notes, AppSettings(target = "zh-CN"))
            val src = PcmAudioSource({ concat(tone(1.0), silence(1.0), tone(1.6), silence(1.0)) }, speed = 0.0)
            val ended = CountDownLatch(1)
            src.onEnded = { ended.countDown() }
            engine.start(src, "file")
            ended.await()
            Thread.sleep(100)
            engine.stop()
            val s = store.get(engine.sessionId!!)!!
            equal("First one.|Second one.", s.lines.joinToString("|") { it.src }, "in segment order")
            equal("第一句。", s.lines[0].dst, "translation from the same call")
            equal("h1-1", s.lines[0].id, "Mac-style ids")
            check(s.endedAt != null, "ended")
        } finally { LingClient.spacing = old }
    }

    fun speaksOnlyTranslations() {
        fun me(src: String, dst: String?, from: String, to: String) =
            ListenEngine.speakable(TranscriptLine(speaker = "me", src = src, dst = dst, srcLang = from, dstLang = to))
        equal("Hello.", me("你好。", "Hello.", "zh-CN", "en"), "my translation is spoken")
        equal(null, me("你好。", null, "zh-CN", "en"), "no translation, nothing spoken")
        equal(null, me("Hello.", "Hello.", "en", "en"), "already their language: not spoken")
        equal(null, me("你好。", "你好。", "zh-CN", "en"), "an echo of my words isn't a translation")
        equal(null, me("你好", "  ", "zh", "en"), "blank")
        equal(null, ListenEngine.speakable(TranscriptLine(speaker = "them", src = "Hi", dst = "嗨", srcLang = "en", dstLang = "zh-CN")), "never the other side")
        check(Languages.same("zh", "zh-CN") && !Languages.same("zh-CN", "zh-TW") && !Languages.same("en", "ja"), "same language")
    }

    private class ManualSource : AudioSource {
        override var onSamples: ((ShortArray) -> Unit)? = null
        override var onEnded: ((String?) -> Unit)? = null
        override fun start() {}
        override fun stop() {}
        fun push(pcm: ShortArray) { var i = 0; while (i < pcm.size) { onSamples?.invoke(pcm.copyOfRange(i, minOf(pcm.size, i + 1600))); i += 1600 } }
    }

    fun holdToSayAndEchoGate() {
        // The other side speaks English; I hold and say something (a different length of tone),
        // then the phone "speaks" while a tone plays: that must not become the other side's line.
        val fake = Fake { body ->
            val system = content(body, 0) as String
            if (system.contains("into English")) reply("LANG: zh-CN\nORIGINAL: 你好。\nTRANSLATION: Hello.")
            else if (body.contains("Ming-3.0-audio-flash")) {
                val url = content(body, 1).arr()[0].obj()!!["audio_url"].obj()!!["url"] as String
                reply(if (url.length < 60_000) "LANG: en\nORIGINAL: First one.\nTRANSLATION: 第一句。" else "LANG: en\nORIGINAL: Echo.\nTRANSLATION: 回声。")
            } else reply("{}")
        }
        val old = LingClient.spacing
        LingClient.spacing = 0.05
        try {
            val ling = client(fake)
            val store = SessionStore()
            val engine = ListenEngine(ling, Translator(ling), store, NotesEngine(ling, store), AppSettings(target = "zh-CN"))
            val said = CountDownLatch(1)
            var spoken: Pair<String, String>? = null
            engine.onSaid = { text, lang -> spoken = text to lang; said.countDown() }
            val src = ManualSource()
            engine.start(src, "mic")
            check(engine.canSay, "面对面 can say")
            equal("en", engine.theirLanguage, "English before anyone spoke")
            src.push(concat(tone(1.0), silence(1.2)))
            val until = System.currentTimeMillis() + 3000
            while (engine.spoken == null && System.currentTimeMillis() < until) Thread.sleep(20)
            engine.hold()
            src.push(tone(1.2))
            engine.release()
            src.push(silence(0.3))
            check(said.await(3, java.util.concurrent.TimeUnit.SECONDS), "said")
            equal("Hello." to "en", spoken, "spoken in their language")
            engine.muted = true
            src.push(concat(tone(2.0), silence(1.2)))
            Thread.sleep(300) // mute lasts as long as the voice plays: let the worker take what came in meanwhile
            engine.muted = false
            src.push(silence(1.0))
            Thread.sleep(300)
            engine.stop()
            val s = store.get(engine.sessionId!!)!!
            equal("them:First one.|me:你好。", s.lines.joinToString("|") { "${it.speaker}:${it.src}" }, "my line recorded, the echo dropped")
            equal("m1", s.lines[1].id, "Mac-style id")
            check(s.lines[1].t >= 2.0, "my line's time is when I pressed")
        } finally { LingClient.spacing = old }
    }

    fun anUntranslatedSentenceIsNeitherSentNorRecorded() {
        // Ming hears me but returns no translation, and Ling and Google both fail.
        val fake = Fake { body ->
            if (body.contains("Ming-3.0-audio-flash")) reply("LANG: zh-CN\nORIGINAL: 你好。")
            else Transport.Response(500, "")
        }
        val old = LingClient.spacing
        LingClient.spacing = 0.05
        try {
            val ling = client(fake)
            val store = SessionStore(loadNow = false)
            val engine = ListenEngine(ling, Translator(ling, fake), store, NotesEngine(ling, store), AppSettings(target = "zh-CN"))
            var spoken: String? = null
            engine.onSaid = { text, _ -> spoken = text }
            val src = ManualSource()
            engine.start(src, "mic")
            engine.hold(); src.push(tone(1.2)); engine.release(); src.push(silence(0.3))
            val until = System.currentTimeMillis() + 4000
            while (engine.sayProblem == null && System.currentTimeMillis() < until) Thread.sleep(20)
            equal("翻译失败，这句话未发送", engine.sayProblem, "the Mac's message")
            equal(null, spoken, "nothing spoken")
            check(store.get(engine.sessionId!!)!!.lines.none { it.speaker == "me" }, "nothing recorded")
            engine.stop()
        } finally { LingClient.spacing = old }
    }

    // MARK: Meeting end (MeetingEndTests.swift, the same cases)

    private val zoom = mapOf("us.zoom.xos" to "Zoom")
    private fun watch(silence: MeetingEndWatch.Silence = MeetingEndWatch.Silence.Prompt, followApps: Boolean = true) =
        MeetingEndWatch(MeetingEndWatch.Config(followApps = followApps, silence = silence), 0.0)
    private val none = emptyMap<String, String>()

    fun hangUpEndsAfterTheGrace() {
        val w = watch()
        equal(null, w.tick(10.0, zoom, true), "in a call")
        equal(null, w.tick(20.0, none, true), "hung up")
        equal(MeetingEndWatch.Pending(MeetingEndWatch.Reason.AppLeft("Zoom"), 50.0), w.pending, "grace")
        equal(null, w.tick(49.0, none, true), "not yet")
        equal(MeetingEndWatch.Reason.AppLeft("Zoom"), w.tick(50.0, none, true), "ends")
    }

    fun rejoiningWithinTheGraceKeepsGoing() {
        val w = watch()
        w.tick(10.0, zoom, true); w.tick(20.0, none, true)
        equal(null, w.tick(30.0, zoom, true), "rejoined")
        equal(null, w.pending, "no pending")
    }

    fun speechDoesNotCancelAHangUp() {
        val w = watch()
        w.tick(10.0, zoom, true); w.tick(20.0, none, true)
        w.heard(25.0)
        equal(MeetingEndWatch.Reason.AppLeft("Zoom"), w.tick(50.0, none, true), "still ends")
    }

    fun keepGoingForgetsTheHangUp() {
        val w = watch()
        w.tick(10.0, zoom, true); w.tick(20.0, none, true)
        w.keepGoing(30.0)
        equal(null, w.tick(100.0, none, true), "kept going")
        equal(null, w.pending, "no pending")
    }

    fun silencePromptsThenEnds() {
        val w = watch()
        w.heard(5.0)
        equal(null, w.tick(604.0, none, true), "not yet")
        equal(null, w.pending, "no prompt yet")
        equal(null, w.tick(605.0, none, true), "prompts")
        equal(MeetingEndWatch.Pending(MeetingEndWatch.Reason.Silence, 665.0), w.pending, "60 s countdown")
        equal(MeetingEndWatch.Reason.Silence, w.tick(665.0, none, true), "ends")
    }

    fun wordsCancelTheSilencePrompt() {
        val w = watch()
        w.tick(600.0, none, true)
        equal(MeetingEndWatch.Reason.Silence, w.pending?.reason, "prompting")
        w.heard(620.0)
        equal(null, w.pending, "words cancel it")
        equal(null, w.tick(700.0, none, true), "and the clock restarts")
    }

    fun silenceEndModeEndsAtOnceAndOffNever() {
        equal(MeetingEndWatch.Reason.Silence, watch(MeetingEndWatch.Silence.End).tick(600.0, none, true), "ends at once")
        val off = watch(MeetingEndWatch.Silence.Off)
        equal(null, off.tick(99_999.0, none, true), "off never ends")
        equal(null, off.pending, "off never prompts")
    }

    fun silenceDoesNotCountDuringACall() {
        val w = watch()
        equal(null, w.tick(5_000.0, zoom, true), "a muted webinar is still a meeting")
        equal(null, w.pending, "no prompt")
        val plain = watch(followApps = false) // Android: a call says nothing
        equal(null, plain.tick(600.0, zoom, true), "prompts")
        equal(MeetingEndWatch.Reason.Silence, plain.pending?.reason, "silence counts")
    }

    fun nothingSaidStopsQuietlyAfterTheSilence() {
        val w = watch()
        equal(null, w.tick(599.0, none, false), "not yet")
        equal(MeetingEndWatch.Reason.NobodySpoke, w.tick(600.0, none, false), "stops")
        equal(null, w.pending, "without a countdown")
        equal(MeetingEndWatch.Reason.NobodySpoke, watch(MeetingEndWatch.Silence.End).tick(600.0, none, false), "end mode too")
        equal(null, watch(MeetingEndWatch.Silence.Off).tick(5_000.0, none, false), "off keeps listening")
        equal(null, watch().tick(5_000.0, zoom, false), "a call keeps listening")
    }

    fun nothingSaidKeepsListening() {
        val w = watch()
        w.tick(10.0, zoom, false)
        equal(null, w.tick(500.0, none, false), "a call that ended before anyone spoke")
        equal(null, w.pending, "no pending")
        w.heard(5_001.0)
        equal(null, w.tick(5_002.0, none, true), "is forgotten once someone does")
        equal(null, w.pending, "no pending")
    }

    fun endsAtTheGivenTime() {
        // An ended-by-itself meeting is stored as ending at the time given, not when it stopped.
        val store = SessionStore()
        val s = store.begin(java.time.Instant.parse("2026-11-04T10:00:00Z"))
        store.append(s.id, TranscriptLine(id = "h1-1", t = 1.0, src = "Hi", srcLang = "en", dstLang = "zh-CN"))
        store.end(s.id, java.time.Instant.parse("2026-11-04T10:00:06Z"))
        equal(java.time.Instant.parse("2026-11-04T10:00:06Z"), store.get(s.id)?.endedAt, "endedAt")
        equal("已经 10 分钟没人说话", Strings.LF("已经 %lld 分钟没人说话", 10), "number placeholder")
    }

    private fun release(tag: String, vararg assets: String, draft: Boolean = false, pre: Boolean = false) = mapOf(
        "tag_name" to tag, "html_url" to "https://github.com/wquguru/cicada/releases/tag/$tag", "draft" to draft, "prerelease" to pre,
        "assets" to assets.map { mapOf("name" to it, "browser_download_url" to "https://github.com/dl/$it", "size" to 1234L) })

    fun findsTheNewestAndroidRelease() {
        val feed = Json.write(listOf(
            release("v1.10.0", "Cicada-1.10.0.dmg"),                                   // Mac only: skipped
            release("v1.11.0", "Cicada-1.11.0-Android.apk", draft = true),
            release("v1.12.0", "Cicada-1.12.0-Android.apk", pre = true),
            release("v1.9.2", "Cicada-1.9.2-Windows-x64.zip", "Cicada-1.9.2-Android.apk"),
            release("v1.9.10", "Cicada-1.9.10-Android.apk"),
        ), pretty = false)
        val u = UpdateChecker.newestAndroid(UpdateChecker.decode(feed)!!)
        equal("1.9.10", u?.version, "newest with an APK")
        equal("https://github.com/dl/Cicada-1.9.10-Android.apk", u?.apk, "apk url")
        equal(1234L, u?.size, "size")
        equal("1.9.2", UpdateChecker.newestAndroid(UpdateChecker.decode(Json.write(release("v1.9.2", "Cicada-1.9.2-Android.apk")))!!)?.version, "one release")
        equal(null, UpdateChecker.decode("{\"message\":\"Not Found\"}"), "an error object")
        equal(null, UpdateChecker.decode("<html>"), "not JSON")
        check(UpdateChecker.isNewer("2.10.0", "2.9.1"), "2.10 > 2.9")
        check(!UpdateChecker.isNewer("1.4.0", "1.4.0-dev"), "suffix ignored")
        check(!UpdateChecker.isNewer("1.4", "1.4.0"), "missing part is 0")
        check(UpdateChecker.isNewer("1.4.1", "1.4"), "patch")
    }

    fun updateCheckIsSilentAndDue() {
        val ok = object : Transport {
            var calls = 0
            override fun send(url: String, method: String, body: String?, headers: Map<String, String>, timeoutMs: Int): Transport.Response {
                calls++
                check(headers["User-Agent"] != null, "User-Agent sent")
                return Transport.Response(200, Json.write(listOf(release("v2.0.0", "Cicada-2.0.0-Android.apk"))))
            }
        }
        val c = UpdateChecker("1.9.0", null, ok)
        var told = 0
        c.onChange { told++ }
        check(c.check(), "reached")
        equal("2.0.0", c.available?.version, "newer found")
        equal(1, told, "listeners told")
        check(c.lastChecked != null, "remembers when")
        check(c.checkIfDue(UpdateChecker.STALE), "not due is fine")
        equal(1, ok.calls, "not due: no request")
        equal(null, UpdateChecker("2.0.0", null, ok).apply { check() }.available, "same version: nothing")
        val down = UpdateChecker("1.9.0", null, object : Transport {
            override fun send(url: String, method: String, body: String?, headers: Map<String, String>, timeoutMs: Int) = Transport.Response(403, "{}")
        })
        check(!down.check(), "rate-limited is a failure")
        equal(null, down.lastChecked, "and not remembered")
        val day = 24 * 3600_000L
        val now = 10 * day
        check(UpdateChecker.due(null, now, day), "never checked")
        check(!UpdateChecker.due(now - 1000, now, day), "just checked")
        check(UpdateChecker.due(now - day, now, day), "old enough")
        check(UpdateChecker.due(now + 1000, now, day), "clock set back")
        val file = File(Paths.root, "feed.json").apply { writeText(Json.write(release("v3.0.0", "Cicada-3.0.0-Android.apk"))) }
        equal("3.0.0", UpdateChecker("1.0.0").apply { feed = file.path; check() }.available?.version, "a file feed")
        equal("3.0.0", UpdateChecker("1.0.0").apply { feed = file.toURI().toString(); check() }.available?.version, "a file:// feed")
        val s = AppSettings(updateLastChecked = 1_762_000_000_123L, updateNotified = "2.0.0")
        s.save()
        val back = AppSettings.load()
        equal(1_762_000_000_123L, back.updateLastChecked, "lastChecked kept")
        equal("2.0.0", back.updateNotified, "notified kept")
    }
}
