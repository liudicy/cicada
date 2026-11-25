// Pure parts of the server, no Worker needed: node --test server/test/unit.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { ipGroup } from "../src/util.js";
import { flagged, ruleHit, BLOCK } from "../src/review.js";

test("IPv6 addresses count per /64; IPv4 per address", () => {
  assert.equal(ipGroup("203.0.113.7"), "203.0.113.7");
  assert.equal(ipGroup("2001:db8:85a3:0042:1000:8a2e:0370:7334"), "2001:db8:85a3:42::/64");
  assert.equal(ipGroup("2001:DB8:85a3:42::1"), "2001:db8:85a3:42::/64");
  assert.equal(ipGroup("2001:db8:85a3:42:ffff::9"), ipGroup("2001:db8:85a3:42::1"));
  assert.equal(ipGroup("2001:db8::1"), "2001:db8:0:0::/64");
  assert.equal(ipGroup("::1"), "0:0:0:0::/64");
  assert.equal(ipGroup(null), "local");
});

test("keys with a fixed shape are caught by the rules alone", () => {
  for (const k of [
    "-----BEGIN OPENSSH PRIVATE KEY-----", "-----BEGIN PRIVATE KEY-----", "AKIAIOSFODNN7EXAMPLE",
    "ghp_" + "a".repeat(36), "xoxb-1234567890-abcdef", "AIza" + "B".repeat(35), "sk-live-4f9a8c21de77b0a1c",
    "sk-proj-abcdefghijklmnop1234",
  ]) assert.ok(ruleHit(`the key is ${k} ok`), k);
  for (const t of ["we put keys in the vault", "risk-management-framework-review", "task-force-for-q4-planning", "sk-short"]) {
    assert.ok(!ruleHit(t), t);
  }
});

test("talking to the reviewer tightens the bar for that piece only", () => {
  const base = { credential: 0.84, confidential: 0.1, crossborder: 0.1, personal: 0.1, harmful: 0.1, manipulation: 0.1 };
  assert.deepEqual(flagged(base, "text"), []); // 0.84 is under BLOCK
  assert.deepEqual(flagged({ ...base, manipulation: 0.99 }, "text"), ["credential"]);
  // "nothing sensitive today" scores high on manipulation but nothing else: no block.
  assert.deepEqual(flagged({ ...base, credential: 0.01, manipulation: 0.9 }, "text"), []);
  // A rule hit blocks whatever the scores say.
  assert.deepEqual(flagged({ ...base, credential: 0.01 }, "key AKIAIOSFODNN7EXAMPLE"), ["credential"]);
  assert.equal(BLOCK, 0.85);
});

test("review pieces stay within what Clef reads, cover every line, and keep a key on a cut whole", async () => {
  const { chunks, PIECE_CHARS } = await import("../src/doc.js");
  const key = "sk-live-4f9a8c21de77b0a1cXYZ";
  const long = "啊".repeat(1400) + ` key ${key} ` + "啊".repeat(1400);
  const lines = Array.from({ length: 100 }, (_, i) => ({ t: i, who: "them", src: i === 50 ? long : "这是一句普通的会议发言，长度大概三十个字左右吧。", dst: i % 2 ? "An ordinary line." : null }));
  const notes = { summary: "总结".repeat(900), topics: [{ title: "t", summary: "s", points: ["p"] }], conclusions: [], todos: [], terms: [] };
  const parts = chunks({ title: "T", lines, notes });
  assert.ok(parts.every((p) => p.text.length <= PIECE_CHARS));
  const covered = new Set();
  for (const p of parts.filter((p) => p.part === "lines")) for (let i = p.from; i <= p.to; i++) covered.add(i);
  assert.equal(covered.size, 100);
  assert.ok(parts.some((p) => p.text.includes(key)));
  assert.ok(parts.filter((p) => p.part === "notes").length >= 2);
});
