"""其他（兼容 OpenAI）for self-hosted models (AIProviderTests.swift): plain http on the local network,
thinking turned off through the chat template (and left out for a server that refuses it), the
check's real sentence and what it says about a thinking model, and the hear model at an address of
its own."""
from __future__ import annotations

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))

from test_providers import Base, Fake, reply  # noqa: E402

from cicada.core import aicheck, jsonfmt, providers  # noqa: E402
from cicada.core.ling import INVALID, NOTES, OK, TRANSLATE, LingError, Response, silence_wav  # noqa: E402
from cicada.core.support import Paths  # noqa: E402
from cicada.core.settings import AppSettings  # noqa: E402


def custom(**kw):
    kw.setdefault("aiCustomBase", "http://192.168.1.20:8000/v1")
    kw.setdefault("aiModels", {"custom": "qwen3:14b"})
    kw.setdefault("aiHearModels", {"custom": "qwen3-omni"})
    return dict(kw)


def answer(content="周五发布。", **message):
    m = {"content": content, **message}
    return Response(200, jsonfmt.write({"choices": [{"message": m, "finish_reason": "stop"}]}, pretty=False))


class Nearby(unittest.TestCase):
    def test_the_local_network_may_use_plain_http(self):
        for ok in ("http://192.168.1.20:8000/v1", "10.0.0.5:8000/v1", "http://172.20.1.1/v1", "http://100.101.102.103:8000/v1",
                   "http://169.254.3.4/v1", "http://gpu.local:30000/v1", "http://[fd12:3456::1]:8000/v1", "http://[::1]:8000/v1",
                   "http://[fe80::1]/v1", "http://localhost:11434/v1"):
            self.assertTrue((providers.custom_base(ok) or "").startswith("http://"), ok)
        for no in ("http://172.32.0.1/v1", "http://172.15.0.1/v1", "http://100.128.0.1/v1", "http://100.63.0.1/v1",
                   "http://8.8.8.8/v1", "http://192.169.1.1/v1", "http://gpu.example.com/v1", "http://10.0.0.5.evil.com/v1",
                   "http://10.0.0.256/v1", "http://[2001:db8::1]/v1"):
            self.assertIsNone(providers.custom_base(no), no)
        self.assertEqual("http://192.168.1.20:8000/v1/", providers.custom_base("192.168.1.20:8000/v1"))
        self.assertEqual("https://10.0.0.5.evil.com/v1/", providers.custom_base("10.0.0.5.evil.com/v1"))
        self.assertEqual("https://gpu.example.com/v1/", providers.custom_base("https://gpu.example.com/v1"))
        self.assertTrue(providers.is_nearby("http://192.168.1.20:8000/v1/"))
        self.assertFalse(providers.is_local("http://192.168.1.20:8000/v1/"))
        self.assertIsNone(providers.custom_base("  "))

    def test_a_nearby_service_needs_no_key(self):
        from cicada.core.ling import AIKey, LingClient
        s = AppSettings(aiProvider="custom", **custom())
        ling = LingClient(AIKey(path=os.path.join(HERE, "no-such-key")), Fake(lambda u, b: answer()), config=s.ai_config)
        self.assertEqual("", ling.current_key())
        s.aiCustomBase = "https://gpu.example.com/v1"
        self.assertIsNone(ling.current_key())


class Shape(unittest.TestCase):
    def test_custom_turns_thinking_off_through_the_template(self):
        c = providers.AIConfig(providers.CUSTOM, "http://localhost/v1/", "m", "h")
        body = {}
        c.shape(body, 50)
        self.assertEqual({"enable_thinking": False}, body["chat_template_kwargs"])
        self.assertNotIn("thinking", body)
        plain = {}
        c.shape(plain, 50, template_kwargs=False)
        self.assertNotIn("chat_template_kwargs", plain)
        for p in (providers.LING, providers.ZENMUX, providers.OPENROUTER):
            other = {}
            providers.AIConfig(p, p.base, "m", "h").shape(other, 50)
            self.assertNotIn("chat_template_kwargs", other, p.id)

    def test_a_thinking_model_is_seen_from_its_reply(self):
        def r(message, usage=None):
            root = {"choices": [{"message": message}]}
            if usage is not None:
                root["usage"] = usage
            return root
        self.assertFalse(providers.thought(r({"content": "周五发布。"})))
        self.assertTrue(providers.thought(r({"content": "周五发布。", "reasoning_content": "The user wants…"})))
        # A reasoning parser on the server: the answer itself sits in reasoning_content.
        self.assertTrue(providers.thought(r({"content": "", "reasoning_content": "周五发布。"})))
        self.assertTrue(providers.thought(r({"content": "周五发布。", "reasoning": "hmm"})))
        self.assertTrue(providers.thought(r({"content": "<think>hmm</think>周五发布。"})))
        self.assertTrue(providers.thought(r({"content": "周五发布。"}, {"completion_tokens_details": {"reasoning_tokens": 212}})))
        self.assertFalse(providers.thought(r({"content": "周五发布。", "reasoning_content": "  "},
                                             {"completion_tokens_details": {"reasoning_tokens": 0}})))
        self.assertFalse(providers.thought({}))

    def test_a_slow_sentence_is_flagged(self):
        self.assertFalse(aicheck.Speed(0.4, False).slow)
        self.assertTrue(aicheck.Speed(0.4, True).slow)
        self.assertTrue(aicheck.Speed(3.0, False).slow)
        self.assertTrue(aicheck.Speed(6.4, False).slow)
        r = aicheck.AICheck()
        r.pass_up_to("hear", 1.0)
        r.translate = aicheck.Speed(4.2, True)
        self.assertTrue(r.slow)
        self.assertIn("4.2", r.slow_line())
        self.assertIn("思考", r.slow_line())
        self.assertIn("Google", r.slow_line())
        # 语音和文字只发给你的服务: no Google to fall back on, the sentence is given up on.
        self.assertNotIn("Google", r.slow_line(google_off=True))
        self.assertIn("不等它了", r.slow_line(google_off=True))
        self.assertIn("思考", r.slow_line(google_off=True))
        r.translate = aicheck.Speed(3.5, False)
        self.assertNotIn("思考", r.slow_line())
        self.assertIn("不等它了", r.slow_line(google_off=True))
        self.assertNotIn("思考", r.slow_line(google_off=True))
        r.translate = aicheck.Speed(0.5, False)
        self.assertIsNone(r.slow_line())
        self.assertIn("translate=0.5s", r.summary())
        # The hear model is a job of its own: not filled in yet, it doesn't hide a thinking text model.
        r = aicheck.AICheck()
        r.pass_up_to("text", 4.2)
        r.translate = aicheck.Speed(4.2, True)
        r.fail("hear", aicheck.DEAF)
        self.assertTrue(r.slow)
        r = aicheck.AICheck()
        r.translate = aicheck.Speed(4.2, True)
        r.fail("text", aicheck.NO_JSON)
        self.assertFalse(r.slow)

    def test_no_hear_model_yet_names_the_service(self):
        from cicada.core import problem
        r = aicheck.AICheck()
        r.fail("hear", aicheck.DEAF)
        self.assertEqual("这个服务 听不了声音。", r.message("这个服务", "10.0.2.2", "qwen3-8b", ""))
        self.assertEqual("这个服务 听不了声音。", problem.title(aicheck.DEAF, "这个服务", "qwen3-8b", ""))
        self.assertEqual("qwen3-omni 听不了声音。", r.message("这个服务", "10.0.2.2", "qwen3-8b", "qwen3-omni"))


class TemplateKwargs(Base):
    def test_a_server_that_refuses_it_is_asked_again_without(self):
        def respond(url, body):
            return Response(422, "{}") if "chat_template_kwargs" in body else answer()
        fake = Fake(respond)
        ling, s = self.client(fake, "custom", key=None, **custom())
        self.assertEqual("周五发布。", ling.chat("x", "Translate.", TRANSLATE))
        self.assertEqual(2, len(fake.sent))
        self.assertIn("chat_template_kwargs", fake.sent[0][1])
        self.assertNotIn("chat_template_kwargs", fake.sent[1][1])
        # Not sent there again…
        ling.chat("x", "Translate.", TRANSLATE)
        self.assertEqual(3, len(fake.sent))
        self.assertNotIn("chat_template_kwargs", fake.sent[2][1])
        # …until settings change.
        ling.key_changed()
        ling.chat("x", "Translate.", TRANSLATE)
        self.assertIn("chat_template_kwargs", fake.sent[3][1])
        # A refused request never showed as a missing model.
        self.assertIsNone(ling.check_result.failure)

    def test_a_400_both_ways_is_not_the_field(self):
        fake = Fake(lambda u, b: Response(400, "{}"))
        ling, _ = self.client(fake, "custom", key=None, **custom())
        with self.assertRaises(LingError) as e:
            ling.chat("x", "Translate.", TRANSLATE)
        self.assertEqual(400, e.exception.status)
        self.assertEqual(2, len(fake.sent))
        fake.respond = lambda u, b: answer()
        ling.chat("x", "Translate.", TRANSLATE)
        self.assertIn("chat_template_kwargs", fake.sent[-1][1])  # nothing remembered

    def test_a_refusal_for_something_else_keeps_thinking_off(self):
        # No JSON mode on this server (OpenRouter's Novita for Ling 3.1 Flash): 400 with or without
        # the kwargs. Asked again without JSON mode.
        fake = Fake(lambda u, b: Response(400, "{}") if "response_format" in b else answer("好"))
        ling, _ = self.client(fake, "custom", key=None, **custom())
        self.assertEqual("好", ling.chat("x", "Notes.", TRANSLATE, json=True))
        last = jsonfmt.parse_object(fake.sent[-1][1])
        self.assertNotIn("response_format", last)
        self.assertIn("chat_template_kwargs", last)
        ling.chat("y", "Translate.", TRANSLATE)
        self.assertIn("chat_template_kwargs", fake.sent[-1][1])

    def test_other_errors_are_not_retried(self):
        fake = Fake(lambda u, b: Response(500, "{}"))
        ling, _ = self.client(fake, "custom", key=None, **custom())
        with self.assertRaises(LingError):
            ling.chat("x", "Translate.", TRANSLATE)
        self.assertEqual(1, len(fake.sent))


class Check(Base):
    def test_the_check_translates_a_real_sentence(self):
        fake = Fake(lambda u, b: Response(404, "") if u.endswith("/models") else answer())
        ling, _ = self.client(fake, "custom", key=None, **custom())
        self.assertEqual(OK, ling.check())
        first = jsonfmt.parse_object(fake.sent[0][1])
        self.assertIn("We will ship the new version on Friday", first["messages"][0]["content"])
        self.assertEqual("Translate.", first["messages"][1]["content"])
        self.assertEqual(120, first["max_tokens"])
        r = ling.check_result
        self.assertIsNotNone(r.translate)
        self.assertFalse(r.translate.thinks)
        self.assertFalse(r.slow)
        self.assertIn("translate=", r.summary())

    def test_a_thinking_model_is_slow(self):
        def respond(url, body):
            if url.endswith("/models"):
                return Response(404, "")
            return answer(reasoning_content="Let me think…")
        ling, _ = self.client(Fake(respond), "custom", key=None, **custom())
        ling.check()
        r = ling.check_result
        self.assertTrue(r.translate.thinks)
        self.assertTrue(r.slow)
        self.assertIn("思考", r.slow_line())

    def test_a_model_that_answers_json_without_json_mode_passes(self):
        def respond(url, body):
            if url.endswith("/models"):
                return Response(404, "")
            if "response_format" in body:
                return Response(400, "{}")
            return answer('```json\n{"ok": true}\n```' if "JSON object" in body else "周五发布。")
        ling, _ = self.client(Fake(respond), "custom", key=None, **custom())
        ling.check()
        self.assertIsNone(ling.check_result.failure)
        # One that can't answer JSON at all still fails.
        fake = Fake(lambda u, b: Response(404, "") if u.endswith("/models") else Response(400, "{}") if "response_format" in b else answer())
        ling, _ = self.client(fake, "custom", key=None, **custom())
        ling.check()
        self.assertEqual(("text", aicheck.NO_JSON, 400), ling.check_result.failure)

    def test_a_json_object_in_plain_text_counts_as_json(self):
        from cicada.core.ling import answers_json
        self.assertTrue(answers_json('{"ok": true}'))
        self.assertTrue(answers_json('```json\n{"ok": true}\n```'))
        self.assertFalse(answers_json("ok"))
        self.assertFalse(answers_json("} {"))
        self.assertFalse(answers_json(None))

    def test_bad_address_words_the_local_network(self):
        ling, _ = self.client(Fake(lambda u, b: answer()), "custom", key="sk-x", aiCustomBase="http://gpu.example.com/v1")
        ling.check()
        self.assertEqual(aicheck.BAD_ADDRESS, ling.check_result.reason)
        self.assertIn("局域网", ling.message())


class HearAddress(Base):
    def test_the_hear_address_falls_back_to_the_text_one(self):
        c = AppSettings(aiProvider="custom", **custom()).ai_config()
        self.assertEqual("http://192.168.1.20:8000/v1/", c.hear_url)
        self.assertFalse(c.own_hear_address)
        c = AppSettings(aiProvider="custom", **custom(aiCustomHearBase="192.168.1.30:8001/v1")).ai_config()
        self.assertEqual("http://192.168.1.30:8001/v1/", c.hear_url)
        self.assertEqual("http://192.168.1.20:8000/v1/", c.base)
        self.assertTrue(c.own_hear_address)
        # Typed but not valid: nowhere to send audio (not the text address).
        c = AppSettings(aiProvider="custom", **custom(aiCustomHearBase="http://gpu.example.com/v1")).ai_config()
        self.assertIsNone(c.hear_url)
        z = AppSettings(aiProvider="zenmux", aiCustomHearBase="http://192.168.1.30/v1").ai_config()
        self.assertEqual(z.base, z.hear_url)

    def test_hear_calls_and_the_check_go_to_the_hear_address(self):
        def respond(url, body):
            if url.endswith("/models"):
                return Response(404, "")
            return answer("NONE" if "input_audio" in body else "周五发布。")
        fake = Fake(respond)
        ling, _ = self.client(fake, "custom", key=None, **custom(aiCustomHearBase="http://192.168.1.30:8001/v1"))
        self.assertEqual(OK, ling.check())
        audio = [u for u, b in fake.sent if "input_audio" in b]
        text = [u for u, b in fake.sent if "chat/completions" in u and "input_audio" not in b]
        self.assertEqual(["http://192.168.1.30:8001/v1/chat/completions"], audio)
        self.assertTrue(text and all(u.startswith("http://192.168.1.20:8000/v1/") for u in text))
        self.assertEqual("ok", ling.check_result["hear"].kind)
        ling.chat("x", "y", TRANSLATE, model="qwen3-omni", audio=silence_wav())
        self.assertEqual("http://192.168.1.30:8001/v1/chat/completions", fake.sent[-1][0])

    def test_an_unreachable_hear_address_leaves_text_working(self):
        def respond(url, body):
            if "192.168.1.30" in url:
                raise OSError("no route")
            return Response(404, "") if url.endswith("/models") else answer()
        ling, _ = self.client(Fake(respond), "custom", key=None, **custom(aiCustomHearBase="http://192.168.1.30:8001/v1"))
        self.assertEqual(OK, ling.check())
        r = ling.check_result
        self.assertEqual(("hear", aicheck.UNREACHABLE, None), r.failure)
        self.assertFalse(r.down)
        self.assertIn("192.168.1.30", ling.message())
        self.assertEqual("192.168.1.30", ling.hear_host)

    def test_an_invalid_hear_address_fails_the_hear_step(self):
        fake = Fake(lambda u, b: Response(404, "") if u.endswith("/models") else answer())
        ling, _ = self.client(fake, "custom", key=None, **custom(aiCustomHearBase="http://gpu.example.com/v1"))
        ling.check()
        self.assertEqual(("hear", aicheck.BAD_ADDRESS, None), ling.check_result.failure)
        self.assertFalse(any("input_audio" in b for _u, b in fake.sent))


class AuthFake(Fake):
    """Fake, also keeping the key each request carried (`auth`, in order)."""

    def __init__(self, respond):
        super().__init__(respond)
        self.auth = []

    def send(self, url, method, body, headers, timeout):
        self.auth.append(headers.get("Authorization"))
        return super().send(url, method, body, headers, timeout)


MAIN, NOTES_AT = "https://main.example/v1/", "https://notes.example/v1/"


class NotesApart(Base):
    """Notes on their own model, or another server with its own key (LingTests.swift › Notes apart)."""

    def notes_client(self, fake, own: bool, **kw):
        kw.setdefault("aiCustomNotesBase", NOTES_AT if own else "")
        s = dict(aiCustomBase=MAIN, aiModels={"custom": "mt", "custom.notes": "big"}, aiHearModels={"custom": "omni"},
                 aiCustomNotesOwn=own, **kw)
        return self.client(fake, "custom", key="sk-main-1111111111", **s)

    def test_notes_go_to_their_model_and_server_translation_stays(self):
        fake = AuthFake(lambda u, b: answer("{}"))
        ling, _ = self.notes_client(fake, own=True)
        ling.notes_key_file.save("sk-notes-222222222")
        ling.chat("x", "Notes.", NOTES, json=True)
        ling.chat("y", "Translate.", TRANSLATE)
        self.assertEqual(["big", "mt"], [jsonfmt.parse_object(b)["model"] for _u, b in fake.sent])
        self.assertEqual([NOTES_AT + "chat/completions", MAIN + "chat/completions"], [u for u, _b in fake.sent])
        self.assertEqual(["Bearer sk-notes-222222222", "Bearer sk-main-1111111111"], fake.auth)
        # Its own key file, named as on the Mac, 0600.
        path = os.path.join(Paths.config(), "ai-key-custom-notes")
        self.assertEqual(path, ling.notes_key_file.path)
        self.assertEqual(0o600, os.stat(path).st_mode & 0o777)
        # Hearing is never notes: it stays at the hear address with the translation key.
        ling.chat("z", "Hear.", NOTES, model="omni", audio=silence_wav())
        self.assertEqual(MAIN + "chat/completions", fake.sent[-1][0])
        self.assertEqual("Bearer sk-main-1111111111", fake.auth[-1])

    def test_notes_without_their_own_key_use_the_translation_key(self):
        fake = AuthFake(lambda u, b: answer("{}"))
        ling, _ = self.notes_client(fake, own=True)
        self.assertFalse(ling.notes_has_own_key)
        ling.chat("x", "Notes.", NOTES)
        self.assertEqual("Bearer sk-main-1111111111", fake.auth[-1])
        self.assertTrue(fake.sent[-1][0].startswith(NOTES_AT))
        # The same service, another model: same address and key, even with a notes key on file.
        same, _ = self.notes_client(fake, own=False)
        same.notes_key_file.save("sk-notes-222222222")
        self.assertFalse(same.notes_has_own_key)
        same.chat("x", "Notes.", NOTES)
        self.assertTrue(fake.sent[-1][0].startswith(MAIN))
        self.assertEqual("Bearer sk-main-1111111111", fake.auth[-1])
        self.assertEqual("big", jsonfmt.parse_object(fake.sent[-1][1])["model"])

    def test_a_refused_notes_key_leaves_translation_working(self):
        fake = AuthFake(lambda u, b: Response(401, "{}") if '"big"' in b else answer("好"))
        ling, _ = self.notes_client(fake, own=True)
        with self.assertRaises(LingError) as e:
            ling.chat("x", "Notes.", NOTES)
        self.assertEqual(LingError.INVALID_KEY, e.exception.kind)
        self.assertNotEqual(INVALID, ling.key_state)
        self.assertEqual("好", ling.chat("y", "Translate.", TRANSLATE))
        # The real request told the notes, and only them: the next notes call doesn't go out.
        r = ling.check_result
        self.assertEqual(aicheck.INVALID_KEY, r.notes.reason)
        self.assertIsNone(r.failure)
        sent = len(fake.sent)
        with self.assertRaises(LingError):
            ling.chat("x", "Notes.", NOTES)
        self.assertEqual(sent, len(fake.sent))
        # A refused translation key still stops translation.
        fake.respond = lambda u, b: Response(401, "{}")
        with self.assertRaises(LingError):
            ling.chat("y", "Translate.", TRANSLATE)
        self.assertEqual(INVALID, ling.key_state)

    def test_notes_fall_back_to_translation_until_set(self):
        plain = providers.AIConfig(providers.CUSTOM, MAIN, "mt", "h")
        self.assertFalse(plain.notes_apart)
        self.assertEqual(plain, plain.for_notes)
        model = providers.AIConfig(providers.CUSTOM, MAIN, "mt", "h", notes_model="big")
        self.assertTrue(model.notes_apart)
        self.assertEqual(("big", MAIN), (model.for_notes.text_model, model.for_notes.base))
        # Only the custom service splits.
        ling = providers.AIConfig(providers.LING, providers.LING.base, "x", "h", notes_model="big")
        self.assertFalse(ling.notes_apart)
        self.assertEqual("x", ling.for_notes.text_model)
        # From the settings: the translation model or address chosen again is no split.
        c = AppSettings(aiProvider="custom", aiCustomBase=MAIN, aiModels={"custom": "mt", "custom.notes": " mt "}).ai_config()
        self.assertFalse(c.notes_apart)
        c = AppSettings(aiProvider="custom", aiCustomBase=MAIN, aiModels={"custom": "mt"}, aiCustomNotesOwn=True,
                        aiCustomNotesBase="main.example/v1").ai_config()
        self.assertIsNone(c.notes_base)
        self.assertTrue(c.notes_apart)  # 另一个服务 alone: its own key may differ
        # 同一个服务 keeps the address typed, unused.
        s = AppSettings(aiProvider="custom", aiCustomBase=MAIN, aiModels={"custom": "mt"}, aiCustomNotesOwn=False,
                        aiCustomNotesBase=NOTES_AT)
        self.assertFalse(s.ai_config().notes_apart)
        self.assertEqual(NOTES_AT, s.aiCustomNotesBase)
        s.aiCustomNotesOwn = True
        self.assertEqual(NOTES_AT, s.ai_config().for_notes.base)
        # http to the internet can't be used.
        s.aiCustomNotesBase = "http://notes.example/v1"
        c = s.ai_config()
        self.assertTrue(c.notes_bad_address)
        self.assertEqual(MAIN, c.for_notes.base)

    def test_settings_keep_notes_across_a_restart(self):
        s = AppSettings(aiProvider="custom", aiCustomNotesOwn=True, aiCustomNotesBase=NOTES_AT,
                        aiModels={"custom": "mt", "custom.notes": "big"})
        s.save()
        back = AppSettings.load()
        self.assertTrue(back.aiCustomNotesOwn)
        self.assertEqual(NOTES_AT, back.aiCustomNotesBase)
        self.assertEqual("big", back.aiModels["custom.notes"])

    def test_a_429_at_the_notes_server_does_not_hold_translation(self):
        ling, _ = self.notes_client(AuthFake(lambda u, b: answer()), own=True)
        ling._rate_limited(10.0, None, base=NOTES_AT)
        # Translation (no retries: it fails at once while its server cools down) goes on…
        self.assertEqual("周五发布。", ling.chat("y", "Translate.", TRANSLATE))
        # …while the notes' server waits.
        with self.assertRaises(LingError) as e:
            ling._acquire(TRANSLATE, fail_if_paused=True, base=NOTES_AT)
        self.assertEqual(LingError.RATE_LIMITED, e.exception.kind)

    def test_the_check_tests_notes_on_their_side(self):
        listed = {"data": [{"id": "big"}, {"id": "bigger"}]}

        def respond(url, body):
            if url.endswith("/models"):
                return Response(200, jsonfmt.write(listed)) if url.startswith(NOTES_AT) else Response(404, "")
            if url.startswith(NOTES_AT):
                return Response(401, "{}")
            return answer("NONE" if "input_audio" in body else "周五发布。")
        fake = AuthFake(respond)
        ling, _ = self.notes_client(fake, own=True)
        self.assertEqual(OK, ling.check())
        r = ling.check_result
        self.assertIsNone(r.failure)
        self.assertTrue(r.passed)
        self.assertEqual(aicheck.FAIL, r.notes.kind)
        self.assertTrue(r.notes_failed)
        self.assertIn("notes=fail(invalidKey)", r.summary())
        # Translation's JSON probe isn't asked: notes are tested where they go.
        main_json = [b for u, b in fake.sent if u.startswith(MAIN) and "json_object" in b]
        self.assertEqual([], main_json)
        self.assertIn("不认上面的 key", r.notes_line("notes.example", "big", shared_key=True))
        self.assertIn("key 无效", r.notes_line("notes.example", "big", shared_key=False))
        self.assertEqual(["big", "bigger"], ling.notes_catalog)
        # Their own key, which works.
        fake.respond = lambda u, b: (Response(404, "") if u.endswith("/models") else
                                     answer('{"ok": true}' if "JSON object" in b else "周五发布。"))
        ling.notes_key_file.save("sk-notes-222222222")
        ling.key_changed()
        self.assertEqual(OK, ling.check())
        self.assertEqual(aicheck.OK, ling.check_result.notes.kind)
        self.assertIsNone(ling.check_result.notes_line("notes.example", "big", True))
        notes_req = [a for (u, _b), a in zip(fake.sent, fake.auth) if u.startswith(NOTES_AT) and "chat" in u]
        self.assertEqual(["Bearer sk-notes-222222222"], notes_req[-1:])

    def test_a_bad_notes_address_fails_only_notes(self):
        fake = AuthFake(lambda u, b: Response(404, "") if u.endswith("/models") else answer())
        ling, _ = self.notes_client(fake, own=True, aiCustomNotesBase="http://notes.example/v1")
        self.assertEqual(OK, ling.check())
        self.assertEqual(aicheck.BAD_ADDRESS, ling.check_result.notes.reason)
        self.assertIn("局域网", ling.check_result.notes_line("x", "big", True))
        self.assertFalse(any("notes.example" in u for u, _b in fake.sent))


class StubLing:
    """The service, for the translator alone: answers each sentence, or fails."""

    def __init__(self, answer=None):
        self.usable = True
        self.answer = answer  # None: the service can't be reached
        self.asked = []
        self.check_result = aicheck.AICheck()  # not checked yet: every sentence is tried

    def chat(self, prompt, user, priority, **kw):
        self.asked.append(prompt)
        if self.answer is None:
            raise LingError("unreachable")
        return self.answer


GOOGLE = Response(200, '[[["周五发布。","We ship on Friday",null,null,1]]]')


class GoogleOff(unittest.TestCase):
    """语音和文字只发给你的服务 (issue #15, TranslatorTests.swift › GoogleOffTests): Google is never asked."""

    def translator(self, ling, google=GOOGLE):
        from cicada.core.translator import Translator
        fake = Fake(lambda u, b: google)
        return Translator(ling, transport=fake), fake

    def test_partial_lines_show_the_original_without_asking_anyone(self):
        from cicada.core.translator import Translator
        ling = StubLing("周五发布。")
        t, fake = self.translator(ling)
        t.google_off = True
        for _ in range(3):
            self.assertIsNone(t.translate("We ship on Friday", "en", "zh-CN", Translator.DRAFT))
        self.assertEqual([], fake.sent)
        self.assertEqual([], ling.asked)  # partial text never goes to the AI service either
        self.assertFalse(t.sentences_untranslated)

    def test_finished_sentences_go_to_the_service_only(self):
        from cicada.core.translator import Translator
        ling = StubLing("周五发布。")
        t, fake = self.translator(ling)
        t.google_off = True
        self.assertEqual("周五发布。", t.translate("We ship on Friday", "en", "zh-CN", Translator.SENTENCE))
        self.assertFalse(t.sentences_untranslated)
        ling.answer = None
        self.assertIsNone(t.translate("We ship on Friday", "en", "zh-CN", Translator.SENTENCE))
        self.assertTrue(t.sentences_untranslated)
        self.assertEqual([], fake.sent)

    def test_off_google_still_stands_in(self):
        from cicada.core.translator import Translator
        t, fake = self.translator(StubLing(None))
        self.assertEqual("周五发布。", t.translate("We ship on Friday", "en", "zh-CN", Translator.SENTENCE))
        self.assertEqual("周五发布。", t.translate("We ship on Friday", "en", "zh-CN", Translator.DRAFT))
        self.assertEqual(2, len(fake.sent))

    def test_flipping_it_clears_a_stale_google_backoff(self):
        from cicada.core.translator import Translator
        t, fake = self.translator(StubLing(None), google=Response(429, ""))
        self.assertIsNone(t.translate("Hello", "en", "zh-CN", Translator.DRAFT))
        self.assertGreater(t._google_backoff_until, 0)
        t.google_off = True
        self.assertEqual(0.0, t._google_backoff_until)
        t.translate("Hello", "en", "zh-CN", Translator.SENTENCE)
        self.assertTrue(t.sentences_untranslated)
        t.google_off = False
        self.assertFalse(t.sentences_untranslated)
        fake.respond = lambda u, b: GOOGLE
        self.assertEqual("周五发布。", t.translate("Hello", "en", "zh-CN", Translator.DRAFT))

    def test_only_with_the_custom_service(self):
        s = AppSettings(aiProvider="custom", aiCustomOnly=True, **custom())
        self.assertTrue(s.google_off)
        s.aiProvider = "ling"
        self.assertFalse(s.google_off)  # kept, but inert
        self.assertTrue(s.aiCustomOnly)
        self.assertFalse(AppSettings(aiProvider="custom", **custom()).google_off)

    def test_the_footnote_names_one_host_only_when_every_use_shares_it(self):
        s = AppSettings(aiProvider="custom", **custom())
        self.assertEqual("192.168.1.20", providers.only_host(s.ai_config()))
        s.aiCustomHearBase = "http://192.168.1.30:8000/v1"
        self.assertIsNone(providers.only_host(s.ai_config()))
        s.aiCustomHearBase = ""
        s.aiVoiceModels = {"custom": "qwen3-tts"}
        s.aiCustomVoiceBase = "http://192.168.1.40:8000/v1"
        self.assertIsNone(providers.only_host(s.ai_config()))


if __name__ == "__main__":
    unittest.main()
