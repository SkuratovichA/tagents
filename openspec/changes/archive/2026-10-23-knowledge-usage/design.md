## Context

See `proposal.md` for the motivation. The constraints that shape the approach:

- The index is derived. `openDb` drops and rebuilds it when its schema version moves, and a read reindexes first. Nothing in it can be the only copy of anything.
- The MCP server opens the index per call and closes it (`withDb`), and `createServer` opens nothing at construction, because the contract generator lists the tools over an in-memory link. The shared daemon makes one `McpServer` per connection, with the environment the daemon started with.
- `TA_LABEL` is a session variable, so the daemon cannot see it. `test/socket.test.ts` fails when the sources read an environment variable that is neither in the key of the shared server nor in its list of reasons to ignore one.

## Goals / Non-Goals

**Goals:**

- A count that survives index rebuilds and can answer "how often in the last N days, on how many different days".
- Recording that can neither fail a read nor make it noticeably slower.
- One shape for the report, produced by one function that the CLI and the MCP tool both print.

**Non-Goals:**

- No handle kept between calls, no background writer and no migration machinery for the store: a later change adds columns that are nullable, or a new file.
- No new way to write a document. The store holds counts about documents and never their text.

## Decisions

**Events, not counters.** One row per read answers every question the report asks: a window, distinct days, the last read, and later the section and the caller. A counter per document answers "how many ever" and nothing else. The cost is a row per read, bounded by the 365-day retention and by a `usage_by_ts` index that lets the prune avoid a scan. Rejected: a counter per document per UTC day, which answers the window and the days in less space but drops the heading and the caller, and neither can be backfilled.

**A file of its own, beside the index in use.** The usage store is the only copy of what happened, so it shares no file and no lifecycle with a derived index. It sits beside the index in use rather than always in the config directory: a run with `--db` or `TAGENTS_KNOWLEDGE_DB`, which is every test, then gets a store of its own without remembering a second flag, and cannot write into the real one. Rejected: always `~/.config/tagents/knowledge-usage.sqlite`, where a test that forgets `--usage-db` writes into the owner's history.

**One recording function, called by the surfaces.** `search`, `getDoc` and `getSection` stay pure queries, because `list`, `lint`, `toc` and the tests call them too and none of those is a read in the sense that counts. The two CLI handlers and the two MCP handlers call one function after a read succeeded, and a test per site proves each. Rejected: recording inside the query functions, which covers every site by construction but counts every internal lookup and hands a store handle to code that has none.

**Open, write in one transaction, close, on every call.** This is what `withDb` does for the index, for the same reason: the daemon lives for hours and is shared, and a handle kept between calls would pin a file the owner may move or delete and would keep the path of the first caller. WAL and a 250 ms busy timeout let a CLI process and the daemon write at once. Rejected: one handle per process, which is faster and has those faults.

**Best effort, all of it.** Every error is caught in the recording function. The CLI prints it only under `--verbose`; the MCP server stays silent, since stdout is the protocol and the daemon's stderr goes nowhere. A counter must not be able to break `show` while someone reads a runbook during an incident. Rejected: failing loudly, which turns a full disk into an outage of the knowledge base.

**A hit is one row per document, and only a `get` makes a candidate.** A hit says a document matched a query, not that anyone read it. It is recorded because it cannot be backfilled and costs one row, with an empty heading because the section that matched is not what was read.

**The caller is a name, never a query or a session id.** The repository is public and queries can hold secrets or customer words, and a session id ties an event to a conversation. For the MCP tools the name is the one the client gave in the handshake, so every Claude Code session reads as the same client; for the CLI it is `TA_LABEL`. Nothing in this change reads `caller` back. The column exists because a later change cannot add it to rows already written.

**UTC days.** The `updated` column of `list` and the `stale` and `generated` findings of `lint` already use UTC dates, and a day that depends on the machine's zone would move an event between days when the zone changes. The grouping is `date(ts / 1000, 'unixepoch')`, the same date `utcDateOf` ends with.

**The report joins in code.** One grouped query over the events gives the counts; `listDocs` gives the documents, with its own `--type` filter; the two are joined by id in a function shared by the verb and the tool. Rejected: `attach` of the index to the usage connection, which makes an unreadable store fail the index too, for a join that only the report needs.

**`TAGENTS_KNOWLEDGE_USAGE_DB` joins the key of the shared server.** The daemon resolves the store from its own environment on every call, so two sessions that differ in it must not share a daemon, or the first one's value would win for both. `canonicalEnv` makes a relative value absolute, as for the other paths. `TA_LABEL` is read by the CLI only and goes into the ignored list with that reason.

**New text is English only, and nothing parallel is written.** The header line and the messages exist in `en.ts` only, as the new messages of `okf-bundle-format` do; `createT` falls back to English for a key `ru.ts` lacks, and adding Russian text later touches no spec. The path rule follows `resolveDb` (`expandHome`, flag then variable then default), rows are read with `text` and `int` from `db.ts`, the clock is the `Clock` of `search.ts`, injected as for `listDocs`, and the new open calls `silenceSqliteWarning`.

## Risks / Trade-offs

- [The modified blocks drift from `okf-bundle-format`] → They repeat that change's text as it stands; `spec:check` does not compare them. The rebase checks them against that change before this one is archived.
- [Two modified requirements grow past 500 characters, and the main-spec check refuses that after archive] → "CLI verbs and flags" is already 582 characters in `okf-bundle-format`. Whichever change is archived first splits them into shorter requirements, as `LEARNING.md` (18.10.2026) says.
- [A write on every read adds latency] → One transaction per call, `synchronous=normal` (a counter may lose its last event in a power cut, but a read must not wait for the disk), and a 250 ms cap on a lock.
- [The store grows] → Retention caps it; at a thousand reads a day it stays at tens of megabytes.
- [A damaged store makes `usage` fail] → That is the point of failing there: reads are unaffected, and the owner sees the file named and can delete it, losing the history.
- [The store lists the ids and headings of private documents] → It never leaves the machine and nothing in this change sends it anywhere. The fixtures of this public repository use synthetic ids.

## Migration Plan

There is nothing to migrate. The first recorded read creates the file, an older program ignores it, and rolling back is deleting it. The first start after the upgrade gets a fresh daemon, because the build stamp in the socket name changes with the build.
