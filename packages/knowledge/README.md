# @tagents/knowledge

The owner's operational knowledge, stored as small markdown documents and made
searchable from a terminal and from any MCP client.

It replaces the one arrangement that does not scale: a single `knowledge.md`
that a system prompt tells the model to read *whole*, every session, whether the
question is about the backup disk or about nothing in the file at all.

Here the corpus is a folder of documents with frontmatter, cut at `## `
headings, indexed with SQLite FTS5. A question returns the two sections that
answer it, addressed as `id#heading`, and the model reads those.

**Writes go through git.** There is no tool in this package that edits a
document — not in the CLI, not over MCP. The documents are a repository a human
edits and commits; an agent that could rewrite them would put its paraphrase
into the source of truth with no diff and no review.

## The document format

One file per subject, `knowledge/<id>.md`:

```markdown
---
id: deploy-runbook          # a slug, and it MUST equal the filename stem
title: Deploying the demo service
kind: runbook               # cheatsheet | runbook | map | decision | note
tags: [deploy, ci]
updated: 2026-09-10         # YYYY-MM-DD, a real calendar date
generated_from: ../src/hosts.yaml   # optional: this file was derived
scope: project              # optional: global | project
---

Everything before the first heading is the preamble — chunk `''`.

## Before you start

One `## ` heading starts one chunk. `###` and deeper stay inside it, and a
`## comment` inside a fenced code block does not start anything.
```

The frontmatter is validated with zod, not merely parsed: an unknown key, a
`kind` outside the five, a `2026-02-30`, an `id` that is not a slug or does not
match the filename are all refused with the file named. `[[wikilinks]]` and
`[[wikilinks#Heading]]` are understood, and `lint` reports the dead ones.

## Where things live

| what | default | override |
| --- | --- | --- |
| the documents | *no default, on purpose* | `--dir`, `TAGENTS_KNOWLEDGE_DIR`, or `knowledge.dir` in `~/.config/tagents/config.yaml` |
| the index | `~/.config/tagents/knowledge.sqlite` | `--db`, `TAGENTS_KNOWLEDGE_DB` |

```yaml
# ~/.config/tagents/config.yaml — the same file core's plugin host reads
knowledge:
  dir: ~/git/personal/knowledge
```

There is no default documents folder because guessing one would index whatever
happened to be under it. Without one, every command exits 1 with the sentence
that says how to set it.

## CLI

| command | does |
| --- | --- |
| `index [--dir D] [--db F] [--full]` | bring the index in line with the folder; `--full` rebuilds from nothing |
| `search <query…> [--tag T] [--kind K] [--limit N] [--json]` | one line per hit: `id#heading  score  snippet` |
| `show <id[#heading]>` | the markdown of the document, or of one section (`id#` is the preamble) |
| `list [--kind K] [--tag T] [--json]` | `id  kind  updated  title  #tags` |
| `lint [--dir D]` | the claims each document makes about itself, checked |
| `mcp` | serve the tools below over stdio |

Exit codes: **0** ok · **1** error · **2** usage · **4** nothing found (a search
with no hits, a `show` of an id or heading that does not exist, an empty
`list`).

Every read command runs an incremental reindex first, so there is no such thing
as searching yesterday's copy of a runbook. A file whose mtime has not moved is
not even read; one whose mtime moved is hashed, so `git checkout` costs a hash
and not a reindex. A document that stopped parsing is named on stderr, removed
from the index, and the rest of the folder keeps answering.

Human strings go through the package's own `knowledge` namespace —
`TAGENTS_LOCALE=ru` for Russian. `--json` output never does: it is a contract.

`lint` reports:

* frontmatter that does not validate, and an `id` that is not the filename stem;
* an id used by two files;
* `updated:` older than the newest commit that touched the file — only when the
  folder is a git repository and the file has been committed;
* `generated_from:` whose source file has been modified since `updated:`;
* `[[wikilinks]]` to a document, or a heading, that does not exist.

## MCP

```sh
claude mcp add tagents -- tagents-knowledge mcp
```

or, for a headless run that must see exactly these tools and nothing else:

```jsonc
// mcp.json
{
  "mcpServers": {
    "tagents": {
      "command": "tagents-knowledge",
      "args": ["mcp"],
      "env": { "TAGENTS_KNOWLEDGE_DIR": "/Users/you/git/personal/knowledge" }
    }
  }
}
```

```sh
claude -p "where do the backups go?" --mcp-config mcp.json --strict-mcp-config
```

Built on `@modelcontextprotocol/sdk` **1.x** (current stable major; input
schemas are zod shapes the SDK turns into JSON Schema). Transport is stdio only:
the client spawns the process and owns its lifetime, so there is no port, no
token and no daemon left running.

| tool | input | returns |
| --- | --- | --- |
| `knowledge_search` | `{ query, tag?, kind?, limit? }` | the matching sections as JSON: `id, title, heading, score, snippet, path` |
| `knowledge_get` | `{ id, heading? }` | the markdown of the document, or of one section |
| `knowledge_list` | `{ kind?, tag? }` | every document as JSON, with its headings |
| `sessions_recent` | `{ limit? }` | recent Claude sessions on this machine — core's renderer, the same text the sessions CLI prints |
| `sessions_search` | `{ words }` | sessions whose project or opening prompt contains every word |

There are no write tools, and there will not be any.

## The tokenizer decision

The index is one FTS5 table over `(doc_id, heading, body)` with

```
tokenize='unicode61 remove_diacritics 2'
```

The corpus is Russian *and* English prose with shell commands and identifiers in
it, so this is the search-quality decision of the package:

* **unicode61 remove_diacritics 2 — chosen.** Unicode-aware word splitting, so
  Cyrillic is tokenised as words instead of one blob; `remove_diacritics 2`
  folds diacritics correctly for multi-byte text, where mode 1 mishandles
  anything outside Latin-1. Punctuation stays a separator, which is what lets
  `agent state` find `tmux-agent-state.sh`.
* **trigram — rejected.** It would match substrings, but it indexes every
  3-character window: several times the rows, and bm25 over trigrams ranks by
  how many windows coincide, which floats unrelated documents above the one that
  actually discusses the term.
* **A stemmer on top — rejected.** English-only stemming would help the English
  half and do nothing for the Russian one.

The cost is real and worth naming: **no morphology**. `бэкапы` finds `бэкапы`,
not `бэкап`. Trailing `*` is passed through as FTS5's prefix operator, so
`бэкап*` covers the forms; everything else a user types is quoted, because an
unquoted `-` means NOT and a stray `"` is a syntax error — a query box must not
be able to crash on `tmux-agent-state.sh`.

Ranking is `bm25(chunks_fts, 0.0, 10.0, 1.0)`: the heading weighs ten times the
body, so a section *called* "Rollback" beats one that mentions rolling back in
passing. `snippet()` marks the match with `[` … `]`.

## Install

```sh
pnpm add link:../tagents/packages/knowledge
```

`prepare` builds `dist/`, which is what the bin and the `exports` point at —
Node strips types from `.ts` files you own but refuses to under `node_modules`.

## Development

```sh
pnpm -r build
pnpm -r typecheck
pnpm -r test
```

No `any`, anywhere: `test/lint-no-any.test.ts` is the gate. Erasable syntax
only. The suites are hermetic — a temp folder, a temp index, a fixture corpus in
Russian and English under `test/fixtures/knowledge/`, and an MCP round trip that
spawns the real binary and kills it again.
