## 1. Loader and format

- [x] 1.1 Read the OKF form and the legacy form into one document shape, skip reserved filenames, take the id from the filename stem and refuse a non-slug stem. Proved by `packages/knowledge/test/doc.test.ts` (OKF accepted, legacy mapped, neither `type` nor `kind` refused while the others load, unknown keys tolerated, `index.md` and `log.md` skipped, non-slug stem refused).
- [x] 1.2 Extract document links of both forms with their fragment, ignoring fenced code. Proved by `packages/knowledge/test/doc.test.ts` (wikilinks, markdown links, schemes and non-`.md` targets ignored, fenced code ignored).
- [x] 1.3 Compute `status`, `stale` and the date part of `generated.at` with an injected clock. Proved by `packages/knowledge/test/doc.test.ts` and `packages/knowledge/test/search.test.ts` (a `FakeClock` moves a document from fresh to stale).

## 2. Index, search and list

- [x] 2.1 Index schema version 2 with `type`, `description`, `status`, `stale_after` and `generated_at`; an index of version 1 is rebuilt. Proved by `packages/knowledge/test/index.test.ts` (an old-version index file is opened, rebuilt and answers).
- [x] 2.2 Case-insensitive `type` filter with the `kind` alias, deprecated documents ranked last and not hidden, and `type`, `description`, `status`, `stale` in results. Proved by `packages/knowledge/test/search.test.ts`.

## 3. CLI and MCP surface

- [x] 3.1 `--type` and the `--kind` alias on `search` and `list`, the new list line with `[deprecated]` and `[stale]`, and the JSON fields. Proved by `packages/knowledge/test/cli.test.ts` and `packages/knowledge/test/cli-spec.test.ts`.
- [x] 3.2 `type` with a `kind` alias on `knowledge_search` and `knowledge_list`, and the new JSON fields. Proved by `packages/knowledge/test/mcp.test.ts` and `packages/knowledge/test/shared-server.test.ts`.
- [x] 3.3 Regenerate `contract.json` and `skills/tagents/references` with `pnpm plugin:gen`. Proved by `packages/contract/test` and a clean `git status` after the command.

## 4. Lint and the toc verb

- [x] 4.1 Strict `frontmatter` findings (tags, `status`, `generated`, `verified`, `stale_after`, `sources`, unknown keys), `stem` for a non-slug stem, and the `legacy` finding. Proved by `packages/knowledge/test/lint.test.ts`.
- [x] 4.2 `stale` and `generated` findings computed from `generated.at` and `sources`, the `expired` finding, and `dead-link` for markdown links and fragments. Proved by `packages/knowledge/test/lint.test.ts`.
- [x] 4.3 The `index` finding and the `toc` verb with `--check`, writing the exact layout. Proved by `packages/knowledge/test/toc.test.ts` and `packages/knowledge/test/lint.test.ts`.
- [x] 4.4 Document the OKF form in the package README. Proved by `packages/knowledge/test/cli-spec.test.ts` (usage text and README agree on the verbs and flags).

## 5. Gates

- [x] 5.1 `pnpm --filter @tagents/knowledge typecheck`, `pnpm --filter @tagents/knowledge test` and `pnpm spec:check` exit 0; `packages/knowledge/test/lint-no-any.test.ts` stays green.
