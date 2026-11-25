"""How the app's requests reach the internet, and the words of the "can't reach the AI service" hint
(ProxyHint.swift). The app never sets a proxy; it uses the one this computer has:

- the environment's `https_proxy` (`http_proxy` for http://), as urllib always did, or `all_proxy`
  (an HTTP or SOCKS5 proxy);
- else GNOME's 设置 › 网络 › 网络代理 set to manual, which isn't passed to apps' environments: its
  HTTPS proxy, else the HTTP one (use-same-proxy, GNOME's default), else its SOCKS host, except for
  the hosts it says to ignore. The website's proxy help sends Linux users exactly there.

"Automatic" (a PAC file) needs a JavaScript engine to evaluate, so requests go direct then, and the
hint says so rather than claiming a proxy is on. Every request (AI service, translation, updates)
goes through `urlopen` here."""
from __future__ import annotations

import ast
import fnmatch
import http.client
import ipaddress
import os
import socket
import struct
import subprocess
import threading
import time
import urllib.parse
import urllib.request

from .support import Log

# Ports common proxy apps listen on (Clash 7890, Clash Verge 7897, SOCKS 1080).
PORTS = (7890, 7897, 1080)
# A host the hint asks about: any public one (GNOME's ignore list names local ones).
PROBE_URL = "https://openrouter.ai/"


class Route:
    """`kind`: "direct"; "env" (urllib reads the environment itself, no_proxy included); "http" or
    "socks" through `host`:`port`, from `origin` ("env" or "gnome"). `url` is the HTTP proxy as
    urllib takes it (credentials in it stay out of logs: `where` is host:port only)."""

    def __init__(self, kind: str, host: str = "", port: int = 0, origin: str = "", url: str = ""):
        self.kind, self.host, self.port, self.origin, self.url = kind, host, port, origin, url

    @property
    def where(self) -> str:
        return "%s:%d" % (self.host, self.port) if self.host else ""

    def key(self) -> tuple:
        return (self.kind, self.host, self.port, self.origin, self.url)

    def __eq__(self, other) -> bool:
        return isinstance(other, Route) and self.key() == other.key()

    def __repr__(self) -> str:
        return "Route(%s)" % " ".join(str(p) for p in self.key()[:4] if p)


# GNOME's settings

def _gsettings_dump() -> str:
    try:
        r = subprocess.run(["gsettings", "list-recursively", "org.gnome.system.proxy"],
                           capture_output=True, text=True, timeout=2)
        return r.stdout if r.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""  # no gsettings (not GNOME, or the Mac running the tests)


def parse_gnome(text: str) -> dict:
    """`gsettings list-recursively org.gnome.system.proxy` as {"mode": "manual", "https.host": …}."""
    out: dict = {}
    for line in text.splitlines():
        parts = line.split(None, 2)
        if len(parts) != 3 or not parts[0].startswith("org.gnome.system.proxy"):
            continue
        child = parts[0][len("org.gnome.system.proxy"):].lstrip(".")
        raw = parts[2].strip()
        if raw.startswith("@"):  # a typed empty value: "@as []"
            raw = raw.split(None, 1)[1] if " " in raw else ""
        raw = {"true": "True", "false": "False"}.get(raw, raw)
        try:
            value = ast.literal_eval(raw)
        except (ValueError, SyntaxError):
            value = raw
        out[(child + "." if child else "") + parts[1]] = value
    return out


_gnome_cache: tuple = (0.0, {})
_gnome_lock = threading.Lock()


def gnome(read=None, ttl: float = 3.0) -> dict:
    """GNOME's proxy settings, read again after `ttl` seconds: partial translations ask several
    times a second, and a changed setting applies within moments, no restart."""
    global _gnome_cache
    if read is not None:
        return parse_gnome(read())
    with _gnome_lock:
        at, value = _gnome_cache
        if time.monotonic() - at < ttl and at:
            return value
    value = parse_gnome(_gsettings_dump())
    with _gnome_lock:
        _gnome_cache = (time.monotonic(), value)
    return value


def ignored(host: str, port: int, patterns) -> bool:
    """GNOME's ignore-hosts (GSimpleProxyResolver's forms): "example.com", ".example.com" and
    "*.example.com" all match it and its subdomains; an address or a CIDR range; any with ":port"."""
    host = host.strip("[]").lower().rstrip(".")
    try:
        addr = ipaddress.ip_address(host)
    except ValueError:
        addr = None
    for p in patterns or ():
        p = str(p).strip().lower()
        if not p:
            continue
        want_port = None
        if p.startswith("[") and "]" in p:  # "[::1]:8080"
            p, _, rest = p[1:].partition("]")
            want_port = int(rest[1:]) if rest.startswith(":") and rest[1:].isdigit() else None
        elif p.count(":") == 1:  # "example.com:8080" (an IPv6 address has several colons)
            p, _, pp = p.partition(":")
            want_port = int(pp) if pp.isdigit() else None
        if want_port is not None and want_port != port:
            continue
        if addr is not None:
            try:
                if addr in ipaddress.ip_network(p, strict=False):
                    return True
            except ValueError:
                pass
            continue
        name = p.lstrip("*").lstrip(".")
        if not name:
            continue
        if host == name or host.endswith("." + name) or fnmatch.fnmatchcase(host, p):
            return True
    return False


# Which way a request goes

def _env(env, *names) -> str:
    for n in names:
        v = (env.get(n) or env.get(n.upper()) or "").strip()
        if v:
            return v
    return ""


def _proxy_url(value: str):
    """("http"|"socks", host, port, url) for a proxy URL, or None when it isn't one we can use."""
    if "://" not in value:
        value = "http://" + value
    u = urllib.parse.urlsplit(value)
    try:
        port = u.port
    except ValueError:
        return None
    if not u.hostname:
        return None
    if u.scheme in ("http", "https"):
        return ("http", u.hostname, port or (443 if u.scheme == "https" else 80), value)
    if u.scheme in ("socks5", "socks5h", "socks"):
        return ("socks", u.hostname, port or 1080, value)
    return None


def route(url: str, env=None, settings=None) -> Route:
    """How a request to `url` leaves the app. `env` and `settings` (parse_gnome's) are for tests."""
    env = os.environ if env is None else env
    u = urllib.parse.urlsplit(url)
    if u.scheme not in ("http", "https") or not u.hostname:
        return Route("direct")  # file:// (tests, a local feed)
    port = u.port or (443 if u.scheme == "https" else 80)
    if _env(env, u.scheme + "_proxy"):
        return Route("env", origin="env")
    every = _env(env, "all_proxy")
    if every:
        # urllib ignores all_proxy; Clash's "copy proxy command" sets it, often as socks5://.
        p = _proxy_url(every)
        no = _env(env, "no_proxy")
        if p and not (no and urllib.request.proxy_bypass_environment(u.hostname, {"no": no})):
            return Route(p[0], p[1], p[2], "env", p[3])
        if p:
            return Route("direct")
    s = gnome() if settings is None else settings
    if s.get("mode") != "manual" or ignored(u.hostname, port, s.get("ignore-hosts")):
        return Route("direct")

    def at(child):
        host, p = str(s.get(child + ".host") or "").strip(), s.get(child + ".port")
        return (host, int(p)) if host and isinstance(p, int) and 0 < p < 65536 else None
    if u.scheme == "https":
        hp = at("https") or (at("http") if s.get("use-same-proxy", True) else None)
    else:
        hp = at("http")
    if hp:
        return Route("http", hp[0], hp[1], "gnome", "http://%s:%d" % (hp[0] if ":" not in hp[0] else "[%s]" % hp[0], hp[1]))
    sp = at("socks")
    if sp:
        return Route("socks", sp[0], sp[1], "gnome")
    return Route("direct")


# SOCKS5 (RFC 1928), no authentication: the name is resolved by the proxy, as socks5h does.

def _recv(sock, n: int) -> bytes:
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise OSError("SOCKS proxy closed the connection")
        data += chunk
    return data


def socks5_connect(proxy_host: str, proxy_port: int, host: str, port: int, timeout=None):
    sock = socket.create_connection((proxy_host, proxy_port), timeout)
    try:
        sock.sendall(b"\x05\x01\x00")
        if _recv(sock, 2) != b"\x05\x00":
            raise OSError("SOCKS proxy wants authentication")
        name = host.encode("idna")
        sock.sendall(b"\x05\x01\x00\x03" + bytes([len(name)]) + name + struct.pack(">H", port))
        head = _recv(sock, 4)
        if head[1] != 0:
            raise OSError("SOCKS proxy refused the connection (%d)" % head[1])
        _recv(sock, {1: 4, 4: 16}.get(head[3], 0) or _recv(sock, 1)[0])
        _recv(sock, 2)
        return sock
    except BaseException:
        sock.close()
        raise


def _through(proxy: Route, cls):
    def connection(host, **kw):
        c = cls(host, **kw)
        c._create_connection = lambda addr, timeout=None, source_address=None: socks5_connect(
            proxy.host, proxy.port, addr[0], addr[1], timeout)
        return c
    return connection


class _SocksHTTP(urllib.request.HTTPHandler):
    def __init__(self, proxy: Route):
        super().__init__()
        self.proxy = proxy

    def http_open(self, req):
        return self.do_open(_through(self.proxy, http.client.HTTPConnection), req)


class _SocksHTTPS(urllib.request.HTTPSHandler):
    def __init__(self, proxy: Route):
        super().__init__()
        self.proxy = proxy

    def https_open(self, req):
        return self.do_open(_through(self.proxy, http.client.HTTPSConnection), req, context=self._context)


_openers: dict = {}
_said: list = [None]


def opener(r: Route):
    k = r.key()
    o = _openers.get(k)
    if o is None:
        if r.kind == "env":
            o = urllib.request.build_opener()
        elif r.kind == "http":
            o = urllib.request.build_opener(urllib.request.ProxyHandler({"http": r.url, "https": r.url}))
        elif r.kind == "socks":
            o = urllib.request.build_opener(urllib.request.ProxyHandler({}), _SocksHTTP(r), _SocksHTTPS(r))
        else:
            o = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        _openers[k] = o
    return o


def urlopen(req, timeout: float):
    """urllib.request.urlopen, through this computer's proxy (route)."""
    url = req.full_url if isinstance(req, urllib.request.Request) else req
    r = route(url)
    if r.key() != _said[0] and url.startswith("http"):  # a file:// test feed would flip it back and forth
        _said[0] = r.key()
        Log.d("net: %s%s" % (r.kind, " %s %s" % (r.origin, r.where) if r.where else ""))
    return opener(r).open(req, timeout=timeout)


# The hint

def listening(port: int, timeout: float = 0.3) -> bool:
    """Something accepts a TCP connection on 127.0.0.1:`port` within `timeout`. Nothing is sent."""
    return reachable("127.0.0.1", port, timeout)


def reachable(host: str, port: int, timeout: float = 1.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def hint(env=None, gsettings=None, probe=listening, reach=reachable) -> tuple:
    """("system",) a proxy is in use and answers; ("dead", "host:port") the proxy in use doesn't
    answer; ("pac",) GNOME's proxy is automatic, which the app can't use; ("app", port) a proxy app
    listens but no proxy is set; ("none",). See AICheck.proxy_line."""
    env = os.environ if env is None else env
    settings = gnome(gsettings) if gsettings is not None else gnome()
    r = route(PROBE_URL, env, settings)
    if r.kind == "env":
        p = _proxy_url(_env(env, "https_proxy"))
        r = Route(p[0], p[1], p[2], "env", p[3]) if p else r
    if r.kind in ("http", "socks"):
        return ("system",) if reach(r.host, r.port) else ("dead", r.where)
    if r.kind == "env":
        return ("system",)
    if settings.get("mode") == "auto":
        return ("pac",)
    for port in PORTS:
        if probe(port):
            return ("app", port)
    return ("none",)
