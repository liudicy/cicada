"""AI 服务检查 (AICheckTests.swift, plus the ports' 听对方 step): which step a failure stops at and
why, what passes, key prefixes, OpenRouter's balance, the models a service lists, the proxy hint,
and whole checks against a fake service, including results from real requests."""
from __future__ import annotations

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))

from test_providers import Base, Fake, reply  # noqa: E402

from cicada.core import aicheck, jsonfmt, proxy  # noqa: E402
from cicada.core.aicheck import AICheck, State  # noqa: E402
from cicada.core.ling import INVALID, OK, TRANSLATE, UNREACHABLE, LingError, Response, silence_wav  # noqa: E402

MODELS = {"data": [
    {"id": "inclusionai/ling-3.0-flash", "input_modalities": ["text"], "output_modalities": ["text"]},
    {"id": "qwen/qwen3.8-flash", "input_modalities": ["text"], "output_modalities": ["text"]},
    {"id": "qwen/qwen3.8-omni-flash", "input_modalities": ["text", "audio"], "output_modalities": ["text"]},
    {"id": "x/text-only", "input_modalities": ["text"], "output_modalities": ["text"]}]}


def kinds(r: AICheck) -> list:
    return [r[s].kind for s in aicheck.STEPS]


class Rules(unittest.TestCase):
    def test_classify(self):
        c = aicheck.classify
        self.assertEqual(("reach", "unreachable", None), c(LingError(LingError.NETWORK), "text"))
        self.assertEqual(("reach", "unreachable", None), c(LingError(LingError.TIMEOUT), "hear", True))
        self.assertEqual(("key", "invalidKey", None), c(LingError(LingError.INVALID_KEY), "text"))
        self.assertEqual(("text", "busy", None), c(LingError(LingError.RATE_LIMITED), "text"))
        self.assertEqual(("hear", "busy", None), c(LingError(LingError.RATE_LIMITED), "hear", True))
        self.assertEqual(("key", "noCredit", 402), c(LingError(LingError.HTTP, 402), "text"))
        self.assertEqual(("text", "noModel", 404), c(LingError(LingError.HTTP, 404), "text"))
        self.assertEqual(("key", "serverError", 400), c(LingError(LingError.HTTP, 400), "key"))
        self.assertEqual(("text", "serverError", 503), c(LingError(LingError.HTTP, 503), "text"))
        # The hear model: what says "this model takes no audio".
        for code in (400, 404, 415, 422):
            self.assertEqual(("hear", "deaf", code), c(LingError(LingError.HTTP, code), "hear", True))
        self.assertEqual(("hear", "serverError", 500), c(LingError(LingError.HTTP, 500), "hear", True))
        for kind in (LingError.NO_KEY, LingError.HIJACKED, LingError.PARSE):
            self.assertIsNone(c(LingError(kind), "text"))

    def test_a_failed_step_skips_the_rest(self):
        r = AICheck()
        r.fail("key", "invalidKey")
        self.assertEqual(["ok", "fail", "skipped", "skipped"], kinds(r))
        self.assertEqual(("key", "invalidKey", None), r.failure)
        # Nothing sent (a management key): the steps before it are not claimed.
        r = AICheck()
        r.fail("key", "mgmtKey", reached=False)
        self.assertEqual(["untested", "fail", "skipped", "skipped"], kinds(r))

    def test_passing_clears_a_failure_and_reopens_skipped_steps(self):
        r = AICheck()
        r.fail("reach", "unreachable")
        r.proxy = ("none",)
        r.pass_up_to("text", 1.5)
        self.assertEqual(["ok", "ok", "ok", "untested"], kinds(r))
        self.assertEqual(1.5, r["text"].seconds)
        self.assertIsNone(r.proxy)
        self.assertIsNone(r.failure)

    def test_busy_passes_and_needs_nobody(self):
        r = AICheck()
        r.pass_up_to("key", None)
        r["text"] = State(aicheck.BUSY_STATE)
        r.at = 1.0
        self.assertTrue(r.passed)
        self.assertTrue(r.busy)
        self.assertFalse(r.needs_user)
        self.assertIn("很忙", r.message("ZenMux", "zenmux.ai", "m", "h"))
        r.fail("text", "serverError", 503)
        self.assertFalse(r.needs_user)
        r.fail("hear", "deaf", 400)
        self.assertTrue(r.needs_user)
        self.assertFalse(r.down)  # notes and translation still work

    def test_not_passed_until_a_result(self):
        r = AICheck()
        self.assertFalse(r.passed)
        r["reach"] = State(aicheck.RUNNING)
        r.at = 1.0
        self.assertFalse(r.passed)

    def test_key_prefixes(self):
        self.assertEqual(("openrouter", False), aicheck.owner("sk-or-v1-abc"))
        self.assertEqual(("zenmux", False), aicheck.owner(" sk-payg-abc\n"))
        self.assertEqual(("zenmux", True), aicheck.owner("sk-mgmt-abc"))
        self.assertIsNone(aicheck.owner("sk-abc"))

    def test_balance_is_the_smaller(self):
        b = aicheck.balance
        self.assertEqual(1.5, b({"data": {"limit_remaining": 1.5}}, {"data": {"total_credits": 10, "total_usage": 2}}))
        self.assertEqual(8.0, b({"data": {"limit_remaining": None}}, {"data": {"total_credits": 10, "total_usage": 2}}))
        self.assertEqual(0.3, b({"data": {"limit_remaining": 0.3}}, None))
        self.assertIsNone(b(None, None))
        r = AICheck()
        r.balance = 0.4
        self.assertTrue(r.low_balance)
        self.assertTrue(r.needs_user)
        self.assertEqual("OpenRouter 余额快用完了（还剩 $0.40）", r.balance_line("OpenRouter"))
        r.balance = 0.5
        self.assertIsNone(r.balance_line("OpenRouter"))

    def test_listed_models(self):
        every, hear = aicheck.listed(jsonfmt.write(MODELS))
        self.assertIn("x/text-only", every)
        self.assertEqual({"qwen/qwen3.8-omni-flash"}, hear)
        # OpenRouter keeps them under `architecture`.
        _, hear = aicheck.listed({"data": [{"id": "a", "architecture": {"input_modalities": ["audio", "text"]}}]})
        self.assertEqual({"a"}, hear)
        # Nothing about modalities: can't tell who hears.
        every, hear = aicheck.listed({"data": [{"id": "a"}]})
        self.assertEqual({"a"}, every)
        self.assertIsNone(hear)
        self.assertEqual((None, None), aicheck.listed("not json"))

    def test_messages(self):
        r = AICheck()
        r.fail("reach", "unreachable")
        self.assertEqual("这台电脑访问不到 zenmux.ai。", r.message("ZenMux", "zenmux.ai", "m", "h"))
        r = AICheck()
        r.fail("text", "noModel", 404)
        self.assertEqual("ZenMux 上找不到 x/y 这个模型。", r.message("ZenMux", "zenmux.ai", "x/y", "h"))
        r = AICheck()
        r.pass_up_to("text", 1.0)
        r.fail("hear", "deaf", 400)
        self.assertEqual("x/text-only 听不了声音。", r.message("ZenMux", "zenmux.ai", "m", "x/text-only"))
        r = AICheck()
        r.fail("text", "serverError", 502)
        self.assertEqual("ZenMux 暂时出错（HTTP 502），稍后再试。", r.message("ZenMux", "zenmux.ai", "m", "h"))

    def test_summary(self):
        r = AICheck()
        r.pass_up_to("text", 1.25)
        r.fail("hear", "deaf", 400)
        self.assertEqual("reach=ok key=ok text=ok(1.2s) hear=fail(deaf 400)", r.summary())

    def test_every_simulated_reason(self):
        for reason in aicheck.REASONS:
            r = aicheck.simulated(reason)
            if reason == "busy":
                self.assertTrue(r.busy)
            else:
                self.assertEqual(reason, r.reason)
        self.assertIsNone(aicheck.simulated("lowBalance").failure)


class ProxyHint(unittest.TestCase):
    def test_cases(self):
        # More in test_proxy.py.
        nothing = lambda: ""  # noqa: E731
        up, down = (lambda h, p: True), (lambda h, p: False)  # noqa: E731
        gnome = ("org.gnome.system.proxy mode '%s'\norg.gnome.system.proxy.https host '10.0.2.2'\n"
                 "org.gnome.system.proxy.https port 7890\n")
        self.assertEqual(("system",), proxy.hint({"https_proxy": "http://10.0.2.2:7890"}, nothing, lambda p: False, up))
        # GNOME's manual proxy: requests go through it now, so "a proxy is on" is true when it answers.
        self.assertEqual(("system",), proxy.hint({}, lambda: gnome % "manual", lambda p: False, up))
        # One that doesn't answer isn't "a proxy is on, try another server".
        self.assertEqual(("dead", "10.0.2.2:7890"), proxy.hint({}, lambda: gnome % "manual", lambda p: True, down))
        # Automatic (PAC) isn't used: requests go direct, so it isn't "a proxy is on" either.
        self.assertEqual(("pac",), proxy.hint({}, lambda: gnome % "auto", lambda p: False, up))
        self.assertEqual(("app", 7897), proxy.hint({}, lambda: gnome % "none", lambda p: p == 7897, up))
        self.assertEqual(("none",), proxy.hint({"https_proxy": " "}, nothing, lambda p: False, up))
        # all_proxy, which urllib ignored, counts now that requests go through it.
        self.assertEqual(("dead", "127.0.0.1:1"), proxy.hint({"all_proxy": "socks5://127.0.0.1:1"}, nothing, lambda p: False, down))

    def test_words(self):
        r = AICheck()
        r.fail("reach", "unreachable")
        for hint, words in ((("system",), "开了代理也连不上：换一个节点，或检查代理软件是否放过 zenmux.ai。"),
                            (("app", 7890), "代理软件在运行（端口 7890），但没开系统代理。在代理软件里打开“系统代理”。"),
                            (("none",), "这台电脑没开代理。在国内通常要开代理才能用 ZenMux。"),
                            (("dead", "10.0.2.2:7890"), "代理 10.0.2.2:7890 没有回应。打开代理软件，或在 设置 › 网络 › 网络代理 里改正。"),
                            (("pac",), "系统代理设成了“自动”，知了用不了。在 设置 › 网络 › 网络代理 里改成“手动”。")):
            r.proxy = hint
            self.assertEqual(words, r.proxy_line("ZenMux", "zenmux.ai"))
        r.fail("key", "invalidKey")
        self.assertIsNone(r.proxy_line("ZenMux", "zenmux.ai"))  # only after "can't reach"

    def test_help_url(self):
        self.assertEqual("https://cicada.indaloop.app/start/#proxy", aicheck.help_url("zh-Hans"))
        self.assertEqual("https://cicada.indaloop.app/ja/start/#proxy", aicheck.help_url("ja"))


def service(text=200, hear=200, models=MODELS, json_ok=True, key_info=None, credits=None):
    """A fake service: the text model's status, the hear model's, its `/models`."""
    def respond(url, body):
        if url.endswith("/models"):
            return Response(200, jsonfmt.write(models)) if models is not None else Response(404, "")
        if url.endswith("/key"):
            return Response(200, jsonfmt.write(key_info or {"data": {"limit_remaining": None}}))
        if url.endswith("/credits"):
            return Response(200, jsonfmt.write(credits or {"data": {"total_credits": 5, "total_usage": 1}}))
        status = hear if "input_audio" in body else text
        if status != 200:
            return Response(status, "{}")
        if "json_object" in body and not json_ok:
            return Response(400, "{}")
        return reply("OK")
    return Fake(respond)


class Checks(Base):
    def setUp(self):
        super().setUp()
        proxy_calls = []
        self.proxy_calls = proxy_calls

    def client(self, fake, provider="zenmux", key="sk-payg-test-000000", **kw):
        ling, s = super().client(fake, provider, key, **kw)
        ling.proxy_hint = lambda: (self.proxy_calls.append(1), ("none",))[1]
        return ling, s

    def test_zenmux_passes_every_step(self):
        ling, _ = self.client(service())
        self.assertEqual(OK, ling.check())
        r = ling.check_result
        self.assertEqual(["ok"] * 4, kinds(r))
        self.assertIsNotNone(r["text"].seconds)
        self.assertIsNotNone(r["hear"].seconds)
        self.assertTrue(r.passed)
        self.assertTrue(ling.hears)

    def test_a_missing_text_model(self):
        ling, _ = self.client(service(text=404), aiModels={"zenmux": "no/such"})
        self.assertEqual(UNREACHABLE, ling.check())
        self.assertEqual(("text", "noModel", 404), ling.check_result.failure)
        self.assertEqual(["ok", "ok", "fail", "skipped"], kinds(ling.check_result))
        self.assertTrue(ling.usable)
        # One the service answers but doesn't list (an alias, a name typed by hand): a real request
        # just went through, so it exists whatever the list says (Ling.swift › check, 2026-11).
        ling, _ = self.client(service(), aiModels={"zenmux": "old/model"})
        self.assertEqual(OK, ling.check())
        self.assertIsNone(ling.check_result.failure)

    def test_a_deaf_hear_model(self):
        ling, _ = self.client(service(hear=400), aiHearModels={"zenmux": "x/text-only"})
        self.assertEqual(OK, ling.check())  # notes and translation still work
        self.assertEqual(("hear", "deaf", 400), ling.check_result.failure)
        self.assertFalse(ling.hears)
        self.assertFalse(ling.can_hear)
        # It takes the request, but the service doesn't list it as taking audio.
        ling, _ = self.client(service(), aiHearModels={"zenmux": "x/text-only"})
        ling.check()
        self.assertEqual(("hear", "deaf", None), ling.check_result.failure)
        # A service that says nothing about modalities can't make it deaf.
        ling, _ = self.client(service(models={"data": [{"id": "inclusionai/ling-3.0-flash"}]}))
        ling.check()
        self.assertIsNone(ling.check_result.failure)

    def test_an_invalid_key_stops_there(self):
        ling, _ = self.client(service(text=401))
        self.assertEqual(INVALID, ling.check())
        self.assertEqual(["ok", "fail", "skipped", "skipped"], kinds(ling.check_result))
        self.assertEqual("ZenMux 说这个 key 无效，可能没复制全，或已删除。", ling.message())

    def test_no_credit(self):
        ling, _ = self.client(service(text=402))
        ling.check()
        self.assertEqual(("key", "noCredit", 402), ling.check_result.failure)

    def test_a_management_key_sends_nothing(self):
        fake = service()
        ling, _ = self.client(fake, key="sk-mgmt-000000")
        self.assertEqual(INVALID, ling.check())
        self.assertEqual(("key", "mgmtKey", None), ling.check_result.failure)
        self.assertEqual([], fake.sent)

    def test_busy_counts_as_passed(self):
        ling, _ = self.client(service(text=429))
        self.assertEqual(OK, ling.check())
        r = ling.check_result
        self.assertTrue(r.passed)
        self.assertEqual("busy", r["text"].kind)

    def test_unreachable_words_the_proxy(self):
        def down(url, body):
            raise OSError("no route")
        ling, _ = self.client(Fake(down))
        self.assertEqual(UNREACHABLE, ling.check())
        r = ling.check_result
        self.assertEqual(["fail", "skipped", "skipped", "skipped"], kinds(r))
        self.assertEqual(("none",), r.proxy)
        self.assertEqual("这台电脑访问不到 zenmux.ai。", ling.message())

    def test_custom_without_json(self):
        ling, _ = self.client(service(json_ok=False, models=None), "custom", key="sk-x",
                              aiCustomBase="https://x.example/v1", aiModels={"custom": "m"}, aiHearModels={"custom": "h"})
        ling.check()
        self.assertEqual(("text", "noJSON", 400), ling.check_result.failure)
        ling, _ = self.client(service(), "custom", key="sk-x", aiCustomBase="http://x.example/v1")
        ling.check()
        self.assertEqual(("reach", "badAddress", None), ling.check_result.failure)

    def test_openrouter_reads_the_balance(self):
        ling, _ = self.client(service(key_info={"data": {"limit_remaining": 0.3}}), "openrouter", key="sk-or-v1-x",
                              aiModels={"openrouter": "inclusionai/ling-3.0-flash"}, aiHearModels={"openrouter": "qwen/qwen3.8-omni-flash"})
        ling.check()
        self.assertEqual(0.3, ling.check_result.balance)
        self.assertTrue(ling.check_result.needs_user)

    def test_ling_proves_hearing_in_a_meeting(self):
        ling, _ = self.client(service(), "ling", key="sk-ling")
        ling.check()
        self.assertEqual(["ok", "ok", "ok", "untested"], kinds(ling.check_result))
        self.assertTrue(ling.hears)
        ling.chat("c", "i", TRANSLATE, audio=silence_wav())
        self.assertEqual("ok", ling.check_result["hear"].kind)
        self.assertTrue(ling.check_result.passive)

    def test_real_requests_update_the_steps(self):
        status = {"text": 200}
        ling, _ = self.client(Fake(lambda u, b: Response(status["text"], "{}") if status["text"] != 200 else reply("OK")))
        ling.check()
        self.assertIsNone(ling.check_result.failure)
        status["text"] = 401
        with self.assertRaises(LingError):
            ling.chat("c", "i", TRANSLATE)
        self.assertEqual(("key", "invalidKey", None), ling.check_result.failure)
        self.assertTrue(ling.check_result.passive)
        # A server error in a meeting changes nothing.
        status["text"] = 200
        ling.key_state = OK
        ling.chat("c", "i", TRANSLATE)
        self.assertIsNone(ling.check_result.failure)
        status["text"] = 503
        with self.assertRaises(LingError):
            ling.chat("c", "i", TRANSLATE)
        self.assertIsNone(ling.check_result.failure)
        # The hear model refusing audio in a meeting: deaf, the text model keeps its ok.
        status["text"] = 415
        with self.assertRaises(LingError):
            ling.chat("c", "i", TRANSLATE, audio=silence_wav())
        self.assertEqual(("hear", "deaf", 415), ling.check_result.failure)
        self.assertEqual("ok", ling.check_result["text"].kind)

    def test_network_change_rechecks_only_after_unreachable(self):
        ling, _ = self.client(service())
        ling.check()
        self.assertFalse(ling.network_changed())
        ling.check_result = aicheck.simulated("unreachable")
        self.assertTrue(ling.network_changed())

    def test_a_stale_check_is_dropped(self):
        ling, s = self.client(service())
        seq = ling._check_seq
        r = aicheck.simulated("invalidKey")
        ling.key_changed()  # the settings changed while that check ran
        ling._finish_check(r, ling.config(), seq)
        self.assertIsNone(ling.check_result.failure)

    def test_simulated_check(self):
        ling, _ = self.client(service())
        ling.simulate = "deaf"
        ling.check()
        self.assertEqual(("hear", "deaf", 400), ling.check_result.failure)
        ling.simulate = "lowBalance"
        ling.check()
        self.assertTrue(ling.check_result.low_balance)


if __name__ == "__main__":
    unittest.main()
