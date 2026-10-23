## 1. The usage store

- [x] 1.1 Resolve the store's file: `--usage-db`, then `TAGENTS_KNOWLEDGE_USAGE_DB`, then `knowledge-usage.sqlite` beside the index in use, with `~` expanded. Proved by `packages/knowledge/test/config.test.ts` (the three sources and their order, `~`, and an index chosen by `--db` or `TAGENTS_KNOWLEDGE_DB` moving the default beside it).
- [x] 1.2 Open the store (created with its directory when absent, WAL, `synchronous=normal`, a 250 ms busy timeout, the table and its indexes created if missing), write the events of one call in one transaction, and delete events older than 365 days on each write. Proved by `packages/knowledge/test/usage.test.ts` (an event reads back with every column; an event 366 days old goes and one 364 days old stays; two connections writing at once both land).
- [x] 1.3 Keep the store out of the index's lifecycle. Proved by `packages/knowledge/test/usage.test.ts` and `packages/knowledge/test/index.test.ts` (events survive `index --full`, the deletion of the index file, and an index of another schema version being rebuilt).
- [x] 1.4 Make recording best effort: one function catches every error, hands it to a callback and returns. Proved by `packages/knowledge/test/usage.test.ts` (a path that cannot be opened, a store held locked by another connection for longer than the busy timeout, and a file that is not a database: none throws, and the lock case returns).

## 2. Recording

- [x] 2.1 `show` records one `get` with the heading as the document writes it, and nothing for an unknown id or heading. Proved by `packages/knowledge/test/cli.test.ts`.
- [x] 2.2 `search` records one `hit` per distinct document with an empty heading, nothing without a result, and never the query text. Proved by `packages/knowledge/test/cli.test.ts` (a query word is absent from every column of the store).
- [x] 2.3 `--usage-db` and `--verbose` on `search` and `show`; a failing store leaves stdout and the exit code as they were, silent without `--verbose` and naming the store with it. Proved by `packages/knowledge/test/cli.test.ts` and `packages/knowledge/test/cli-spec.test.ts`.
- [x] 2.4 `knowledge_get` and `knowledge_search` record the same events through the MCP server, with the client name of the handshake as the caller; `knowledge_list` and the sessions tools record nothing. Proved by `packages/knowledge/test/mcp.test.ts`.
- [x] 2.5 `index`, `list`, `lint`, `toc` and `usage` record nothing. Proved by `packages/knowledge/test/cli.test.ts` (the store file does not exist after them).
- [x] 2.6 The caller of a CLI event is `TA_LABEL` when it is set and not empty, and `TA_LABEL` is on the ignored list of the key scan with its reason. Proved by `packages/knowledge/test/cli.test.ts` and `packages/knowledge/test/socket.test.ts`.
- [x] 2.7 Search order does not depend on usage. Proved by `packages/knowledge/test/cli.test.ts` (two equally matching documents, the one that sorts second read many times: the same order through `search --json` as with an empty store) and by `packages/knowledge/test/mcp.test.ts` (the order of a `knowledge_search` after many more reads).

## 3. The report

- [x] 3.1 Build the rows: counts in the window, distinct UTC dates with a `get`, the newest `get` of any age, unread documents with zeros, ids gone from the folder only with `--all`, `--type`, the sort and `--top`, all with an injected clock. Proved by `packages/knowledge/test/usage.test.ts` (in-memory stores; the edge of the window, three gets on one date and one on the next, an old get only, a removed document with and without `--all`).
- [x] 3.2 `--candidates` with `--min-gets` and `--min-days`. Proved by `packages/knowledge/test/usage.test.ts` (5 gets on 3 dates is in; 5 on 2 and 4 on 3 are out; a deprecated document and hits alone are out; own thresholds).
- [x] 3.3 The `usage` verb: its command spec, its English summary and its line in the hand-written usage text, flag checks that exit 2 naming the flag, the text table with its header and `-` for unknown values, `--json` with exactly seven keys, exit 4 with nothing left, a missing store that counts as empty and is not created, and a damaged store that exits 1 naming the file. Proved by `packages/knowledge/test/cli.test.ts` and `packages/knowledge/test/cli-spec.test.ts`.
- [x] 3.4 The `knowledge_usage` tool, built on the same rows as the verb. Proved by `packages/knowledge/test/mcp.test.ts` (its rows equal `usage --json` on the same store, the input schema, a bad `since` as a tool error, no row as `[]`).

## 4. The shared server

- [x] 4.1 `TAGENTS_KNOWLEDGE_USAGE_DB` in the key and among the variables made absolute. Proved by `packages/knowledge/test/socket.test.ts` (the key changes with it; a relative value becomes absolute) and `packages/knowledge/test/shared-server.test.ts` (two usage stores get two daemons and each records into its own file; a daemon lists six tools).

## 5. Documentation and contract

- [x] 5.1 Document the usage store and the verb in the package README (the "Where things live" table, the CLI table, the MCP table, the key variables of the shared server), replace "There are no write tools" with the statement that no tool writes a document, and amend the header comment of the MCP server the same way. Proved by `packages/knowledge/test/cli-spec.test.ts` (the README row of every verb names its flags; the usage text and the specs agree).
- [ ] 5.2 Regenerate `contract.json` and `skills/tagents/references` with `pnpm plugin:gen`. Proved by `packages/contract/test` and a clean `git status` after the command.

## 6. Gates

- [ ] 6.1 `pnpm --filter @tagents/knowledge typecheck`, `pnpm --filter @tagents/knowledge test`, `pnpm spec:check` and `pnpm plugin:gen` exit 0 with nothing uncommitted afterwards, and `packages/knowledge/test/lint-no-any.test.ts` stays green.

## Workflow follow-up

- Write each test before the code it proves and watch it fail first.
- This change stacks on `okf-bundle-format`. PR #12 is merged, so the base of the pull request is `main`, but that change is not archived yet. Before this one is archived, diff the modified blocks of its delta against that change's and re-copy what moved.
- Archive this change after `okf-bundle-format`, splitting the requirements that the main-spec check refuses for length.
