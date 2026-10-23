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

The folder is an OKF (Open Knowledge Format) v0.2 bundle and every document in it is an OKF concept: one markdown file per subject, `knowledge/<id>.md`, whose id is the filename without `.md`. The id must be a slug (lowercase words joined by single dashes), because every verb and tool addresses a document by it.

```markdown
---
type: Runbook                # required, free text: Runbook, Decision, Map, Note…
title: Deploying the demo service
description: How the demo service is deployed and rolled back.   # one line
tags: [deploy, ci]           # slugs
resource: https://example.invalid/deploy   # kept and listed, not interpreted
generated:                   # who wrote it and when: ISO 8601 with an explicit offset
  by: deploy-tool
  at: 2026-09-10T08:00:00Z
verified:                    # a mapping or a list of them, kept and not interpreted
  - by: someone
    at: 2026-09-11T09:00:00+02:00
sources:                     # what it was derived from; only `resource` is required
  - resource: ../src/hosts.yaml
    title: Host inventory
status: stable              # draft | stable | deprecated; absent means stable
stale_after: 2026-12-01T00:00:00+01:00   # a datetime with an explicit offset
scope: project              # global | project
---

Everything before the first heading is the preamble — chunk `''`.

## Before you start

One `## ` heading starts one chunk. `###` and deeper stay inside it, and a `## comment` inside a fenced code block does not start anything.
```

Only `type` is required. The loader is tolerant, as OKF asks of a consumer: a key it does not know, a missing title, a malformed date or an unknown status never refuses a file, the value loads as absent (an unknown `status` as `stable`). A file is refused only when it cannot be addressed or classified: no frontmatter block, frontmatter that is not YAML, no `type`, or a stem that is not a slug. The strict reading of the folder is `lint`, below.

The legacy form, with `kind`, `updated` and `generated_from` instead of `type`, `generated` and `sources`, is still read for one release and never written: `kind: runbook` becomes the type `Runbook`, `updated` becomes `generated.at` at 00:00:00Z and `generated_from` becomes the one source. `lint` reports every legacy document so that the folder gets rewritten.

Two kinds of link to another document are understood, and `lint` reports the dead ones. `[[id]]` and `[[id#Heading]]` are wikilinks; `[text](/id.md)`, `[text](/id.md#fragment)`, `[text](./id.md)` and `[text](id.md#fragment)` are standard markdown links. A link with a URL scheme, a target that is not a `.md` file and a bare `#fragment` are not links to documents. A wikilink heading matches a section heading case-insensitively; a markdown fragment matches after URL-decoding either the heading, case-insensitively, or its slug (`#failover-steps` for `Failover steps`). Links inside fenced code are not links.

`status: deprecated` keeps a document loaded, searchable and listable but ranks it after the others and marks it `[deprecated]` in `list`. A document is stale once the clock reaches its `stale_after`; staleness is computed when a query is answered and never stored in the index, and `list` marks it `[stale]` while search results and `--json` carry a `stale` flag.

`index.md` at the folder root is the OKF progressive-disclosure file and `log.md` is the OKF change log; neither is a document, and no verb lists, searches or counts them. `tagents-knowledge toc` writes `index.md`: the frontmatter `okf_version: "0.2"`, then one group per `type` (alphabetical, types that differ only in case share a group), and in each group one line per document ordered by id, `* [<title>](<id>.md) - <description>`, with ` (deprecated)` appended for a deprecated one. The output is deterministic, so a diff of `index.md` is a diff of the folder.

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
| `search <query…> [--tag T] [--type T] [--kind K] [--limit N] [--json]` | one line per hit: `id#heading  score  snippet` |
| `show <id[#heading]>` | the markdown of the document, or of one section (`id#` is the preamble) |
| `list [--type T] [--kind K] [--tag T] [--json]` | `id  type  updated  title  #tags`, then ` [deprecated]` and ` [stale]` marks; `--kind` is the deprecated alias of `--type` |
| `lint [--dir D]` | the claims each document makes about itself, checked |
| `toc [--dir D] [--check]` | write `index.md`; `--check` writes nothing and exits 1 when it is absent or out of date |
| `mcp` | serve the tools below over stdio, one process for this one client |
| `serve [--idle S] [--foreground] [--socket P]` | make sure the shared MCP server for this environment is running and print the unix socket it listens on; `--idle S` is the quiet time in seconds before it exits (default 600); `--foreground` runs the server in this process instead, on `--socket P` |

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

`lint` reads the folder without using the index and prints one line per finding, `<filename>: <message>`, then `N problem(s) in DIR` and exits 1, or `N document(s) in DIR: no problems` and exits 0. A file the loader refuses is one finding and the others are still checked. The findings:

* `frontmatter`: a tag that is not a slug, a `status` outside `draft|stable|deprecated`, a `scope` outside `global|project`, a malformed `generated` or `verified`, a `stale_after` that is not a datetime with an explicit offset, a `sources` entry without a string `resource`, a title, description or resource that is not a string, or a key this package does not know (`unknown key "owner"`; the known keys are the ones in the example above plus `id`, and for a legacy document `kind`, `updated` and `generated_from`);
* `stem`: a frontmatter `id` that differs from the filename stem, or a stem that is not a slug;
* `duplicate-id`: two files that declare the same `id`;
* `legacy`: a document in the legacy form, to be rewritten in the OKF form;
* `expired`: `stale_after` has passed;
* `stale`: the UTC date of `generated.at` is earlier than the date of the newest commit that touched the file, checked only inside a git work tree, for committed files that have `generated`;
* `generated`: a `sources[].resource` that is a relative or bundle-relative path (`~` expanded) to an existing file modified on a UTC date after `generated.at`; URLs, other values that are not paths and files that do not exist on this machine are skipped;
* `dead-link`: a link of either form to a document, heading or fragment that does not exist, reported as `dead link <the link as written>`;
* `index`: `index.md` is missing or differs from what `toc` would write, which is cured by running `toc`.

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

Built on `@modelcontextprotocol/sdk` **1.x** (current stable major; input schemas are zod shapes the SDK turns into JSON Schema). The framing is stdio, newline-delimited JSON-RPC, and there are two ways to reach it: `tagents-knowledge mcp` is a process of its own for one client, and the shared server below is one process for every client with the same environment.

| tool | input | returns |
| --- | --- | --- |
| `knowledge_search` | `{ query, tag?, type?, kind?, limit? }` | the matching sections as JSON: `id, title, heading, score, snippet, path` |
| `knowledge_get` | `{ id, heading? }` | the markdown of the document, or of one section |
| `knowledge_list` | `{ type?, kind?, tag? }` | every document as JSON, with its headings |
| `sessions_recent` | `{ limit? }` | recent Claude sessions on this machine — core's renderer, the same text the sessions CLI prints |
| `sessions_search` | `{ words }` | sessions whose project or opening prompt contains every word |

There are no write tools, and there will not be any.

## The shared server

A `tagents-knowledge mcp` process is about 30 MB resident, and a Claude session starts one of its own. The plugin therefore registers `packages/knowledge/bin/knowledge-mcp` instead (`sh ${CLAUDE_PLUGIN_ROOT}/packages/knowledge/bin/knowledge-mcp`), a two-line POSIX script: it asks `tagents-knowledge serve` for the socket of the shared server and `exec`s `nc -U` on it, so a session is left with one `nc` of about 1.4 MB. If `serve` fails, a checkout predates it, or there is no `nc`, the script runs `tagents-knowledge mcp` and the session gets a server of its own, as before.

`serve` prints the socket and exits 0. If something already answers on it, that is all it does. Otherwise it starts the server detached (its own process group, so it outlives the session that happened to start it), waits until the socket accepts a connection and prints the path. The server gives every connection its own MCP server over the same stdio framing, and exits after 10 minutes without a connection: a one-shot timer, armed when the last connection closes and cleared by the next, so nothing polls.

One server per environment, not per session. The socket is `$TMPDIR/tagents-<uid>/knowledge-<key>.sock` in a directory of mode 0700 (under `/tmp` when `$TMPDIR` is too long for a socket address), and `<key>` is a hash of `HOME`, `TAGENTS_CONFIG_DIR`, `XDG_CONFIG_HOME`, `TAGENTS_KNOWLEDGE_DIR`, `TAGENTS_KNOWLEDGE_DB` and `CLAUDE_HOMES`, the variables the server and the session renderers behind it read, plus a stamp of the running build, so a rebuilt checkout starts a server of its own instead of joining the previous build's. Relative paths in those variables are made absolute against the starter's directory, because the server starts elsewhere. `test/socket.test.ts` scans the sources and fails when they read a variable that is neither in the key nor on its list of reasons not to be. Beside each socket the server keeps `<socket>.pid`, written once it listens and removed when it leaves.

Starters that race are settled by the kernel: the loser's `listen` fails with `EADDRINUSE`, it finds a live server and leaves. A socket file that refuses connections (its server was killed) is removed and replaced under a lock, in the same critical section as the new `listen`, so two servers that both see the dead file cannot unlink each other's fresh one.

Two limits worth knowing. A session that connects in the few milliseconds when the server is already leaving gets a connection refused, and its MCP server fails to start for that session. And the build stamp is the modification time of `dist/cli/main.js`, which `pnpm build` rewrites; running from `src/` does not notice an edit to another file.

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
spawns the real binary and kills it again. The shared-server suite
(`test/shared-server.test.ts`) runs the bridge script against real daemons in a
scratch `TMPDIR` and stops every process whose command line names that directory.
