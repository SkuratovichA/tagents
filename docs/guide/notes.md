# Notes workspace

A chat is a bad place to review a document. `.claude/notes/` is where the long-form output goes instead: Claude writes `<name>.md` files there, you open them in neovim, and what you type back reaches the session on your next prompt. Chat replies stay in chat; only documents go to the folder.

There is one folder per project, next to `.claude/settings.local.json`. It is a git repository of its own, and that is the whole mechanism.

## The editor beside your chat

`prefix + C-t` toggles the editor ("text"). It opens beside the Claude pane it was called from, on the notes folder of that pane's project, so it doubles as the place to write a long prompt without fighting the terminal's line editing.

The editor is an ordinary split of the chat's window, beside the chat and beside whatever else the window holds. Closing it gives the width back. `ta-notes` only matters to editors an older version parked there, which `tnotes sync` brings back beside their chats once.

### Sending the draft

`:q` commits the draft and leaves `@.claude/notes/prompt.md ` in the chat's input. **You** press Enter, and the CLI reads the file at that moment. Until you do, `prefix + C-t` reopens the draft and whatever you change is what gets sent.

- **Other documents come along.** Every other document in the folder that you changed since the session last saw it is mentioned right beside it (`@.claude/notes/review.md `), so a remark you left under a paragraph arrives with the whole file around it, not only as a `+` line in the diff.
- **"Since the session last saw it"** is the context hook's own marker, so the two agree. A document you annotate *after* the first `:q` is added to the line, and nothing is mentioned twice.
- **What is never mentioned**: anything under an `archive/` folder (see below), and a document that is gone.
- **Nothing is truncated** on the way out.
- **The file is cleared for you** the next time the editor opens *after* it was actually sent. The submit hook commits it as `user: <first line>` and records the sha in `.git/ta-sent`, and the editor starts blank only when the file still matches that commit.

### Other shapes

The `notes.send` leaf in the tagents config picks a different shape. Absent or unrecognised means `reference`.

| `notes.send` | what `:q` does |
|--------------|----------------|
| `reference` (default) | types `@.claude/notes/prompt.md ` into the chat and stops |
| `paste` | puts the text itself in the input, without pressing Enter. Only the draft is sent, with no other documents mentioned |
| `submit` | the original behaviour: paste, Enter, and clear the file at once. Only the draft is sent |

To point the session at one document in particular, reference it from `prompt.md` as `@.claude/notes/<file>`. The mention attaches the file, no completion needed; `@`-completion does not offer paths inside a dot-directory, and does not have to. Usually you do not need it at all, since the diff already carries what changed.

## How your remarks reach Claude

The folder is a git repo of its own:

- **Claude's writes are committed for it.** `notes-autocommit.sh`, on `PostToolUse`, commits each file as `claude: <file>`, and the marker `.git/ta-last-seen` moves with them.
- **Your edits are not**, until you commit them or `tnotes` does. On the next prompt `notes-context.sh` injects everything since the marker: the commit log, the diffstat, and the unified diff of the text files. Lines you added arrive as `+` lines and are read as your comments, so `> is this right?` on the line under a paragraph is a review remark, in place, with no quoting and no re-reading of the file.
- **`prompt.md` is excluded** from all of it, since it was already delivered as a prompt. A diff over 60 KB is replaced by its stat with a note to open the files.

### The archive folder

An `archive/` folder is out of the prompt. It can sit at the top of the notes or inside a ticket's folder (`PROJ-1234/archive/`). A document whose conclusions have landed goes there to keep its reasoning without re-entering every turn.

- Nothing under it is diffed or mentioned, and a change made only inside one injects nothing.
- A document you move into one arrives as a single line (`archived: plan.md => PROJ-1234/archive/plan.md`) rather than as its whole text deleted.
- A folder that merely contains the word (`notes-archive/`) is a folder like any other.

### Keeping notes out of the project's history

The folder is ignored globally (`**/.claude/notes/` in `.gitignore_global`), so notes never land in the project's own history.

## Registering the hooks

Like the state hook, these are registered in Claude Code's `settings.json`. The installer puts their wrappers next to the state hook's.

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "sh \"$HOME/.claude/hooks/notes-context.sh\"" }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "sh \"$HOME/.claude/hooks/notes-context.sh\"" }] }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [{ "type": "command", "command": "sh \"$HOME/.claude/hooks/notes-autocommit.sh\"", "async": true }]
      }
    ]
  }
}
```

The two other hooks in the same folder are optional: `notes-freshness.sh` (on `PostToolUse` with the matcher `Read`) tells the reader when a notes document was written, and `ticket-ledger.sh` (on `SessionStart`) hands the session a pointer to its ticket's ledger.

## The `tnotes` command

`tnotes` is the command behind the key. Run it with no arguments for the usage text.

| command | what it does |
|---------|--------------|
| `tnotes toggle <pane>` | opens the editor beside a Claude pane, or hides it again when it is already there. This is what the key's binding runs |
| `tnotes sync` | closes the editors whose chat is gone, brings back the editors an older version parked in `ta-notes`, and cleans up after them. It takes no pane |
| `tnotes send <chat> <dir>` | commits the notes and hands `prompt.md` to the chat, as a reference, a paste or a submitted paste (see `notes.send`) |
| `tnotes close <editor>` | asks the editor to write and quit, then makes sure it did |
| `tnotes editor <chat> <dir>` | the program the editor pane runs; not for you |
