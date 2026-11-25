// 分享…: the Mac's ShareTests (the share document is a contract with the server and the other
// apps: the same record gives the same bytes, Tests/fixtures/share), plus the crypto Android does
// itself (Ed25519, PBKDF2) and the client's requests against a fake server.
package cicada.cli

import cicada.*
import java.io.File
import java.security.KeyFactory
import java.security.Signature
import java.security.spec.X509EncodedKeySpec

object ShareTests {
    val tests: List<Pair<String, () -> Unit>> = listOf(
        "shareDocMatchesTheMacsBytes" to ::fixtureBytes,
        "shareDocLeavesNothingPrivate" to ::nothingPrivateLeaves,
        "shareDocNamesWhenAsked" to ::namesWhenAsked,
        "shareDocNotesOnlyAndRemoved" to ::notesOnlyAndRemoved,
        "shareDocSpeakerNumbersWithoutNames" to ::speakerNumbersWithoutNames,
        "shareDocRoundsAndKeepsSlashes" to ::roundsAndKeepsSlashes,
        "sharePasswordIsTheBrowsersPbkdf2" to ::password,
        "shareBlockedHitsMapBack" to ::blockedHitsMapBack,
        "ed25519MatchesRfc8032" to ::ed25519Vectors,
        "ed25519VerifiesWithTheJdk" to ::ed25519Jdk,
        "shareClientRegistersOnceAndSigns" to ::clientSigns,
        "shareMessageInTheUiLanguage" to ::message,
    )

    /// 生成并复制's clipboard: title, link, password with how long it stays open (the Mac's clipboardText).
    private fun message() {
        val now = java.time.Instant.parse("2026-11-08T10:00:00Z")
        fun record(days: Long, pw: String?) =
            ShareRecord("A", "https://test/s/A", "tok", now.plusSeconds(days * 86400 - 5), "notes", pw, now)
        try {
            loadStrings("zh-Hans")
            equal("「周会」会议记录\nhttps://test/s/A\n密码：ruby-41-lake（7 天内有效）", record(7, "ruby-41-lake").message("周会", now), "zh, password")
            equal("「周会」会议记录\nhttps://test/s/A\n1 年内有效", record(365, null).message("周会", now), "zh, a year, no password")
            loadStrings("en")
            equal("Meeting record: Weekly\nhttps://test/s/A\nPassword: ruby-41-lake (valid for 30 days)", record(30, "ruby-41-lake").message("Weekly", now), "en, password")
            equal("Meeting record: Weekly\nhttps://test/s/A\nvalid for 7 days", record(7, null).message("Weekly", now), "en, no password")
            loadStrings("ja")
            equal("会議記録：週例\nhttps://test/s/A\nパスワード：pw-pw-pw（1 年間有効）", record(365, "pw-pw-pw").message("週例", now), "ja")
        } finally { loadStrings("zh-Hans") }
    }

    private fun check(ok: Boolean, what: String) { if (!ok) throw AssertionError(what) }
    private fun <T> equal(expected: T, actual: T, what: String) { if (expected != actual) throw AssertionError("$what: expected «$expected», got «$actual»") }

    private val fixtures get() = File(resources, "../Tests/fixtures/share")
    private fun session() = Session.read(File(fixtures, "session.json").readText())!!
    private fun setUp() { loadStrings("zh-Hans"); SpeakerLabels.voices = true }
    private fun hex(b: ByteArray) = ShareClient.hex(b)
    private fun bytes(hex: String) = ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private fun fixtureBytes() {
        setUp()
        val want = File(fixtures, "share-doc.json").readText().trim()
        equal(want, ShareProjection.encode(ShareProjection.doc(session(), ShareScope.Full, names = false)), "the Mac's share document")
    }

    private fun nothingPrivateLeaves() {
        setUp()
        val text = ShareProjection.encode(ShareProjection.doc(session(), ShareScope.Full, names = false))
        for (secret in listOf("/Users/someone", "Emma", "Kenji", "Emmer", "Sure, Emma")) check(!text.contains(secret), secret)
    }

    private fun namesWhenAsked() {
        setUp()
        val notes = ShareProjection.doc(session(), ShareScope.Full, names = true)["notes"].obj()!!
        equal("Emma", notes["todos"].arr()[0].obj()!!["owner"], "to-do owner")
        equal("Emma", notes["terms"].arr()[0].obj()!!["name"], "term")
    }

    private fun notesOnlyAndRemoved() {
        setUp()
        val s = session()
        equal(0, ShareProjection.doc(s, ShareScope.Notes, names = false)["lines"].arr().size, "notes only has no lines")
        val d = ShareProjection.doc(s, ShareScope.Full, names = false, removed = setOf(3), dropNotes = true)
        equal(3, d["lines"].arr().size, "a line removed")
        equal(null, d["notes"], "notes dropped")
        equal(2, d["hidden"], "hidden counts both")
    }

    private fun speakerNumbersWithoutNames() {
        setUp()
        val s = session()
        // Two voices with five substantive lines each get numbers; their names stay out.
        s.lines = (0 until 10).map { i ->
            TranscriptLine(id = "v$i", t = i.toDouble(), speaker = "them", src = "this is line number $i", dst = "第 $i 句话", srcLang = "en", dstLang = "zh", voice = if (i % 2 == 0) 3 else 7)
        }.toMutableList()
        equal(setOf("说话人 1", "说话人 2"), ShareProjection.doc(s, ShareScope.Full, names = false)["lines"].arr().map { it.obj()!!["who"] }.toSet(), "numbers")
        equal(setOf("Emma", "Kenji"), ShareProjection.doc(s, ShareScope.Full, names = true)["lines"].arr().map { it.obj()!!["who"] }.toSet(), "names")
    }

    private fun roundsAndKeepsSlashes() {
        setUp()
        val s = session()
        s.lines = mutableListOf(
            TranscriptLine(id = "a", t = 12.25, src = "see https://example.com/a/b", dst = "see https://example.com/a/b", srcLang = "en-US", dstLang = "zh-Hans"),
            TranscriptLine(id = "b", t = 0.05, src = "x", dst = "", srcLang = "en", dstLang = "zh"))
        val text = ShareProjection.encode(ShareProjection.doc(s, ShareScope.Full, names = false))
        check(text.contains("\"src\":\"see https://example.com/a/b\""), "slashes as they are")
        check(!text.contains("\"dst\""), "no dst when the same as src or empty")
        check(text.contains("\"t\":12.3") && text.contains("\"t\":0.1"), "halves round up like Swift: $text")
        check(text.contains("\"langs\":[\"en\",\"zh\"]"), "base codes")
    }

    private fun password() {
        val salt = ByteArray(16) { 1 }
        // Same as the browser's crypto.subtle PBKDF2-SHA256, 32 bytes (server/test/api.test.mjs).
        val v = SharePassword.verifier("ruby-41-lake", salt, 1000)
        equal("eab69fcd00a0517794c156495dd76ad1fbfb036ea03df3d59a68a33519009c81", hex(v), "PBKDF2 vector")
        check(!v.contentEquals(SharePassword.verifier("ruby-41-laka", salt, 1000)), "another password differs")
        equal(3, SharePassword.make().split("-").size, "word-NN-word")
    }

    private fun blockedHitsMapBack() {
        // The server counts lines of what was sent; the app maps them back to the record.
        val hits = listOf(ShareHit("lines", 2, 3, listOf("credential")))
        equal(setOf(4, 5), ShareHit.recordLines(hits, listOf(0, 1, 4, 5, 6)), "record lines")
    }

    private fun ed25519Vectors() {
        // RFC 8032 §7.1, tests 1–3 and the 1023-byte message's key.
        val cases = listOf(
            Triple("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", "",
                   "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
            Triple("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb", "72",
                   "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
            Triple("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7", "af82",
                   "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"),
        )
        val publics = listOf("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
                             "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
                             "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025")
        cases.forEachIndexed { i, (seed, msg, sig) ->
            equal(publics[i], hex(Ed25519.publicKey(bytes(seed))), "public key $i")
            equal(sig, hex(Ed25519.sign(bytes(seed), bytes(msg))), "signature $i")
        }
    }

    private fun ed25519Jdk() {
        // The JDK has Ed25519 (Android only from 13): it must accept ours for random keys and messages.
        val random = java.util.Random(7)
        repeat(8) { n ->
            val seed = ByteArray(32).also(random::nextBytes)
            val msg = ByteArray(n * 37).also(random::nextBytes)
            val spec = X509EncodedKeySpec(bytes("302a300506032b6570032100") + Ed25519.publicKey(seed))
            val v = Signature.getInstance("Ed25519")
            v.initVerify(KeyFactory.getInstance("Ed25519").generatePublic(spec))
            v.update(msg)
            check(v.verify(Ed25519.sign(seed, msg)), "JDK verifies signature $n")
            // Ed25519 is deterministic: the JDK's own signature is the same bytes.
            val s = Signature.getInstance("Ed25519")
            s.initSign(KeyFactory.getInstance("Ed25519").generatePrivate(java.security.spec.PKCS8EncodedKeySpec(bytes("302e020100300506032b657004220420") + seed)))
            s.update(msg)
            equal(hex(s.sign()), hex(Ed25519.sign(seed, msg)), "same signature as the JDK $n")
        }
    }

    /// A fake server that checks what auth.js checks: the proof of work, then each signature.
    private fun clientSigns() {
        setUp()
        val home = File(Paths.root, "share-test").apply { deleteRecursively(); mkdirs() }
        val root = Paths.root
        Paths.root = home
        try {
            var pub: ByteArray? = null
            var registrations = 0
            var forget = false
            val calls = ArrayList<String>()
            val transport = object : Transport {
                override fun send(url: String, method: String, body: String?, headers: Map<String, String>, timeoutMs: Int): Transport.Response {
                    val path = url.removePrefix("https://test")
                    calls.add("$method $path")
                    check(headers["X-Cicada-Client"] == "android/1.5.1", "client header")
                    if (path == "/api/v1/devices") {
                        val o = Json.parseObject(body!!)!!
                        val key = java.util.Base64.getUrlDecoder().decode(o["key"].str())
                        val work = ShareClient.sha256(key + java.util.Base64.getUrlDecoder().decode(o["pow"].str()))
                        check(work[0].toInt() == 0 && work[1].toInt() == 0 && (work[2].toInt() and 0xF0) == 0, "20 zero bits")
                        equal("android", o["platform"], "platform")
                        pub = key; registrations++; forget = false
                        return Transport.Response(201, """{"device":"${"ab".repeat(16)}"}""")
                    }
                    if (forget) return Transport.Response(401, """{"code":"unknown_device"}""")
                    val message = "$method\n$path\n${headers["X-Cicada-Time"]}\n${headers["X-Cicada-Nonce"]}\n${hex(ShareClient.sha256((body ?: "").toByteArray()))}"
                    val v = Signature.getInstance("Ed25519")
                    v.initVerify(KeyFactory.getInstance("Ed25519").generatePublic(X509EncodedKeySpec(bytes("302a300506032b6570032100") + pub!!)))
                    v.update(message.toByteArray())
                    check(v.verify(java.util.Base64.getUrlDecoder().decode(headers["X-Cicada-Signature"])), "signed $method $path")
                    check(Regex("^[A-Za-z0-9_-]{16,64}$").matches(headers["X-Cicada-Nonce"]!!), "nonce shape")
                    return when {
                        method == "POST" && body!!.contains("Hk8!") -> Transport.Response(422, """{"code":"blocked","hits":[{"part":"lines","from":1,"to":1,"questions":["credential"]}]}""")
                        method == "POST" -> {
                            check(headers["Idempotency-Key"]!!.startsWith("20261106-140000-"), "idempotency key")
                            check(!body!!.contains("\\/"), "body keeps slashes")
                            Transport.Response(201, """{"id":"AAAAAAAAAAAAAAAAAAAAAA","url":"https://test/s/AAAAAAAAAAAAAAAAAAAAAA","token":"tok","expiresAt":1800000000}""")
                        }
                        method == "DELETE" -> { check(headers["Authorization"] == "Bearer tok", "manage token"); Transport.Response(204, "") }
                        else -> Transport.Response(200, """{"shares":[{"id":"AAAAAAAAAAAAAAAAAAAAAA","expiresAt":1800000000,"state":"live","views":3}]}""")
                    }
                }
            }
            val client = ShareClient("android", "1.5.1", transport, "https://test")
            val s = session()
            val shared = client.share(s, ShareClient.Options(scope = ShareScope.Full, password = "ruby-41-lake")) as ShareClient.Outcome.Shared
            equal("ruby-41-lake", ShareStore.read(s.id)?.password, "record kept, with its password")
            equal(3, client.stats(listOf(shared.record.id))[shared.record.id]?.views, "stats")
            equal(1, registrations, "registered once")
            forget = true // the server lost this phone: registers again, once
            check(client.revoke(shared.record, s.id), "revoked")
            equal(2, registrations, "registered again after unknown_device")
            equal(null, ShareStore.read(s.id), "record forgotten")
            s.lines[1].src = "The prod database password is Hk8!vQ2#mZ, root account."
            val blocked = client.share(s, ShareClient.Options(scope = ShareScope.Full)) as ShareClient.Outcome.Blocked
            equal(setOf(1), ShareHit.recordLines(blocked.hits, blocked.kept), "blocked line")
            check(!File(home, "share-device.json").readText().contains("tok"), "no token in the device file")
        } finally { Paths.root = root }
    }
}
