// Runs the real review (Jev via ZenMux) on meeting records, to see what it would block:
//   NODE_USE_ENV_PROXY=1 ZENMUX_API_KEY=… node server/test/review-live.mjs <session.json>…
// Builds a rough share document from each record (all lines, the notes) and prints the scores.
// Costs a fraction of a cent per meeting; not part of the automatic tests.
import { readFileSync } from "node:fs";
import { review } from "../src/review.js";

const env = { ZENMUX_API_KEY: process.env.ZENMUX_API_KEY || process.env.ZENMUX_CICADA_API_KEY };
for (const file of process.argv.slice(2)) {
  const s = JSON.parse(readFileSync(file, "utf8"));
  const n = s.notes;
  const doc = {
    v: 1, title: s.title, startedAt: s.startedAt, duration: 0, langs: [], hidden: 0,
    lines: s.lines.map((l) => ({ t: l.t, who: l.speaker === "me" ? "me" : "them", src: l.src, dst: l.dst ?? null })),
    notes: n ? { summary: n.summary || "", topics: n.topics || [], conclusions: n.conclusions || [], todos: n.todos || [], terms: n.terms || [] } : null,
  };
  const t = Date.now();
  const r = await review(env, doc);
  console.log(file.split("/").slice(-2, -1)[0], `${Date.now() - t} ms`, r.blocked ? "BLOCKED" : "ok", JSON.stringify(r.max), JSON.stringify(r.hits));
}
