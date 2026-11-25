"""AI 服务: the service table, how each one's requests are shaped, per-service keys, and the client
against each service (no network: a fake transport that records where each request went)."""
from __future__ import annotations

import base64
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from cicada.core import jsonfmt, providers, voices  # noqa: E402
from cicada.core.ling import (INVALID, NONE, OK, TRANSLATE, AIKey, LingClient, LingError, Response,  # noqa: E402
                              StreamResponse, pcm_from_wav)
from cicada.core.listen import problem  # noqa: E402
from cicada.core.settings import AppSettings  # noqa: E402
from cicada.core.support import Paths  # noqa: E402
from cicada.core.translator import Translator, is_noise  # noqa: E402


class Fake:
    """Answers every request with `respond(url, body)`; speech with `speech(url, body)`."""

    def __init__(self, respond, speech=None):
        self.respond = respond
        self.speech = speech
        self.sent = []      # (url, body or "")
        self.streamed = []  # (url, body)

    def send(self, url, method, body, headers, timeout):
        self.sent.append((url, body or ""))
        return self.respond(url, body or "")

    def stream(self, url, body, headers, timeout):
        self.streamed.append((url, body))
        return self.speech(url, body)


def reply(content, finish="stop"):
    choice = {"message": {"content": content}}
    if finish is not None:
        choice["finish_reason"] = finish
    return Response(200, jsonfmt.write({"choices": [choice]}, pretty=False))


class Base(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="cicada-providers-")
        Paths.home_override = self.home
        Paths.log_override = os.path.join(self.home, "debug.log")
        LingClient.spacing = 0.0

    def tearDown(self):
        LingClient.spacing = None
        Paths.home_override = None
        Paths.log_override = None

    def client(self, fake, provider="zenmux", key="sk-test-0000000000", **kw):
        s = AppSettings(aiProvider=provider, **kw)
        k = AIKey(service=lambda: s.aiProvider)
        if key:
            k.save(key)
        return LingClient(k, fake, config=s.ai_config), s


class Table(Base):
    def test_defaults_are_the_recommended_models(self):
        c = AppSettings(aiProvider="zenmux").ai_config()
        self.assertEqual("https://zenmux.ai/api/v1/", c.base)
        self.assertEqual("qwen/qwen3.8-omni-flash", c.hear_model)
        self.assertEqual("inclusionai/ling-3.0-flash", c.text_model)
        self.assertEqual("google/gemini-3.8-flash-tts", c.voice_model)
        ling = AppSettings().ai_config()
        self.assertEqual(("Ming-3.0-audio-flash", "Ling-3.1-flash"), (ling.hear_model, ling.text_model))
        # Ling keeps its own key ("model"); a service never named falls back to Ling.
        self.assertEqual("Ling-3.0-flash", AppSettings(model="Ling-3.0-flash").ai_config().text_model)
        self.assertEqual("ling", providers.named("openai").id)

    def test_chosen_models_and_a_custom_service(self):
        s = AppSettings(aiProvider="openrouter", aiHearModels={"openrouter": "google/gemini-3.1-flash-lite"})
        self.assertEqual("google/gemini-3.1-flash-lite", s.ai_config().hear_model)
        s = AppSettings(aiProvider="custom", aiCustomBase="localhost:11434/v1", aiModels={"custom": "qwen3:14b"})
        c = s.ai_config()
        self.assertEqual("http://localhost:11434/v1/", c.base)
        self.assertEqual("", c.hear_model)
        self.assertFalse(c.has_voices)
        s.aiVoiceModels["custom"], s.aiCustomVoice = "kokoro", "af_heart"
        self.assertEqual(("kokoro", "http://localhost:11434/v1/"), (s.ai_config().voice_model, s.ai_config().voice_base))
        self.assertEqual(["af_heart"], [v.id for v in s.ai_config().voices])

    def test_custom_address(self):
        self.assertEqual("https://api.example.com/v1/", providers.custom_base("api.example.com/v1"))
        self.assertEqual("http://127.0.0.1:1234/v1/", providers.custom_base("127.0.0.1:1234/v1"))
        self.assertIsNone(providers.custom_base("http://api.example.com/v1"))  # http only on this computer
        self.assertIsNone(providers.custom_base(" "))

    def test_settings_keep_the_service_across_a_restart(self):
        s = AppSettings(aiProvider="zenmux", aiHearModels={"zenmux": "bytedance/doubao-seed-2.0-mini"})
        s.save()
        back = AppSettings.load()
        self.assertEqual("zenmux", back.aiProvider)
        self.assertEqual("bytedance/doubao-seed-2.0-mini", back.ai_config().hear_model)

    def test_each_service_turns_thinking_off_its_own_way(self):
        for pid, key, value in (("ling", "thinking", {"type": "disabled"}), ("zenmux", "reasoning", {"enabled": False}),
                                ("openrouter", "reasoning", {"enabled": False})):
            body = {}
            AppSettings(aiProvider=pid).ai_config().shape(body, 100)
            self.assertEqual(value, body[key])
            self.assertEqual(100, body["max_tokens"])
        body = {}
        AppSettings(aiProvider="custom", aiCustomBase="https://x.example/v1").ai_config().shape(body, 5)
        self.assertNotIn("reasoning", body)
        self.assertNotIn("thinking", body)

    def test_audio_goes_in_the_form_each_model_takes(self):
        wav = bytes([1, 2, 3])
        ling = AppSettings().ai_config().audio_part(wav, "Ming-3.0-audio-flash")
        self.assertEqual({"type": "audio_url", "audio_url": {"url": "data:audio/wav;base64,AQID"}}, ling)
        zen = AppSettings(aiProvider="zenmux").ai_config()
        self.assertEqual({"type": "input_audio", "input_audio": {"data": "AQID", "format": "wav"}},
                         zen.audio_part(wav, "google/gemini-3.1-flash-lite"))
        self.assertEqual("data:audio/wav;base64,AQID", zen.audio_part(wav, "qwen/qwen3.8-omni-flash")["input_audio"]["data"])

    def test_catalog_lists_chat_models_and_those_that_hear(self):
        data = {"data": [
            {"id": "qwen/qwen3.8-omni-flash", "input_modalities": ["text", "image", "audio", "video"], "output_modalities": ["text"]},
            {"id": "x/asr-only", "input_modalities": ["audio"], "output_modalities": ["text"]},
            {"id": "x/text-model", "architecture": {"input_modalities": ["text"], "output_modalities": ["text"]}},
            {"id": "x/tts", "input_modalities": ["text"], "output_modalities": ["audio"]},
            {"id": "x/embed-1"},
            {"id": "google/gemini-3.1-flash-lite:batch", "input_modalities": ["audio", "text"], "output_modalities": ["text"]},
        ]}
        self.assertEqual(["rec/one", "qwen/qwen3.8-omni-flash"], providers.catalog(data, ["rec/one"], hears=True))
        self.assertEqual(["qwen/qwen3.8-omni-flash", "x/text-model"], providers.catalog(data, [], hears=False))


class Keys(Base):
    def test_one_file_per_service_0600(self):
        s = AppSettings()
        k = AIKey(service=lambda: s.aiProvider)
        k.save("sk-ling-000000000")
        s.aiProvider = "zenmux"
        self.assertIsNone(k.read())
        k.save("sk-zen-0000000000")
        self.assertTrue(k.path.endswith("ai-key-zenmux"))
        self.assertEqual(0o600, os.stat(k.path).st_mode & 0o777)
        s.aiProvider = "ling"
        self.assertEqual("sk-ling-000000000", k.read())
        self.assertNotIn("sk-", open(Paths.settings(), encoding="utf-8").read() if os.path.exists(Paths.settings()) else "")

    def test_a_local_custom_service_needs_no_key(self):
        ling, s = self.client(Fake(lambda u, b: reply("ok")), "custom", key=None, aiCustomBase="localhost:11434/v1",
                              aiModels={"custom": "qwen3:14b"})
        self.assertEqual("", ling.current_key())
        self.assertTrue(ling.has_key)
        s.aiCustomBase = "https://api.example.com/v1"
        self.assertFalse(ling.has_key)


class Client(Base):
    def test_requests_go_to_the_service_in_its_shape(self):
        fake = Fake(lambda u, b: reply("LANG: en\nORIGINAL: Hi.\nTRANSLATION: 嗨。", finish=None))
        ling, _ = self.client(fake)
        # No finish reason: Ling's search essays come without one, other services may just omit it.
        r = ling.chat("c", "i", TRANSLATE, model="qwen/qwen3.8-omni-flash", audio=bytes([1]))
        self.assertIn("ORIGINAL: Hi.", r)
        url, body = fake.sent[0]
        self.assertEqual("https://zenmux.ai/api/v1/chat/completions", url)
        b = jsonfmt.parse(body)
        self.assertEqual({"enabled": False}, b["reasoning"])
        self.assertNotIn("thinking", b)
        self.assertEqual("input_audio", b["messages"][1]["content"][0]["type"])
        # Text calls use the service's text model.
        ling.chat("c", "i", TRANSLATE)
        self.assertEqual("inclusionai/ling-3.0-flash", jsonfmt.parse(fake.sent[1][1])["model"])

    def test_ling_still_drops_replies_without_a_finish_reason(self):
        ling, _ = self.client(Fake(lambda u, b: reply("fine", finish=None)), "ling")
        with self.assertRaises(LingError) as e:
            ling.chat("c", "i", TRANSLATE)
        self.assertEqual(LingError.HIJACKED, e.exception.kind)

    def test_check_finds_a_hear_model_that_refuses_audio(self):
        def respond(url, body):
            if url.endswith("models"):
                return Response(200, jsonfmt.write({"data": [{"id": "a/b", "input_modalities": ["text"], "output_modalities": ["text"]},
                                                              {"id": "inclusionai/ling-3.0-flash"}]}))
            return Response(400, "{}") if "input_audio" in body else reply("OK")
        ling, s = self.client(Fake(respond), aiHearModels={"zenmux": "x/text-only"})
        self.assertEqual(OK, ling.check())
        self.assertFalse(ling.hears)
        self.assertFalse(ling.can_hear)
        self.assertTrue(ling.usable)  # notes and translation still work
        self.assertIn("a/b", ling.text_catalog)
        s.aiHearModels.clear()
        ling.key_changed()
        self.assertIsNone(ling.hears)

    def test_check_says_why(self):
        ling, _ = self.client(Fake(lambda u, b: Response(401, "")))
        self.assertEqual(INVALID, ling.check())
        ling, _ = self.client(Fake(lambda u, b: Response(404, "")))
        ling.check()
        self.assertEqual(("text", "noModel", 404), ling.check_result.failure)
        ling, _ = self.client(Fake(lambda u, b: Response(200, "")), "openrouter", key=None)
        self.assertEqual(NONE, ling.key_state)

    def test_speech_from_each_service(self):
        def sse(url, body):
            chunk = base64.b64encode(b"\x01\x00\x02\x00").decode()
            return StreamResponse(200, iter(["data: " + jsonfmt.write({"audio": chunk}, pretty=False), "data: {\"type\": \"speech.audio.done\"}"]))
        fake = Fake(lambda u, b: reply("ok"), sse)
        ling, _ = self.client(fake)
        self.assertEqual([b"\x01\x00\x02\x00"], list(ling.speech("Hello", voice="Puck", language="ja")))
        url, body = fake.streamed[0]
        b = jsonfmt.parse(body)
        self.assertEqual("https://zenmux.ai/api/v1/audio/speech", url)
        self.assertEqual(("google/gemini-3.8-flash-tts", "Puck", True), (b["model"], b["voice"], b["stream"]))
        self.assertNotIn("language_id", b)
        # A voice that isn't this service's (a Ming name left in settings) becomes its first one.
        list(ling.speech("Hello", voice="US_Emma"))
        self.assertEqual("Kore", jsonfmt.parse(fake.streamed[1][1])["voice"])
        # OpenRouter streams the PCM bytes themselves, without `stream`.
        raw = Fake(lambda u, b: reply("ok"), lambda u, b: StreamResponse(200, iter(()), "audio/pcm", iter([b"\x05\x00", b"\x06\x00"])))
        ling, _ = self.client(raw, "openrouter")
        self.assertEqual([b"\x05\x00", b"\x06\x00"], list(ling.speech("Hi", voice=None)))
        self.assertNotIn("stream", jsonfmt.parse(raw.streamed[0][1]))
        # One JSON with a WAV in it.
        wav = b"RIFF\x00\x00\x00\x00WAVEfmt \x10\x00\x00\x00" + bytes(16) + b"data\x04\x00\x00\x00\x07\x00\x08\x00"
        one = Fake(lambda u, b: reply("ok"), lambda u, b: StreamResponse(
            200, iter(()), "application/json", iter([jsonfmt.write({"audio": base64.b64encode(wav).decode()}).encode()])))
        ling, _ = self.client(one, "custom", aiCustomBase="https://x.example/v1", aiVoiceModels={"custom": "kokoro"}, aiCustomVoice="af_heart")
        self.assertEqual([b"\x07\x00\x08\x00"], list(ling.speech("Hi", voice="af_heart")))
        self.assertEqual(b"\x07\x00\x08\x00", pcm_from_wav(wav))

    def test_no_voice_model_no_speech(self):
        ling, _ = self.client(Fake(lambda u, b: reply("ok")), "custom", aiCustomBase="https://x.example/v1", aiModels={"custom": "m"})
        self.assertFalse(ling.speaks)
        with self.assertRaises(LingError):
            list(ling.speech("Hi"))

    def test_hearing_uses_the_hear_model(self):
        fake = Fake(lambda u, b: reply("LANG: en\nORIGINAL: We ship on Friday.\nTRANSLATION: 我们周五发布。"))
        ling, _ = self.client(fake, aiHearModels={"zenmux": "bytedance/doubao-seed-2.0-mini"})
        heard = Translator(ling).hear(b"RIFF" + bytes(40) + bytes(32000), "zh-CN", None)
        self.assertEqual("我们周五发布。", heard.translation)
        self.assertEqual("bytedance/doubao-seed-2.0-mini", jsonfmt.parse(fake.sent[0][1])["model"])


class Words(Base):
    def test_voices_follow_the_service(self):
        zen = AppSettings(aiProvider="zenmux").ai_config()
        self.assertEqual(["Kore", "Aoede", "Charon", "Puck"], [v for v, _n, _t in voices.voices("ja", zen)])
        self.assertIsNone(voices.ming_language("ja", zen))
        self.assertEqual("ja", voices.ming_language("ja", AppSettings().ai_config()))
        self.assertEqual("US_Emma", voices.default_voice("en"))

    def test_problems_name_the_service(self):
        self.assertEqual("key", problem(LingError(LingError.HTTP, 400), "ZenMux")[0])
        self.assertIn("ZenMux", problem(LingError(LingError.NETWORK), "ZenMux")[1])
        self.assertEqual(("network", "字幕和纪要等 Ling 恢复 · 连上后自动继续"), problem(LingError(LingError.TIMEOUT), "Ling"))
        self.assertIsNone(problem(LingError(LingError.HTTP, 400), "Ling")[0])
        # A gateway's 502 in front of the server: the service's trouble, not the network or the key.
        self.assertEqual(("busy", "ZenMux 暂时出错（HTTP 502），稍后再试。"), problem(LingError(LingError.HTTP, 502), "ZenMux"))
        self.assertEqual(("busy", "Ling 暂时出错（HTTP 503），稍后再试。"), problem(LingError(LingError.HTTP, 503), "Ling"))
        # 其他（兼容 OpenAI） is UI text: in English it reads as the settings name it.
        from cicada.core import strings
        res = [os.path.join(os.path.dirname(__file__), "..", "..", "Resources")]
        strings.load("en", res)
        try:
            self.assertEqual("Other (OpenAI-compatible) has a temporary error (HTTP 502). Try again shortly.",
                             problem(LingError(LingError.HTTP, 502), "其他（兼容 OpenAI）")[1])
        finally:
            strings.load("zh-Hans", res)

    def test_final_notes_keep_retrying_for_about_a_minute(self):
        from cicada.core.ling import NOTES, retry_waits
        self.assertEqual([], retry_waits(TRANSLATE))
        self.assertEqual([1, 2, 4, 8], retry_waits(TRANSLATE, audio=True))
        from cicada.core.ling import SPEAK
        self.assertEqual([1], retry_waits(SPEAK, audio=True))
        self.assertEqual([1, 2, 4], retry_waits(NOTES))
        self.assertTrue(50 <= sum(retry_waits(NOTES, patient=True)) <= 70)

    def test_a_clock_is_not_speech(self):
        for made_up in ("00:00", "00:00.", "1:02:03"):
            self.assertTrue(is_noise(made_up, 1.2), made_up)
        for said in ("Hello.", "3 点", "15%", "好的"):
            self.assertFalse(is_noise(said, 1.2), said)


if __name__ == "__main__":
    unittest.main()
