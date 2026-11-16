## ADDED Requirements

### Requirement: A tag and the limit
A tag SHALL be 1 to 32 characters, the first a letter or digit and the rest letters, digits or `.` `_` `:` `/` `-`, and SHALL be stored in lower case. A session SHALL keep at most 10 tags, in `tags.tsv` of the state directory, one line per tagged session, keyed by session id and never by pane. A call with an invalid tag, or one that would leave more than 10, SHALL write nothing and exit 2.

#### Scenario: An invalid tag
- **WHEN** a call carries the tag `bad!tag` among valid ones
- **THEN** it exits 2 with a message on standard error that names the tag and the rule
- **AND** `tags.tsv` is as it was

#### Scenario: The eleventh tag
- **WHEN** a session has 10 tags and `--tags-add` is called with a new one
- **THEN** it exits 2 and `tags.tsv` is as it was
- **AND** the message gives the limit, the session id and the tags it has now, and names `--tags-set`

### Requirement: Three verbs read and write the tags
`tagents --tags K` SHALL print the tags of a session on one line separated by single spaces, `--tags-add K TAGS` SHALL add TAGS to them and print the result, and `--tags-set K TAGS` SHALL replace them, an empty TAGS clearing them. K is a session id or a pane id, which is resolved to the session its record names. TAGS is split on spaces, commas, tabs and newlines, and a duplicate is dropped. None of the three needs tmux.

#### Scenario: Adding by pane
- **WHEN** `--tags-add %12 'Proj-123,Api proj-123'` is run for a pane whose record names session `s1`
- **THEN** it prints `proj-123 api` and `tags.tsv` holds `s1` and those tags

#### Scenario: Clearing
- **WHEN** `--tags-set s1 ''` is run for a session with tags
- **THEN** it prints nothing and the line of `s1` is gone from `tags.tsv`

#### Scenario: A key that names no session
- **WHEN** the key is empty, or a pane whose record names no session, or a word with whitespace in it
- **THEN** the verb exits 2 and writes nothing

### Requirement: The search finds a session by its tags
A row of `tagents --list` whose session has tags SHALL carry, at the end of its second field, as many spaces as the list is wide and at least 300, the tags, a space and the tags in upper case, so that nothing of them is drawn and the dashboard's fzf, which runs with `--no-hscroll`, matches them. A row of a session without tags SHALL be exactly what it was, and the width of the list SHALL not depend on the tags.

#### Scenario: A query in all lower case or all upper case
- **WHEN** one of two sessions has the tag `proj-123` and the query is `proj-123` or `PROJ-123`
- **THEN** fzf keeps the row of that session and not the other

#### Scenario: A query that mixes the cases
- **WHEN** one of two sessions has the tag `proj-123` and the query is `Proj-123`
- **THEN** fzf keeps neither row, because its smart-case search is case-sensitive once the query has a capital letter

#### Scenario: An untagged row
- **WHEN** a session is tagged
- **THEN** the rows of the other sessions are byte for byte what they were before

### Requirement: The preview shows the tags
The preview of a session with tags SHALL carry the line `tags: ` and the tags, after the line with the session id, and the preview of a session without tags SHALL carry no such line.

#### Scenario: A tagged session
- **WHEN** the preview is asked for a session with the tags `proj-123 api`
- **THEN** it shows `tags: proj-123 api`

### Requirement: Only /clear drops the tags
The state hook SHALL remove the line of a session from `tags.tsv` when it receives `SessionEnd` with the reason `clear` for that session id, and SHALL keep it for every other reason and event, because a resumed or resurrected session keeps its id and returns with its tags. The file name in the hook SHALL be the one `lib/tagents/tags.sh` uses.

#### Scenario: A clear
- **WHEN** `SessionEnd` with the reason `clear` arrives for session `s1`
- **THEN** the line of `s1` is gone from `tags.tsv` and the line of another session is kept

#### Scenario: Another ending
- **WHEN** `SessionEnd` arrives for `s1` with the reason `logout`, `prompt_input_exit` or `other`
- **THEN** the line of `s1` is kept

### Requirement: A new session is told its id
The plugin's `SessionStart` hook SHALL print one line that gives the session its id and names the tool `tagents_tags_add` and the limit of 10, and SHALL print nothing and exit 0 when `$TMUX_PANE` is empty, when `$CLAUDE_CODE_ENTRYPOINT` is set to anything but `cli`, or when the hook's input names no session id.

#### Scenario: A session in a pane
- **WHEN** the hook runs with `$TMUX_PANE` set and a payload with `session_id` `s1`
- **THEN** it prints a line that holds `s1` and `tagents_tags_add`

#### Scenario: A headless run
- **WHEN** the hook runs with `CLAUDE_CODE_ENTRYPOINT=sdk-cli`
- **THEN** it prints nothing and exits 0
