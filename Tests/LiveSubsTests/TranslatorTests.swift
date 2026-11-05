import Testing
@testable import LiveSubs

@Suite struct TranslatorTests {
    @Test func remarkInsteadOfTranslationIsDropped() {
        // Issue #2: Ling commented on a garbled line and the remark became the subtitle.
        let reply = "The subtitle appears to be a mix of Chinese and heavily garbled English (likely from poor audio or ASR errors). Here is the best-effort translation:"
        #expect(TranslationService.cleanTranslation(reply, target: "en-US") == nil)
        #expect(TranslationService.cleanTranslation(reply, target: "zh-CN") == nil)
    }

    @Test func remarkLinesAroundATranslationAreStripped() {
        let reply = "Here is the best-effort translation:\n我们周五前把落地页文案定下来。"
        #expect(TranslationService.cleanTranslation(reply, target: "zh-CN") == "我们周五前把落地页文案定下来。")
        #expect(TranslationService.cleanTranslation("Translation: We ship on Friday.", target: "en-US") == "We ship on Friday.")
        #expect(TranslationService.cleanTranslation("“我们周五发布。”", target: "zh-CN") == "我们周五发布。")
    }

    @Test func ordinaryTranslationsAreKept() {
        #expect(TranslationService.cleanTranslation("The text is due on Friday.", target: "en-US") == "The text is due on Friday.")
        #expect(TranslationService.cleanTranslation("There are three points:", target: "en-US") == "There are three points:")
        #expect(TranslationService.cleanTranslation("Note the deadline is Tuesday.", target: "en-US") == "Note the deadline is Tuesday.")
        #expect(TranslationService.cleanTranslation("2026", target: "zh-CN") == "2026")
        #expect(TranslationService.cleanTranslation("我们用 API 和 SDK。", target: "zh-CN") == "我们用 API 和 SDK。")
    }

    /// Replies found in stored meetings.
    @Test func remarksFromRecordedMeetings() {
        let note = "好的。\n\n(Note: The subtitle \"Right.\" is a very short affirmation. In a live meeting context, it can be translated in a few ways:\n- 对。\n- 没错。)"
        #expect(TranslationService.cleanTranslation(note, target: "zh-CN") == "好的。")
        #expect(TranslationService.cleanTranslation("The user wants me to translate the subtitle \"Yes.\" from English into Simplified Chinese. The translation is \"是的。\"", target: "zh-CN") == nil)
        #expect(TranslationService.cleanTranslation("请提供需要翻译的字幕内容。", target: "zh-CN") == nil)
        #expect(TranslationService.cleanTranslation("The user wants a translation of \"Yes.\"\nI must output only the translation.</think>\n是的。", target: "zh-CN") == "是的。")
        #expect(TranslationService.cleanTranslation("您似乎忘记提供需要翻译的字幕内容了。请提供具体的英文字幕文本。", target: "zh-CN") == nil)
        let mixed = "The subtitle appears to be a mix of Chinese and garbled English. The Chinese portion translates to:\n\"Only 500 messages today.\""
        #expect(TranslationService.cleanTranslation(mixed, target: "en-US") == "Only 500 messages today.")
    }

    @Test func quotesInsideTheTextStay() {
        let s = "我想到了一个人，他说：“在这个派对上，永远都是晚上十点。”"
        #expect(TranslationService.cleanTranslation(s, target: "zh-CN") == s)
        #expect(TranslationService.cleanTranslation("He said \"no\" and \"never\"", target: "en-US") == "He said \"no\" and \"never\"")
        #expect(TranslationService.cleanTranslation("我们会把字幕翻译成中文。", target: "zh-CN") == "我们会把字幕翻译成中文。")
    }

    @Test func translationInTheWrongScriptIsDropped() {
        #expect(TranslationService.cleanTranslation("We ship on Friday.", target: "zh-CN") == nil)
        #expect(TranslationService.cleanTranslation("我们周五发布。", target: "en-US") == nil)
    }

    // What you say is spoken into the room only as Ming's translation; anything that is not
    // clearly one sends the press to the on-device path instead.
    @MainActor @Test func interpretationNeedsBothLinesAndARealTranslation() {
        let good = TranslationService.parseInterpretation("ORIGINAL: 我们周五发布。\nTRANSLATION: We ship on Friday.", target: "en-US")
        #expect(good?.original == "我们周五发布。")
        #expect(good?.translation == "We ship on Friday.")
        #expect(TranslationService.parseInterpretation("ORIGINAL: 我们周五发布。", target: "en-US") == nil)
        #expect(TranslationService.parseInterpretation("ORIGINAL: 我们周五发布。\nTRANSLATION:", target: "en-US") == nil)
        #expect(TranslationService.parseInterpretation("We ship on Friday.", target: "en-US") == nil)
    }

    @MainActor @Test func interpretationThatRepeatsTheOriginalIsDropped() {
        #expect(TranslationService.parseInterpretation("ORIGINAL: OK.\nTRANSLATION: OK.", target: "zh-CN") == nil)
        #expect(TranslationService.parseInterpretation("ORIGINAL: 我们周五发布。\nTRANSLATION: 我们周五发布。", target: "en-US") == nil)
        #expect(TranslationService.parseInterpretation("ORIGINAL: We ship on Friday.\nTRANSLATION: We ship on Friday", target: "zh-CN") == nil)
    }
}
