# 存到文件夹 (folder export)

After a meeting is settled, Cicada writes it as one Markdown file into a folder the user picked, so a
notes vault (Obsidian, Logseq), a synced folder or an agent watching the folder picks it up. The Mac
app is the reference (`Sources/Cicada/FolderExport.swift`); every port writes the same file name and
the same frontmatter. The fixtures in `Tests/fixtures/folder-export` are the contract: each
platform's unit tests check them.

## The file

`<frontmatter><Markdown body>`: the frontmatter below, then the body exactly as the platform's
existing 导出 Markdown gives it (the body is not part of the contract).

```
---
cicada: 1
id: "<record id>"
title: "<name>"
started: "<yyyy-MM-ddTHH:mm:ss±hh:mm>"
ended: "<yyyy-MM-ddTHH:mm:ss±hh:mm>"
minutes: <int>
languages: ["<code>", …]
source: "meeting" | "file"
notes: "final" | "draft" | "none"
tags: ["cicada"]
---
```

- Keys in this order, `\n` line ends, no trailing spaces. `cicada` is the format version.
- Every string is written as a JSON-style double-quoted string: `\` → `\\`, `"` → `\"`, `\n` `\r`
  `\t` as such, other characters below U+0020 as `\u00XX` (lowercase hex), everything else
  (including `/` and non-ASCII) as is. Lists are `[` items joined by `, ` `]`; empty: `[]`.
- Times are the device's local time with its offset (`+08:00`, `+00:00` for UTC, never `Z`), no
  fractional seconds.
- `minutes`: whole minutes of `ended − started`, rounded down.
- `languages`: the distinct `srcLang` of the lines, sorted by code point.
- `source`: `"file"` when the record has a `sourceFile` (an imported file), else `"meeting"`.
- `notes`: `"none"` without notes or with empty notes, `"final"` when `notes.final`, else `"draft"`.
- `name` (also used in the file name): the record's own title when the user renamed it (`renamed`,
  or for older records a title not starting with `会议 `), else the notes' title, else the imported
  file's name without its extension, else empty. Never the localized display title.

## The file name

`<yyyy-MM-dd HHmm>[ <safe name>].md`, the start in local time. The safe name:

1. Each of `/ \ : * ? " < > | # ^ [ ]` and each character below U+0020 becomes a space.
2. Runs of whitespace become one space; leading and trailing spaces and dots are removed.
3. Cut to at most 120 UTF-8 bytes at a code-point boundary, then trim trailing spaces and dots again.

An empty safe name leaves just the date: `2026-11-06 1400.md`.

Taken names (another record's file in the index, or a file on disk Cicada didn't write) get ` 2`,
` 3`… before `.md`. Cicada never overwrites a file it didn't write.

## When it writes

- A meeting is written once it is settled: it has ended, isn't being imported, has lines, and its
  final notes pass is not running or queued. Without a key or when the final pass fails, the
  transcript alone is written (`notes: "none"`), and rewritten if notes come later.
- A written record is rewritten after any later change (rename, names for voices, 重新整理…);
  unchanged content isn't written again. A new name moves the file.
- Deleting a record in Cicada leaves its file alone.
- Pending records are kept in the index and tried again at launch, when the app comes forward and on
  the next change. Writes are in order, one at a time, off the UI thread, and atomic (temporary file
  then rename) where the platform allows.
- 以前的会议 › 也存一份 queues every settled record not written yet; the first permission error
  stops the rest.

## The index

Next to the records (`FolderExport.json` on the Mac): the folder, each record's file name, and the
records still to write. A new folder starts a new index; files in the old one stay.

## Problems

- No permission (macOS privacy, Windows controlled folder access, a lost Android grant): one row in
  settings and one line in the record, plus one system notification after a meeting (never during
  one, never for 也存一份), once until it works again.
- The folder can't be found (drive unplugged): Cicada recreates only the last folder, and only when
  its parent exists; otherwise one grey line in settings and the record, no notification. It saves
  when the folder is back.
