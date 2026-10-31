# session-history Specification

## Purpose
Finding past Claude Code sessions by project or opening prompt across every Claude home on the machine, through the `tagents-core sessions` text verbs, so an agent or a person can answer what was worked on and where.

## Requirements

### Requirement: Where transcripts are looked for
The `sessions` verbs SHALL read the session transcripts that every Claude account keeps on disk as `<claude home>/projects/<project>/<session id>.jsonl`. By default the Claude homes are `~/.claude` and every `~/.claude-<name>` directory in the home directory (the name may contain letters, digits, underscores, dots and dashes). A home without a `projects` directory contributes nothing. The homes are looked up again on every call, so a changed environment takes effect at once.

#### Scenario: Several homes
- **WHEN** `~/.claude` and `~/.claude-work` both hold transcripts and `CLAUDE_HOMES` is not set
- **THEN** the sessions of both are listed together

#### Scenario: Home without projects
- **WHEN** a listed home has no `projects` directory
- **THEN** it is skipped without an error

### Requirement: The CLAUDE_HOMES override
The environment variable `CLAUDE_HOMES`, a comma-separated list of Claude home directories (entries are trimmed, empty ones dropped), SHALL replace the discovery of the homes entirely when it is set and non-empty.

#### Scenario: Override
- **WHEN** `CLAUDE_HOMES` names one directory that holds a `projects` folder
- **THEN** only that directory's transcripts are listed

#### Scenario: Two homes
- **WHEN** `CLAUDE_HOMES` is `~/a/.claude, ~/b/.claude-x`
- **THEN** the transcripts of both are listed

### Requirement: Account names
Each session SHALL be labelled with the account of its Claude home: `personal` for a directory called `.claude`, otherwise the directory name without its `.claude-` prefix.

#### Scenario: Default account
- **WHEN** a transcript lives under `~/.claude/projects`
- **THEN** its account is `personal`

#### Scenario: Named account
- **WHEN** a transcript lives under `~/.claude-work/projects`
- **THEN** its account is `work`

### Requirement: Which transcripts count as sessions
A session SHALL be a `.jsonl` file lying directly in a project directory under `projects`, whose session id is the file name without the extension. Files smaller than 2000 bytes (empty shells and aborted starts) are not sessions, and neither are other files or nested directories. Sessions are ordered by the file's modification time, newest first, across all homes together. Directories and files that disappear or cannot be read while listing are skipped.

#### Scenario: Aborted start
- **WHEN** a transcript is smaller than 2000 bytes
- **THEN** it appears in no `sessions` output

#### Scenario: Newest first
- **WHEN** two sessions were last written on 2 January and 3 February
- **THEN** the February one is listed before the January one

### Requirement: Project paths in listings
The project shown for a session SHALL be its project directory name decoded back into a path: Claude names the directory after the working directory with every `/` replaced by `-`, so the decoding replaces every `-` with `/`, and when the name starts with the encoded home directory, that prefix is folded into `~`. The decoding is lossy: a dash inside a real directory name also becomes a slash.

#### Scenario: Under the home
- **WHEN** the home is `/home/demo` and the project directory is `-home-demo-git-x`
- **THEN** the project is `~/git/x`

#### Scenario: Outside the home
- **WHEN** the project directory is `-opt-src-y`
- **THEN** the project is `/opt/src/y`

### Requirement: The opening prompt
A session's opening prompt SHALL be the content of the first record of type `user` in the first 64 KiB of the transcript that is not marked as meta and whose message content is a plain string that is non-blank after trimming and does not start with `<` (so command wrappers and injected context are passed over). The prompt is trimmed. When there is none, the listings show `(no opening prompt)`.

#### Scenario: Meta message first
- **WHEN** the first user record is marked meta and the second holds `the real question`
- **THEN** the opening prompt is `the real question`

#### Scenario: Prompt out of reach
- **WHEN** the first qualifying user record starts after the first 64 KiB
- **THEN** the session has no opening prompt

### Requirement: Listing recent sessions
`tagents-core sessions recent [N]` SHALL print the N newest sessions, 15 when N is absent, not a number or zero, and exit 0. `tagents-core sessions` with no verb does the same as `recent`. The listing ends with an empty line and the line `full text of one: sessions.mjs show <id-prefix>`. The wording, including the program name `sessions.mjs`, is a contract that agents read, and the text is never translated.

#### Scenario: Cap
- **WHEN** two sessions exist and `sessions recent 1` runs
- **THEN** only the newest session is printed, followed by the trailer

#### Scenario: Nothing recorded
- **WHEN** no session exists
- **THEN** the output is just the empty line and the trailer, with exit code 0

#### Scenario: No verb
- **WHEN** `tagents-core sessions` runs
- **THEN** the output equals that of `sessions recent`

### Requirement: Shape of a session entry
Each session in `recent` and `search` output SHALL take two lines. The first holds the first 8 characters of the id, two spaces, the last-write time in UTC as `MM-DD HH:MM` (followed by ` (today/yday)` when it is less than 24 hours old) padded to 18 characters, a space, the account padded to 8 characters, a space and the project. The second holds ten spaces and the opening prompt with whitespace runs collapsed to single spaces and cut at 150 characters.

#### Scenario: Entry
- **WHEN** a session of account `personal` in project `/home/demo/git/other/repo` was last written on 3 February at 04:05 UTC
- **THEN** its first line is the id prefix, two spaces, `02-03 04:05` padded to 18 characters, a space, `personal`, a space and the project

#### Scenario: Long prompt
- **WHEN** the opening prompt is longer than 150 characters
- **THEN** the second line shows only its first 150 characters

### Requirement: Searching sessions
`tagents-core sessions search <words…>` SHALL scan the 400 newest sessions and print, in the same two-line form (and without a trailer), the first 12 whose project path followed by the opening prompt contain every word, matched case-insensitively as a substring. The words are all arguments joined by spaces and split on whitespace.

#### Scenario: A hit on the prompt
- **WHEN** a session was opened with `Fix the deploy script for the staging cluster` and `sessions search deploy` runs
- **THEN** that session's two lines are printed

#### Scenario: A hit on the project
- **WHEN** the word is part of the decoded project path and not of the prompt
- **THEN** the session is still printed

#### Scenario: All words
- **WHEN** the words are `deploy zzzz` and only one of them appears
- **THEN** the session is not printed

### Requirement: Search misses and usage
When no session matches, `sessions search` SHALL print `nothing matches "<the words, lower-cased and joined by spaces>" in the last 400 sessions' opening prompts` on stdout and exit 0. Called with no words, or only blanks, it prints `usage: sessions.mjs search <words…>` on stderr, nothing on stdout, and exits 1.

#### Scenario: Miss
- **WHEN** `sessions search zzzznothing` runs and nothing matches
- **THEN** stdout is `nothing matches "zzzznothing" in the last 400 sessions' opening prompts`

#### Scenario: No words
- **WHEN** `sessions search` runs
- **THEN** stdout is empty, stderr is `usage: sessions.mjs search <words…>` and the exit code is 1

### Requirement: Showing one session
`tagents-core sessions show <id-prefix>` SHALL pick the newest session whose id starts with the prefix and print: `session <full id>`; the line `account <account> · project <project> · last activity <ISO-8601 UTC time of the last write>`; an empty line; `── opening prompt ──` and the opening prompt; an empty line; `── last assistant reply (tail) ──` and the last assistant reply. Both texts have whitespace runs collapsed and are cut at 1500 characters.

#### Scenario: Known session
- **WHEN** a session whose opening prompt is `Fix the deploy script for the staging cluster` and whose last reply is `Deploy script fixed and staging is green.` is shown by its first 8 characters
- **THEN** the output holds the account, the project, the last-activity time, that prompt and that reply under the two headings

#### Scenario: Shared prefix
- **WHEN** two sessions share the prefix
- **THEN** the newer one is shown

### Requirement: The last assistant reply
The reply shown by `sessions show` SHALL be the last non-blank text block of any assistant record within the final 48 KiB of the transcript, so an assistant record that holds only tool calls does not hide an earlier reply. A missing opening prompt shows `(none)` and a missing reply `(none in tail window)`.

#### Scenario: Reply in the tail
- **WHEN** the last assistant message of a large transcript lies in its final 48 KiB
- **THEN** that message's text is shown

#### Scenario: No reply in the tail
- **WHEN** the final 48 KiB hold no assistant text
- **THEN** the line shows `(none in tail window)`

### Requirement: Show errors
`sessions show` without a prefix SHALL print `usage: sessions.mjs show <id-prefix>` on stderr and exit 1. With a prefix that matches no session it prints `no session starts with "<prefix>"` on stderr, nothing on stdout, and exits 1.

#### Scenario: Unknown prefix
- **WHEN** `sessions show nope` runs and no id starts with `nope`
- **THEN** stderr is `no session starts with "nope"`, stdout is empty and the exit code is 1

#### Scenario: No prefix
- **WHEN** `sessions show` runs
- **THEN** stderr is `usage: sessions.mjs show <id-prefix>` and the exit code is 1

### Requirement: Unknown sessions subcommand
`tagents-core sessions <other>` with a subcommand that is not `recent`, `search` or `show` SHALL print the usage line `usage: sessions.mjs [recent [N] | search <words…> | show <id-prefix>]` on stdout and exit 0.

#### Scenario: Bogus subcommand
- **WHEN** `tagents-core sessions bogus` runs
- **THEN** stdout is the usage line and the exit code is 0

### Requirement: Reading transcripts stays cheap
The history verbs SHALL read only a bounded window of each transcript, never the whole file: the first 64 KiB for the opening prompt and the last 48 KiB for the last reply. A window that starts in the middle of a line drops that fragment, and lines that are not valid JSON are skipped. This keeps a listing of hundreds of multi-megabyte transcripts fast.

#### Scenario: Large transcript
- **WHEN** a transcript is several megabytes long and its last reply is in the final 48 KiB
- **THEN** `sessions show` finds the reply without reading the middle of the file

#### Scenario: Torn line
- **WHEN** the tail window begins in the middle of a JSON line
- **THEN** the fragment is ignored and the complete lines after it are used

### Requirement: Independent of plugins and locale
The text of `sessions recent`, `search` and `show` SHALL be independent of the plugins installed and of the locale, because agents read it out of a shell. The MCP tools that search sessions through the knowledge package are specified by the `knowledge` capability and are not part of this one.

#### Scenario: Locale
- **WHEN** `TAGENTS_LOCALE=ru` is set and `sessions recent` runs
- **THEN** the output is byte-identical to the output without it

### Requirement: The same bytes from either implementation
`sessions recent`, `sessions search`, `sessions show`, the bare `sessions` and the usage lines of a misspelled subcommand SHALL print the same stdout, the same stderr and exit with the same code whether the node CLI or the Rust binary serves the call, for the same transcripts, the same environment and the same clock. The cases in `packages/core/test/fixtures/sessions/` are the reference, and `tests/rust-parity.sh` runs both implementations on the same seeded home and compares every byte.

#### Scenario: The recorded cases
- **WHEN** the Rust binary runs `sessions recent`, `sessions recent 1`, `sessions search deploy`, `sessions search` for a word nobody wrote and `sessions show` of a recorded id on the seeded home
- **THEN** its stdout is the content of `recent.txt`, `recent-1.txt`, `search-deploy.txt`, `search-miss.txt` and `show.txt` of `packages/core/test/fixtures/sessions/`

#### Scenario: Awkward transcripts
- **WHEN** a transcript holds invalid UTF-8, a lone surrogate escape, a number that overflows a float or a line nested thirty thousand levels deep
- **THEN** both implementations list the same sessions and print the same bytes

#### Scenario: Awkward files
- **WHEN** a project directory is unreadable, a transcript is a symbolic link, or a modification time is before 1970
- **THEN** both implementations print the same bytes and exit with the same code
