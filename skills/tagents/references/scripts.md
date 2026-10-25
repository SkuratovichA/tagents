# Scripts

This file is generated from the code by `pnpm plugin:gen`. Do not edit it by hand: change the code and regenerate.

## tagents

Output of `tagents --help`:

```text
tagents — live dashboard of every Claude Code session running under tmux.

State comes from ~/.claude/hooks/tmux-agent-state.sh, which every Claude
session writes to on each hook event; this script joins that with the live
pane list and renders it through fzf. The model column comes from
~/.claude/hooks/claude-statusline.sh, registered as Claude Code's statusLine,
which is the only channel that knows which model a session is SET to.

STATES, in the order they sort. ⚠ BLOCKED means Claude asked a question and
cannot go on until it is answered. ✓ IDLE means the turn simply ended — your
move, but nothing is stuck; Claude Code also pings a notification after a
minute of silence saying exactly that, and it is folded in here rather than
given a louder state of its own. Then ● working, ○ new (opened, never used)
and ✗ closed. Only "blocked" reaches the tmux window tab, so the ⚠ there
stays worth reacting to.

  tagents                 interactive dashboard (default)
  tagents --timeline      who worked when over the last day, as bars
  tagents --list          one row per agent, for fzf reloads
  tagents --flat          same, but ungrouped regardless of the saved mode
  tagents --label K NAME  name an agent from outside; K is its session id (or
                          pane id), an empty NAME clears it back to the title
  tagents --counts        compact summary, for the tmux status bar
  tagents --preview PANE  live view of a pane, for the fzf preview window
  tagents --preview-popup PANE [STATE]
                          the same view as a modal popup, which is what ctrl-v
                          opens. This entry point is the detour the ? window
                          takes to reach it: it is itself a popup, and a popup
                          cannot open a second one, so it asks tmux to run
                          this detached instead
  tagents --sync-names    name every window after the agent living in it, once
                          (see WINDOW NAMES). The refresher and the status bar
                          both run this; it is here to be run by hand
  tagents --keys          every shortcut the dashboard binds, one
                          key<TAB>verb<TAB>what it does line each. This table
                          is what the ? window is built from, so it is also
                          the one place a new key has to be named. Every key
                          in it can be moved with a `keys:` block in the
                          config (see config.example.yaml), and this is what
                          prints where yours ended up — including a `# ` note
                          for any that could not be honoured
  tagents --closed-rows   every closed session, one TAB-separated line each:
                          sid, last activity, first seen, account, badge,
                          name, directory, and which files it was found in.
                          This is what ctrl-y's picker is built from
  tagents --resurrect-save
                          write down which chat lives in which pane — session
                          id, account, model, window — so a reboot can bring
                          it back. tmux-resurrect's save hook, every launch
                          and kill, and the status bar every resurrect.every
                          seconds (300; 0 is never) run this; it is here to
                          be run by hand before a planned reboot. A tmux
                          server younger than 5 minutes is not captured while
                          tmux-resurrect's restore hook runs tagents and has
                          not restored it yet (a by-hand run says so)
  tagents --resurrect-rows [file|latest]
                          the raw rows of a snapshot, one TAB-separated line
                          per chat: the one --resurrect would use (the newest
                          written before this tmux server started), the
                          newest of all, or that file
  tagents --resurrect [--dry-run] [--auto] [--from file|latest]
                          resume every recorded chat that is not running, in
                          its own pane on the login it ran on, with its model,
                          and the notes editor it had on screen unless
                          resurrect.notes is off. --dry-run only says what it
                          would do; --auto is what tmux-resurrect's restore
                          hook runs: once per tmux server and only in its
                          first 5 minutes, silent when resurrect.auto is
                          false, and its report goes to resurrect.log in the
                          state directory
  tagents --hidden-cols   which columns are hidden right now (see ctrl-w)
  tagents --col-rows      the picker's rows as the picker itself reads them,
                          key<TAB>the checkmark line — what ctrl-w shows you
  tagents --toggle-col KEY [PORT]
                          flip one column, which is exactly what enter in that
                          picker runs; PORT is the list's fzf listen port, so
                          the rows behind the picker redraw (empty: no reload)
  tagents --header [COLS] the key header the dashboard would draw at that
                          width. One line, which is the whole point of it
  tagents --ensure-dash   put the sidebar in the window the client is in: a running
                          list is moved there, none running is started there
  tagents --viewport      the right pane of the cockpit (dashboard.layout: cockpit),
                          started by the dashboard itself: it keeps a second client of
                          this tmux server attached to the session being shown. Anywhere
                          else it prints an error and exits 1
  tagents --follow [CLIENT]
                          move the sidebar into the window CLIENT shows (default:
                          the most recent client); tmux's own hooks run this. With
                          no list running and a sidebar wanted (a list claimed a
                          pane and was not quit with ctrl-q), it starts one there
  tagents --new [DIR] [PROFILE]
                          start an agent in DIR from outside the list — a tmux
                          binding, a shell, anything. DIR defaults to $PWD and
                          the account to whatever the rules below pick
  tagents --profile-for DIR [SESSION]
                          which account those rules pick, without launching
                          anything. Prints a profile name or "ask"; exits 1
                          when no profiles are configured
  tagents --config        the config as tagents actually reads it, one
                          path<TAB>value line per leaf. This is the answer to
                          "why is my rule not firing"; --check is the answer
                          to "why did it start logged out"
  tagents --check         what is wrong with the config, one line each: the
                          file, the key, what is wrong and what to do. A
                          profile whose config_dir is not on this machine, a
                          rule naming no profile or one that does not exist,
                          a default or usage.watch that is not a profile, a
                          usage number that is not one, a notes.send outside
                          its three words, a resurrect.* value it cannot read,
                          a key fzf does not know, and the lines the parser
                          refused. Prints nothing and exits
                          0 when nothing is wrong, exits 1 otherwise. The
                          dashboard header and the status bar count the same
                          problems (see CONFIG)
  tagents --agent-cmd PROFILE new|resume [SID]
                          the exact command string a launch on that profile
                          would run, quoting and all
  tagents update [--check]
                          move the managed copy (install.sh puts it in
                          ~/.local/share/tagents) to the newest origin/main,
                          rebuild it and rewrite the command and hook wrappers.
                          --check only says whether main has moved. Takes the
                          other install.sh options too; see install.sh --help
  tagents <verb> …        anything that is not one of the flags above — see
                          THE ECOSYSTEM

THE ECOSYSTEM. This script is the tmux half of it. The other half is
@tagents/core (packages/core) — headless sessions, the plugin host — behind
the `tagents-core` CLI, and the plugins a config names (the Telegram
orchestrator, @tagents/plugin-telegram, is the first). A VERB THIS SCRIPT DOES
NOT KNOW IS THAT HALF'S: it is handed to tagents-core with the same argv and
its exit code comes back untouched, so `tagents plugin add ./my-plugin`,
`tagents session list` and `tagents doctor` all work from here and there is
one name to type for the whole thing. tagents-core is looked for on $PATH and
then beside this script, at packages/core/dist/cli/main.js, which is where a
repo checkout has it after a build; with neither, an unknown verb says which
of the two is missing and exits 2. Everything the dashboard answers itself is
a --flag (and `update`) and is matched first, so nothing can be shadowed by
forwarding.

Agents are grouped into a tree by tmux session: a header names the session and its rows are that session's windows, whichever directory their panes are in. Every tmux session is a group, whether or not a chat has ever run in it. A window with no chat in it is a dimmed row, a session whose only window holds nothing but the sidebar is a header with no row under it, which ctrl-n, ctrl-p and ctrl-a open a window in, and a closed session with no window sits under `no window`. Groups sort by their most urgent member, so a blocked agent still floats its whole session to the top. ctrl-t (or TA_FLAT=1) switches to one flat list ordered purely by urgency.

Claude sessions have no names of their own, so each row shows that session's terminal title (what /rename sets) until you name it with ctrl-r. Names are keyed by session id, so they survive resuming and the pane being moved.

WINDOW NAMES. The dashboard is one way to find an agent; prefix+w, the status
bar and `tmux ls` are the other, and they are the ones that work when the
dashboard is not on screen. So the tmux window an agent lives in is named
after that agent — the name the list shows, which is its label when it has one
and its terminal title otherwise, never the directory (tmux automatic-rename
already names a window after what is running in it, and that name is right).
It follows a /rename or a ctrl-r within about ten seconds while the dashboard
is up, and within thirty when it is not: the status bar runs the same pass,
throttled, so this works with no dashboard at all. A window several agents
share is named after the one with the newest activity — the agent you are
actually working with names the window.

A NAME YOU TYPED IS NEVER OVERWRITTEN. A window is only ever renamed when its
current name is tmux own automatic one, or the name tagents itself gave it
last time (recorded in the window option @tagents_name). Rename a window by
hand — in tmux, not in here — and nothing above touches it again, until the
day its name coincides with one of those two. The sidebar does not stop a window being named: a window that holds the sidebar and a chat is named after the chat, and one that holds only the sidebar is never named.

Each row carries three columns joined on the session id via `tusage`: the live
context size (yellow past 200k, red past 600k — that is where every request
starts re-reading a book from cache), what the session has cost in dollars,
and the model it is set to now. A ⑂ figure appears when subagents or workflows are
what is actually spending it, and the project header totals the last five
hours. The preview breaks a session down per subagent AND per model. On a wide
enough list one more column follows: which Claude ACCOUNT the session is on,
named after the profile in the config that claims its CLAUDE_CONFIG_DIR (see
CONFIG below). It is blank for a session whose record predates that column
rather than guessed at.

THE BADGE is that same answer in the width a sidebar can always afford: one
dim character — two at the outside — immediately before the name, on every row
at every width. It is the first character of the profile name, so personal and
work read as p and w with nothing configured at all; claude.profiles.X.badge
sets it by hand where two accounts start with the same letter. A longer one is
clipped to two: the column is as wide as the widest badge configured, at every
breakpoint, so a badge that ignored the promise took the detail column off
every list. "·" is the default account when no single profile claims it, "?" a
config dir no profile knows about, and a space a record written before the
account was recorded — the column says nothing rather than guessing. No
profiles configured means no column at all, and rows byte for byte as they
were before it existed.

ANY OF THESE COLUMNS CAN GO. ctrl-w opens a small window with a checkmark per
column — badge, ctx, cost, model, acct, loc — where enter toggles the one
under the cursor and the list reloads behind it, picker still open. Hiding
`cost` takes every figure in dollars with it: the column, the ⑂ share and the
project header's /5h total. What is hidden is one key per line in
$STATE_DIR/cols, so it survives a restart, and TA_HIDE_COLS=cost,model
overrides that file for a single run. Nothing is ever reordered: the freed
width goes to the detail column, exactly as it does when the pane is narrow.

WHERE THE DOLLAR FIGURE COMES FROM. Claude Code keeps its own cost ledger and
publishes it to the status line, so for any session that is open the number
shown IS that ledger — exact, and inclusive of the requests that never reach
the transcript at all (retries, title and summary generation). settings.json
gives the status line refreshInterval: 30 for this, otherwise an idle session
never re-renders one and sits on a stale estimate exactly when you are looking
at it. A "~" prefix means the figure IS the estimate: a closed session, and
always the 5h burn and the ⑂ subagent share, which the ledger does not break
down. Do not compare a ~ figure to the status line and expect a match.

THE FALLBACK IS PRICED PER REQUEST, at the model that actually served it
— never at the model the session happens to be on now. That distinction is not
academic: a session that starts on Fable and finishes on Opus, or fans work out
to subagents on a cheaper tier, is mispriced by ~2x if you multiply its token
total by one rate. The model column is display only, and deliberately answers
a different question from the money: it is what the NEXT request will be
billed at, read from the status line, because the transcript can only say what
answered last and that lags a /model switch until you type again.
A trailing `?` means part of the session ran on a model with no published
rate, so the figure is a floor rather than the whole bill.

--timeline draws one bar per session over the last day (TA_TIMELINE_HOURS),
green while the session is still running. It reads the append-only history the
hook keeps — session starts, turn ends and session ends only, so it stays a
few lines per session rather than one per tool call.

"Running" means a Claude process really is alive in that pane, checked against
the process tree — not merely that a state file exists. Panes whose Claude has
exited are listed as closed, dimmed and sorted below everything live, and
enter restarts them with `claude --resume <id>` (see RESUME_CMD).

HEADLESS SESSIONS. A `claude -p` started by a daemon, a launchd job or a
`nohup` has no tmux pane anywhere in its ancestry, and used to be invisible
here — the state hook gave up at its pane check, so the busiest agents on the
machine were the ones you could not see. They are now recorded under their
session id (`s-<id>.tsv`) and listed in the group of the directory they were
launched in, exactly like everybody else, with "headless" where the location
column would name a pane. Liveness is the pid of their claude process, which
the hook writes into the record, so the row shows the real state — ● working,
✓ IDLE, ⚠ BLOCKED — while that process lives and sinks to a dimmed ✗ closed
when it does not; a closed one is never offered for resume, having no pane to
come back into. Nothing that acts on a pane can act on such a row, so enter,
ctrl-s, ctrl-e and ctrl-r refuse with one line. ctrl-v is the
exception and the point: it follows $TA_LOG, the log the thing that started
the session sent it to, which is that agent's only window on itself. Export
TA_LABEL (the name to show) and TA_LOG before starting one; `tagents --label
<session id> NAME` names one from outside afterwards.

CHILD SESSIONS. An agent that runs `claude -p` from its own Bash tool starts a
separate conversation with a session id of its own — and one that inherits
$TMUX_PANE, so it used to overwrite the record of the agent that spawned it on
every event and delete it on SessionEnd. Such a session is now listed UNDER
that agent, one level deeper in the tree, in its group rather than in the one
its scratch directory would put it in, with "child" where the location column
names a pane; the ⑂ count on the parent row includes it, and the group badges
count it like any other row. It is named by $TA_LABEL where it has one of its
own — a value it merely inherited names an ancestor rather than itself, so the
hook drops it, and drops an inherited $TA_LOG with it, however many
generations up the family the two came from — and otherwise by the title the
session gave itself, read out of its transcript. Nothing that needs a pane
works on it, exactly as for a headless row, and it usually has no $TA_LOG of
its own: ctrl-v and the sidebar preview show the last turns of the transcript
instead. It is never offered in the closed-session picker (ctrl-y)
— nobody can resume a conversation somebody else was having — and the
timeline marks it with a ↳. A child of an agent that is no longer on the list
falls back to a row of its own, at the top level.

CONFIG — WHICH ACCOUNT AN AGENT IS STARTED ON.
~/.config/tagents/config.yaml (or $TA_CONFIG). With no such file nothing below
happens and every agent is started exactly as it always was: a plain
`claude --dangerously-skip-permissions` with the environment inherited.

An account is a Claude Code config dir, and it is a whole login rather than a
preference: Claude derives its keychain item from the literal path, so
~/.claude-personal and ~/.claude are two independent logins that never evict
each other, and CLAUDE_CONFIG_DIR *unset* is a third thing again — not the
same as empty. That is why the config names accounts as `profiles` (a profile
with no config_dir IS the default account) and why every launch goes out as
`env -u CLAUDE_CONFIG_DIR [CLAUDE_CONFIG_DIR=…] claude …`.

The reason this exists at all: tmux runs a new-window command through /bin/sh
as a child of the tmux SERVER, so your .zshrc never runs and never gets to
choose the account from $PWD. The server has no CLAUDE_CONFIG_DIR of its own,
so before this every agent tagents started ran on the default account whatever
directory it was in. The `env` prefix is carried in the command string rather
than passed with `tmux -e` so the very same string also works when it is typed
into a shell (the resume-in-its-own-pane path), and so it bypasses any
`claude()` shell function that would re-resolve the account itself.

  claude:
    args: --dangerously-skip-permissions   # a string, or a list of arguments
    profiles:
      personal:
        config_dir: ~/.claude-personal
      work:         # no config_dir: CLAUDE_CONFIG_DIR is unset for this one
    rules:          # first match wins
      - dir: ~/git/personal                # the directory and everything under it
        profile: personal
      - session: work                      # tmux session name CONTAINS this
        profile: work
    default: ask    # when nothing matches; `ask` opens the dialog

A profile may also carry `command:` (the binary or wrapper to run), its own
`args:`, an `env:` map of extra variables, and `badge:` — the one or two
characters the row column above shows for it, which defaults to the first
character of the profile name. See config.example.yaml.

`profile: ask` — and the default `ask` — open a small fzf over the profiles
instead of guessing. ctrl-p opens it unconditionally, so an account can always
be chosen by hand whatever the rules say. RESUMING NEVER CONSULTS THE RULES:
the account a closed session comes back on is the one it actually ran on,
recorded by the state hook, because a conversation resumed on another login
simply is not there. `tagents --config` shows what tagents thinks the file
says, and `--agent-cmd` the command it would build from it.

A WRONG CONFIG SAYS SO. `tagents --check` lists what is wrong with it — the
file, the key, what is wrong and what to do — and exits 1 while anything is.
The first thing it looks for is a profile whose config_dir is not on this
machine: that is the config a shared dotfiles repo produces on every machine
but the one it was written on, and the agent it starts has nothing to log in
as, from a picker that looked fine. The dashboard header carries the count
(`config: 2 problems (tagents --check)`) for as long as it is wrong, the
status bar shows `cfg!2`, and a good config shows nothing anywhere. Unknown
keys are not problems: the file is shared across versions as well.

The dashboard is a sidebar: the list on the left of whichever window you are in. A row is a tmux window, a group is a tmux session, and there is one sidebar pane, which moves.

WINDOWS, SESSIONS AND THE SIDEBAR. enter on a row moves the sidebar into that row's window, as its leftmost full-height pane at TA_WIDTH percent of the window (default 45), and switches the client there; enter on a group header shows that session's last-used window the same way. Anything else the window holds (a shell, a dev server, a notes editor) is yours: tagents never moves, resizes or kills it, and it leaves the screen with the window and comes back with it. The widths the other panes had are remembered per window and put back when the sidebar leaves.

THE SIDEBAR FOLLOWS YOU. tmux's own switches (prefix n, prefix s, a click on the status bar) fire session-window-changed and client-session-changed, and tagents hooks both with `tagents --follow`, which moves the sidebar into the window now on screen, in whichever session that is. When the window or the session that held the sidebar is killed, the client lands elsewhere, the same hook fires and, with no list running, starts a new one there (one, however many hooks fire): a list in a pane makes a sidebar wanted, and ctrl-q ends the want, so a quit stays a quit. The follow hooks are installed with the event hooks and put back by the refresher's slow pass.

WHEREVER THE LIST IS, THAT IS THE SIDEBAR. Run it in a pane, in any window, and it claims that pane (claim_dash()); no marker gets to disagree, because a marker once drifted onto a chat in another window and enter followed the marker. The popup is the one list with no pane of its own to claim, so it brings the sidebar to the client's window with --ensure-dash before it selects a row.

JOINED CHATS, AND WINDOWS WITH NO CHAT. ctrl-s joins another chat's pane into the window on screen, to the right of its chat; the pane remembers its home session in @tagents_joined, and ctrl-u breaks it out into a window of its own. A window with no chat in it is a dimmed row, and enter on it selects the window.

CLOSING A PANE CLOSES NOTHING ELSE. There are no seats and no placeholders any more, so closing a chat's pane or window is plain tmux and prefix+x and prefix+& need no binding of tagents' own. ctrl-x on the chat that is the only pane of its window besides the sidebar moves the sidebar to the window the client lands on first, so killing a chat never takes the sidebar with it.

THE SEATS OF THE PREVIOUS VERSION. It swapped chats into seats of an agents:1 window and left a placeholder pane in each chat's home window. On the first start after the upgrade tagents sends every docked chat home, closes the placeholders, removes the old options and focus hooks and asks tnotes to bring parked editors back (migrate_seats in lib/tagents/migrate.sh); a start with nothing left to clean changes nothing, and the state it leaves is one the previous version handles. An update lands under a running list, so until that start the old focus hooks still fire: --poke and --unpark, which they call, and --undock-pane and --undock-window, which the old kill bindings call, exit 0 and do nothing. A `bind-key x … --undock-pane` line in a tmux.conf then falls through to a plain kill-pane, and a `bind-key &` line with --undock-window to a plain kill-window: both can be deleted.

Keys inside the dashboard:
  enter / dbl-click  select the agent's row: the sidebar moves into the chat's window, the client switches there and the cursor lands in the chat. On a closed session: resume it, then select it. On a dimmed window row: select the window. On a group header: show that session's last-used window
  ctrl-s             join the agent's pane into the window on screen, beside its chat: two chats side by side, both live, either closable without touching the other. A closed row is resumed first. It only works at all because the dashboard turns off terminal flow control, where ctrl-s would otherwise be XOFF and freeze the pane's output
  ctrl-g             go to the agent where it lives: switch the client to its window and select its pane. It never resumes; on a closed row it only says so
  ctrl-e             type a line straight into that agent without leaving
  ctrl-n             start a NEW agent next to the row under the cursor, with `claude --dangerously-skip-permissions` (TA_NEW_CMD). Works on a group header and on an agent row alike. The window is opened, detached, in the tmux session of the group the cursor is in and then selected like any row: the sidebar and the client move into it. On the `no window` group, and from a shell with `tagents --new`, it opens in the session that owns the project. See new_agent()
  ctrl-p             the same, but always asking which account to start it on, whatever the rules would have picked. ctrl-p is fzf's own "up", but ctrl-n (down) was already spent on "new", so the pair is at least consistent; the arrows and ctrl-j/ctrl-k still move the cursor
  ctrl-a             open a plain SHELL in a new window of the session of the group the cursor is in, on an agent row, a dimmed row and a group header alike (a session holding only the sidebar included). It starts in the row's directory, else the session's own, else home; nothing is asked. The window is created detached and then selected like any row. ctrl-a is the prefix of some tmux configurations, which would swallow it: `keys: {shell: ...}` moves it
  ctrl-r             name this agent; an empty name goes back to its title (F2 does the same, for keyboards that have an F-row; set TA_RENAME_KEY to move it somewhere else — or keys.rename in the config, like any other key here)
  ctrl-u             break a joined chat out into a window of its own, in its home session (in the session it is in when that session is gone). On a chat that is not joined it only says so
  ctrl-x             kill this agent: hang up its Claude and close its pane,
                     and its window with it when that was the pane's window.
                     Asks first, naming the agent. The session stays
                     resumable — the row turns into a closed one that enter
                     brings back — so on a row that is ALREADY closed there is
                     nothing to kill and this forgets the record instead,
                     taking the row off the list. On a dimmed window row it
                     closes the whole window with every pane in it, asking
                     first and listing what runs there; the sidebar moves out
                     of that window before it goes
  ctrl-t             toggle tree / flat
  ctrl-v             the preview in a window of its own: a popup 80% by 85%,
                     the size prefix+C-f, tsess and tneww all open at, with
                     the per-subagent cost breakdown and the tail of the
                     transcript in a pager so both can be scrolled. `q` closes
                     it. It is a snapshot — the live view of an agent is the
                     agent's own pane, one enter away.
                     In the prefix+a popup, and on a tmux with no popups at
                     all, it stays fzf's own preview beside the list instead:
                     a popup cannot open a second popup, and where the modal
                     cannot exist the old behaviour is the fallback. Those are
                     also the only two cases where the list asks fzf for a
                     --preview at all
  ctrl-l             refresh now
  ctrl-w             show or hide columns — see above. Like ? it is a key
                     taken off fzf: ctrl-w was delete-the-word-before-the-
                     cursor in the filter query, which is the second and last
                     thing spent here. The query is a project name long, so
                     backspace covers it
  ctrl-y             every session that is NOT running, however long ago it
                     was closed, under the name this dashboard knows it by —
                     the one you typed, else the one $TA_LABEL announced, else
                     its first prompt. Enter resumes the one you pick, on the
                     account it ran on and in the tmux session that owns its
                     project. The dead rows in the list itself are a different
                     thing and still expire after DEAD_TTL
  ?                  every key of this list, in a window of its own, and enter
                     RUNS the one you pick, on the row the cursor was on. That
                     is what makes it worth having over a printed list, and it
                     is why the header above the list is one line now instead
                     of four rows of a sidebar that has forty. The direct keys
                     all still work; this is a second way in, not a
                     replacement. The cost is that ? is a printable character,
                     so binding it means it can no longer be typed into the
                     filter query — the one key that is spent, deliberately.
                     keys_table() is where a new key gets its row
  ctrl-q             quit (only way out of the dedicated session — Esc and
                     ctrl-c are absorbed there so the dashboard cannot be
                     closed by accident; in the popup Esc closes it normally)

bash 3.2 compatible on purpose — macOS ships nothing newer.
```

## tusage

Output of `tusage --help`:

```text
tusage — token accounting for Claude Code, read straight from the transcripts
in ~/.claude/projects. Answers "where did my limit go", per project, per
session, per subagent.

  tusage                      summary: last 5h window, today, last 7 days
  tusage --by day|project|session|agent|model|hour
  tusage --since 5h|3d|month  window for --by (default 7d; month = since the 1st)
  tusage --until <epoch>      close the --daily window at that instant too
  tusage --calibrate <account> <amount> [--at "YYYY-MM-DD HH:MM"|<epoch>]
                              price that account at a factor that makes the
                              month-to-date equal what its own meter showed
  tusage --meter [--refresh|--force]
                              what the account's own meter says it has spent
  tusage --sessions           machine-readable per-session totals (for tagents)
  tusage --session <sid>      one session in detail
  tusage --burn               one-line status-bar string
  tusage --update             refresh the index and exit
  tusage --rebuild            throw the index away and rescan everything
  tusage --json               emit the current window as JSON
  tusage --daily              day<TAB>account<TAB>usd<TAB>reqs<TAB>unpriced

ACCOUNTS. --daily splits the bill by login. TU_ACCOUNTS is "name=dir;name=dir"
(an empty dir means ~/.claude); unset, it is the default config dir plus every
~/.claude-* that keeps a history. TU_ACCOUNT_RULES is "dir=name;dir=name" and
places the sessions no history.jsonl lists — headless -p runs write none — by
the directory they were launched in. Anything still unplaced prints as "?".

THE DOLLARS ARE AN ESTIMATE, NOT A BILL: roughly 3% under Claude Code's own
ledger on a large session and more on small ones, because retries, titles and
away summaries never reach a transcript and so are never counted.

EXCEPT FOR THE MONTH, WHICH IS THE METER. The account's own spend is one
authenticated GET away — `/api/oauth/usage`, with the OAuth token Claude Code
keeps in the keychain for the default config dir — and that figure is the one
the bill is written from. --meter reads it into meter.tsv (one row per
account, at most one fetch per account per call, TU_METER_TTL seconds apart —
900 by default, 300 past 90% of the limit), re-calibrates the per-day factor
from it, and --update refreshes it in passing, which is how the dashboard gets
it for free. TU_NO_METER=1 turns the whole thing off. The token is read into a
variable, handed to curl as one header and dropped: it is never printed,
never logged, and never written anywhere.

WHY AN INDEX. 800 MB of transcripts across ~1300 files: a full scan costs a
second and a half, which is fine once and far too slow for a dashboard that
refreshes every two seconds. So the parsed byte offset of every file is
remembered and only the tail is re-read.

WHY DEDUPE. One API response is written to the transcript once per content
block, each copy carrying the SAME usage object and the same requestId.
Summing entries naively overcounts by ~2.2x. Everything here counts unique
requestIds. Duplicates are adjacent in the file, so carrying the last few ids
across an incremental read is enough to keep the seam honest.

WHY A LOCK. That dedupe is per-process, and the index is append-only, so two
updaters running at once both start from the same offset, both parse the same
new bytes and both append them — and nothing downstream can tell, because the
facts file records totals, not ids. The dashboard refreshes on a timer and
`tusage` with no arguments updates too, so the sessions being typed into are
exactly the ones that collide. Measured on a fixture: 13 requests indexed as
21. One updater at a time, `mkdir` as the atomic primitive (macOS has no
flock); losing the race is not an error, the winner reads the same bytes.

WHY "COST UNITS". Raw token counts are not comparable: a cached read is an
order of magnitude cheaper than a fresh write, and output is several times
more expensive than input. The `cost` column normalises everything to
input-token equivalents using the published cache multipliers:

    cost = input + 1.25*cache_write_5m + 2.0*cache_write_1h
                 + 0.1*cache_read + 5*output

It is a proxy for what a request actually costs you, not a billing figure.
Raw totals are always available with --raw.

For actual money, see PRICES below: every row is priced at the model that
produced it, so a session that switched models mid-conversation — or spread
work across subagents on a cheaper tier — still totals correctly. `--sessions`
reports both, and `--session <id>` breaks a session down per subagent and per
model.

That figure is an ESTIMATE, and knowably a few percent low: it can only price
requests that reached the transcript, and Claude Code also spends on calls
that never do — retries, conversation titles, away summaries. Measured against
Claude Code own ledger on a live session: 3% under on a large one, more on a
small one where that fixed overhead weighs more. tagents prefers the ledger
(via the status line) for the headline number and uses these figures for what
the ledger cannot answer: subagent share, the 5h window, closed sessions.

bash 3.2 compatible — macOS ships nothing newer.
```

## tnotes

Output of `tnotes --help`:

```text
tnotes — a neovim pane beside a Claude pane, in the chat's own window.

  tnotes toggle <pane>        open the notes editor beside a Claude pane,
                              or move the cursor between the two when it is there
  tnotes sync                 close the editors whose chat is gone, and bring back
                              the ones an older version parked
  tnotes send <chat> <dir>    commit the notes and hand prompt.md to <chat>
  tnotes close <editor>       ask the editor to write and quit, then make sure
  tnotes editor <chat> <dir>  the program the editor pane runs (not for you)

WHAT THIS IS FOR. A one-line `read` is the wrong place to write a prompt worth
writing. This gives every Claude pane a real editor next to it, on a file that
lives with the project (<repo>/.claude/notes/prompt.md) and is committed to a
little repo of its own, so nothing you drafted is ever lost to a closed pane.

WHAT :q ACTUALLY SENDS. A reference, not the text. tnotes types
`@<notes>/prompt.md ` into the chat and stops: the CLI reads the file when the
user presses Enter, so the draft can be reopened and rewritten right up to
that moment, and nothing is ever truncated behind their back. `notes.send` in
the tagents config picks another shape for anyone who wants the old one —
`paste` puts the text in the input, `submit` pastes it and presses Enter.

WHY A SEPARATE SCRIPT AND NOT A tagents SUBCOMMAND. The editor pane runs this
program for as long as nvim is open — hours. `tagents` is read lazily by bash
while it runs, so a long-lived tagents process is a process that breaks the
moment the file is edited. This one is short and stays short.

WHY NO TAGENTS MARKER EVER. tagents decides what belongs to it by the options it puts on a pane (the sidebar's, a joined chat's) and never by position. An editor pane carries only the two options of this script, @ta_notes_for and the chat's @ta_notes, so everything of tagents's that moves, joins or closes panes passes it by, which is exactly the contract we want: it leaves us alone and we leave it alone.

WHERE THE EDITOR LIVES. The editor is an ordinary split of the chat's window. tnotes never moves it: switching rows takes the whole window, editor included, off the screen and back. toggle moves the cursor between the chat and its editor; sync only cleans up, and brings back editors an older version parked in a session called ta-notes.
```
