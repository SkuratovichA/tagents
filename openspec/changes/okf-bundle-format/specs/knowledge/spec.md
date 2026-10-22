## MODIFIED Requirements

### Requirement: Document file format
A knowledge document SHALL be one markdown file named `<id>.md` in the knowledge folder, opening with a `---` YAML frontmatter block, in the form of an OKF v0.2 concept: the block SHALL carry `type` and MAY carry `title`, `description`, `tags`, `resource`, `generated`, `verified`, `sources`, `status`, `stale_after` and `scope`, whose rules are in the field rules. The loader SHALL be tolerant: a key it does not know SHALL be kept and ignored, never an error, and a field that is missing or breaks its rule SHALL NOT refuse the file. A file SHALL be refused, with a message naming the file and the offending field, only when it has no frontmatter, when its frontmatter is not YAML, when it has neither `type` nor `kind`, when its `type` (or, in the legacy form, `kind`) is not a non-empty string, or when its filename stem is not a slug. The other files of the folder SHALL still load.

#### Scenario: A valid document is accepted
- **WHEN** a file `backup-runbook.md` has frontmatter with `type: Runbook`, a title, a description, tags `[backup, ops]` and a `generated` mapping
- **THEN** it is indexed and listed with those values and with the type `Runbook`

#### Scenario: A legacy document is accepted
- **WHEN** a file has `kind: runbook` and no `type`, together with `id`, `title`, `tags` and `updated: 2026-09-10`
- **THEN** it is indexed and listed as in the legacy form requirement

#### Scenario: Invalid frontmatter is refused
- **WHEN** a file has frontmatter with a title but neither `type` nor `kind`, or a `type` that is empty or not a string
- **THEN** the file is refused with a message naming `type`, and the other files still load

#### Scenario: Unknown keys are tolerated
- **WHEN** a file with a valid `type` also carries `owner: platform` and `x-note: 1`
- **THEN** it is accepted and its search results are unchanged

#### Scenario: A file without frontmatter is refused
- **WHEN** a file does not open with a `---` block
- **THEN** it is refused with the message that no YAML frontmatter was found

#### Scenario: Frontmatter that is not YAML is refused
- **WHEN** the block between the `---` lines does not parse as YAML
- **THEN** the file is refused with a message that the frontmatter is not YAML

### Requirement: Frontmatter field rules
`type` SHALL be a non-empty string of free text (for example `Runbook`, `Decision`, `Map`, `Note`), kept as written. `title`, when given, SHALL be a string, and when absent the title is the filename stem. `description`, when given, SHALL be a one-line string. `tags`, when given, SHALL be a list of strings, and when absent the document has no tags. `resource`, when given, SHALL be a string, kept and listed but not interpreted. `generated`, when given, SHALL be a mapping with a non-empty string `by` and an `at` that is a real ISO 8601 datetime with an explicit offset (`Z` or `+hh:mm`). `verified`, when given, SHALL be a mapping or a list of mappings with `by` and `at`, kept and not interpreted. `sources`, when given, SHALL be a list of mappings each with a string `resource` and optionally `id` and `title`; other keys of a source (such as `author`, `usage_count`, `last_modified`, `usage_window`) SHALL be kept and never validated. `status`, when given, SHALL be `draft`, `stable` or `deprecated`, and absent means `stable`. `stale_after`, when given, SHALL be an ISO 8601 datetime with an explicit offset. `scope`, when given, SHALL be `global` or `project`. A value that breaks its rule SHALL be treated by the loader as absent (`status` as `stable`) and reported by `lint`, never by a refusal.

#### Scenario: Optional keys
- **WHEN** a document sets `scope: project`, `resource: https://example.invalid/backup` and a `sources` list with one entry that has a `resource`
- **THEN** it is valid and the values are kept

#### Scenario: Bad scope
- **WHEN** `scope` is `everywhere`
- **THEN** the document loads without a scope and `lint` reports a `frontmatter` finding naming `scope`

#### Scenario: Bad status is read as stable
- **WHEN** `status` is `retired`
- **THEN** the document loads with the status `stable` and `lint` reports a `frontmatter` finding naming `status`

#### Scenario: A datetime without an offset is ignored
- **WHEN** `stale_after` is `2026-10-01T00:00:00`
- **THEN** the document loads and is never stale, and `lint` reports a `frontmatter` finding naming `stale_after`

### Requirement: Id equals filename stem
The id of a document SHALL be its filename without the `.md` extension, because every verb and tool addresses documents by id. A frontmatter `id` is optional; when present and different from the stem the loader SHALL use the stem and `lint` SHALL report a `stem` finding. A file whose stem is not a slug (lowercase words joined by single dashes) SHALL be refused by the loader and the index, and reported by `lint` as a `stem` finding.

#### Scenario: Mismatch is refused
- **WHEN** `other-name.md` declares `id: sample`
- **THEN** `lint` refuses it with a `stem` finding naming both, and the loader uses the id `other-name`

#### Scenario: A stem that is not a slug is refused
- **WHEN** a file is named `Not A Slug.md`
- **THEN** the loader refuses it with a message naming the stem, and `lint` reports a `stem` finding

### Requirement: Which files are documents
Only regular files in the top level of the knowledge folder whose name ends in `.md` and does not start with a dot SHALL be considered documents, in id order. The names `index.md` and `log.md` are reserved and SHALL never be documents. Subdirectories and dotfiles SHALL be ignored: the folder is a flat bundle.

#### Scenario: Hidden files and subfolders are skipped
- **WHEN** the folder holds `.draft.md` and a subdirectory containing `x.md`
- **THEN** neither appears in `index`, `list`, `search` or `lint`

#### Scenario: Reserved names are skipped
- **WHEN** the folder holds `index.md` and `log.md`
- **THEN** neither appears in `index`, `list`, `search` or in the count of documents checked by `lint`

### Requirement: Wikilinks
The forms `[[id]]` and `[[id#Heading]]` SHALL be recognised as links to a document, or to a section of one, and are checked by `lint`. A link inside a fenced code block (``` or ~~~) SHALL NOT be a link, in this form or in the markdown form.

#### Scenario: Both forms are read
- **WHEN** a body contains `[[other-doc]]` and `[[other-doc#Some Heading]]`
- **THEN** both links are recognised, the second with its heading

#### Scenario: Fenced code holds no links
- **WHEN** a fenced block contains `[[other-doc]]`
- **THEN** it is not a link and `lint` does not report it as dead

### Requirement: Locating the index
The search index SHALL be a single SQLite file chosen from the `--db` flag, then the `TAGENTS_KNOWLEDGE_DB` environment variable, then `knowledge.sqlite` in the tagents config directory. Unlike the documents folder, the index has a default. The file and its parent directories SHALL be created when missing. The index is derived data: when it was written by an incompatible schema version it SHALL be discarded and rebuilt from the documents, and deleting it SHALL lose nothing. The schema version of this format is 2, so an index written by the previous format SHALL be rebuilt on first use.

#### Scenario: Default location
- **WHEN** neither `--db` nor `TAGENTS_KNOWLEDGE_DB` is given and `TAGENTS_CONFIG_DIR` is `/cfg`
- **THEN** the index is `/cfg/knowledge.sqlite`

#### Scenario: Environment moves the index
- **WHEN** `TAGENTS_KNOWLEDGE_DB` names another file
- **THEN** that file is used, unless `--db` is also given, in which case `--db` wins

#### Scenario: An index of the previous format is rebuilt
- **WHEN** the index file was written with schema version 1 and `list` runs
- **THEN** the index is rebuilt from the documents and `list` answers with every document

### Requirement: Unreadable documents
A document that is refused SHALL be reported per file as `<filename>: <message>` on stderr, SHALL be removed from the index (it must not keep serving its last good text), and SHALL NOT stop the rest of the folder from being indexed. The `index` verb SHALL print the counts, report `N file(s) could not be read; run lint` and exit 1 when any file failed; read verbs (`search`, `show`, `list`) report the failing files on stderr and carry on with their own exit code.

#### Scenario: One bad file among good ones
- **WHEN** `slomannyj.md` has neither `type` nor `kind` and `search rollback` runs
- **THEN** stderr names `slomannyj.md: frontmatter…`, the hits from the good documents are printed and the exit code is 0
- **AND** `index` on the same folder exits 1

### Requirement: Search semantics
A search SHALL match sections of documents, returning for each hit the document `id`, `title`, section `heading` (empty for the preamble), `score`, `snippet`, absolute `path`, and the lifecycle fields `type`, `description`, `status` and `stale`. Every whitespace-separated word of the query SHALL appear in the same section, and a word ending in `*` SHALL match as a prefix. Words are split Unicode-aware with diacritics folded and punctuation as a separator, so Cyrillic is searchable and `agent state` finds `tmux-agent-state.sh`. There is no stemming.

#### Scenario: Russian and English corpora
- **WHEN** searching `бэкапы`
- **THEN** only the Russian section containing that word is returned, and searching `бэкапы embeddings` returns nothing

#### Scenario: No morphology
- **WHEN** a section holds `бэкапы` and the query is `бэкап`
- **THEN** it is not found, while `бэкап*` finds it

#### Scenario: Prefix form
- **WHEN** the query is `релиз*`
- **THEN** sections containing `релизы` are found

### Requirement: Ranking, score and snippet
Hits SHALL be ordered best first, with a match in a section's heading weighing ten times a match in its body, except that hits from documents whose status is `deprecated` SHALL come after all other hits, each group in the order described here. The score SHALL be a number rounded to three decimals where a bigger value is a better match, and equal scores SHALL be ordered by document id, then section order. The snippet SHALL be one line of about 14 tokens with the matched words wrapped in `[` and `]`. The default limit is 10 hits. No hit is hidden because of its status.

#### Scenario: Heading beats mention
- **WHEN** searching `rollback` in a corpus where one section is titled `Rollback` and another mentions it once
- **THEN** the titled section is first, the mention is still returned later, and the first score is greater than the second

#### Scenario: Snippet shape
- **WHEN** a hit is returned
- **THEN** its snippet contains no newline and marks the matched word as `[word]`

#### Scenario: Deprecated ranks last
- **WHEN** a deprecated document has a section titled `Failover` and an active document mentions `failover` once in a body, and `failover` is searched
- **THEN** the active document's hit comes first and the deprecated document's hit is still returned after it

### Requirement: Filters and limit
Search and list SHALL accept a `type` filter that keeps documents whose type equals the given value, compared case-insensitively, and a `tag` filter that keeps documents carrying that tag; given together they combine. `kind` SHALL remain accepted as a deprecated alias of `type` with the same meaning, so that `--kind runbook` finds the type `Runbook`; when both are given, `type` wins. Search SHALL accept a limit of hits.

#### Scenario: Kind and tag narrow results
- **WHEN** `search релиз* --kind note` runs, and `search rollback --tag tmux --limit 1` runs
- **THEN** the first returns only hits from documents of type `Note`, the second returns exactly one hit, from a document tagged `tmux`

#### Scenario: Type narrows results
- **WHEN** `search релиз* --type note` runs
- **THEN** it returns the same hits as `--kind note`

#### Scenario: The type comparison ignores case
- **WHEN** a document has `type: Runbook` and `list --type RUNBOOK` runs
- **THEN** that document is listed

#### Scenario: The kind alias
- **WHEN** `list --kind runbook` and `list --type runbook` run on the same folder
- **THEN** they print the same lines

#### Scenario: Unknown tag
- **WHEN** the tag matches no document
- **THEN** the result is empty

### Requirement: Listing documents
A list SHALL return every indexed document in id order, except that documents whose status is `deprecated` come after all others, with `id`, `title`, `type`, `description`, `tags`, `status`, `stale`, `updated`, absolute `path` and `headings` (the section headings in document order, without the preamble), optionally filtered by `type` (or its alias `kind`) and `tag`. `updated` SHALL be the UTC date part of `generated.at`, or `-` when the document has no `generated`. `description` SHALL be the empty string when the document has none. `stale` SHALL be a boolean computed when the list is made: true when `stale_after` is given and the current time is at or after it.

#### Scenario: Headings
- **WHEN** a document has a preamble and sections `Диски` and `Сервисы`
- **THEN** its `headings` are `["Диски", "Сервисы"]`

#### Scenario: Stale is computed at query time
- **WHEN** a document has `stale_after: 2026-10-01T00:00:00Z` and the list is made before and after that instant
- **THEN** `stale` is false the first time and true the second

#### Scenario: No generated
- **WHEN** a document has no `generated`
- **THEN** its `updated` is `-`

### Requirement: CLI verbs and flags
The `tagents-knowledge` program SHALL provide the verbs `index [--dir D] [--db F] [--full]`, `search <query…> [--dir] [--db] [--tag T] [--type T] [--kind K] [--limit N] [--json]`, `show <id[#heading]> [--dir] [--db]`, `list [--dir] [--db] [--type T] [--kind K] [--tag T] [--json]`, `lint [--dir D]`, `toc [--dir D] [--check]`, `mcp` and `serve [--idle S] [--foreground] [--socket P]`. `--kind` is a deprecated alias of `--type`. `help`, `--help` and `-h` SHALL print the usage text on stdout. An invalid `--limit` (not a positive number) SHALL be ignored in favour of the default.

#### Scenario: Verbs match the generated contract
- **WHEN** the CLI contract is generated
- **THEN** it lists exactly `index`, `search`, `show`, `list`, `lint`, `toc`, `mcp`, `serve`, in English, with exit codes 0, 1, 2 and 4

### Requirement: CLI exit codes
The CLI SHALL exit with 0 for success, 1 for an error (no or missing documents folder, a folder that could not be indexed clean, lint findings, an `index.md` that `toc --check` finds out of date), 2 for a usage error, and 4 when nothing was found.

#### Scenario: Usage errors
- **WHEN** `search` or `show` runs without an argument, or a verb receives an unknown flag, or the verb is unknown, or no verb is given
- **THEN** the exit code is 2; for an unknown verb the usage text goes to stderr, with no verb it goes to stdout

#### Scenario: Nothing found
- **WHEN** a search has no hits, or `show` names an unknown id or heading, or `list` finds no documents
- **THEN** the exit code is 4 and a sentence on stderr says what was missing

### Requirement: Search output
Without `--json`, `search` SHALL print one line per hit: the address (`id#heading`, or just `id` for the preamble) padded to 38 characters, the score with two decimals, then the snippet, then the suffixes of the lifecycle requirement. With `--json` it SHALL print a JSON array of objects with exactly the keys `id`, `title`, `heading`, `score`, `snippet`, `path`, `type`, `description`, `status`, `stale`; with no hits it prints `[]` and still exits 4.

#### Scenario: First line
- **WHEN** `search rollback` runs on the fixture corpus
- **THEN** the first line matches `deploy-runbook#Rollback`, a decimal score and a snippet

#### Scenario: JSON keys
- **WHEN** `search backup --json` runs
- **THEN** each object has exactly the ten keys and no `kind`

### Requirement: List output
Without `--json`, `list` SHALL print one line per document: id padded to 28, type padded to 10, `updated`, title, then two spaces and the tags written `#tag` and separated by single spaces when the document has tags, then the suffixes of the lifecycle requirement. With `--json` it SHALL print the JSON array of document summaries, without a `kind` key; an empty result prints `[]` and exits 4.

#### Scenario: Text line
- **WHEN** `list --type runbook` runs on a folder that holds the legacy runbook `deploy-runbook`
- **THEN** the single line reads like `deploy-runbook  Runbook  2026-09-10  Deploying the demo service  #deploy #ci`

#### Scenario: Deprecated line
- **WHEN** a deprecated document is listed
- **THEN** its line ends with ` [deprecated]`

### Requirement: Lint
`lint` SHALL check the claims each document makes about itself, without using the index, and report each finding as `<filename>: <message>` on stdout. The finding kinds are `frontmatter`, `stem`, `duplicate-id`, `legacy`, `expired`, `stale`, `generated`, `dead-link` and `index`. A file that is refused by the loader SHALL be one finding, not the end of the report. With no findings `lint` SHALL print `N document(s) in DIR: no problems` and exit 0; otherwise it prints `N problem(s) in DIR` after the findings and exits 1. The number of documents checked SHALL NOT count `index.md` or `log.md`. A `duplicate-id` finding SHALL mean that two files declare the same frontmatter `id`.

#### Scenario: Clean corpus
- **WHEN** `lint --dir` points at a folder of valid documents in the OKF form with a current `index.md` and no broken links
- **THEN** the output says `N document(s)… no problems` and the exit code is 0

#### Scenario: Broken file is one finding
- **WHEN** a file has no frontmatter at all
- **THEN** it yields one `frontmatter` finding, it still counts in the number of documents checked, and the other files are still checked

#### Scenario: Duplicate declared id
- **WHEN** two files declare the same `id`
- **THEN** a `duplicate-id` finding is reported for the second file, together with a `stem` finding for the file whose name differs

### Requirement: Lint freshness checks
A `stale` finding SHALL mean that the UTC date of `generated.at` is earlier than the date of the newest git commit touching the file, and is checked only inside a git work tree, only for committed files and only for documents that have `generated`.

#### Scenario: Stale update date
- **WHEN** a committed document says `generated.at: 2020-01-01T00:00:00Z` and its newest commit is later
- **THEN** exactly that document gets a `stale` finding

#### Scenario: Outside git
- **WHEN** the folder is not a git work tree
- **THEN** no `stale` findings are produced

#### Scenario: No generated
- **WHEN** a committed document has no `generated`
- **THEN** it gets no `stale` finding

### Requirement: Lint generated documents
A `generated` finding SHALL mean that a `sources[].resource` that is a relative or bundle-relative path (resolved against the folder, `~` expanded) resolving to an existing file was modified on a UTC date later than the UTC date of `generated.at`. A resource that is a URL, or any other value that is not a path, SHALL be skipped, and so SHALL a path that does not exist on this machine.

#### Scenario: Generated source moved on
- **WHEN** a source resource names a file modified on 2026-09-20 and the document says `generated.at: 2026-09-11T00:00:00Z`
- **THEN** a `generated` finding mentioning 2026-09-20 is reported, and it disappears once `generated.at` is on 2026-09-20 or later

#### Scenario: Missing source is not a finding
- **WHEN** the file named by a source resource does not exist
- **THEN** no `generated` finding is reported

#### Scenario: A URL is skipped
- **WHEN** a source resource is `https://example.invalid/page`
- **THEN** no `generated` finding is reported

### Requirement: Lint dead links
A `dead-link` finding SHALL mean that a link to a document of the folder, in the wikilink form or the markdown form, targets a missing document, or a heading or fragment the target does not have. The message SHALL be `dead link <the link as written>`. For a wikilink a heading matches when it is equal to a section heading case-insensitively; for a markdown link see the fragment rule.

#### Scenario: Dead links
- **WHEN** a document links `[[sqlite-over-vectors]]` after that file was deleted, or `[[deploy-runbook#Нет раздела]]` for a missing heading
- **THEN** each is reported as `dead link [[…]]`

#### Scenario: A dead markdown link
- **WHEN** a document links `[the plan](/no-such-doc.md)`
- **THEN** `lint` reports `dead link [the plan](/no-such-doc.md)`

### Requirement: MCP server
`tagents-knowledge mcp` SHALL serve the MCP protocol over stdio only, as server `tagents-knowledge`, and exit when the client closes the pipe. It SHALL expose exactly five tools: `knowledge_search`, `knowledge_get`, `knowledge_list`, `sessions_recent`, `sessions_search`. It SHALL offer no tool that writes, edits, deletes or generates a document or an `index.md`. Tool output is English text, and the server SHALL write nothing to stdout besides the protocol.

#### Scenario: Tool inventory
- **WHEN** a client lists the tools
- **THEN** it sees exactly those five names

### Requirement: Tool knowledge_search
`knowledge_search` SHALL take `query` (required, non-empty string), `tag`, `type` and `kind` (optional strings, `kind` being a deprecated alias of `type`) and `limit` (optional integer from 1 to 50, default 10), with the same matching, filtering and ranking as the CLI. It SHALL return the hits as pretty-printed JSON text, an array of objects with `id`, `title`, `heading`, `score`, `snippet`, `path`, `type`, `description`, `status`, `stale`; when nothing matches it returns the plain text `nothing matches "<query>"`, which is not an error.

#### Scenario: Ranked hits
- **WHEN** a client searches `rollback`
- **THEN** the first hit has id `deploy-runbook`, heading `Rollback` and a numeric score

#### Scenario: Schema
- **WHEN** the tool list is read
- **THEN** the input properties are `kind`, `limit`, `query`, `tag`, `type` and only `query` is required

#### Scenario: The kind alias
- **WHEN** a client searches with `kind: runbook` and then with `type: Runbook`
- **THEN** the two answers hold the same hits

### Requirement: Tool knowledge_list
`knowledge_list` SHALL take optional `type`, `kind` (a deprecated alias of `type`) and `tag` strings and return the matching documents as pretty-printed JSON, an array of objects with `id`, `title`, `type`, `description`, `tags`, `status`, `stale`, `updated`, `path`, `headings`; an empty match is the JSON `[]`, not an error.

#### Scenario: Filter by kind
- **WHEN** called with `kind: runbook`
- **THEN** the array holds only the runbook documents, and none of the objects has a `kind` key

#### Scenario: Filter by type
- **WHEN** called with `type: Runbook`
- **THEN** the array is the same as for `kind: runbook`

## ADDED Requirements

### Requirement: Legacy document form
A document with a `kind` key and no `type` key SHALL be read as a legacy document, whose keys are `id`, `title`, `kind`, `tags`, `updated`, and optionally `generated_from` and `scope`. A legacy document SHALL be loaded, searchable and listable, and `lint` SHALL report it as `legacy`. The package SHALL NOT write the legacy form, and a folder in the legacy form SHALL load without being migrated first.

#### Scenario: Legacy mapping
- **WHEN** a document has `kind: runbook` and `updated: 2026-09-10` and no `type`
- **THEN** `list` shows the type `Runbook` and the updated date `2026-09-10`

#### Scenario: Filters still find it
- **WHEN** `list --type runbook` runs on a folder that holds that legacy document
- **THEN** the document is listed

### Requirement: Legacy field mapping
A legacy document SHALL be read as if it had the type equal to its `kind` with the first letter uppercased (`runbook` becomes `Runbook`), the generation time `updated` at 00:00:00Z, one source whose `resource` is `generated_from` when that key is given, and the status `stable`.

#### Scenario: Mapped fields
- **WHEN** a legacy document has `kind: runbook`, `updated: 2026-09-10` and `generated_from: ../hosts.yaml`
- **THEN** it is read with type `Runbook`, generation time `2026-09-10T00:00:00Z`, one source `../hosts.yaml` and status `stable`

### Requirement: Lifecycle in search and list
In text output, a hit or a list line of a document whose status is `deprecated` SHALL end with ` [deprecated]`, and one of a stale document SHALL end with ` [stale]`; when both apply the suffixes appear in that order. In JSON output the corresponding objects SHALL carry `status` (`stable`, `draft` or `deprecated`) and `stale`. A status of `draft` has no suffix and no effect on ranking.

#### Scenario: Suffixes
- **WHEN** a deprecated document and a stale document are listed
- **THEN** the first line ends with ` [deprecated]` and the second with ` [stale]`

### Requirement: Lint frontmatter profile
`lint` SHALL hold the frontmatter to this package's profile and report each violation as a `frontmatter` finding whose message names the key. The violations are: a tag that is not a slug; a `status` outside `draft`, `stable`, `deprecated`; a malformed `generated` or `verified`; a `stale_after` that is not a real datetime with an explicit offset; a `sources` entry without a string `resource`; and an unknown top-level key, reported as `unknown key "<key>"`.

#### Scenario: Unknown key
- **WHEN** a document carries `owner: platform`
- **THEN** `lint` reports a `frontmatter` finding that contains `unknown key "owner"`

#### Scenario: Bad values
- **WHEN** a document has `tags: [Not A Slug]`, `status: retired` and `sources: [{title: x}]`
- **THEN** `lint` reports one `frontmatter` finding for each, naming `tags`, `status` and `sources`

### Requirement: Lint known keys and stems
The known top-level keys are `type`, `title`, `description`, `tags`, `resource`, `generated`, `verified`, `sources`, `status`, `stale_after`, `scope` and `id`, and for a legacy document also `kind`, `updated` and `generated_from`. Other OKF keys are tolerated by the loader and are still reported by `lint` as unknown. A `stem` finding SHALL be reported for a declared `id` that differs from the stem and for a stem that is not a slug.

#### Scenario: A stem finding
- **WHEN** a file named `Not A Slug.md` is linted
- **THEN** a `stem` finding is reported for it

### Requirement: Lint legacy documents
`lint` SHALL report a document in the legacy form as a `legacy` finding whose message says that it is legacy and must be rewritten in the OKF form.

#### Scenario: Legacy is reported
- **WHEN** a folder holds the legacy fixture documents
- **THEN** every one of them gets exactly one `legacy` finding and `lint` exits 1

### Requirement: Lint expired documents
`lint` SHALL report an `expired` finding for a document whose `stale_after` is given and has passed, that is, the current time is at or after it. The message SHALL contain the `stale_after` value as written.

#### Scenario: Expired
- **WHEN** a document has `stale_after: 2020-01-01T00:00:00Z`
- **THEN** it gets an `expired` finding, and a document with `stale_after` in the far future does not

### Requirement: Markdown links to documents
A standard markdown link whose target is a document of the folder SHALL be recognised as a link to that document, in the forms `[text](/id.md)`, `[text](/id.md#fragment)`, `[text](./id.md)` and `[text](id.md#fragment)`, and is checked by `lint`. A link whose target has a URL scheme (such as `https:` or `mailto:`), or whose path does not end in `.md`, or that has no path (a bare `#fragment`), SHALL NOT be a document link and SHALL be ignored.

#### Scenario: Four forms
- **WHEN** a body contains `[a](/cache-policy.md)`, `[b](/cache-policy.md#decision)`, `[c](./cache-policy.md)` and `[d](cache-policy.md#decision)`
- **THEN** all four are recognised as links to `cache-policy`, two of them with the fragment `decision`

#### Scenario: Other links are ignored
- **WHEN** a body contains `[x](https://example.invalid/a.md)`, `[y](mailto:a@example.invalid)`, `[z](notes.txt)` and `[w](#local)`
- **THEN** none of them is a document link

### Requirement: Link fragments
A fragment of a markdown link SHALL match a section of the target when, after URL-decoding, it equals the section heading case-insensitively, or equals the heading's slug: the heading in lowercase with spaces turned into dashes and every character that is not a letter, a digit or a dash dropped. A link without a fragment needs only the target document.

#### Scenario: Heading and slug
- **WHEN** the target has a section `Failover steps` and links use `#Failover%20steps`, `#failover steps` and `#failover-steps`
- **THEN** all three match, and `#failover-step` does not

### Requirement: Lifecycle status and staleness
`status` SHALL be `stable` when absent, and a `deprecated` document SHALL stay loaded, searchable and listable. A document SHALL be stale when `stale_after` is given and the current time is at or after it; staleness SHALL be computed when a query is answered and SHALL never be stored in the index. The index SHALL store the document's `type`, `description`, `status`, `stale_after` and generation time.

#### Scenario: Deprecated stays visible
- **WHEN** a document has `status: deprecated`
- **THEN** `list` still shows it, after the other documents, with the suffix ` [deprecated]`

#### Scenario: Stale flips with the clock
- **WHEN** a document has `stale_after: 2026-10-01T00:00:00+02:00`
- **THEN** it is not stale at 2026-09-30T21:59:59Z and is stale at 2026-09-30T22:00:00Z

### Requirement: Lint index file
`lint` SHALL report an `index` finding, attributed to `index.md`, when `index.md` is absent from the folder or its content differs from what `toc` would write.

#### Scenario: Missing
- **WHEN** the folder has no `index.md`
- **THEN** `lint` reports an `index` finding saying that `index.md` is missing

#### Scenario: Out of date
- **WHEN** a document was added after `index.md` was written
- **THEN** `lint` reports an `index` finding saying that `index.md` is out of date, and it disappears after `toc` runs

### Requirement: The index.md file
`index.md` at the folder root is the OKF progressive disclosure file. Its frontmatter SHALL be exactly the key `okf_version` with the value `"0.2"`. Its body SHALL group the documents by `type` under the heading `# <Type>`, groups ordered alphabetically by the lowercased type, and types that differ only in case SHALL share the group headed with the spelling of the first of them in id order. The output SHALL be deterministic.

#### Scenario: Grouping
- **WHEN** documents of the types `Runbook` and `runbook` and `Note` are listed
- **THEN** there are two groups, `Note` first, then one headed with the spelling of the first of the two runbook documents in id order

### Requirement: The index.md entries
Within a group the documents SHALL be ordered by id, one line each: `* [<title>](<stem>.md) - <description>`, with ` - <description>` omitted when the document has none and ` (deprecated)` appended for a deprecated document.

#### Scenario: Entry forms
- **WHEN** a document has a description and another has none and is deprecated
- **THEN** the first line ends with ` - ` and the description, and the second ends with ` (deprecated)` and has no ` - `

### Requirement: The index.md layout
The file SHALL be the frontmatter block, a blank line, then each group as its heading, a blank line and its lines, with groups separated by one blank line, and it SHALL end with exactly one newline.

#### Scenario: Layout
- **WHEN** the folder holds `backup-runbook` (type Runbook, title "Nightly backup run", description "How the nightly backup runs") and a deprecated `old-queue-notes` (type Note, no description, title "Retired queue")
- **THEN** `index.md` is `---`, `okf_version: "0.2"`, `---`, a blank line, `# Note`, a blank line, `* [Retired queue](old-queue-notes.md) (deprecated)`, a blank line, `# Runbook`, a blank line, `* [Nightly backup run](backup-runbook.md) - How the nightly backup runs`, and one final newline

### Requirement: The toc verb
`toc [--dir D] [--check]` SHALL write `index.md` into the folder, creating or replacing it, print `wrote <path>` on stdout and exit 0. With `--check` it SHALL write nothing: it exits 0 when the file is current, and exits 1 with the single line `index.md is out of date` on stderr when the file differs or is absent. The folder is chosen as for the other verbs, and a folder that cannot be found is an error with exit 1. There SHALL be no MCP tool for it.

#### Scenario: Write
- **WHEN** `toc` runs on a folder without `index.md`
- **THEN** it prints `wrote` followed by the path of `index.md`, exits 0, and the file holds the layout of the index.md requirement

#### Scenario: Check
- **WHEN** `toc --check` runs after `toc`, and again after a document is added
- **THEN** the first exits 0 and writes nothing, the second exits 1 with `index.md is out of date` and still writes nothing
