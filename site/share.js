// The share page (/s/<id>, site/share.html): fetches the shared meeting and draws it as one page
// that discloses step by step. The notes come first; each chapter's dialogue appears when its row is
// opened; the speakers, the original text and search wait until asked for.
// Everything from the document goes in with textContent, never as HTML, and styles only through
// classes or the CSSOM (the page's CSP allows no inline script or style attribute).
// A password share is opened with PBKDF2 of the password; only that, not the password, is sent.
(function () {
  "use strict";
  var T = JSON.parse(document.getElementById("share-text").textContent);
  var id = (location.pathname.match(/^\/s\/([A-Za-z0-9_-]+)/) || [])[1] || "";
  var $ = function (s) { return document.getElementById(s); };
  var lang = document.documentElement.lang;
  var doc = null;
  var chapters = [];  // {el, row, open, lines: [{el, who, text}]}
  var speakers = [];  // {who, cls, share}
  var who = "";       // the speaker the dialogue is narrowed to

  function show(which) {
    ["sh-loading", "sh-password", "sh-gone", "sh-doc"].forEach(function (k) { $(k).hidden = k !== which; });
    $("sh-tools").hidden = which !== "sh-doc";
  }

  function gone(code) {
    var h = { revoked: T.revoked, expired: T.expired, locked: T.locked }[code] || T.missing;
    var p = code === "locked" ? T.locked_p : code === "not_found" ? T.missing_p : T.gone_p;
    $("sh-gone").setAttribute("data-kind", code === "expired" || code === "locked" ? code : "missing");
    $("sh-gone-h").textContent = h;
    $("sh-gone-p").textContent = p;
    show("sh-gone");
  }

  function failed() {
    $("sh-loading").textContent = T.error;
    show("sh-loading");
  }

  function el(tag, text, cls) {
    var e = document.createElement(tag);
    if (text != null) e.textContent = text;
    if (cls) e.className = cls;
    return e;
  }

  function clock(t) {
    t = Math.max(0, Math.floor(t || 0));
    var h = Math.floor(t / 3600), m = Math.floor(t / 60) % 60, s = t % 60;
    var two = function (n) { return (n < 10 ? "0" : "") + n; };
    return h ? h + ":" + two(m) + ":" + two(s) : two(m) + ":" + two(s);
  }

  function langName(c) {
    try { return new Intl.DisplayNames([lang], { type: "language" }).of(c) || c; } catch (e) { return c; }
  }

  // "说话人 2" → "2", "对方" → "对": what the avatar shows.
  function initial(name) {
    var digits = /(\d+)\s*$/.exec(name);
    return digits ? digits[1].slice(-2) : (Array.from(name.trim())[0] || "?").toUpperCase();
  }

  function avatar(s) {
    var a = el("span", initial(s.who), "sh-av " + s.cls);
    a.setAttribute("aria-hidden", "true");
    return a;
  }

  function render(d) {
    doc = d;
    var n = d.notes;
    document.title = d.title + " · " + document.title.split(" · ").pop();
    $("sh-title").textContent = d.title;
    var when = new Date(d.startedAt), date = "";
    if (!isNaN(when)) {
      var opts = { month: "long", day: "numeric" };
      if (when.getFullYear() !== new Date().getFullYear()) opts.year = "numeric";
      date = when.toLocaleDateString(lang, opts);
    }
    $("sh-meta").textContent = [date, T.minutes.replace("{n}", Math.max(1, Math.round(d.duration / 60))),
      d.langs.map(langName).join(" → ")].filter(Boolean).join(" · ");

    drawPeople(d);
    if (n) {
      $("sh-summary").textContent = n.summary;
      $("sh-summary").hidden = !n.summary;
      fill("sh-conclusions", "ol", n.conclusions, function (c) { return el("li", c.text); });
      fill("sh-todos", "ul", n.todos, function (c) {
        var li = el("li"), box = el("span", null, "box");
        box.setAttribute("aria-hidden", "true");
        li.appendChild(box);
        li.appendChild(el("span", (c.owner ? c.owner + "：" : "") + c.text));
        return li;
      });
      fill("sh-terms", "ul", n.terms, function (c) {
        var li = el("li");
        li.appendChild(el("b", c.name));
        if (c.note) li.appendChild(el("span", " " + c.note));
        return li;
      });
    }
    drawChapters(d);
    $("sh-hidden").textContent = d.hidden ? T.hidden.replace("{n}", d.hidden) : T.no_audio;
    show("sh-doc");
  }

  function fill(boxId, tag, items, make) {
    if (!items || !items.length) return;
    var box = $(boxId), list = box.querySelector(tag);
    items.forEach(function (x) { list.appendChild(make(x)); });
    box.hidden = false;
  }

  // Who spoke and how much: each line counts until the next one starts, at most 30 s (a pause is no one's).
  function drawPeople(d) {
    var time = {};
    d.lines.forEach(function (l, i) {
      if (!l.who) return;
      var next = i + 1 < d.lines.length ? d.lines[i + 1].t : d.duration;
      time[l.who] = (time[l.who] || 0) + Math.min(30, Math.max(1, (next || l.t) - l.t));
    });
    var order = [];
    d.lines.forEach(function (l) { if (l.who && order.indexOf(l.who) < 0) order.push(l.who); });
    var total = order.reduce(function (s, w) { return s + time[w]; }, 0) || 1;
    speakers = order.map(function (w, i) { return { who: w, cls: "sp" + Math.min(i, 5), share: Math.round(100 * time[w] / total) }; });
    speakers.sort(function (a, b) { return b.share - a.share; });
    if (!speakers.length) return;

    var stack = $("sh-stack"), list = $("sh-people");
    speakers.slice(0, 4).forEach(function (s) { stack.appendChild(avatar(s)); });
    $("sh-people-label").textContent = (speakers.length === 1 ? T.person : T.people).replace("{n}", speakers.length);
    speakers.forEach(function (s) {
      var li = el("li", null, s.cls), track = el("span", null, "track"), bar = el("span", null, "fill");
      li.appendChild(avatar(s));
      li.appendChild(el("span", s.who, "name"));
      bar.style.width = s.share + "%";
      track.appendChild(bar);
      track.setAttribute("aria-hidden", "true");
      li.appendChild(track);
      li.appendChild(el("span", s.share + "%", "pct"));
      if (speakers.length > 1) {
        var only = el("button", T.only, "only");
        only.type = "button";
        only.setAttribute("aria-pressed", "false");
        only.addEventListener("click", function () { narrow(who === s.who ? "" : s.who); });
        s.button = only;
        li.appendChild(only);
      }
      list.appendChild(li);
    });
    $("sh-people-btn").hidden = false;
  }

  // The chapters, each holding the lines said in it. Lines before the first chapter belong to it;
  // a meeting without chapters has one, all of its dialogue.
  function drawChapters(d) {
    var topics = (d.notes && d.notes.topics) || [], hasLines = d.lines.length > 0;
    var groups = topics.length ? topics.map(function (t) { return { start: t.start, title: t.title, summary: t.summary, points: t.points, lines: [] }; })
      : hasLines ? [{ start: d.lines[0].t, title: T.all_lines, summary: "", points: [], lines: [] }] : [];
    if (!groups.length) return;
    d.lines.forEach(function (l) {
      var k = 0;
      groups.forEach(function (g, i) { if (l.t >= g.start) k = i; });
      groups[k].lines.push(l);
    });
    var cls = {};
    speakers.forEach(function (s) { cls[s.who] = s.cls; });
    var anySrc = d.lines.some(function (l) { return l.dst && l.dst !== l.src; });

    $("sh-chapters-h").textContent = hasLines ? T.chapters_lines : T.chapters;
    var list = $("sh-chapter-list");
    groups.forEach(function (g, i) {
      var box = el("div", null, "sh-ch"), canOpen = g.lines.length > 0 || g.points.length > 0;
      var row = el(canOpen ? "button" : "div", null, "sh-row");
      if (canOpen) { row.type = "button"; row.setAttribute("aria-expanded", "false"); row.setAttribute("aria-controls", "sh-ch-" + i); }
      row.appendChild(el("span", clock(g.start), "t"));
      var body = el("span", null, "body");
      body.appendChild(el("span", g.title, "h"));
      if (g.summary) body.appendChild(el("span", g.summary, "s"));
      row.appendChild(body);
      if (canOpen) {
        var count = el("span", g.lines.length ? (g.lines.length === 1 ? T.line : T.lines).replace("{n}", g.lines.length) : "", "n");
        count.appendChild(chevron());
        row.appendChild(count);
      }
      box.appendChild(row);

      var open = el("div", null, "sh-open"), c = { el: box, row: row, panel: open, open: false, lines: [] };
      open.id = "sh-ch-" + i;
      open.hidden = true;
      if (g.points.length) {
        var ul = el("ul", null, "sh-pts");
        g.points.forEach(function (p) { ul.appendChild(el("li", p)); });
        open.appendChild(ul);
      }
      if (g.lines.length && anySrc) open.appendChild(srcSwitch());
      g.lines.forEach(function (l) {
        var line = el("div", null, "sh-line " + (cls[l.who] || "sp5")), head = el("span", l.who, "who");
        head.appendChild(el("span", " · " + clock(l.t)));
        line.appendChild(head);
        var translated = l.dst && l.dst !== l.src;
        line.appendChild(el("p", translated ? l.dst : l.src, "main"));
        if (translated) line.appendChild(el("p", l.src, "src"));
        open.appendChild(line);
        c.lines.push({ el: line, who: l.who, text: (l.src + "\n" + (l.dst || "")).toLowerCase() });
      });
      box.appendChild(open);
      if (canOpen) row.addEventListener("click", function () { toggle(c, !c.open); syncAll(); });
      chapters.push(c);
      list.appendChild(box);
    });
    if (groups.length === 1) toggle(chapters[0], true);
    var openable = chapters.filter(function (c) { return c.row.tagName === "BUTTON"; });
    $("sh-all").hidden = !hasLines || openable.length < 2;  // its words are about dialogue
    $("sh-chapters").hidden = false;
    syncAll();
  }

  function chevron() {
    var ns = "http://www.w3.org/2000/svg", svg = document.createElementNS(ns, "svg"), path = document.createElementNS(ns, "path");
    [["width", "14"], ["height", "14"], ["viewBox", "0 0 24 24"], ["fill", "none"], ["stroke", "currentColor"], ["stroke-width", "2"], ["aria-hidden", "true"]]
      .forEach(function (a) { svg.setAttribute(a[0], a[1]); });
    path.setAttribute("d", "M6 9l6 6 6-6");
    svg.appendChild(path);
    return svg;
  }

  function srcSwitch() {
    var row = el("div", null, "sh-switch-row"), label = el("span", T.show_src), sw = el("button", null, "sh-switch");
    sw.type = "button";
    sw.setAttribute("role", "switch");
    sw.setAttribute("aria-checked", "false");
    sw.setAttribute("aria-label", T.show_src);
    sw.addEventListener("click", function () {
      var on = !$("sh-doc").classList.contains("show-src");
      $("sh-doc").classList.toggle("show-src", on);
      document.querySelectorAll(".sh-switch").forEach(function (x) { x.setAttribute("aria-checked", on ? "true" : "false"); });
    });
    label.setAttribute("aria-hidden", "true");
    row.appendChild(label);
    row.appendChild(sw);
    return row;
  }

  function toggle(c, open) {
    if (c.row.tagName !== "BUTTON") return;
    c.open = open;
    c.panel.hidden = !open;
    c.row.setAttribute("aria-expanded", open ? "true" : "false");
  }

  function syncAll() {
    var all = shown().every(function (c) { return c.open; });
    $("sh-all").textContent = all ? T.collapse_all : T.expand_all;
  }

  // The chapters that can open and are not narrowed away.
  function shown() {
    return chapters.filter(function (c) { return c.row.tagName === "BUTTON" && !c.el.classList.contains("miss"); });
  }

  $("sh-all").addEventListener("click", function () {
    var list = shown(), all = list.every(function (c) { return c.open; });
    list.forEach(function (c) { toggle(c, !all); });
    syncAll();
  });

  // Narrowing (to one speaker, or to what matches the search) opens the chapters that still have lines.
  function apply() {
    var q = $("sh-search").value.trim().toLowerCase(), found = 0, narrowed = !!who || q !== "";
    chapters.forEach(function (c) {
      var left = 0;
      c.lines.forEach(function (l) {
        var miss = (who && l.who !== who) || (q && l.text.indexOf(q) < 0);
        l.el.classList.toggle("miss", !!miss);
        if (!miss) left++;
      });
      found += left;
      c.el.classList.toggle("miss", narrowed && left === 0);
      if (narrowed && left) toggle(c, true);
    });
    var f = $("sh-filter");
    f.hidden = !who;
    f.textContent = who ? T.only_who.replace("{name}", who) : "";
    $("sh-none").textContent = T.no_match;
    $("sh-none").hidden = !narrowed || found > 0;
    syncAll();
  }

  function narrow(w) {
    who = w;
    speakers.forEach(function (s) {
      if (!s.button) return;
      var on = s.who === w;
      s.button.setAttribute("aria-pressed", on ? "true" : "false");
      s.button.textContent = on ? T.everyone : T.only;
    });
    apply();
    if (w) $("sh-chapters").scrollIntoView({ block: "start" });
  }

  $("sh-filter").addEventListener("click", function () { narrow(""); });
  $("sh-people-btn").addEventListener("click", function () {
    var open = this.getAttribute("aria-expanded") !== "true";
    this.setAttribute("aria-expanded", open ? "true" : "false");
    $("sh-people").hidden = !open;
  });

  $("sh-search-btn").addEventListener("click", function () {
    var open = $("sh-search-row").hidden;
    $("sh-search-row").hidden = !open;
    this.setAttribute("aria-expanded", open ? "true" : "false");
    if (open) $("sh-search").focus();
    else if ($("sh-search").value) { $("sh-search").value = ""; apply(); }
  });
  // The first letter typed brings the dialogue up; later ones only narrow it.
  var searching = false;
  $("sh-search").addEventListener("input", function () {
    apply();
    var now = this.value.trim() !== "";
    if (now && !searching) $("sh-chapters").scrollIntoView({ block: "start" });
    searching = now;
  });
  $("sh-search").addEventListener("keydown", function (e) { if (e.key === "Escape") $("sh-search-btn").click(); });

  // The share menu: copy the link, copy the notes, or the system's share sheet where there is one.
  function menu(open) {
    $("sh-menu").hidden = !open;
    $("sh-share-btn").setAttribute("aria-expanded", open ? "true" : "false");
  }
  $("sh-share-btn").addEventListener("click", function (e) { e.stopPropagation(); menu($("sh-menu").hidden); });
  document.addEventListener("click", function (e) { if (!$("sh-menu").contains(e.target)) menu(false); });
  document.addEventListener("keydown", function (e) { if (e.key === "Escape") menu(false); });
  if (navigator.share) $("sh-send").hidden = false;

  function link() { return location.href.split("#")[0]; }

  function notesText() {
    var d = doc, n = d.notes, out = [d.title, $("sh-meta").textContent, ""];
    if (n) {
      if (n.summary) out.push(n.summary, "");
      if (n.conclusions.length) out.push(n.conclusions.map(function (c) { return "- " + c.text; }).join("\n"), "");
      if (n.todos.length) out.push(n.todos.map(function (c) { return "- [ ] " + (c.owner ? c.owner + "：" : "") + c.text; }).join("\n"), "");
      n.topics.forEach(function (t) { out.push(t.title + (t.summary ? "：" + t.summary : "")); t.points.forEach(function (p) { out.push("- " + p); }); out.push(""); });
    }
    out.push(link());
    return out.join("\n");
  }

  // The item says it worked for a moment, then the menu closes.
  function copy(text, b, done) {
    var was = b.textContent;
    (navigator.clipboard ? navigator.clipboard.writeText(text) : Promise.reject()).then(function () {
      b.textContent = done;
      setTimeout(function () { b.textContent = was; menu(false); }, 1200);
    }, function () { menu(false); window.prompt("", text); });
  }
  $("sh-copy-link").addEventListener("click", function () { copy(link(), this, T.link_copied); });
  $("sh-copy").addEventListener("click", function () { copy(notesText(), this, T.copied); });
  $("sh-send").addEventListener("click", function () {
    menu(false);
    navigator.share({ title: doc ? doc.title : document.title, url: link() }).catch(function () {});
  });

  function b64(bytes) {
    var s = "";
    new Uint8Array(bytes).forEach(function (c) { s += String.fromCharCode(c); });
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }
  function unb64(t) {
    var s = atob(t.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((t.length + 3) % 4));
    return Uint8Array.from(s, function (c) { return c.charCodeAt(0); });
  }

  function answer(r) {
    if (r.ok) return r.json().then(function (d) { if (d.locked) { lock = d; show("sh-password"); $("sh-pw").focus(); } else render(d); });
    return r.json().then(function (e) {
      if (r.status === 404 || r.status === 410 || r.status === 423) gone(e.code);
      else if (r.status === 403) { refuse(T.wrong); $("sh-pw").select(); }
      else if (r.status === 429 && lock) refuse(T.wait.replace("{s}", e.retryAfter || 60));
      else failed();
    }, failed);
  }

  // The password page: a wrong password shakes the field and says so in red; typing again puts the
  // reassurance back. The arrow turns into a spinner while the browser works the password out.
  var lock = null, note = $("sh-pw-text").textContent;
  function say(text, err) {
    $("sh-pw-text").textContent = text;
    $("sh-pw-msg").classList.toggle("err", err);
  }
  function refuse(text) {
    var form = $("sh-pw-form");
    form.classList.remove("bad");
    void form.offsetWidth;  // restart the shake
    form.classList.add("bad");
    say(text, true);
  }
  // The arrow only looks faint while the field is empty (CSS); it is never disabled for that, so a
  // password manager's fill, which may send no input event, can still be submitted.
  $("sh-pw").addEventListener("input", function () {
    if ($("sh-pw-form").classList.contains("bad")) { $("sh-pw-form").classList.remove("bad"); say(note, false); }
  });
  $("sh-pw-eye").addEventListener("click", function () {
    var shown = $("sh-pw").type === "password";
    $("sh-pw").type = shown ? "text" : "password";
    this.setAttribute("aria-pressed", shown ? "true" : "false");
    $("sh-pw").focus();
  });
  $("sh-pw-form").addEventListener("submit", function (ev) {
    ev.preventDefault();
    var pw = $("sh-pw").value, form = this;
    if (!pw) { $("sh-pw").focus(); return; }
    if (!lock || !crypto.subtle || form.classList.contains("busy")) return;
    form.classList.add("busy");
    crypto.subtle.importKey("raw", new TextEncoder().encode(pw), "PBKDF2", false, ["deriveBits"]).then(function (key) {
      return crypto.subtle.deriveBits({ name: "PBKDF2", salt: unb64(lock.salt), iterations: lock.iter, hash: "SHA-256" }, key, 256);
    }).then(function (bits) {
      return fetch("/api/v1/s/" + id + "/open", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ verifier: b64(bits) }) });
    }).then(answer, failed).then(function () { form.classList.remove("busy"); });
  });

  if (!id) { gone("not_found"); return; }
  fetch("/api/v1/s/" + id).then(answer, failed);
})();
