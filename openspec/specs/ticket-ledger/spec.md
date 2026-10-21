# ticket-ledger Specification

## Purpose
The ticket-ledger hook answers, before the first prompt of a session, which ticket the session is on and where its ledger is, keeps the machine-producible half of that ledger current, and hands the session a short pointer to it instead of the file.

## Requirements

### Requirement: Hook contract
`ticket-ledger.sh` is a `SessionStart` hook. It SHALL read one JSON payload on stdin and print either one JSON object `{"hookSpecificOutput":{"hookEventName":<event>,"additionalContext":<text>}}` (the event defaulting to `SessionStart`) or nothing, and SHALL always exit 0. It SHALL print nothing when `jq` or `git` is missing, when the payload is empty or not JSON, or when `cwd` is absent or not an existing directory.

#### Scenario: Bad input
- **WHEN** the payload is empty, not JSON, has no `cwd`, or names a directory that does not exist
- **THEN** nothing is printed and the exit status is 0

### Requirement: The ticket comes from the branch first
The hook SHALL name the session's ticket by the first match, in this order, of a ticket key in the current branch name of `cwd`; in the base name of `cwd` (a worktree directory); and in the dashboard label recorded for the session id in `labels.tsv` (tab-separated session id and label) in the agent-state directory. A ticket key is an uppercase letter followed by uppercase letters or digits, a hyphen, and digits (`<KEY>-<number>`). When none matches, the hook SHALL print nothing.

#### Scenario: Branch names the ticket
- **WHEN** the branch is `feature/<KEY>-<number>-report-editing`
- **THEN** the session is on `<KEY>-<number>`

#### Scenario: Worktree directory names it
- **WHEN** the branch carries no key but the directory name does
- **THEN** the directory's key is used

#### Scenario: Label is the last resort
- **WHEN** neither carries a key and `labels.tsv` holds a key-bearing label for the session id
- **THEN** that key is used
- **AND** for a session id with no such label nothing is printed

### Requirement: The agent-state directory
The agent-state directory the hook reads `labels.tsv` from and keeps its PR cache in SHALL be `$TA_STATE_DIR`, default `~/.claude/agent-state`.

#### Scenario: Redirected state
- **WHEN** `TA_STATE_DIR` points at another directory and no other variable is set
- **THEN** labels and the PR cache are read from and written to that directory
- **AND** nothing is created under `~/.claude/agent-state`

### Requirement: Where the ledger lives
The ledger of a ticket SHALL be `.claude/notes/<ticket>/ledger.md` under the top level of the git repository containing `cwd` (or under `cwd` itself when it is not in a repository).

#### Scenario: Ledger path
- **WHEN** the session is on a ticket in a repository
- **THEN** the context names `<repo root>/.claude/notes/<ticket>/ledger.md`

### Requirement: No ledger yet
When the ledger file does not exist, the hook SHALL emit `This session looks like <ticket>, and it has no ledger yet.` with the path where it would go and an invitation to write there a decision and its reason, an approach that was rejected, a question answered, and what is left. It SHALL NOT create the file.

#### Scenario: First session on a ticket
- **WHEN** the ticket resolves and no ledger exists
- **THEN** the context names the ledger path and mentions what is worth writing
- **AND** no file is created

### Requirement: Pointer to an existing ledger
When the ledger exists, the hook SHALL emit `This session is on <ticket>. Its ledger is <path>` with an instruction to read it before starting and to update its hand-written half before finishing.

#### Scenario: Existing ledger
- **WHEN** the ledger file exists
- **THEN** the context names the ticket and the ledger path

### Requirement: The pointer carries the open questions and the next action
The pointer SHALL append ` Open questions: <N>.` when the `## Open questions` section holds `N` (above zero) lines starting with `- `, and ` Next: <text>` made of the first three lines after the `## Next` heading, joined by single spaces. Without open bullets, or without a `## Next` section, the corresponding part SHALL be omitted.

#### Scenario: Both halves present
- **WHEN** the ledger has one bullet under `## Open questions` and `write the e2e specs` under `## Next`
- **THEN** the context holds `Open questions: 1` and `write the e2e specs`

#### Scenario: Nothing to add
- **WHEN** the ledger has no open bullets and no `## Next` section
- **THEN** the pointer carries neither part

### Requirement: Only the derived block is rewritten
When the ledger has a line starting with `<!-- derived` and a later line `<!-- /derived -->`, the hook SHALL replace everything between those two lines, keeping both marker lines, with the freshly produced block, and SHALL leave every other byte of the file alone. Running it repeatedly SHALL not duplicate the block. A ledger without both markers SHALL NOT be modified at all.

#### Scenario: Hand-written half survives
- **WHEN** the hook runs on a ledger with decisions, open questions and a next action below the block
- **THEN** the block holds the current state and the rest of the file is unchanged

#### Scenario: Repeated runs
- **WHEN** the hook runs four times in a row
- **THEN** the file holds one `## State` heading and one closing marker

#### Scenario: Hand-written ledger
- **WHEN** the ledger has no markers
- **THEN** the file is byte-for-byte unchanged and the pointer is still emitted

### Requirement: The state line
The derived block SHALL start with `## State · synced <dd.mm HH:MM>` followed by the line `worktree  <top level> — branch \`<branch>\`` (`(detached)` when there is no branch), with `, <ahead/behind text>` when the branch differs from its upstream, and always `, <N> uncommitted`, counting the changed and untracked paths (0 when clean).

#### Scenario: Dirty tree
- **WHEN** the working tree has an untracked file
- **THEN** the block says `1 uncommitted`

### Requirement: The spec line and its drift
When a directory `openspec/changes/<name>/` of the repository belongs to the ticket (its path contains the ticket lowercased, or its `proposal.md` or `tasks.md` mentions the ticket), the block SHALL add a line `spec      \`openspec/changes/<name>/\` — stage \`<stage>\`, ledger.yaml written <relative age>`, using the `stage:` value of the change's `ledger.yaml`. Without a `ledger.yaml` the line SHALL say `no ledger.yaml`. Only the first matching change is described.

#### Scenario: Current stage
- **WHEN** the change's `ledger.yaml` says `stage: applied`
- **THEN** the block names the change and ``stage `applied` ``

#### Scenario: Change moved on
- **WHEN** two more commits touched the change directory after the one that wrote `ledger.yaml`
- **THEN** the line ends in `STALE`

#### Scenario: No ledger.yaml
- **WHEN** the change directory has no `ledger.yaml`
- **THEN** the line says `no ledger.yaml`

### Requirement: Drift of the spec stage
The spec line SHALL end with ` — <N> commits to the change since, STALE` when more than one commit touched the change directory since the commit that last wrote its `ledger.yaml`, `N` being that count minus one.

#### Scenario: Quiet change
- **WHEN** no commit touched the change directory after `ledger.yaml` was written
- **THEN** the line has no `STALE` suffix

### Requirement: Pull request state comes from a cache
The block SHALL add a line `PRs       <listing>` when the file `ledger/prs.<ticket>.txt` in the agent-state directory is non-empty. The listing is `<repo>#<number> <state>` entries, lowercase state, joined by ` · `. The hook SHALL read only that cache and SHALL NOT wait for the network.

#### Scenario: Cached listing
- **WHEN** the cache holds `repo-a#77 open · repo-b#7 merged`
- **THEN** the block contains that listing

### Requirement: The cache is refreshed in the background
When `gh` is on the `PATH` and the cache file is missing or older than `TL_PR_TTL` minutes (default 15), the hook SHALL first touch the file so that a second session starting at once does not also refresh, and then, in a detached background process, search pull requests for the ticket key (up to 20) and replace the cache with the result only when the result is non-empty. A slow or failing `gh` SHALL NOT delay or fail the hook.

#### Scenario: Slow gh
- **WHEN** the cache is stale and `gh` sleeps for 30 seconds
- **THEN** the hook still finishes within a few seconds

#### Scenario: Failing gh
- **WHEN** `gh` fails or prints nothing
- **THEN** the previous cache content is kept
