# knowledge Specification

## Purpose
The owner's operational knowledge kept as small markdown documents and made searchable through a full-text index, from a terminal (`tagents-knowledge`) and from any MCP client, either one server process per client or one server shared by every client of the same environment. Documents are only ever read by this capability; writes go through git.

## Requirements

### Requirement: Document file format
A knowledge document SHALL be one markdown file named `<id>.md` in the knowledge folder, opening with a `---` YAML frontmatter block, in the form of an OKF v0.2 concept: the block SHALL carry `type` and MAY carry `title`, `description`, `tags`, `resource`, `generated`, `verified`, `sources`, `status`, `stale_after` and `scope`, whose rules are in the field rules.

#### Scenario: A valid document is accepted
- **WHEN** a file `backup-runbook.md` has frontmatter with `type: Runbook`, a title, a description, tags `[backup, ops]` and a `generated` mapping
- **THEN** it is indexed and listed with those values and with the type `Runbook`

#### Scenario: A legacy document is accepted
- **WHEN** a file has `kind: runbook` and no `type`, together with `id`, `title`, `tags` and `updated: 2026-09-10`
- **THEN** it is indexed and listed as in the legacy form requirement

### Requirement: Tolerant loading
The loader SHALL be tolerant: a key it does not know SHALL be kept and ignored, never an error, and a field that is missing or breaks its rule SHALL NOT refuse the file. A value that breaks its field's rule SHALL be treated by the loader as absent (`status` as `stable`) and reported by `lint`, never by a refusal.

#### Scenario: Unknown keys are tolerated
- **WHEN** a file with a valid `type` also carries `owner: platform` and `x-note: 1`
- **THEN** it is accepted and its search results are unchanged

### Requirement: Refused files
A file SHALL be refused, with a message naming the file and the offending field, only when it has no frontmatter, when its frontmatter is not YAML, when it has neither `type` nor `kind`, when its `type` (or, in the legacy form, `kind`) is not a non-empty string, or when its filename stem is not a slug. The other files of the folder SHALL still load.

#### Scenario: Invalid frontmatter is refused
- **WHEN** a file has frontmatter with a title but neither `type` nor `kind`, or a `type` that is empty or not a string
- **THEN** the file is refused with a message naming `type`, and the other files still load

#### Scenario: A file without frontmatter is refused
- **WHEN** a file does not open with a `---` block
- **THEN** it is refused with the message that no YAML frontmatter was found

#### Scenario: Frontmatter that is not YAML is refused
- **WHEN** the block between the `---` lines does not parse as YAML
- **THEN** the file is refused with a message that the frontmatter is not YAML

### Requirement: Frontmatter field rules
`type` SHALL be a non-empty string of free text (for example `Runbook`, `Decision`, `Map`, `Note`), kept as written. `title`, when given, SHALL be a string, and when absent the title is the filename stem. `description`, when given, SHALL be a one-line string. `tags`, when given, SHALL be a list of strings, and when absent the document has no tags. `resource`, when given, SHALL be a string, kept and listed but not interpreted.

#### Scenario: Defaults of absent fields
- **WHEN** a document has `type: Note` and neither `title` nor `tags`
- **THEN** its title is its filename stem and it has no tags

### Requirement: Provenance field rules
`generated`, when given, SHALL be a mapping with a non-empty string `by` and an `at` that is a real ISO 8601 datetime with an explicit offset (`Z` or `+hh:mm`). `verified`, when given, SHALL be a mapping or a list of mappings with `by` and `at`, kept and not interpreted.

#### Scenario: Generated and verified
- **WHEN** a document has `generated` with `by: tool` and `at: 2026-10-01T23:30:00-02:00`, and `verified` as a list of two mappings with `by` and `at`
- **THEN** it is valid, `lint` reports nothing about it, and its `updated` is `2026-10-02`

#### Scenario: A generated time without an offset
- **WHEN** `generated.at` is `2026-10-01T09:30:00`
- **THEN** the document loads as if it had no `generated`, so its `updated` is `-`, and `lint` reports a `frontmatter` finding naming `generated`

### Requirement: Sources field rules
`sources`, when given, SHALL be a list of mappings each with a string `resource` and optionally `id` and `title`; other keys of a source (such as `author`, `usage_count`, `last_modified`, `usage_window`) SHALL be kept and never validated.

#### Scenario: Optional keys
- **WHEN** a document sets `scope: project`, `resource: https://example.invalid/backup` and a `sources` list with one entry that has a `resource`
- **THEN** it is valid and the values are kept

### Requirement: Lifecycle field rules
`status`, when given, SHALL be `draft`, `stable` or `deprecated`, and absent means `stable`. `stale_after`, when given, SHALL be an ISO 8601 datetime with an explicit offset. `scope`, when given, SHALL be `global` or `project`.

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

### Requirement: Sections
The body of a document SHALL be split into sections at lines beginning with `## `. Text before the first such heading is the preamble section, whose heading is the empty string; a document that opens directly with a `## ` heading has no preamble section. Deeper headings (`###` and below) SHALL stay inside their section, and a `## ` line inside a fenced code block (``` or ~~~) SHALL NOT start a section. A search hit or a section read is addressed as `id#heading`.

#### Scenario: Fenced shell comments do not split
- **WHEN** a section contains a fenced block with the line `## not a heading, a shell comment`
- **THEN** the line stays in that section and no new section starts

#### Scenario: No preamble when the body starts with a heading
- **WHEN** a body begins with `## Only`
- **THEN** the document has exactly one section, `Only`

### Requirement: Wikilinks
The forms `[[id]]` and `[[id#Heading]]` SHALL be recognised as links to a document, or to a section of one, and are checked by `lint`. A link inside a fenced code block (``` or ~~~) SHALL NOT be a link, in this form or in the markdown form.

#### Scenario: Both forms are read
- **WHEN** a body contains `[[other-doc]]` and `[[other-doc#Some Heading]]`
- **THEN** both links are recognised, the second with its heading

#### Scenario: Fenced code holds no links
- **WHEN** a fenced block contains `[[other-doc]]`
- **THEN** it is not a link and `lint` does not report it as dead

### Requirement: Locating the documents folder
The folder of documents SHALL be chosen, in order of precedence, from the `--dir` flag, the `TAGENTS_KNOWLEDGE_DIR` environment variable, then `knowledge.dir` in the tagents `config.yaml` (in the tagents config directory, `~/.config/tagents` unless `TAGENTS_CONFIG_DIR` moves it). There SHALL be no default folder, and a blank value is treated as not given.

#### Scenario: Environment beats config, flag beats both
- **WHEN** config names folder A, `TAGENTS_KNOWLEDGE_DIR` names folder B and `--dir` names folder C
- **THEN** the CLI uses C; without `--dir` it uses B; with neither it uses A

#### Scenario: Config alone is enough
- **WHEN** only `config.yaml` holds `knowledge: { dir: ./knowledge }`
- **THEN** `tagents-knowledge list` reads the `knowledge` folder next to the config file

#### Scenario: Blank value ignored
- **WHEN** `TAGENTS_KNOWLEDGE_DIR` is set to an empty or whitespace string and config names a folder
- **THEN** the config folder is used

#### Scenario: Nobody said where
- **WHEN** no flag, variable or config key names a folder
- **THEN** the command exits 1 and stderr explains that `TAGENTS_KNOWLEDGE_DIR`, `--dir` or the `config.yaml` key must be set

#### Scenario: The chosen folder does not exist
- **WHEN** the chosen path does not exist
- **THEN** the command exits 1 and stderr says the knowledge directory does not exist

### Requirement: Path forms in the folder setting
A leading `~` in `--dir`, `TAGENTS_KNOWLEDGE_DIR` or `knowledge.dir` SHALL be expanded to the home directory, and only at the start. A relative `knowledge.dir` SHALL be resolved against the directory that holds the config file. A config file that is missing, unparseable, or without `knowledge.dir` SHALL count as not set, and its other keys (such as `plugins:`) SHALL be ignored.

#### Scenario: Tilde in config
- **WHEN** config holds `knowledge: { dir: ~/knowledge }`
- **THEN** the folder is `knowledge` under the home directory

#### Scenario: Config without a knowledge section
- **WHEN** config holds only `plugins: {}`, or does not exist
- **THEN** the folder counts as not set

### Requirement: Locating the index
The search index SHALL be a single SQLite file chosen from the `--db` flag, then the `TAGENTS_KNOWLEDGE_DB` environment variable, then `knowledge.sqlite` in the tagents config directory. Unlike the documents folder, the index has a default. The file and its parent directories SHALL be created when missing.

#### Scenario: Default location
- **WHEN** neither `--db` nor `TAGENTS_KNOWLEDGE_DB` is given and `TAGENTS_CONFIG_DIR` is `/cfg`
- **THEN** the index is `/cfg/knowledge.sqlite`

#### Scenario: Environment moves the index
- **WHEN** `TAGENTS_KNOWLEDGE_DB` names another file
- **THEN** that file is used, unless `--db` is also given, in which case `--db` wins

### Requirement: The index is derived data
The index is derived data: when it was written by an incompatible schema version it SHALL be discarded and rebuilt from the documents, and deleting it SHALL lose nothing. The schema version of this format is 2, so an index written by the previous format SHALL be rebuilt on first use.

#### Scenario: An index of the previous format is rebuilt
- **WHEN** the index file was written with schema version 1 and `list` runs
- **THEN** the index is rebuilt from the documents and `list` answers with every document

### Requirement: Incremental indexing
Bringing the index in line with the folder SHALL add new documents, re-index changed ones, drop the documents whose file is gone, and report the counts of added, changed, unchanged and removed documents. A file whose modification time has not moved SHALL NOT be read. A file whose modification time moved SHALL be compared by content hash, and counted unchanged when the bytes did not change.

#### Scenario: Second run reads nothing
- **WHEN** `index` runs twice on a folder of five documents
- **THEN** the first reports `5 new, 0 changed, 0 unchanged, 0 removed` and the second `0 new, 0 changed, 5 unchanged`

#### Scenario: Touching a file is not a change
- **WHEN** a file's mtime is moved without changing its bytes
- **THEN** it is counted unchanged

#### Scenario: Edit and delete
- **WHEN** a document gains a new section and another document file is deleted
- **THEN** the next run reports one changed and one removed, the new section becomes searchable and the deleted document does not answer

### Requirement: Full rebuild
`index --full` SHALL empty the index and rebuild it from the folder, ending in the same content as an incremental run.

#### Scenario: Rebuild from nothing
- **WHEN** `index --full` runs on a folder of five documents already indexed
- **THEN** it reports five added and none unchanged, and `list` returns the same documents as before

### Requirement: Unreadable documents
A document that is refused SHALL be reported per file as `<filename>: <message>` on stderr, SHALL be removed from the index (it must not keep serving its last good text), and SHALL NOT stop the rest of the folder from being indexed. The `index` verb SHALL print the counts, report `N file(s) could not be read; run lint` and exit 1 when any file failed; read verbs (`search`, `show`, `list`) report the failing files on stderr and carry on with their own exit code.

#### Scenario: One bad file among good ones
- **WHEN** `slomannyj.md` has neither `type` nor `kind` and `search rollback` runs
- **THEN** stderr names `slomannyj.md: frontmatter…`, the hits from the good documents are printed and the exit code is 0
- **AND** `index` on the same folder exits 1

### Requirement: Freshness of reads
Every read verb (`search`, `show`, `list`) and every MCP knowledge tool SHALL bring the index in line with the folder before answering, so that an edit made since the last call is visible.

#### Scenario: A new document is found at once
- **WHEN** a document is added to the folder after the last `index` and `search` runs for a word it contains
- **THEN** the new document is among the hits

### Requirement: Search semantics
A search SHALL match sections of documents, returning for each hit the document `id`, `title`, section `heading` (empty for the preamble), `score`, `snippet`, absolute `path`, and the lifecycle fields `type`, `description`, `status` and `stale`. Every whitespace-separated word of the query SHALL appear in the same section, and a word ending in `*` SHALL match as a prefix. Words are split Unicode-aware with diacritics folded and punctuation as a separator. There is no stemming.

#### Scenario: Russian and English corpora
- **WHEN** searching `бэкапы`
- **THEN** only the Russian section containing that word is returned, and searching `бэкапы embeddings` returns nothing

#### Scenario: No morphology
- **WHEN** a section holds `бэкапы` and the query is `бэкап`
- **THEN** it is not found, while `бэкап*` finds it

#### Scenario: Prefix form
- **WHEN** the query is `релиз*`
- **THEN** sections containing `релизы` are found

#### Scenario: Punctuation separates words
- **WHEN** a section holds `tmux-agent-state.sh` and the query is `agent state`
- **THEN** the section is a hit

### Requirement: Queries cannot break the search
Words typed into a search SHALL be matched literally: operators such as `-`, `OR`, `NOT` and quotation marks carry no special meaning, and no query can cause a syntax error. A query that matches nothing, or consists only of quotes or whitespace, SHALL return no hits.

#### Scenario: Hostile characters are harmless
- **WHEN** the query is `"` or `tmux-agent-state.sh OR`
- **THEN** the search returns no hits and does not fail

#### Scenario: Identifier with punctuation
- **WHEN** the query is `tmux-agent-state.sh`
- **THEN** it is treated as one phrase of words, not as an exclusion

### Requirement: Ranking and score
Hits SHALL be ordered best first, with a match in a section's heading weighing ten times a match in its body, except that hits from documents whose status is `deprecated` SHALL come after all other hits, each group in the order described here. The score SHALL be a number rounded to three decimals where a bigger value is a better match, and equal scores SHALL be ordered by document id, then section order. No hit is hidden because of its status.

#### Scenario: Heading beats mention
- **WHEN** searching `rollback` in a corpus where one section is titled `Rollback` and another mentions it once
- **THEN** the titled section is first, the mention is still returned later, and the first score is greater than the second

#### Scenario: Deprecated ranks last
- **WHEN** a deprecated document has a section titled `Failover` and an active document mentions `failover` once in a body, and `failover` is searched
- **THEN** the active document's hit comes first and the deprecated document's hit is still returned after it

### Requirement: Snippet
The snippet of a hit SHALL be one line of about 14 tokens with the matched words wrapped in `[` and `]`.

#### Scenario: Snippet shape
- **WHEN** a hit is returned
- **THEN** its snippet contains no newline and marks the matched word as `[word]`

### Requirement: Filters and limit
Search and list SHALL accept a `type` filter that keeps documents whose type equals the given value, compared case-insensitively, and a `tag` filter that keeps documents carrying that tag; given together they combine. Search SHALL accept a limit of hits, 10 by default; an invalid `--limit` (not a positive number) SHALL be ignored in favour of the default.

#### Scenario: Kind and tag narrow results
- **WHEN** `search релиз* --kind note` runs, and `search rollback --tag tmux --limit 1` runs
- **THEN** the first returns only hits from documents of type `Note`, the second returns exactly one hit, from a document tagged `tmux`

#### Scenario: The type comparison ignores case
- **WHEN** a document has `type: Runbook` and `list --type RUNBOOK` runs
- **THEN** that document is listed

#### Scenario: Unknown tag
- **WHEN** the tag matches no document
- **THEN** the result is empty

#### Scenario: Default and invalid limit
- **WHEN** a query matches twelve sections and runs with no `--limit`, with `--limit 0` and with `--limit many`
- **THEN** each run returns ten hits and exits 0

### Requirement: Kind is an alias of type
`kind` SHALL remain accepted as a deprecated alias of `type` with the same meaning, so that `--kind runbook` finds the type `Runbook`; when both are given, `type` wins.

#### Scenario: Type narrows results
- **WHEN** `search релиз* --type note` runs
- **THEN** it returns the same hits as `--kind note`

#### Scenario: The kind alias
- **WHEN** `list --kind runbook` and `list --type runbook` run on the same folder
- **THEN** they print the same lines

### Requirement: Listing documents
A list SHALL return every indexed document in id order, except that documents whose status is `deprecated` come after all others, with `id`, `title`, `type`, `description`, `tags`, `status`, `stale`, `updated`, absolute `path` and `headings` (the section headings in document order, without the preamble), optionally filtered by `type` (or its alias `kind`) and `tag`.

#### Scenario: Headings
- **WHEN** a document has a preamble and sections `Диски` and `Сервисы`
- **THEN** its `headings` are `["Диски", "Сервисы"]`

### Requirement: Computed fields of a listed document
`updated` SHALL be the UTC date part of `generated.at`, or `-` when the document has no `generated`. `description` SHALL be the empty string when the document has none. `stale` SHALL be a boolean computed when the list is made: true when `stale_after` is given and the current time is at or after it.

#### Scenario: Stale is computed at query time
- **WHEN** a document has `stale_after: 2026-10-01T00:00:00Z` and the list is made before and after that instant
- **THEN** `stale` is false the first time and true the second

#### Scenario: No generated
- **WHEN** a document has no `generated`
- **THEN** its `updated` is `-`

### Requirement: Reading a document or section
Reading by address SHALL accept `id` for the whole document (the file as it is on disk, frontmatter included) or `id#heading` for one section. Heading matching SHALL be case-insensitive and work for non-ASCII letters (`диски` finds `Диски`). An empty heading (`id#`) addresses the preamble.

#### Scenario: One section only
- **WHEN** `show mashina-karta#Диски` runs
- **THEN** the output starts with `## Диски`, a blank line, and the section body, and does not contain other sections

#### Scenario: Preamble
- **WHEN** `show mashina-karta#` runs
- **THEN** the output is the preamble text without a heading line

### Requirement: CLI verbs and flags
The `tagents-knowledge` program SHALL provide the verbs `index [--dir D] [--db F] [--full]`, `search <query…> [--dir] [--db] [--usage-db F] [--verbose] [--tag T] [--type T] [--kind K] [--limit N] [--json]`, `show <id[#heading]> [--dir] [--db] [--usage-db F] [--verbose]`, `list [--dir] [--db] [--type T] [--kind K] [--tag T] [--json]`, `lint [--dir D]`, `toc [--dir D] [--check]`, `usage` (its flags are in the arguments of the usage verb), `mcp` and `serve [--idle S] [--foreground] [--socket P]`.

#### Scenario: Verbs match the generated contract
- **WHEN** the CLI contract is generated
- **THEN** it lists exactly `index`, `search`, `show`, `list`, `lint`, `toc`, `usage`, `mcp`, `serve`, in English, with exit codes 0, 1, 2 and 4

### Requirement: CLI help
`help`, `--help` and `-h` SHALL print the usage text on stdout.

#### Scenario: Help on stdout
- **WHEN** the verb is `help`, `--help` or `-h`
- **THEN** the usage text is printed on stdout, nothing is printed on stderr, and the exit code is 0

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

### Requirement: Human text is localised, machine output is not
Human-facing CLI text (usage, messages, lint findings) SHALL follow `TAGENTS_LOCALE` (`en` or `ru`), with any other value meaning English. `--json` output, lint finding codes, the generated CLI contract and the text returned by MCP tools SHALL stay in English whatever the locale.

#### Scenario: Russian messages
- **WHEN** `TAGENTS_LOCALE=ru` and a search finds nothing
- **THEN** stderr says `ничего не найдено…`, and the exit code is 4

#### Scenario: Unknown locale
- **WHEN** `TAGENTS_LOCALE=xx` and `help` runs
- **THEN** the English usage is printed

### Requirement: Quiet stderr
The CLI SHALL NOT print Node's experimental-SQLite warning on any verb; every other warning is unaffected.

#### Scenario: No experimental notice
- **WHEN** `lint`, `help`, `list` or `search` runs
- **THEN** stderr does not contain `ExperimentalWarning`

### Requirement: Lint
`lint` SHALL check the claims each document makes about itself, without using the index, and report each finding as `<filename>: <message>` on stdout. The finding kinds are `frontmatter`, `stem`, `duplicate-id`, `legacy`, `expired`, `stale`, `generated`, `dead-link` and `index`. A file that is refused by the loader SHALL be one finding, not the end of the report. A `duplicate-id` finding SHALL mean that two files declare the same frontmatter `id`.

#### Scenario: Broken file is one finding
- **WHEN** a file has no frontmatter at all
- **THEN** it yields one `frontmatter` finding, it still counts in the number of documents checked, and the other files are still checked

#### Scenario: Duplicate declared id
- **WHEN** two files declare the same `id`
- **THEN** a `duplicate-id` finding is reported for the second file, together with a `stem` finding for the file whose name differs

### Requirement: Lint summary and exit code
With no findings `lint` SHALL print `N document(s) in DIR: no problems` and exit 0; otherwise it prints `N problem(s) in DIR` after the findings and exits 1. The number of documents checked SHALL NOT count `index.md` or `log.md`.

#### Scenario: Clean corpus
- **WHEN** `lint --dir` points at a folder of valid documents in the OKF form with a current `index.md` and no broken links
- **THEN** the output says `N document(s)… no problems` and the exit code is 0

### Requirement: Lint freshness checks
A `stale` finding SHALL mean that the UTC date of `generated.at` is earlier than the date of the newest git commit touching the file, and is checked only inside a git work tree, only for committed files and only for documents that have `generated`. Both sides SHALL be UTC dates: the commit date is the commit instant (committer date with its offset) converted to UTC.

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
`tagents-knowledge mcp` SHALL serve the MCP protocol over stdio only, as server `tagents-knowledge`, and exit when the client closes the pipe. It SHALL expose exactly six tools: `knowledge_search`, `knowledge_get`, `knowledge_list`, `knowledge_usage`, `sessions_recent`, `sessions_search`. It SHALL offer no tool that writes, edits, deletes or generates a document or an `index.md`. Tool output is English text, and the server SHALL write nothing to stdout besides the protocol.

#### Scenario: Tool inventory
- **WHEN** a client lists the tools
- **THEN** it sees exactly those six names

### Requirement: MCP document source
The MCP knowledge tools SHALL locate the folder and the index from the environment alone (`TAGENTS_KNOWLEDGE_DIR` or config `knowledge.dir`, and `TAGENTS_KNOWLEDGE_DB`), SHALL refresh the index on each call, and SHALL return a tool error (`isError: true`) with a message naming `TAGENTS_KNOWLEDGE_DIR` and the config file when no folder is configured, or saying the directory does not exist when it is configured but absent.

#### Scenario: Unconfigured server
- **WHEN** a client calls `knowledge_list` with no folder configured
- **THEN** the result is an error whose text mentions `TAGENTS_KNOWLEDGE_DIR`

### Requirement: The serve verb
`tagents-knowledge serve` SHALL print on stdout the unix socket of the shared server for the caller's environment and exit 0, starting that server first, detached, when nothing answers on the socket. `--idle S` SHALL be a positive number of seconds, default 600; any other value SHALL exit 2 with a message naming `--idle`. A server that cannot be started SHALL exit 1 with a message on stderr.

#### Scenario: The same socket twice
- **WHEN** `serve` runs twice while the server lives
- **THEN** both print the same socket and one server process exists

#### Scenario: A bad idle time
- **WHEN** `serve --idle` is given `0`, `-3` or `soon`
- **THEN** it exits 2 and stderr names `--idle`

### Requirement: The server run in the foreground
`serve --foreground` SHALL be the shared server itself, run in the calling process: it listens on `--socket P` (default the socket of the caller's environment), serves until it has been idle for `--idle` seconds or receives SIGTERM or SIGINT, and exits 0. When another server already answers on that socket it SHALL exit 0 at once. The directory of P SHALL be owned by the caller and is tightened to mode 0700; when it is not, `serve --foreground` exits 1 with a message on stderr.

#### Scenario: Another server holds the socket
- **WHEN** `serve --foreground` is started on a socket that a live server holds
- **THEN** it exits 0 without disturbing that server

### Requirement: One shared server per environment
Every client of the same environment SHALL be served by one daemon, and clients whose environments differ SHALL get separate daemons that answer from their own documents. The environment is `HOME`, `TAGENTS_CONFIG_DIR`, `XDG_CONFIG_HOME`, `TAGENTS_KNOWLEDGE_DIR`, `TAGENTS_KNOWLEDGE_DB`, `TAGENTS_KNOWLEDGE_USAGE_DB` and `CLAUDE_HOMES`, plus the build of the program that runs.

#### Scenario: Two sessions, one daemon
- **WHEN** two sessions start at the same moment in the same environment
- **THEN** one daemon serves both, and it outlives them

#### Scenario: Different documents
- **WHEN** one session sets `TAGENTS_KNOWLEDGE_DIR` to folder A and another to folder B
- **THEN** each daemon lists only its own folder's documents

#### Scenario: Different usage stores
- **WHEN** one session sets `TAGENTS_KNOWLEDGE_USAGE_DB` to file A and another to file B, and each reads a document through its daemon
- **THEN** the two sessions get separate daemons, and each read is recorded in its own file only

### Requirement: What makes a different environment
Relative values of `TAGENTS_CONFIG_DIR`, `XDG_CONFIG_HOME`, `TAGENTS_KNOWLEDGE_DIR`, `TAGENTS_KNOWLEDGE_DB`, `TAGENTS_KNOWLEDGE_USAGE_DB` and the entries of `CLAUDE_HOMES` SHALL count as absolute from the caller's directory, `HOME` and values beginning with `~` count as written, and unset counts as empty. Other variables SHALL NOT split daemons, except that a different `TMPDIR` names a different socket directory and so gets a daemon of its own.

#### Scenario: A variable the server does not read
- **WHEN** a session differs only in `CLAUDE_CONFIG_DIR`
- **THEN** it joins the daemon the others use

#### Scenario: A different TMPDIR
- **WHEN** one session sets `TMPDIR` to another directory
- **THEN** it gets a daemon of its own

#### Scenario: A relative usage store
- **WHEN** a session sets `TAGENTS_KNOWLEDGE_USAGE_DB` to `usage.sqlite` and starts in directory D
- **THEN** its daemon records into `D/usage.sqlite`, whatever directory the daemon itself runs in

### Requirement: Where the shared server lives
The daemon SHALL listen on `knowledge-<12 hex digits>.sock` in the directory `tagents-<uid>` under `TMPDIR` (the system temporary directory when blank), or under `/tmp` when the socket name would not fit an address. The directory SHALL be mode 0700 and owned by the user: a looser one is tightened and one owned by another user or not a directory is refused. The daemon SHALL write `<socket>.pid` once it listens and remove the socket and that file when it leaves.

#### Scenario: A private directory
- **WHEN** `serve` has started a daemon
- **THEN** the printed socket is in the `tagents-<uid>` directory, whose mode is 0700, and `<socket>.pid` holds the daemon's pid

#### Scenario: A clean exit
- **WHEN** the daemon is sent SIGTERM
- **THEN** it leaves and the socket and the pid file are gone, and the next `serve` starts a new daemon

### Requirement: Starting the daemon is safe under races
The daemon SHALL run detached, in a process group of its own and in the directory `/`, with no output of its own, so that it outlives the session that started it. Starters that meet in the same moment SHALL end up with one daemon. A socket file left by a daemon that was killed SHALL be replaced under the lock `<socket>.lock`, so that bridges meeting it together start exactly one new daemon on the same name.

#### Scenario: Four bridges meet a dead socket
- **WHEN** the daemon is killed with SIGKILL and four sessions start together
- **THEN** one new daemon listens on the same socket name and serves all four

### Requirement: The daemon leaves when it is idle
The daemon SHALL exit after `--idle` seconds (default 600) with no client connected, counted from the last disconnect or, if none ever connected, from its start, and SHALL NOT exit while a client stays connected. A client that closes only its writing side SHALL be released at once, so that it does not keep the daemon alive.

#### Scenario: A client holds it open
- **WHEN** the idle time is 1 second and a client stays connected for 2 seconds
- **THEN** the daemon is still running, and leaves after the client goes

#### Scenario: Nobody ever connects
- **WHEN** a daemon is started and no client connects
- **THEN** it exits after the idle time

### Requirement: One bad client does not stop the others
A client that sends rubbish (text that is not JSON, JSON that is not a request, bytes that are not text, an unknown method, a cut-off line) or whose connection fails while it is set up SHALL cost only its own connection. An exception or rejection nobody caught SHALL be reported on stderr as a line starting `tagents-knowledge:` that names what failed, followed by the error's stack, and the daemon SHALL go on serving. A signal SHALL stop it.

#### Scenario: Garbage, then a real client
- **WHEN** a client sends rubbish and disconnects, and a session then connects
- **THEN** the daemon pid is unchanged and the session lists the five tools

### Requirement: The shared server speaks the same protocol
Each connection to the daemon SHALL get its own MCP server over newline-delimited JSON-RPC, exposing the same six tools with the same behaviour as `tagents-knowledge mcp`.

#### Scenario: Through the bridge
- **WHEN** a session reaches the daemon through the plugin's server entry
- **THEN** it lists exactly the six tools of the MCP server requirement, and closing its stdin ends its connection

### Requirement: Tool knowledge_search
`knowledge_search` SHALL take `query` (required, non-empty string), `tag`, `type` and `kind` (optional strings, `kind` being a deprecated alias of `type`) and `limit` (optional integer from 1 to 50, default 10), with the same matching, filtering and ranking as the CLI.

#### Scenario: Schema
- **WHEN** the tool list is read
- **THEN** the input properties are `kind`, `limit`, `query`, `tag`, `type` and only `query` is required

#### Scenario: The kind alias
- **WHEN** a client searches with `kind: runbook` and then with `type: Runbook`
- **THEN** the two answers hold the same hits

### Requirement: Tool knowledge_search output
`knowledge_search` SHALL return the hits as pretty-printed JSON text, an array of objects with `id`, `title`, `heading`, `score`, `snippet`, `path`, `type`, `description`, `status`, `stale`; when nothing matches it returns the plain text `nothing matches "<query>"`, which is not an error.

#### Scenario: Ranked hits
- **WHEN** a client searches `rollback`
- **THEN** the first hit has id `deploy-runbook`, heading `Rollback` and a numeric score

### Requirement: Tool knowledge_get
`knowledge_get` SHALL take `id` (required, non-empty) and `heading` (optional). Without `heading` it SHALL return the document's file text including its frontmatter. With `heading` it SHALL return `## <heading>`, a blank line, the section body and a newline. An unknown id SHALL be a tool error saying there is no document with that id; an unknown heading SHALL be a tool error that names the document's available headings.

#### Scenario: Whole document
- **WHEN** `knowledge_get` is called with id `mashina-karta`
- **THEN** the text begins with `---\nid: mashina-karta` and contains the document's sections

#### Scenario: One section
- **WHEN** it is called with a heading `Диски`
- **THEN** the text begins with `## Диски` and holds no other section

#### Scenario: Unknown id
- **WHEN** the id does not exist
- **THEN** the result is a tool error, not an empty answer

### Requirement: Tool knowledge_list
`knowledge_list` SHALL take optional `type`, `kind` (a deprecated alias of `type`) and `tag` strings and return the matching documents as pretty-printed JSON, an array of objects with `id`, `title`, `type`, `description`, `tags`, `status`, `stale`, `updated`, `path`, `headings`; an empty match is the JSON `[]`, not an error.

#### Scenario: Filter by kind
- **WHEN** called with `kind: runbook`
- **THEN** the array holds only the runbook documents, and none of the objects has a `kind` key

#### Scenario: Filter by type
- **WHEN** called with `type: Runbook`
- **THEN** the array is the same as for `kind: runbook`

### Requirement: Session tools
`sessions_recent` SHALL take an optional integer `limit` from 1 to 50 (default 15) and return the latest Claude sessions across every Claude account on the machine, newest first. `sessions_search` SHALL take a required non-empty string `words`, split on whitespace, and return the sessions whose project path or opening prompt contains every word. Both return the same text the sessions CLI prints, as the `session-history` capability defines it.

#### Scenario: No Claude homes
- **WHEN** the machine has no Claude account directories
- **THEN** the tools still answer with text rather than failing

#### Scenario: Recent sessions
- **WHEN** `sessions_recent` is called with `limit: 3`
- **THEN** the text is the sessions listing and ends with the hint about `sessions.mjs show <id-prefix>`

#### Scenario: No matching session
- **WHEN** `sessions_search` is called with words that match nothing
- **THEN** the text says that nothing matches

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
- **WHEN** the target has a section `Failover steps` and links use `#Failover%20steps`, `#FAILOVER%20STEPS` and `#failover-steps`
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

### Requirement: Links in code and to reserved files
A link inside an inline code span (backticks) SHALL NOT be a link, in either form, just as inside a fenced block. Link text MAY contain backslash-escaped brackets. A link to `index.md` or `log.md`, with or without a leading slash or `./`, SHALL be valid when that file exists in the folder and a dead link only when it does not.

#### Scenario: Inline code
- **WHEN** a body contains `` `[[nothing]]` ``
- **THEN** `lint` reports no dead link for it

#### Scenario: Reserved file
- **WHEN** a document links `[a](index.md)` and the folder holds `index.md`
- **THEN** `lint` reports no dead link, and reports `dead link [a](index.md)` once the file is gone

### Requirement: Lint non-string id
A frontmatter `id` that is present and is not a string SHALL be a `frontmatter` finding naming `id`.

#### Scenario: Numeric id
- **WHEN** a document has `id: 42`
- **THEN** `lint` reports a `frontmatter` finding naming `id`

### Requirement: toc reports refused files
When the loader refuses a file, `toc` without `--check` SHALL print `<filename>: <message>` for it on stderr, leave it out of `index.md` and still exit 0, and `toc --check` SHALL print only its own line.

#### Scenario: One bad file
- **WHEN** `toc` runs on a folder with one file that has no frontmatter
- **THEN** stderr names that file, `index.md` omits it and the exit code is 0

### Requirement: The usage store
Reads SHALL be recorded in a usage store: a SQLite file of its own, apart from the index, whose table `usage_events` has one row per event, with the columns `ts` (milliseconds since the epoch), `doc_id`, `heading` (empty for a whole document or a search hit), `kind` (`get` or `hit`) and `caller` (null when unknown). Rebuilding, upgrading or deleting the index SHALL leave the store untouched.

#### Scenario: The index is rebuilt
- **WHEN** events are recorded, then `index --full` runs, then the index file is deleted and a read builds it again
- **THEN** every recorded event is still in the usage store

### Requirement: Locating the usage store
The usage store SHALL be the file named by `--usage-db`, else by `TAGENTS_KNOWLEDGE_USAGE_DB`, else `knowledge-usage.sqlite` in the directory of the index in use, however that index was chosen. `~` SHALL be expanded. The MCP tools have no flags and SHALL locate the store from the environment alone. The file and its directory SHALL be created when the first event is recorded.

#### Scenario: Beside the index
- **WHEN** `show` runs with `--db /tmp/x/index.sqlite` and no usage setting
- **THEN** its event is recorded in `/tmp/x/knowledge-usage.sqlite`

#### Scenario: Flag, variable, default
- **WHEN** `--usage-db a.sqlite` is given while `TAGENTS_KNOWLEDGE_USAGE_DB` names `b.sqlite`
- **THEN** the event is recorded in `a.sqlite`, and with the variable alone, in `b.sqlite`

### Requirement: What a get records
`show` and `knowledge_get` SHALL record one `get` for each call that returns text: the document `id` as indexed, and the section heading as the document writes it when a section was asked for, otherwise an empty heading. A call that fails, for an unknown id or heading, SHALL record nothing.

#### Scenario: A section
- **WHEN** `show deploy-runbook#rollback` runs on a document whose section is `Rollback`
- **THEN** one `get` is recorded, with `doc_id` `deploy-runbook` and `heading` `Rollback`

#### Scenario: An unknown id
- **WHEN** `knowledge_get` is called with an id that does not exist
- **THEN** the result is a tool error and no event is recorded

### Requirement: What a hit records
`search` and `knowledge_search` SHALL record one `hit` for each distinct document among the results they return, with an empty heading, however many of its sections matched. A search that returns nothing SHALL record nothing.

#### Scenario: Two sections of one document
- **WHEN** a search returns two sections of `deploy-runbook` and one of `mashina-karta`
- **THEN** two `hit` events are recorded, one for each document

#### Scenario: Nothing matches
- **WHEN** a search finds nothing
- **THEN** no event is recorded

### Requirement: Other reads record nothing
`index`, `list`, `lint`, `toc`, `usage`, `knowledge_list`, `knowledge_usage` and the sessions tools SHALL record no event, so that listing or reporting never counts as use.

#### Scenario: A report is not a read
- **WHEN** `usage` runs twice in a row
- **THEN** both reports show the same counts

### Requirement: The caller of an event
The `caller` of an event SHALL be the client name given in the MCP handshake for the tools, the value of `TA_LABEL` for the CLI verbs when it is set and not empty, and null otherwise. The text of a query and any session identifier SHALL NOT be stored.

#### Scenario: A client name
- **WHEN** a client that calls itself `knowledge-suite` calls `knowledge_get`
- **THEN** the event's `caller` is `knowledge-suite`

#### Scenario: A label
- **WHEN** `show` runs with `TA_LABEL=builder`
- **THEN** the event's `caller` is `builder`

#### Scenario: A query is not stored
- **WHEN** `search` runs with a query that matches a document
- **THEN** no column of any row of the store contains the query text

### Requirement: Recording never fails a read
A usage store that cannot be opened, stays locked for more than 250 ms, or cannot be written SHALL NOT change the output or the exit code of the read that tried to record. `search` and `show` with `--verbose` SHALL then say on stderr that the read was not recorded and why; without it they SHALL stay silent.

#### Scenario: An unwritable store
- **WHEN** `TAGENTS_KNOWLEDGE_USAGE_DB` names a path that cannot be opened and `show deploy-runbook` runs
- **THEN** stdout and the exit code are those of a run without the problem, and stderr is empty

#### Scenario: Verbose
- **WHEN** the same run has `--verbose`
- **THEN** stderr names the usage store, and the exit code is still 0

### Requirement: Retention of usage events
Recording an event SHALL delete the events older than 365 days.

#### Scenario: Old events go
- **WHEN** a store holds one event 366 days old and another 364 days old, and a read is recorded
- **THEN** the older event is gone and the other stays

### Requirement: The usage report
`usage` SHALL print a header line and then one line per document with the columns `id`, `type`, `status`, `gets`, `hits`, `days` and `last`, separated by at least two spaces, sorted by `gets` descending, then `hits` descending, then `id`, and limited to `--top N` lines (default 20). A value that is unknown is printed as `-`.

#### Scenario: Order and columns
- **WHEN** `deploy-runbook` has 4 `get` events on 2 UTC dates and 1 `hit`, and `mashina-karta` has none, all inside the window
- **THEN** `deploy-runbook` is listed first with 4, 1 and 2 and the date of its newest `get`, and `mashina-karta` after it with 0, 0, 0 and `-`

#### Scenario: Top
- **WHEN** the folder holds 25 documents and `usage` runs without `--top`
- **THEN** 20 document lines follow the header

### Requirement: Counts in the report
`gets` and `hits` SHALL count the events not older than the window, `--since <N>d` (default `30d`), a day being 24 hours. `days` SHALL be the number of distinct UTC dates on which the document has a `get` in the window. `last` SHALL be the UTC date of its newest `get` in the store, whatever its age, and `-` when it has none.

#### Scenario: The window
- **WHEN** a document has a `get` 31 days old and another 29 days old
- **THEN** with the default window its `gets` is 1 and its `last` is the date of the newer one

#### Scenario: Days
- **WHEN** a document has three `get` events on one UTC date and one on the next
- **THEN** its `gets` is 4 and its `days` is 2

#### Scenario: Only an old get
- **WHEN** the only `get` of a document is 100 days old
- **THEN** its `gets` and `days` are 0 and its `last` is that date

### Requirement: Arguments of the usage verb
The `usage` verb SHALL take `[--dir] [--db] [--usage-db F] [--top N] [--since <N>d] [--type T] [--all] [--candidates] [--min-gets N] [--min-days N] [--json]`. `--since` SHALL be a positive whole number followed by `d`; `--top`, `--min-gets` and `--min-days` SHALL be positive whole numbers. Any other value SHALL exit 2 with a message on stderr that names the flag.

#### Scenario: Bad values
- **WHEN** `--since` is given `30`, `0d` or `soon`, or `--top` is given `0` or `many`
- **THEN** the exit code is 2 and stderr names the flag

### Requirement: Documents in the report
`usage` SHALL list every document of the folder, the unread ones with zeros. An id that has events but is no longer in the folder SHALL be listed only with `--all`, with `-` (JSON `null`) as its type and status. `--type T` SHALL keep only the documents of that type, matched as `list` matches it, and so drops ids no longer in the folder.

#### Scenario: An unread document
- **WHEN** `mashina-karta` has no events
- **THEN** it is listed with `gets`, `hits` and `days` 0 and `last` `-`

#### Scenario: A removed document
- **WHEN** events exist for `old-runbook`, which is not in the folder
- **THEN** `usage` does not list it, and `usage --all` does, with `-` as its type and status

### Requirement: Candidates for a skill
`--candidates` SHALL keep only the documents of the folder whose status is not `deprecated` and that have at least `--min-gets` `get` events (default 5) on at least `--min-days` distinct UTC dates (default 3) inside the window. Hits do not count. It only names documents: it creates, edits and ranks nothing.

#### Scenario: At the thresholds
- **WHEN** a stable document has 5 `get` events on 3 UTC dates inside the window
- **THEN** `usage --candidates` lists it, and does not when it has 5 on 2 dates or 4 on 3

#### Scenario: Deprecated documents and hits
- **WHEN** a deprecated document has 9 `get` events on 5 dates, and another has 2 `get` and 40 `hit` events
- **THEN** `usage --candidates` lists neither

#### Scenario: Own thresholds
- **WHEN** `--min-gets 2 --min-days 1` is given and a document has 2 `get` events on one date
- **THEN** it is listed

### Requirement: Usage report output
With `--json`, `usage` SHALL print a JSON array of objects with exactly the keys `id`, `type`, `status`, `gets`, `hits`, `days` and `last`, where `type`, `status` and `last` are null when unknown. When no row is left it SHALL exit 4, printing `[]` with `--json` and a sentence on stderr without it.

#### Scenario: JSON
- **WHEN** `usage --json` runs on a folder with one read document
- **THEN** stdout is an array whose objects have exactly those seven keys, with `gets`, `hits` and `days` as numbers

#### Scenario: Nothing left
- **WHEN** `usage --candidates --json` finds no candidate
- **THEN** stdout is `[]` and the exit code is 4

### Requirement: A missing or damaged usage store
A usage store that does not exist SHALL count as holding no events, and `usage` SHALL NOT create it. A store that exists but cannot be read SHALL make `usage` exit 1 with a message on stderr that names the file.

#### Scenario: No store yet
- **WHEN** `usage` runs before any read was recorded
- **THEN** every document is listed with zeros, the exit code is 0 and the store file does not exist afterwards

#### Scenario: A damaged store
- **WHEN** the store file holds text that is not a database
- **THEN** `usage` exits 1 and stderr names the file

### Requirement: Tool knowledge_usage
`knowledge_usage` SHALL take optional `since` (as `--since`, default `30d`), `top` (integer from 1, default 20), `type` (string), `all` and `candidates` (booleans), `min_gets` and `min_days` (integers from 1), and return the rows of `usage --json` as pretty-printed JSON text; no row is the JSON `[]`, not an error. A bad `since` SHALL be a tool error that names `since`.

#### Scenario: The same rows as the CLI
- **WHEN** `knowledge_usage` is called with `candidates: true` and `usage --candidates --json` runs on the same store
- **THEN** the two arrays are equal

#### Scenario: Schema
- **WHEN** the tool list is read
- **THEN** the input properties are `all`, `candidates`, `min_days`, `min_gets`, `since`, `top`, `type` and none is required

#### Scenario: A bad window
- **WHEN** it is called with `since: "soon"`
- **THEN** the result is a tool error whose text names `since`

### Requirement: Usage does not rank
The order of the results of `search` and `knowledge_search` SHALL NOT depend on the usage store: the same query on the same documents returns the same hits in the same order, whatever has been recorded.

#### Scenario: A busy document
- **WHEN** one of two equally matching documents has many `get` events and the other none
- **THEN** a search lists them in the same order as it does with an empty usage store
