## Why

The knowledge package reads a document format of its own that only resembles OKF. A decommissioned system can be described only in a prose banner that search cannot see, and the `updated:` date of such a document keeps claiming it is current. OKF v0.2 has the fields that fix this (`type`, `generated`, `status`, `stale_after`, `sources`) and standard markdown links, and adopting it makes the documents folder a valid OKF bundle that other OKF tools can read.

## What Changes

- **BREAKING (output):** `kind` is replaced by `type` in `list` text and JSON, in search JSON and in the MCP `knowledge_list` and `knowledge_search` answers. `--kind` and the MCP `kind` argument stay accepted for this release as an alias of `type`, with the same case-insensitive meaning.
- The loader becomes tolerant, as OKF requires of a consumer: unknown frontmatter keys, a missing `title`, `tags` or dates, and broken links no longer refuse a file. A file is refused only when it has no frontmatter, its frontmatter is not YAML, it has neither `type` nor `kind`, or its filename stem is not a slug. Strictness moves to `lint`.
- The id of a document is its filename stem. A frontmatter `id` is optional; a mismatch is a `lint` finding and the loader uses the stem. `index.md` and `log.md` are reserved names and are never documents.
- The legacy form (`kind`, `updated`, `generated_from`) is still read, mapped to the OKF fields, and reported by `lint` as `legacy`, so a folder in the old form keeps working without migration.
- New lifecycle fields: `status` (`draft`, `stable`, `deprecated`) and `stale_after`. Search and list results carry `status` and `stale`; deprecated documents rank after all others and are marked `[deprecated]` in text, stale ones `[stale]`. Nothing is hidden.
- Standard markdown links to a document of the folder (`[text](/id.md#fragment)`) are read next to `[[id#Heading]]`, both ignoring fenced code, and are checked by `lint`.
- The SQLite index schema version becomes 2; an index of the previous version is dropped and rebuilt.
- `lint` holds the folder to this package's profile: new finding kinds `legacy`, `expired` and `index`, stricter `frontmatter`, and `stale` and `generated` computed from `generated.at` and `sources`.
- New verb `toc [--dir D] [--check]` writes the folder's `index.md` (OKF progressive disclosure) or, with `--check`, reports whether it is current.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `knowledge`: the document format, loader rules, links, filters, list and search output, lint, the MCP tools and the CLI verbs.

## Impact

- `packages/knowledge`: the loader, the index schema, search, the CLI, the MCP server, the messages in both locales and the tests. The generated `contract.json` and `skills/tagents/references` change with the CLI options.
- A knowledge folder in the legacy form keeps loading unchanged, so the installed copy of the package and the folder it reads need no coordinated migration. Moving a folder to the OKF form is done outside this package.
- Out of scope: attested computation, trust tiers derived from `verified`, `log.md` generation, subdirectory bundles, and a migration command.
