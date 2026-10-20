# notes-hooks Specification

## Purpose
Three Claude Code hooks make the notes folder `.claude/notes/` a conversation held in files: one commits what Claude writes there, one carries what the user changed into the next prompt as a diff, and one tells a session when a notes document it just read has gone stale.

## Requirements

### Requirement: Hooks fail silent
Each of the three hooks (`notes-context.sh`, `notes-autocommit.sh`, `notes-freshness.sh`) SHALL read one JSON payload on stdin, print either one JSON object of the form `{"hookSpecificOutput":{"hookEventName":<event>,"additionalContext":<text>}}` or nothing, and always exit 0. They SHALL print nothing when `jq` or `git` is missing, when stdin is empty or not JSON, or when the payload lacks the fields they need.

#### Scenario: Garbage payload
- **WHEN** a hook is fed `not json at all`
- **THEN** it prints nothing and exits 0

### Requirement: Which folder the context and autocommit hooks act on
`notes-context.sh` and `notes-autocommit.sh` SHALL take the notes folder to be `.claude/notes` under the top level of the git repository containing the payload's `cwd`, or under `cwd` itself when it is not in a repository, and SHALL act only when that folder has a `.git` of its own.

#### Scenario: Prompt from a subdirectory
- **WHEN** a prompt is submitted with a `cwd` inside a subdirectory of the project
- **THEN** the hook reads the notes folder at the project root

#### Scenario: Project without notes
- **WHEN** the project has no notes folder or it is not a git repository
- **THEN** both hooks print nothing

### Requirement: The standing paragraph at session start
On `SessionStart`, `notes-context.sh` SHALL emit a paragraph saying that the notes folder (named by its full path) is a git-versioned notes folder, that documents for the user go there as `<name>.md` while chat replies stay in chat, that the user edits them in neovim, and that lines starting with `+` in the diffs it later receives are the user's comments to address. The event name in the output SHALL be `SessionStart`.

#### Scenario: Session starts in a project with notes
- **WHEN** a `SessionStart` payload arrives for such a project
- **THEN** the output carries the standing paragraph and the folder path

### Requirement: A session that missed the start is told once
The standing paragraph SHALL also be delivered on the first `UserPromptSubmit` of any session that has not been told yet, even when the folder has not changed, because the folder may have been created after the session began. Who has been told SHALL be remembered in `.git/ta-seen-sessions` inside the notes repository (the last 200 session ids), and a session told at `SessionStart` SHALL NOT be told again at its first prompt.

#### Scenario: Told once
- **WHEN** two prompts arrive from a session that was never told, with nothing changed in the folder
- **THEN** the first emits the standing paragraph and nothing else
- **AND** the second emits nothing

#### Scenario: Second session
- **WHEN** a different session submits a prompt
- **THEN** it is told as well, and both ids are in `ta-seen-sessions`

### Requirement: The prompt hook injects what changed since the last turn
On `UserPromptSubmit`, `notes-context.sh` SHALL compare the notes repository's `HEAD` with the commit in `.git/ta-last-seen`. When they differ and files other than the excluded ones changed, it SHALL emit the standing paragraph, the line `The notes folder changed since your last turn.`, the commit log since the marker (one `<short sha> <subject>` per commit), the diffstat, and the diff, and then set the marker to `HEAD`. Added lines arrive as `+` lines.

#### Scenario: First prompt with no marker
- **WHEN** no marker exists
- **THEN** every document in the folder is reported as added, with its content as `+` lines, and the marker becomes `HEAD`

#### Scenario: The user's own comment
- **WHEN** the user committed a line `> is this right?` to a document since the marker
- **THEN** the output carries `+> is this right?` and the commit subject
- **AND** the marker advances

#### Scenario: Nothing new
- **WHEN** `HEAD` equals the marker and the session has been told
- **THEN** the hook prints nothing

### Requirement: Only text documents are diffed
The unified diff SHALL cover only files named `*.md`, `*.txt`, `*.markdown`, `*.json`, `*.yaml` or `*.yml`; other changed files SHALL appear in the diffstat only.

#### Scenario: Binary file
- **WHEN** a user commit adds an image to the folder
- **THEN** the stat names it and the diff body does not include it

### Requirement: A marker that points nowhere means everything
When the commit named in `.git/ta-last-seen` no longer exists, the hook SHALL treat the marker as empty and report the whole folder, instead of failing.

#### Scenario: Rewritten history
- **WHEN** the marker names a commit that was amended away
- **THEN** the next prompt reports every document and writes a valid marker

### Requirement: The outbox and the archives are not replayed
`prompt.md` and everything under an `archive/` folder, at the top of the notes folder or inside any subfolder, SHALL be left out of the stat and the diff. A folder that merely contains the word, such as `notes-archive/`, SHALL be treated like any other. A change that touches only excluded paths SHALL emit nothing (apart from a pending standing paragraph) and SHALL still advance the marker.

#### Scenario: Outbox-only commit
- **WHEN** only `prompt.md` changed since the marker
- **THEN** nothing is injected and the marker equals `HEAD`

#### Scenario: Edit inside an archive
- **WHEN** only a file under `archive/` or `<ticket>/archive/` changed
- **THEN** nothing is injected and the marker advances

#### Scenario: Lookalike folder
- **WHEN** a new document sits in `notes-archive/`
- **THEN** its content is injected as usual

### Requirement: A document moved into an archive is one line
When a document was renamed into an `archive/` folder, the hook SHALL NOT report the old path as a deletion with its text as `-` lines. It SHALL list the move in the stat as `archived: <old path> => <new path>`. A document moved back out of an archive SHALL be an ordinary document again.

#### Scenario: Absorbed document
- **WHEN** `doc.md` is moved to `sub/archive/doc.md` and committed
- **THEN** the output has the line `archived: doc.md => sub/archive/doc.md` and none of the document's lines

#### Scenario: Revived document
- **WHEN** it is moved back out
- **THEN** its content arrives as `+` lines and no `archived:` line appears

### Requirement: A very large diff is replaced by its stat
When the unified diff exceeds 60000 bytes the hook SHALL replace it with the text `(diff over 60 KB — read the changed files)` and still emit the log and the stat.

#### Scenario: Pasted log
- **WHEN** a user commit adds a document of several thousand lines
- **THEN** the stat names the file, the body says the diff is over 60 KB, and no line of the file appears

### Requirement: A submitted draft is recorded as sent
When a submitted prompt contains an `@`-mention ending in `/prompt.md` that resolves (as an absolute path, relative to `cwd`, or relative to the repository root) to the notes folder's own `prompt.md`, and that file has non-blank content, the hook SHALL commit `prompt.md` with the subject `user: <first non-blank line, at most 72 characters>` (an empty commit when nothing changed) and write the new `HEAD` into `.git/ta-sent`. It SHALL NOT modify `prompt.md`.

#### Scenario: Reference submitted
- **WHEN** the prompt contains `@.claude/notes/prompt.md ` and the draft is `do the thing`
- **THEN** a commit `user: do the thing` is made and `.git/ta-sent` holds its sha
- **AND** the file is untouched

#### Scenario: Sent again
- **WHEN** the same reference is submitted again with an unchanged draft
- **THEN** another `user:` commit is recorded and `ta-sent` follows it

#### Scenario: Absolute mention from a subdirectory
- **WHEN** the mention is the absolute path of the notes folder's `prompt.md` and `cwd` is a subdirectory
- **THEN** it is a send as well

#### Scenario: Not a send
- **WHEN** the mention points at another folder's `prompt.md`, or the outbox is blank, or the prompt has no mention
- **THEN** no commit is made, `ta-sent` does not move, and no attachment sentence is added

### Requirement: A send tells the turn what the attachment is
When a send was recorded, the turn's context SHALL contain the sentence `The attached prompt.md is the user's message for this turn — follow it as the instruction.`, together with the rest of that turn's notes context, or alone when nothing else is to be said.

#### Scenario: Send without other changes
- **WHEN** a send is recorded and the folder has no other change
- **THEN** the output holds that sentence

### Requirement: Autocommit records Claude's writes
`notes-autocommit.sh`, for a `Write`, `Edit` or `MultiEdit` tool payload carrying `cwd` and `tool_input.file_path`, SHALL stage the written file, commit it with the subject `claude: <path relative to the notes folder>` when that stages a change, set `.git/ta-last-seen` to the new `HEAD`, and print nothing. A write that changed nothing on disk SHALL make no commit and leave the marker alone. It is meant to run asynchronously.

#### Scenario: Claude writes a document
- **WHEN** a document is written into the notes folder
- **THEN** one commit `claude: haiku.md` is made and the marker equals `HEAD`
- **AND** the next prompt injects nothing

#### Scenario: No-op edit
- **WHEN** an edit left the file as the repository already has it
- **THEN** no commit is made and the marker does not move

### Requirement: Autocommit ignores what is not a notes document
The hook SHALL do nothing for a file outside the notes folder (compared after resolving symlinks, with the folder path followed by a slash, so a sibling like `notes-archive/` does not count), for the top-level `prompt.md`, and for a file that does not exist.

#### Scenario: Outside the folder
- **WHEN** the written file is in the project but outside `.claude/notes/`, or in a sibling folder with the same prefix
- **THEN** no commit is made

#### Scenario: The outbox
- **WHEN** the written file is `prompt.md` in the notes folder
- **THEN** no commit is made

### Requirement: Hook commits need no git identity
`notes-context.sh` (for the `user:` commit) and `notes-autocommit.sh` SHALL fall back to the identity `tnotes <tnotes@localhost>` when the first commit attempt fails, so that a machine without a git identity still records the commit and advances the marker.

#### Scenario: No identity at all
- **WHEN** a write is committed with no global or per-repository identity
- **THEN** the commit `claude: haiku.md` exists and the marker advanced

### Requirement: Freshness fires only for a notes document that was read
`notes-freshness.sh` SHALL act only for a `Read` tool call whose `tool_input.file_path` is an existing `.md` file under a `.claude/notes/` folder (at any depth) whose notes folder has a `.git`. It SHALL stay silent for `prompt.md` and `ledger.md` (as described by the `ticket-ledger` capability) wherever they are, for other tools, for files outside a notes folder, and for documents never committed to the notes repository.

#### Scenario: Not a document
- **WHEN** the tool is `Edit`, or the file is outside a notes folder, or is `prompt.md`, or does not exist
- **THEN** the hook prints nothing

#### Scenario: Uncommitted document
- **WHEN** a document was created but never committed
- **THEN** the hook prints nothing

### Requirement: Freshness is said once per document per session
After it has spoken, the hook SHALL remember the pair of session id and document path in `.git/ta-freshness-seen` (the last 500 entries) and SHALL stay silent for the same pair afterwards. A different session, or a document that goes stale later and has not been announced, SHALL still be announced. The bookkeeping file SHALL stay inside `.git` and never show up as an untracked file.

#### Scenario: Read twice
- **WHEN** the same session reads the same stale document twice
- **THEN** the first read carries the banner and the second carries nothing

#### Scenario: Other session
- **WHEN** another session reads it
- **THEN** it gets the banner too, and is then quiet

### Requirement: A pin names the paths a document is about
A document MAY declare what it describes with lines of the form `<!-- pinned: <repo>@<sha> · <paths…> -->` at the start of a line within its first ten lines (the separator is the middle dot; the paths are optional and space-separated). `<repo>` is relative to the folder above `.claude/notes`, absolute, or starts with `~/`. The hook SHALL count, per pin, the commits in that repository after `<sha>` touching the listed paths (any path when none), and sum them.

#### Scenario: Commit inside the pinned scope
- **WHEN** a pin lists `app` and a commit after the pinned sha touched `app/reports.py`
- **THEN** the banner says `1 commits touched the paths it pins`
- **AND** it does not fall back to counting the whole repository

#### Scenario: Several repositories
- **WHEN** a document pins two repositories and three commits landed in scope across them
- **THEN** the banner says 3 and breaks the count down per repository, as `sibling 2`

#### Scenario: A pin quoted in the text
- **WHEN** the marker appears indented in a fenced example or below line ten
- **THEN** it does not count as a pin

### Requirement: The banner for moved pins
When the summed count is above zero, the hook SHALL emit `<name> was written <dd.mm>. Since then <N> commits touched the paths it pins (<repo> <n>, …). Its measurements and its reasoning hold for that date; treat its claims about current code, and any recommendation it still lists as open, as hypotheses to verify before acting on them.` with the repositories that moved listed by directory name, and the event name of the payload (default `PostToolUse`) echoed back.

#### Scenario: Banner wording
- **WHEN** a pinned scope has moved
- **THEN** the banner names the document, says when it was written, and separates measurements and reasoning that still hold from claims about current code that need checking

### Requirement: A pin that did not move is silence
When at least one pin resolves and no commit touched any pinned scope, the hook SHALL print nothing. A pin whose repository directory is missing, or whose sha is unknown to that repository, SHALL be skipped, not counted. The date `<dd.mm>` SHALL come from the notes repository's own log for the document, never from the document's text.

#### Scenario: Nothing in scope moved
- **WHEN** commits landed in the repository but none in the pinned paths
- **THEN** nothing is printed

#### Scenario: Loose pin
- **WHEN** the pinned sha no longer exists
- **THEN** no count is invented from it and the hook falls back to the unpinned rule below

### Requirement: Without a pin the surrounding repository is counted
For a document with no usable pin, when the folder above `.claude/notes` is inside a git repository, the hook SHALL count the commits in that repository since the document was last committed and, when above zero, emit `<name> was written <dd.mm>, and <N> commits have landed in <folder name> since. It pins no paths, so that counts the whole repository rather than the files it is about.` followed by the same closing sentence about hypotheses. With a count of zero it SHALL print nothing.

#### Scenario: Unpinned document
- **WHEN** two commits landed in the surrounding repository after the document was written
- **THEN** the banner says `2 commits have landed in <folder>` and that it pins no paths

#### Scenario: Quiet repository
- **WHEN** nothing has landed since
- **THEN** nothing is printed

### Requirement: Without any repository only old age is reported
For a document with no usable pin and no repository around its notes folder, the hook SHALL stay silent until the document is at least `NF_AGE_DAYS` days old (default 14; a non-numeric value means 14), and then emit `<name> was written <dd.mm>, <N> days ago, and there is no repository beside it to say whether what it describes has moved.` followed by the closing sentence about hypotheses.

#### Scenario: Old enough
- **WHEN** `NF_AGE_DAYS` is 1 and the document is older than a day
- **THEN** the banner says `days ago` and that no repository sits beside it

#### Scenario: Young enough
- **WHEN** `NF_AGE_DAYS` is larger than the document's age
- **THEN** nothing is printed

### Requirement: Freshness never edits
The freshness hook SHALL NOT change any document. Its only file is `.git/ta-freshness-seen` inside the notes repository.

#### Scenario: Document untouched
- **WHEN** a banner has been emitted for a document
- **THEN** the document's content is byte-for-byte unchanged
