// GET /s/:id: the share page. It is one static shell per language (site/share.html, built by
// scripts/site.py); share.js in the browser fetches and shows the document. Here only the head is
// rewritten, for link previews: an open share's title and size, never its text unless the owner
// chose to show the summary. Password shares, gone shares and unknown ids keep the shell's generic card.
import { visible } from "./shares.js";
import { SECURITY } from "./util.js";

const LANGS = { zh: "", en: "en/", ja: "ja/", ko: "ko/" };
const WORDS = {
  zh: { brand: "知了", min: (n) => `${n} 分钟`, made: "知了生成的双语会议纪要。" },
  en: { brand: "Cicada", min: (n) => `${n} min`, made: "Bilingual meeting notes by Cicada." },
  ja: { brand: "Cicada", min: (n) => `${n} 分`, made: "Cicada が作成したバイリンガル議事録。" },
  ko: { brand: "Cicada", min: (n) => `${n}분`, made: "Cicada가 만든 이중 언어 회의록." },
};
const LANG_NAMES = { zh: "中文", en: "English", ja: "日本語", ko: "한국어", es: "Español", fr: "Français", de: "Deutsch", ru: "Русский", pt: "Português", it: "Italiano", ar: "العربية", th: "ไทย", vi: "Tiếng Việt", id: "Bahasa Indonesia" };

export function pickLang(request) {
  const url = new URL(request.url);
  const asked = url.searchParams.get("lang");
  if (asked && asked in LANGS) return asked;
  for (const part of (request.headers.get("Accept-Language") || "").split(",")) {
    const c = part.trim().slice(0, 2).toLowerCase();
    if (c in LANGS) return c;
  }
  return "en";
}

// Only this page runs a script, its own (share.js); the document is drawn with textContent.
const CSP = "default-src 'none'; script-src 'self'; style-src 'self' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

export async function page(request, env, id) {
  const lang = pickLang(request);
  const shell = await env.ASSETS.fetch(new URL(`/${LANGS[lang]}share/`, request.url));
  const v = await visible(env, id);
  const status = v.row ? 200 : v.status;
  const headers = new Headers({ "Content-Type": "text/html; charset=utf-8", "Cache-Control": "private, no-store", "Content-Security-Policy": CSP, ...SECURITY });
  let out = new HTMLRewriter();
  const url = new URL(request.url).origin + "/s/" + id;
  out = out.on('meta[property="og:url"]', { element: (e) => e.setAttribute("content", url) });
  if (v.row && v.row.mode === "open") {
    const w = WORDS[lang];
    const title = `${v.row.title} · ${w.brand}`;
    const langs = (v.row.langs || "").split(",").filter(Boolean).map((c) => LANG_NAMES[c] || c).join(" → ");
    const desc = v.row.og_desc || [w.min(Math.max(1, Math.round(v.row.duration / 60))), langs, w.made].filter(Boolean).join(" · ");
    out = out
      .on("title", { element: (e) => e.setInnerContent(title) })
      .on('meta[property="og:title"]', { element: (e) => e.setAttribute("content", title) })
      .on('meta[name="twitter:title"]', { element: (e) => e.setAttribute("content", title) })
      .on('meta[property="og:description"]', { element: (e) => e.setAttribute("content", desc) })
      .on('meta[name="twitter:description"]', { element: (e) => e.setAttribute("content", desc) })
      .on('meta[name="description"]', { element: (e) => e.setAttribute("content", desc) });
  }
  return out.transform(new Response(shell.body, { status, headers }));
}
