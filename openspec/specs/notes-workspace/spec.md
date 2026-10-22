# notes-workspace Specification

## Purpose
`tnotes` gives every Claude chat a real editor beside it, on a prompt file that lives with the project in `.claude/notes/` (a git repository of its own), and hands what was written back to the chat. The editor is a split of the chat's window and goes off the screen and comes back with it; `sync` only cleans up.

## Requirements

### Requirement: Command surface
`tnotes` SHALL accept the verbs `toggle <pane>`, `sync`, `send <chat> <dir>`, `close <editor>` and `editor <chat> <dir>`. `sync` takes no pane, and a pane given to it, as an older focus hook passed one, is ignored. Run with no argument, or with `-h` or `--help`, it SHALL print its usage text and exit 0. Any other first argument SHALL print `tnotes: unknown command <word>` on stderr and exit 2.

#### Scenario: Unknown verb
- **WHEN** `tnotes frobnicate` is run
- **THEN** stderr says `tnotes: unknown command frobnicate`
- **AND** the exit status is 2

#### Scenario: Missing arguments
- **WHEN** `tnotes send` or `tnotes editor` is run without both a chat and a directory
- **THEN** stderr says `tnotes: send <chat> <dir>` or `tnotes: editor <chat> <dir>` respectively
- **AND** the exit status is 2

#### Scenario: An old hook's argument
- **WHEN** `tnotes sync %5` is run
- **THEN** it behaves as `tnotes sync` and exits 0

### Requirement: Errors are shown where the user is looking
When `tnotes` fails for a reason the user should see, it SHALL show `tnotes: <message>` as a tmux status message, fall back to stderr when no tmux client can show it, and exit 1.

#### Scenario: Toggle without a pane
- **WHEN** `tnotes toggle` is run with no pane
- **THEN** the message `tnotes: toggle needs a pane` is shown
- **AND** the exit status is 1

#### Scenario: Toggle on a pane that no longer exists
- **WHEN** `tnotes toggle %99` is run and no such pane exists
- **THEN** the message `tnotes: %99 is gone` is shown
- **AND** the exit status is 1

### Requirement: What counts as a Claude pane
A pane SHALL be treated as a chat when the command it is running starts with `claude`, or is a bare version number of the form `N.N.N` (the way the installed CLI reports itself), or when the agent-state directory holds a record for it (`<pane number>.tsv` in `$TA_STATE_DIR`, default `~/.claude/agent-state`). A pane running a shell or any other program, with no such record, SHALL NOT be treated as a chat.

#### Scenario: Version-number command
- **WHEN** a pane's running command is `2.1.261` and it has no state record
- **THEN** `tnotes toggle` on it opens an editor and `tnotes send` types into it

#### Scenario: Non-chat pane refused
- **WHEN** `tnotes toggle` is run on a pane running a plain program
- **THEN** the message `tnotes: not a Claude pane` is shown and the exit status is 1
- **AND** no pane is split off it and it receives no `@ta_notes` option

### Requirement: Where the notes folder lives
The notes folder for a chat SHALL be `.claude/notes` under the top level of the git repository containing the chat's current directory, or under the chat's current directory itself when that is not inside a repository. Opening an editor SHALL create the folder if needed, initialise it as a git repository of its own when it has no `.git`, and create an empty `prompt.md` when none exists.

#### Scenario: First editor in a project
- **WHEN** an editor is opened beside a chat whose directory is inside a project that has no notes folder
- **THEN** `<project root>/.claude/notes/` exists, is a git repository, and holds an empty `prompt.md`

#### Scenario: Chat started in a subdirectory
- **WHEN** the chat's current directory is a subdirectory of the repository
- **THEN** the notes folder is still the one at the repository root

### Requirement: Toggle opens an editor beside the chat
`tnotes toggle <pane>` on a chat that has no editor SHALL split the chat's window horizontally, giving the new editor pane 45 percent of the chat pane's width, start the editor program in the notes folder, and leave the cursor where it was. The editor is an ordinary pane of that window: tnotes SHALL NOT move it afterwards, so it leaves the screen with its window when another row is selected and is there again when the row is selected again.

#### Scenario: First toggle
- **WHEN** `tnotes toggle` is run on a chat with no editor
- **THEN** the chat's window holds the editor as a second pane, beside the chat

#### Scenario: Seats are unaffected
- **WHEN** editors are opened and closed
- **THEN** panes that are not chats or editors stay in their windows, and the sidebar and the user's own panes are not moved by `tnotes`

#### Scenario: Another row selected
- **WHEN** the user selects another row of the dashboard and then selects the chat's row again
- **THEN** the editor is the same pane, still beside the chat, with the width it had

### Requirement: Editor and chat name each other
After an editor is created the chat pane SHALL carry the option `@ta_notes` naming the editor pane, and the editor pane SHALL carry `@ta_notes_for` naming the chat.

#### Scenario: Markers after the first toggle
- **WHEN** an editor has just been created
- **THEN** the chat's `@ta_notes` is the editor's pane id and the editor's `@ta_notes_for` is the chat's pane id

### Requirement: Toggle moves the cursor between the chat and its editor
`tnotes toggle <pane>` on a chat whose editor exists SHALL move the cursor into the editor, selecting the editor's window first when it is not the one on screen, and SHALL move the cursor back into the chat when it is already in the editor. It SHALL NOT hide, move or close the editor. This SHALL be the only operation that moves the cursor into an editor.

#### Scenario: Toggle twice
- **WHEN** `tnotes toggle` is run on a chat with an editor beside it and the cursor is in the chat
- **THEN** the cursor is in the editor and the editor has not moved
- **WHEN** it is run again
- **THEN** the cursor is in the chat

### Requirement: Sync only cleans up
`tnotes sync` SHALL NOT move, hide or split any editor of a living chat. It SHALL close editors whose chat pane no longer exists (see the next requirement), bring back editors parked by an older version, and exit 0.

#### Scenario: The backstop changes nothing
- **WHEN** `tnotes sync` is run twice with every editor beside its chat
- **THEN** every editor stays where it was and is alive

### Requirement: Orphaned editors are closed
`tnotes sync` SHALL close every editor whose chat pane is gone.

#### Scenario: Chat killed
- **WHEN** a chat with an editor is killed and `tnotes sync` runs
- **THEN** the editor pane is gone

### Requirement: One layout move at a time
`toggle` and `sync` SHALL serialise through a lock directory `.tnotes.lock` in the agent-state directory (`$TA_STATE_DIR`, default `~/.claude/agent-state`). A lock older than five seconds SHALL be taken over. `sync` that cannot get the lock within about three seconds SHALL give up silently with exit 0; `toggle` SHALL fail with `tnotes: another tnotes is moving panes; try again`.

#### Scenario: Lock held
- **WHEN** another `tnotes` holds a fresh lock for longer than `toggle` waits
- **THEN** `toggle` shows `tnotes: another tnotes is moving panes; try again` and exits 1

### Requirement: The editor program
`tnotes editor <chat> <dir>`, the program the editor pane runs, SHALL open `nvim` on `prompt.md` in `<dir>` with every buffer written automatically when focus or the buffer is left, so that the file on disk is current at all times. When `nvim` exits it SHALL run `send` for the chat, then remove the chat's `@ta_notes` option, and exit 0.

#### Scenario: Quit sends and unlinks
- **WHEN** the user writes a draft and quits the editor
- **THEN** the draft is committed, a reference is left in the chat's input (see the `send` requirements)
- **AND** the editor pane is gone, the chat's `@ta_notes` is unset, and the chat's window no longer holds the editor

#### Scenario: No nvim
- **WHEN** the editor program starts and `nvim` is not on the `PATH`
- **THEN** it reports that on stderr, waits five seconds, and sends nothing
- **AND** the chat's `@ta_notes` is still cleared

#### Scenario: Folder gone
- **WHEN** `<dir>` does not exist when the editor program starts
- **THEN** it prints `tnotes: <dir> is gone` on stderr, waits five seconds and exits 1

### Requirement: A sent draft starts the next page blank
When the editor program starts and `<dir>/.git/ta-sent` names a commit (written by the `notes-hooks` capability when a prompt is submitted) whose copy of `prompt.md` is byte-for-byte the file on disk, it SHALL empty `prompt.md` before opening `nvim`. A draft that differs from that commit, or no `ta-sent` file, SHALL leave the file as it is.

#### Scenario: Sent draft
- **WHEN** `prompt.md` equals its content in the commit named by `ta-sent` and the editor starts
- **THEN** `nvim` opens on an empty file and the file on disk is empty

#### Scenario: Edited after the send
- **WHEN** `prompt.md` was changed after the sent commit, or was never sent
- **THEN** the editor opens on the draft unchanged

### Requirement: Every send commits the notes first
`tnotes send <chat> <dir>` SHALL first commit everything in the notes folder, whether or not the draft is then sent. The commit subject SHALL be the first non-blank line of `prompt.md` with leading whitespace removed, cut to 72 characters, or `notes: edits` when the draft is blank. Nothing to commit SHALL mean no commit.

#### Scenario: Draft committed under its first line
- **WHEN** the editor quits on a draft whose first line is `hello`
- **THEN** the notes repository has a commit with subject `hello`

#### Scenario: Cleared outbox is no edit
- **WHEN** `prompt.md` was emptied after a send and nothing else changed
- **THEN** `tnotes send` makes no commit, and the emptying is left for the next real draft to carry

### Requirement: Notes commits need no git identity
When the user's git has no identity to commit with, `tnotes` SHALL commit as `tnotes <tnotes@localhost>` instead of losing the draft, because the notes repository is never pushed.

#### Scenario: No identity configured
- **WHEN** the notes folder is committed on a machine with no `user.name`
- **THEN** the commit exists with author name `tnotes`

### Requirement: A draft is never typed into a shell
`tnotes send` SHALL type into the chat only when the pane's own running command is a Claude command as defined above; a state record alone SHALL NOT be enough. Otherwise it SHALL show `tnotes: <chat> is not running claude — prompt kept`, exit 1, and leave `prompt.md` as it is (the notes are still committed). With a blank draft, the text-sending shapes SHALL do nothing and exit 0.

#### Scenario: Chat pane now holds a shell
- **WHEN** `tnotes send` targets a pane that is not running Claude
- **THEN** the exit status is 1 and `prompt.md` is unchanged
- **AND** the draft was committed under its first line

### Requirement: Send shape comes from notes.send
The shape of a send SHALL be read from the config key `notes.send` as `tagents --config` reports it: `reference`, `paste` or `submit`. An absent key or any other value SHALL mean `reference`.

#### Scenario: Unknown value
- **WHEN** `notes.send` is `sideways`
- **THEN** `tnotes send` behaves as `reference`

### Requirement: The reference shape types a mention and stops
In the `reference` shape, `tnotes send` SHALL type `@<path>/prompt.md ` (with a trailing space) into the chat's input without pressing Enter, and SHALL NOT clear or alter `prompt.md`. `<path>` SHALL be the notes folder relative to the chat's current directory (for example `.claude/notes`) when the folder is under it, and the absolute folder path otherwise. Nothing SHALL be typed for a blank draft.

#### Scenario: Quit leaves a reference
- **WHEN** the editor quits on a non-blank draft
- **THEN** the chat's input shows `@.claude/notes/prompt.md` and nothing was submitted
- **AND** the draft is still on disk for the CLI to read

### Requirement: Changed documents are mentioned beside the draft
In the `reference` shape, `tnotes send` SHALL also type a mention `@<path>/<file> ` for every document committed in the notes folder after the commit in `.git/ta-last-seen`, or for every tracked document when that marker is missing or names no commit. At most eight documents SHALL be mentioned, and with a blank draft the documents SHALL be typed alone. The `paste` and `submit` shapes SHALL NOT add mentions.

#### Scenario: Document without a draft
- **WHEN** a document was changed after the marker, `prompt.md` is blank, and `tnotes send` runs
- **THEN** that document is mentioned and the empty draft is not
- **AND** a document at or before the marker is not mentioned

#### Scenario: Archived and deleted documents
- **WHEN** documents sit in `archive/`, in `<ticket>/archive/`, were moved into an archive, or were deleted
- **THEN** none of them is mentioned, and a live document is

### Requirement: What is never mentioned
The mentions of the previous requirement SHALL skip `prompt.md`, anything under an `archive/` folder at the top of the notes folder or inside any subfolder (a folder that merely contains the word, such as `notes-archive/`, is not one), documents that no longer exist (a document moved into an archive counts as such), and paths containing whitespace. This is the same line the `notes-hooks` context hook draws for the diff it injects.

#### Scenario: Lookalike folder
- **WHEN** a changed document sits in `notes-archive/`
- **THEN** it is mentioned like any other document

### Requirement: Mentions are never typed twice
Before typing in the `reference` shape, `tnotes send` SHALL read the input box of the chat from its screen, that is the rows between the horizontal rules around the cursor, with a mention cut by a wrap rejoined, and SHALL type only the mentions not already there. When nothing is left to type it SHALL type nothing and exit 0.

#### Scenario: Second quit before pressing Enter
- **WHEN** the editor is reopened and quit again before the first reference was submitted
- **THEN** the input still holds exactly one mention of the draft and one of each document

#### Scenario: Narrow pane
- **WHEN** the chat is narrow enough that the mentions wrap over several rows
- **THEN** a second send still adds nothing

### Requirement: The paste shape
In the `paste` shape, `tnotes send` SHALL paste the text of `prompt.md` into the chat as one bracketed paste, so that a multi-line draft is a single input, without pressing Enter and keeping the file.

#### Scenario: Paste
- **WHEN** `notes.send` is `paste` and the draft is `paste me`
- **THEN** the input shows `paste me`, nothing was submitted, and `prompt.md` still holds the draft

### Requirement: The submit shape
In the `submit` shape, `tnotes send` SHALL paste the draft as above, press Enter after a short pause, and empty `prompt.md` at once.

#### Scenario: Submit
- **WHEN** `notes.send` is `submit` and the draft is `submit me`
- **THEN** the chat receives `submit me` and Enter
- **AND** `prompt.md` is empty

### Requirement: Close asks the editor to save first
`tnotes close <editor>` SHALL send the editor `Escape`, `:wqa` and Enter, wait up to about two seconds for the pane to end, and kill the pane if it is still alive, then remove `@ta_notes` from the chat if that pane still exists. With no argument it SHALL do nothing.

#### Scenario: Unsaved buffer
- **WHEN** an editor with unsaved changes is closed by `tnotes close`
- **THEN** the changes are written to `prompt.md` before the pane goes

### Requirement: Other panes are left alone
`tnotes` SHALL NOT move, split, join or kill any pane that is neither a chat it was asked about nor one of its own editors, and SHALL NOT move an editor after creating it. Its editors are ordinary panes of the chat's window, which the dashboard's selecting, following and joining of rows never move.

#### Scenario: Surrounding windows
- **WHEN** editors are opened and closed
- **THEN** every other pane is alive in the window it started in, and a window holding only a non-chat pane still has that one pane

### Requirement: Editors parked by an older version come back
`tnotes sync` SHALL, when a session named `ta-notes` exists, bring every editor parked in it back beside its chat as a split of the chat's window, given the share of the chat's width recorded in the editor's `@ta_notes_pct` when that is between 10 and 90 and 45 percent otherwise, and leave the cursor where it was. It SHALL do nothing when there is no such session.

#### Scenario: A parked editor
- **WHEN** an editor was parked in `ta-notes` by an older version and `tnotes sync` runs
- **THEN** the editor is a pane of its chat's window and `@ta_notes` still names it

#### Scenario: Nothing parked
- **WHEN** there is no `ta-notes` session
- **THEN** `tnotes sync` changes nothing

### Requirement: The parking session is wound up
`tnotes sync` SHALL close a parked editor whose chat pane is gone, unset `@ta_notes_pct`, `@ta_notes_open` and the global `@ta_notes_any`, and end the `ta-notes` session once no editor is left in it.

#### Scenario: The chat is gone
- **WHEN** the chat of a parked editor no longer exists
- **THEN** the editor is closed and the `ta-notes` session is gone
