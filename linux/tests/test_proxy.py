"""Which way requests go (proxy.py): the environment's proxy, else GNOME's manual one (HTTPS, the HTTP
one, else SOCKS), its ignore-hosts, and real requests through a fake HTTP proxy and a fake SOCKS5 one."""
from __future__ import annotations

import http.server
import os
import socket
import socketserver
import struct
import sys
import threading
import unittest
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from cicada.core import proxy  # noqa: E402

GNOME = """org.gnome.system.proxy autoconfig-url ''
org.gnome.system.proxy ignore-hosts ['localhost', '127.0.0.0/8', '::1']
org.gnome.system.proxy mode 'manual'
org.gnome.system.proxy use-same-proxy true
org.gnome.system.proxy.http enabled false
org.gnome.system.proxy.http host '10.0.2.2'
org.gnome.system.proxy.http port 7891
org.gnome.system.proxy.https host '10.0.2.2'
org.gnome.system.proxy.https port 7890
org.gnome.system.proxy.socks host ''
org.gnome.system.proxy.socks port 0
"""


def gnome(**changes) -> dict:
    s = proxy.parse_gnome(GNOME)
    s.update(changes)
    return s


class Settings(unittest.TestCase):
    def test_parse(self):
        s = proxy.parse_gnome(GNOME + "org.gnome.system.proxy.ftp host @as []\n")
        self.assertEqual("manual", s["mode"])
        self.assertEqual(["localhost", "127.0.0.0/8", "::1"], s["ignore-hosts"])
        self.assertIs(True, s["use-same-proxy"])
        self.assertEqual(("10.0.2.2", 7890), (s["https.host"], s["https.port"]))
        self.assertEqual([], s["ftp.host"])
        self.assertEqual({}, proxy.parse_gnome(""))  # no gsettings: the Mac running the tests

    def test_ignore_hosts(self):
        pats = ["localhost", "127.0.0.0/8", "::1", ".corp.example", "*.lan", "intra.example:8080", "10.1.2.3"]
        for host, port, want in (("localhost", 443, True), ("127.0.0.1", 11434, True), ("::1", 80, True),
                                 ("[::1]", 80, True), ("corp.example", 443, True), ("a.corp.example", 443, True),
                                 ("x.lan", 443, True), ("intra.example", 8080, True), ("intra.example", 443, False),
                                 ("10.1.2.3", 443, True), ("10.1.2.4", 443, False), ("zenmux.ai", 443, False),
                                 ("notlocalhost", 443, False)):
            self.assertEqual(want, proxy.ignored(host, port, pats), host)


class Routes(unittest.TestCase):
    def test_gnome_manual_https(self):
        r = proxy.route("https://zenmux.ai/api/v1/models", {}, gnome())
        self.assertEqual(("http", "10.0.2.2", 7890, "gnome"), r.key()[:4])
        self.assertEqual("http://10.0.2.2:7890", r.url)
        self.assertEqual("10.0.2.2:7891", proxy.route("http://example.com/", {}, gnome()).where)

    def test_gnome_falls_back_to_http_then_socks(self):
        s = gnome(**{"https.host": ""})
        self.assertEqual("10.0.2.2:7891", proxy.route("https://zenmux.ai/", {}, s).where)
        s = gnome(**{"https.host": "", "use-same-proxy": False, "socks.host": "127.0.0.1", "socks.port": 1080})
        self.assertEqual(("socks", "127.0.0.1", 1080, "gnome"), proxy.route("https://zenmux.ai/", {}, s).key()[:4])
        s = gnome(**{"https.host": "", "http.host": ""})
        self.assertEqual("direct", proxy.route("https://zenmux.ai/", {}, s).kind)

    def test_gnome_ignores_and_other_modes(self):
        self.assertEqual("direct", proxy.route("http://127.0.0.1:11434/v1", {}, gnome()).kind)  # a local service
        self.assertEqual("direct", proxy.route("https://localhost/", {}, gnome()).kind)
        self.assertEqual("direct", proxy.route("https://zenmux.ai/", {}, gnome(mode="auto")).kind)
        self.assertEqual("direct", proxy.route("https://zenmux.ai/", {}, gnome(mode="none")).kind)
        self.assertEqual("direct", proxy.route("file:///tmp/feed.json", {}, gnome()).kind)
        self.assertEqual("direct", proxy.route("https://zenmux.ai/", {}, gnome(**{"https.port": 0, "http.host": ""})).kind)

    def test_environment_first(self):
        env = {"https_proxy": "http://127.0.0.1:7897"}
        self.assertEqual("env", proxy.route("https://zenmux.ai/", env, gnome()).kind)  # urllib reads it
        self.assertEqual("10.0.2.2:7891", proxy.route("http://example.com/", env, gnome()).where)  # no http_proxy
        self.assertEqual("env", proxy.route("https://zenmux.ai/", {"HTTPS_PROXY": "http://h:1"}, {}).kind)
        self.assertEqual("10.0.2.2:7890", proxy.route("https://zenmux.ai/", {"https_proxy": " "}, gnome()).where)
        r = proxy.route("https://zenmux.ai/", {"all_proxy": "socks5://127.0.0.1:7890"}, gnome())
        self.assertEqual(("socks", "127.0.0.1", 7890, "env"), r.key()[:4])
        r = proxy.route("https://zenmux.ai/", {"ALL_PROXY": "http://u:p@127.0.0.1:7890"}, {})
        self.assertEqual(("http", "127.0.0.1:7890"), (r.kind, r.where))  # credentials stay out of `where`
        self.assertEqual("direct", proxy.route("https://zenmux.ai/", {"all_proxy": "socks5://h:1", "no_proxy": "zenmux.ai"}, gnome()).kind)


class Hint(unittest.TestCase):
    def hint(self, env, text, probe=lambda p: False, reach=lambda h, p: True):
        return proxy.hint(env, lambda: text, probe, reach)

    def test_cases(self):
        manual = GNOME
        none = GNOME.replace("'manual'", "'none'")
        self.assertEqual(("system",), self.hint({"https_proxy": "http://10.0.2.2:7890"}, ""))
        self.assertEqual(("dead", "10.0.2.2:7890"), self.hint({"https_proxy": "http://10.0.2.2:7890"}, "", reach=lambda h, p: False))
        self.assertEqual(("system",), self.hint({}, manual))
        self.assertEqual(("dead", "10.0.2.2:7890"), self.hint({}, manual, reach=lambda h, p: False))
        self.assertEqual(("pac",), self.hint({}, GNOME.replace("'manual'", "'auto'")))
        self.assertEqual(("app", 7897), self.hint({}, none, probe=lambda p: p == 7897))
        self.assertEqual(("none",), self.hint({"https_proxy": " "}, none))
        self.assertEqual(("none",), self.hint({}, ""))


class _Echo(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = ("path=" + self.path).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


class _Socks(socketserver.BaseRequestHandler):
    """A SOCKS5 proxy without authentication that remembers the name it was asked for."""
    asked: list = []

    def handle(self):
        c = self.request
        c.recv(3)
        c.sendall(b"\x05\x00")
        head = c.recv(4)
        name = c.recv(c.recv(1)[0]).decode()
        port = struct.unpack(">H", c.recv(2))[0]
        _Socks.asked.append((name, port))
        up = socket.create_connection(("127.0.0.1", port))
        c.sendall(b"\x05\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack(">H", port))
        assert head[1] == 1

        def pipe(a, b):
            try:
                while True:
                    d = a.recv(65536)
                    if not d:
                        break
                    b.sendall(d)
            except OSError:
                pass
            finally:
                try:
                    b.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
        t = threading.Thread(target=pipe, args=(up, c), daemon=True)
        t.start()
        pipe(c, up)
        t.join(5)
        up.close()


class Through(unittest.TestCase):
    """Real requests: the opener a route picks carries them through the proxy."""

    def serve(self, server):
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server.server_address[1]

    def test_http_proxy(self):
        # An HTTP proxy gets the absolute URL; the echo server plays the proxy here.
        port = self.serve(http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Echo))
        r = proxy.Route("http", "127.0.0.1", port, "gnome", "http://127.0.0.1:%d" % port)
        with proxy.opener(r).open(urllib.request.Request("http://cicada.invalid/x"), timeout=5) as resp:
            self.assertEqual(b"path=http://cicada.invalid/x", resp.read())

    def test_socks5(self):
        web = self.serve(http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Echo))
        socks = self.serve(socketserver.ThreadingTCPServer(("127.0.0.1", 0), _Socks))
        r = proxy.Route("socks", "127.0.0.1", socks, "gnome")
        _Socks.asked.clear()
        with proxy.opener(r).open(urllib.request.Request("http://localhost:%d/y" % web), timeout=5) as resp:
            self.assertEqual(b"path=/y", resp.read())
        self.assertEqual([("localhost", web)], _Socks.asked)  # the name, resolved by the proxy

    def test_dead_socks_is_an_oserror(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        r = proxy.Route("socks", "127.0.0.1", port, "gnome")
        with self.assertRaises(OSError):
            proxy.opener(r).open(urllib.request.Request("https://zenmux.ai/"), timeout=2)


if __name__ == "__main__":
    unittest.main()
