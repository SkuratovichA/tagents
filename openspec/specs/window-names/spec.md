# window-names Specification

## Purpose
A tmux window that holds an agent is named after that agent, so `prefix+w`, the status bar and `tmux ls` identify chats even when the dashboard is not on screen. This capability covers the naming rule, the sweep that applies it, the agent labels that override titles, and the rename dialog.

## Requirements

### Requirement: A window is named after its agent
The sweep SHALL rename a window that holds a live agent to that agent's display name: the label given with ctrl-r or `tagents --label` when there is one, otherwise the pane's terminal title (what Claude's `/rename` sets) without its leading glyph. It SHALL NOT use the directory name. An agent with no label whose title is only the machine's host name, short or full, or is empty, has no name to give and SHALL leave its window alone, claiming nothing.

#### Scenario: A new agent
- **WHEN** an agent whose title is `fix-login-bugs` lives alone in a window with tmux's automatic name and a sweep runs
- **THEN** the window is named `fix-login-bugs` and `automatic-rename` is off for it
- **AND** the window option `@tagents_name` records `fix-login-bugs`

#### Scenario: The title is the host name
- **WHEN** an agent's title is the machine's host name and a sweep runs
- **THEN** its window keeps the name it had and `@tagents_name` stays unset

#### Scenario: A window with no agent
- **WHEN** a window holds only shells
- **THEN** a sweep does not rename it

### Requirement: The leading glyph is not part of the name
The terminal title Claude sets starts with a spinner glyph. A leading token SHALL be dropped, together with the spaces after it, only when it is exactly one character and that character is a symbol: an ASCII character that is not a letter or digit, a character in U+2000 to U+2BFF, or a character in U+1F000 to U+1FFFF. Any other first token SHALL be kept. Rows, window names, dialogs and the preview heading SHALL apply this one rule.

#### Scenario: The spinner glyph
- **WHEN** the title is `✳ fix-login-bugs busy`
- **THEN** the window is named `fix-login-bugs busy`

#### Scenario: A Cyrillic title
- **WHEN** the title is `два слова`
- **THEN** the window is named `два слова`, and with `✳ ` in front the name is still `два слова`

#### Scenario: A one-letter non-ASCII first word
- **WHEN** the title is `я иду`
- **THEN** the window is named `я иду`, and with `✳ ` in front the name is still `я иду`

#### Scenario: A braille or emoji glyph
- **WHEN** the title is `⠂ fix-login-bugs` or `🚀 launch`
- **THEN** the window is named `fix-login-bugs` or `launch`

#### Scenario: Other single characters are words
- **WHEN** the title is `中 文`, `é bon` or `a b`
- **THEN** the window name keeps the whole title

### Requirement: The newest agent names a shared window
When a window holds several agents, the one with the newest state timestamp SHALL name it, with ties broken by the lowest pane index. A pane with no state record SHALL rank below every pane that has one. Shells and other panes with no name to give are never candidates.

#### Scenario: Two agents
- **WHEN** one agent in a window has a state timestamp ten minutes old and another one minute old
- **THEN** the window is named after the newer one
- **AND** when the older agent is worked in, the name is handed over to it

#### Scenario: A tie
- **WHEN** both agents have the same timestamp
- **THEN** the one in the leftmost pane names the window

#### Scenario: A shell beside the agent
- **WHEN** an agent shares its window with a shell whose title is the host name
- **THEN** the agent names the window

### Requirement: A name a person typed is never overwritten
The sweep SHALL rename a window only when the window's current name is tmux's automatic name (`automatic-rename` on) or equals the name tagents gave it last time, which is recorded in the window option `@tagents_name`. A window renamed by hand SHALL be left alone even when the agent's title changes afterwards, until its name again equals the recorded name or tmux takes the window back.

#### Scenario: Renamed by hand
- **WHEN** the user renames an agent's window with tmux and the agent's title then changes
- **THEN** a sweep leaves the hand-typed name

#### Scenario: Back to the recorded name
- **WHEN** the user renames the window back to the name recorded in `@tagents_name`
- **THEN** the next sweep names it after the agent again

### Requirement: The decision is checked again before it is applied
Just before each rename the sweep SHALL ask tmux again whether the window is still automatic or still carries the recorded name, and SHALL skip the window if neither holds or if it already has the target name, so a hand rename that lands while the sweep is working is not overwritten and not claimed.

#### Scenario: A hand rename during the sweep
- **WHEN** the user renames a window while a sweep is between planning and applying
- **THEN** the window keeps the hand-typed name and `@tagents_name` is not changed

### Requirement: The title follows /rename
A change of the agent's title, such as a Claude `/rename`, SHALL show in the window name on the next sweep without any other action, as long as no label overrides it.

#### Scenario: A new title
- **WHEN** the agent's title changes
- **THEN** the window keeps its name until the next sweep
- **AND** the next sweep renames it to the new title

### Requirement: What the sweep never names
The sweep SHALL leave out the dashboard's own window, any window in which a list is running (the pid in `@tagents_list` is alive), and every docked chat, identified by its `@tagents_docked` marker. A docked chat names no window. Once a list is gone, its window is an ordinary window again.

#### Scenario: A docked agent
- **WHEN** an agent is docked in the dashboard window
- **THEN** the dashboard window keeps its name

#### Scenario: A window with a list
- **WHEN** a window holds a pane with a live `@tagents_list` claim
- **THEN** the sweep does not rename it, and renames it once the claim is removed

### Requirement: A name is a name, not a tmux format
Whatever name is applied SHALL reach the window exactly as written: a `#` is literal and a name that starts with `-` is not a flag. `@tagents_name` SHALL record the name the window actually has afterwards, and a rename that fails SHALL record nothing, so the sweep keeps recognising its own names.

#### Scenario: A hash in the title
- **WHEN** the title is `Deploy #Staging pipeline`
- **THEN** the window is named `Deploy #Staging pipeline`, `@tagents_name` equals the window name, and a second sweep changes nothing
- **AND** a later clean title still renames the window

#### Scenario: A leading dash
- **WHEN** the title is `-wip refactor`
- **THEN** the window is named `-wip refactor`, and the next title still gets through

### Requirement: The one-shot sweep
`tagents --sync-names` SHALL run one sweep immediately, print nothing and exit 0. It is the same sweep the refresher and the status bar run.

#### Scenario: By hand
- **WHEN** `tagents --sync-names` runs twice in a row
- **THEN** the second pass changes nothing

### Requirement: The sweep runs with or without a dashboard
While a list is up, its refresher SHALL run the sweep on its slow pass, the first wake at least `TA_REFRESH_SLOW` seconds after the last one, and at the idle timeout when nothing rings. The status bar's `tagents --counts` SHALL also start a sweep in the background, throttled by the stamp file `.names.ts` in the state directory to one pass per `TA_NAMES_EVERY` seconds, 30 by default, with `0` meaning every call. The `--counts` exit status SHALL NOT depend on the sweep.

#### Scenario: No dashboard at all
- **WHEN** only `tagents --counts` is run and an agent has a title
- **THEN** its window is named after the agent shortly afterwards, and `--counts` exits 0

#### Scenario: Throttled
- **WHEN** the title changes and `--counts` is run again inside the interval
- **THEN** the window name does not change
- **AND** once `.names.ts` is older than the interval, the next `--counts` renames it

### Requirement: The label file
A label SHALL be stored in `labels.tsv` in the state directory as one line `<key><TAB><name>`, where the key is the session id, or the pane id for a session that has no id yet. Setting a label replaces any earlier line of that key, and an empty name removes the key. A label SHALL win over the terminal title for the row and for the window name. Setting a label inside tmux SHALL ring the refresher's channel, so that the list draws the new name without waiting.

#### Scenario: A label rings the list
- **WHEN** a label is set from inside tmux
- **THEN** the global option `@tagents_evgen` goes up by one

#### Scenario: A label beats a title
- **WHEN** an agent has the label `named-by-hand` and a different terminal title
- **THEN** a sweep leaves the window named `named-by-hand`

### Requirement: Naming an agent from outside
`tagents --label KEY [NAME]` SHALL store the label for KEY, a session id or a pane id, and SHALL rename the agent's window at once, including a window it shares with other panes, then exit 0. With no KEY it SHALL print a usage error on stderr and exit 2. A docked agent's rename SHALL NOT rename the dashboard window. An empty NAME SHALL remove the label, turn `automatic-rename` back on for the window and drop `@tagents_name`, so the sweep names the window from the titles again.

#### Scenario: A label renames at once
- **WHEN** `tagents --label sid-e named-by-hand` is run for an agent in a window
- **THEN** the window is named `named-by-hand` and `@tagents_name` records it
- **AND** a later sweep keeps that name

#### Scenario: A shared window
- **WHEN** an agent that shares its window with another agent is labelled
- **THEN** the window takes the label

#### Scenario: A name with a hash
- **WHEN** the label is `ticket #Sup-42`
- **THEN** the window is named exactly that and `@tagents_name` equals it

#### Scenario: An empty name
- **WHEN** the label of the agent is cleared with an empty NAME
- **THEN** `automatic-rename` is on for its window and `@tagents_name` is unset
- **AND** the next sweep names it after the newest agent in it

#### Scenario: A docked agent
- **WHEN** `--label` names an agent that is docked in the dashboard window
- **THEN** the dashboard window keeps its name

### Requirement: The rename dialog starts from the current name
The rename dialog behind ctrl-r SHALL open with the line already holding the agent's current label, or, when it has none, the name the row shows, so a rename is an edit rather than a retyping. Esc SHALL leave the label as it was, and an empty line SHALL clear it. Without a terminal the dialog SHALL read one line from stdin, waiting at most 300 seconds. The key binding itself belongs to the `dashboard-keys` capability.

#### Scenario: Seeded with the label
- **WHEN** an agent has the label `current name` and the dialog opens
- **THEN** the input line starts as `current name`

#### Scenario: Seeded with the displayed name
- **WHEN** the agent has no label
- **THEN** the input line starts as the name on its row, not empty

#### Scenario: Esc
- **WHEN** the dialog is cancelled with Esc
- **THEN** the label is unchanged
