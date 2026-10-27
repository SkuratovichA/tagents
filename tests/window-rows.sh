#!/usr/bin/env bash
#
# tests/window-rows.sh — a row is a tmux window: selecting rows with no cockpit up, joined chats, the list of sessions and windows,
# tnotes beside a chat, resurrect, the migration from seats, and the panes that belong to the user. What the cockpit does with a
# selection is tests/cockpit.sh's.
#
# NOTHING HERE MAY TOUCH THE DEFAULT TMUX SOCKET. The server is `tmux -L tatest-$$ -f /dev/null`, torn down in the trap, and tagents is
# pointed at it by exporting $TMUX in the test process (`run`) — never by a `tmux` shim on $PATH. Run as
#   env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$(mktemp -d)" bash tests/window-rows.sh
#
# No cockpit is up here. A pane with a live pid in @tagents_list and @tagents_dash 1 stands for a list an earlier version left in a window
# (all dash_pane asks), in the sections about what such a pane is not: a chat, a line of a question, a pane to kill or to count. The
# agents are a copy of /bin/sleep named `claude`, so the process walk in live_panes counts them. bash 3.2, any cwd.

set -uo pipefail

[ "${TERM:-dumb}" = dumb ] && TERM=xterm-256color
export TERM
[ -n "${LC_ALL:-}${LC_CTYPE:-}" ] || export LC_CTYPE=en_US.UTF-8

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/scratch-guard.sh" && scratch_guard window-rows.sh || exit 1
TA="$HERE/../tagents"
TN="$HERE/../tnotes"

command -v tmux >/dev/null 2>&1 || { echo "window-rows.sh: no tmux"; exit 1; }
command -v fzf  >/dev/null 2>&1 || { echo "window-rows.sh: no fzf"; exit 1; }
command -v git  >/dev/null 2>&1 || { echo "window-rows.sh: no git"; exit 1; }

WRS=tatest-$$
WRSOCK=""
WRSOCKB=""
WRROOT=$(mktemp -d "${TMPDIR:-/tmp}/tagents-wr.XXXXXX") || exit 1
WRROOT=$(cd "$WRROOT" && pwd -P) || exit 1
trap 'tmux -L "$WRS" kill-server >/dev/null 2>&1; tmux -L "${WRS}b" kill-server >/dev/null 2>&1; tmux -L "${WRS}c" kill-server >/dev/null 2>&1
      for f in "$WRROOT"/keeper*.pid; do [ -s "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
      [ -n "$WRSOCK" ] && rm -f "$WRSOCK"; [ -n "$WRSOCKB" ] && rm -f "$WRSOCKB"
      rm -rf "$WRROOT"' EXIT INT TERM

. "$HERE/wait.sh"

BIN="$WRROOT/bin";       mkdir -p "$BIN"
WRSTATE="$WRROOT/state"; mkdir -p "$WRSTATE"
REPO="$WRROOT/repo";     mkdir -p "$REPO/.git" "$REPO/packages/client"
NREPO="$WRROOT/nrepo";   mkdir -p "$NREPO"; git init -q "$NREPO"
cp /bin/sleep "$BIN/claude" || exit 1
codesign --remove-signature "$BIN/claude" >/dev/null 2>&1
codesign -f -s - "$BIN/claude" >/dev/null 2>&1
"$BIN/claude" 0 >/dev/null 2>&1 || { echo "window-rows.sh: cannot build a stub agent (codesign?)"; exit 1; }
printf '#!/bin/sh\nexit 0\n' >"$BIN/tusage"
printf '#!/bin/sh\nexec sleep 600\n' >"$BIN/nvim"     # the notes editor program: a pane that stays
RESUMED="$WRROOT/resumed.log"; : >"$RESUMED"
cat >"$BIN/rec" <<WRAP
#!/bin/sh
printf '%s %s\n' "\$TMUX_PANE" "\$*" >>"$RESUMED"
exec "$BIN/claude" 600
WRAP
chmod +x "$BIN/claude" "$BIN/tusage" "$BIN/nvim" "$BIN/rec"

export PATH="$BIN:$PATH"
export TA_STATE_DIR="$WRSTATE"
export TA_CONFIG=/nonexistent/config.yaml
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset TMUX TMUX_PANE TA_MODE TA_FLAT TA_COLS TA_NEW_CMD TA_RESUME_CMD TA_HOME TA_SESSION TA_WIDTH CLAUDE_CONFIG_DIR CLAUDE_PID

tm()  { tmux -L "$WRS" "$@"; }
tmb() { tmux -L "${WRS}b" "$@"; }
EVB=$(sed -n "s/^EV_BUMP='\(.*\)'\$/\1/p" "$HERE/../lib/tagents/core.sh")
[ -n "$EVB" ] || { echo "window-rows.sh: no EV_BUMP in core.sh"; exit 1; }
ring() { tm set -gF @tagents_evgen "$EVB" \; wait-for -S tagents-ev; }

tm -f /dev/null new-session -d -s tatest-work -x 200 -y 50 -n home -c "$REPO" "exec sleep 600" || exit 1
tm set -g default-shell /bin/sh >/dev/null 2>&1
tm set -g default-command '' >/dev/null 2>&1
tm new-session -d -s tatest-personal -x 200 -y 50 -c "$REPO" "exec sleep 600" >/dev/null 2>&1
tm new-session -d -s tatest-scratch -x 200 -y 50 -c "$REPO" "exec sleep 600" >/dev/null 2>&1
WRSOCK=$(tm display -p '#{socket_path}' 2>/dev/null)
[ -n "$WRSOCK" ] || { echo "window-rows.sh: no socket for $WRS"; exit 1; }

keeper() {  # <n> <session> — a client on a pty, attached to <session>; its stdin is a sleep, so it never detaches by itself
  ( { sleep 300 & printf '%s\n' "$!" >"$WRROOT/keeper$1.pid"; wait; } |
      script -q /dev/null tmux -L "$WRS" attach -t "$2" >/dev/null 2>&1 & ) >/dev/null 2>&1
  sleep 0.5
}
keeper 1 tatest-work
CLIENT=$(tm list-clients -F '#{client_name}' | head -1)

run()    { env TMUX="$WRSOCK,0,0" bash "$TA" "$@"; }
runb()   { env TMUX="$WRSOCKB,0,0" bash "$TA" "$@"; }
act()    { run --act "$@"; }
resume_run() { TA_RESUME_CMD="$BIN/rec" run "$@"; }
tn()     { env TMUX="$WRSOCK,0,0" "$TN" "$@"; }
# A lib function in a shell of its own, the way the refresher calls it: every module (core first). WR_PRE is code run before it.
modrun() {  # <function or builtin> [args…]
  env TMUX="$WRSOCK,0,0" WR_PRE="${WR_PRE:-:}" bash -c '
    SELF=$1; shift; L=${SELF%/*}/lib/tagents
    . "$L/core.sh"; for f in "$L"/*.sh; do case $f in */core.sh) ;; *) . "$f" ;; esac; done
    eval "$WR_PRE"; "$@"' _ "$TA" "$@"
}
# The first start after an upgrade asks tnotes for one sync in the background (migrate_seats), and a sync may close a pane: a check that compares the server before and after waits for it to end. Quiet is no tnotes sync of this tree's for four samples in a row, which also covers the gap between the fork and the exec.
wait_syncs() {
  local i=0 quiet=0
  while [ "$i" -lt 100 ] && [ "$quiet" -lt 4 ]; do
    if pgrep -f "$TN sync" >/dev/null 2>&1; then quiet=0; else quiet=$((quiet + 1)); fi
    sleep 0.1; i=$((i + 1))
  done
}
hooks_of() {  # <event> — the lines of one event, from the session and the window scope: a pane or a window hook is shown by -gw only
  { tm show-hooks -g; tm show-hooks -gw; } 2>/dev/null | awk -v e="$1" 'index($0, e "[") == 1'
}

wid()    { tm display -p -t "${1:-}" '#{window_id}' 2>/dev/null; }
sbpane() { tm list-panes -a -F '#{pane_id} #{@tagents_dash}' 2>/dev/null | awk '$2 == 1 { print $1; exit }'; }
nsbs()   { tm list-panes -a -F '#{@tagents_dash}' 2>/dev/null | grep -c 1; }
npanes() { tm list-panes -t "${1:-}" -F x 2>/dev/null | wc -l | tr -d ' '; }
nwins()  { tm list-windows -a -F x 2>/dev/null | wc -l | tr -d ' '; }
winlive() { tm list-windows -a -F '#{window_id}' 2>/dev/null | awk -v w="${1:-}" '$1 == w { f = 1 } END { print f ? "yes" : "no" }'; }
paneok() { tm list-panes -a -F '#{pane_id}' 2>/dev/null | awk -v p="${1:-}" '$1 == p { f = 1 } END { print f ? "yes" : "no" }'; }
cwin()   { tm list-clients -F '#{client_name} #{window_id}' 2>/dev/null | awk -v c="${1:-$CLIENT}" '$1 == c { print $2; exit }'; }
csess()  { tm list-clients -F '#{client_name} #{session_name}' 2>/dev/null | awk -v c="${1:-$CLIENT}" '$1 == c { print substr($0, index($0, $2)); exit }'; }
nclients() { tm list-clients 2>/dev/null | wc -l | tr -d ' '; }
active() { tm display -p -t "${1:-}" '#{pane_id}' 2>/dev/null; }           # the active pane of a window
msgs_since() { msgs | sed "/ message: $1\$/q"; }   # <marker> — the notices shown since the last `display-message <marker>`
width_of() { tm display -p -t "$1" '#{pane_width}'; }

stamp_sidebar() {  # <pane> — make an existing pane count as a list
  local pid; pid=$(tm display -p -t "$1" '#{pane_pid}')
  tm set -p -t "$1" @tagents_list "$pid" \; set -p -t "$1" @tagents_dash 1 \; select-pane -T tagents-sidebar -t "$1"
}
fake_sidebar() {  # <window> -> its pane id, a list pane as an earlier version left it (leftmost, full height, 45 percent)
  local p
  p=$(tm split-window -d -f -b -h -l 45% -P -F '#{pane_id}' -t "$1" "exec sleep 600")
  stamp_sidebar "$p"; printf '%s' "$p"
}
kill_sidebars() { local p; for p in $(tm list-panes -a -F '#{pane_id} #{@tagents_dash}' 2>/dev/null | awk '$2 == 1 { print $1 }'); do tm kill-pane -t "$p" 2>/dev/null; done; }
unhook() {   # the hooks a refresher installs
  local ev; for ev in $(modrun eval 'echo $EV_EVENTS') session-window-changed client-session-changed; do
    tm set-hook -gu "$ev[42]" 2>/dev/null; tm set-hook -gu "$ev[43]" 2>/dev/null; done
}
n=0
chatrec() {  # <pane> <sid> [state] [dir] — the record the agent-state hook would write
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "${3:-working}" "$2" "${4:-$REPO}" "" "agent $2" "" >"$WRSTATE/${1#%}.tsv"
  printf '%s\t%s\n' "$2" "agent $2" >>"$WRSTATE/labels.tsv"
  ring
}
mkchat() {  # <session> [name] [dir] — a detached window with a stub agent and its record. Sets LASTWIN LASTPANE LASTSID.
  local p
  n=$((n + 1))
  p=$(tm new-window -d -t "=$1:" -P -F '#{pane_id}' -c "${3:-$REPO}" ${2:+-n "$2"} "exec '$BIN/claude' 600")
  LASTPANE=$p; LASTSID=sid-$n; LASTWIN=$(wid "$p")
  chatrec "$p" "$LASTSID" working "${3:-$REPO}"
}
mkshell() {  # <session> [name] [dir] — a detached window with no chat in it (a pane that sleeps). Sets LASTWIN LASTPANE.
  LASTPANE=$(tm new-window -d -t "=$1:" -P -F '#{pane_id}' -c "${3:-$REPO}" ${2:+-n "$2"} "exec sleep 600")
  LASTWIN=$(wid "$LASTPANE")
}
newsess() {  # <name> — a session with one shell-less window. Sets LASTWIN.
  tm new-session -d -s "$1" -x 200 -y 50 -c "$REPO" "exec sleep 600" >/dev/null 2>&1
  LASTWIN=$(wid "=$1:")
}
to() { tm switch-client -c "$CLIENT" -t "=$1:" 2>/dev/null; }      # the keeper client to a session
# The list, read the way a test can: lines key<TAB>text<TAB>state<TAB>sid<TAB>dir, colours stripped.
lst()    { TA_COLS=${TA_COLS:-140} run --list; }
strip()  { sed $'s/\033\\[[0-9;]*m//g'; }
keys()   { lst | awk -F'\t' '{ print $1 }'; }
groups() { lst | strip | awk -F'\t' '   # key<TAB>group, a row under its header
    index($2, "\342\226\276") { g = substr($2, index($2, "\342\226\276") + 4); sub(/  .*$/, "", g); next }
    { print $1 "\t" g }'; }
grp_of() { groups | awk -F'\t' -v k="$1" '$1 == k { print $2; exit }'; }
hdrs()   { lst | strip | awk -F'\t' 'index($2, "\342\226\276") { g = substr($2, index($2, "\342\226\276") + 4); sub(/  .*$/, "", g); print g }'; }
line_of() { lst | strip | awk -F'\t' -v k="$1" 'index($2, "\342\226\276") == 0 && $1 == k { print; exit }'; }
rows_of() { groups | awk -F'\t' -v g="$1" '$2 == g { printf "%s ", $1 }'; }    # the keys of a group, in list order

# ---------------------------------------------------------------------------------------------------------------------------------
t "F9 no cockpit: follow is silent, moves no pane and posts no cursor"
kill_sidebars
SB=$(fake_sidebar "$(wid tatest-work:home)"); tm set -p -t "$SB" @tagents_port 9
mkchat tatest-work two; tm select-window -t "$LASTWIN"
: >"$WRROOT/post.log"; before=$(tm list-panes -a -F '#{pane_id}:#{window_id}:#{pane_left}:#{pane_width}')
out=$(WR_PRE='post_fzf() { echo "$2" >>"'"$WRROOT"'/post.log"; }' modrun follow "$CLIENT" 2>&1); rc=$?
ok "F9 exit 0" 0 "$rc"; ok "F9 silent" "" "$out"
ok "F9 no cursor was posted to the list" "" "$(cat "$WRROOT/post.log")"
ok "F9 no pane moved or was resized" "$before" "$(tm list-panes -a -F '#{pane_id}:#{window_id}:#{pane_left}:#{pane_width}')"
out=$(run --follow "$CLIENT" 2>&1); rc=$?
ok "F9 the verb itself: exit 0" 0 "$rc"; ok "F9 ...and silent" "" "$out"
kill_sidebars; tm select-window -t "$(wid tatest-work:home)"

t "R33 no client: nothing is started or moved and the exit status is 1"
tmb -f /dev/null new-session -d -s solo -x 100 -y 30 "exec sleep 600"
WRSOCKB=$(tmb display -p '#{socket_path}')
n1=$(tmb list-panes -a -F x | wc -l | tr -d ' ')
runb --ensure-dash; rc=$?
ok "R33 exit 1" 1 "$rc"
ok "R33 nothing started" "$n1" "$(tmb list-panes -a -F x | wc -l | tr -d ' ')"

t "F26 session names with a space and with a dot: enter on a chat in them brings the client there"
tm new-session -d -s 'release notes' -x 200 -y 50 -c "$REPO" "exec '$BIN/claude' 600"
RNP=$(tm list-panes -t '=release notes:' -F '#{pane_id}' | head -1); chatrec "$RNP" sid-rn
tm new-session -d -s 'a.b' -x 200 -y 50 -c "$REPO" "exec '$BIN/claude' 600"
DOTP=$(tm list-panes -t '=a.b:' -F '#{pane_id}' | head -1); chatrec "$DOTP" sid-dot
act open "$RNP" working sid-rn "$REPO"
ok "F26 enter on a chat of 'release notes': the client is in that session" "release notes" "$(csess)"
ok "F26 ...and in the chat's window" "$(wid "$RNP")" "$(cwin)"
to tatest-work

t "F27 a session whose only window holds just a list pane gets neither a header nor a row"
newsess tatest-empty; EW=$LASTWIN; stamp_sidebar "$(tm list-panes -t "$EW" -F '#{pane_id}' | head -1)"
hasnt "F27 no header" tatest-empty "$(hdrs)"
ok "F27 and no row" "" "$(rows_of tatest-empty)"
tm kill-session -t =tatest-empty

# ---------------------------------------------------------------------------------------------------------------------------------
t "R1 R2 R3 enter on a row: the client goes to its window"
newsess tatest-r1; RB=$LASTWIN
mkchat tatest-r1 a; RA=$LASTWIN; PA=$LASTPANE; SIDA=$LASTSID
mkchat tatest-r1 b; RB2=$LASTWIN; PB=$LASTPANE; SIDB=$LASTSID
newsess tatest-r2; mkchat tatest-r2 c; RC=$LASTWIN; PC=$LASTPANE; SIDC=$LASTSID
to tatest-r1; tm select-window -t "$RA"
panes=$(tm list-panes -a -F '#{pane_id}:#{window_id}:#{pane_left}:#{pane_width}')
act open "$PB" working "$SIDB" "$REPO"
ok "R1 the client shows the row's window" "$RB2" "$(cwin)"
ok "R1 the active pane is the chat" "$PB" "$(active "$RB2")"
ok "R1 no pane changed window or size" "$panes" "$(tm list-panes -a -F '#{pane_id}:#{window_id}:#{pane_left}:#{pane_width}')"
act open "$PC" working "$SIDC" "$REPO"
ok "R2 another session: the client is switched" tatest-r2 "$(csess)"
ok "R2 ...to the row's window" "$RC" "$(cwin)"
ok "R2 ...and is still attached" 1 "$(nclients)"
act open "$PC" working "$SIDC" "$REPO"
ok "R3 already there: no pane moved or was resized" "$panes" "$(tm list-panes -a -F '#{pane_id}:#{window_id}:#{pane_left}:#{pane_width}')"
ok "R3 the active pane is the chat" "$PC" "$(active "$RC")"

t "R4 enter on a window row whose window closed after the list was drawn"
mkshell tatest-r1 tmp; WTMP=$LASTWIN
tm kill-window -t "$WTMP"
err=$(run --act open "$WTMP" none "" "$REPO" 2>&1 >/dev/null); rc=$?
ok "R4 exit 0" 0 "$rc"; has "R4 a line says the window is gone" "gone" "$err"
ok "R4 the client stayed in its window" "$RC" "$(cwin)"; ok "R4 ...and in its session" tatest-r2 "$(csess)"
has "R4 the notice was shown" "that window is gone" "$(msgs)"

t "R5 R6 R7 L16 headers and dimmed rows"
mkshell tatest-r1 devserver; WD=$LASTWIN
tm select-window -t "$RA"                       # the selected window of tatest-r1
act open "$PB" working "$SIDB" "$REPO" "▾ tatest-r1"
ok "R5 the header shows the session's selected window" "$RA" "$(cwin)"
ok "R5 the client is in that session" tatest-r1 "$(csess)"
ok "R5 the session's selected window is unchanged" "$RA" "$(wid '=tatest-r1:')"
act open "$PC" working "$SIDC" "$REPO"
act open "$PB" working "$SIDB" "$REPO"
ok "L16 without the line text the call opens the row" "$RB2" "$(cwin)"
act open "$WD" none "" "$REPO"
ok "R7 enter on a dimmed row selects the window" "$WD" "$(cwin)"
act open "$PC" working "$SIDC" "$REPO"; act goto "$WD" none "" "$REPO"
ok "R7 ctrl-g on a dimmed row selects the window" "$WD" "$(cwin)"
CWIN=$(tm display -p -t "$WD" '#{window_id}'); np=$(npanes "$WD"); nw=$(nwins)
for v in beside undock send rename; do
  : >"$WRROOT/none"; tm display-message "reset"
  act "$v" "$WD" none "" "$REPO"
  has "R8 $v on a dimmed row" "tagents: that window runs no chat" "$(msgs)"
done
ok "R8 nothing joined or killed" "$np:$nw" "$(npanes "$WD"):$(nwins)"
# the no-window header opens its stand-in: a closed row whose pane is gone is resumed
chatrec "%998" sid-gone dead
resume_run --act open "%998" dead sid-gone "$REPO" "▾ no window"
RP=""; i=0; while [ "$i" -lt 30 ] && [ -z "$RP" ]; do RP=$(awk '$2 == "sid-gone" { p = $1 } END { print p }' "$RESUMED"); i=$((i+1)); sleep 0.1; done
ok "R6 the no-window header resumes its stand-in" yes "$([ -n "$RP" ] && echo yes || echo no)"

t "R9 R10 R11 R12 a second Claude in a terminal the user split beside a chat"
newsess tatest-r9; mkchat tatest-r9 pair; W9=$LASTWIN; PA9=$LASTPANE; SA9=$LASTSID
P29=$(tm split-window -d -h -t "$PA9" -P -F '#{pane_id}' "exec '$BIN/claude' 600"); chatrec "$P29" sid-second
to tatest-r9; tm select-window -t "$W9"
has "R9 the second chat has a row" "$P29" "$(keys)"; has "R9 and so has the first" "$PA9" "$(keys)"
ok "R9 both rows are under one header" "$(grp_of "$PA9")" "$(grp_of "$P29")"
ok "R9 first_chat_pane is the first chat" "$PA9" "$(modrun first_chat_pane "$W9")"
act open "$P29" working sid-second "$REPO"
ok "R9 enter on the second shows the window" "$W9" "$(cwin)"; ok "R9 with the cursor in the second" "$P29" "$(active "$W9")"
act undock "$P29" working sid-second "$REPO"
has "R11 ctrl-u on a never-joined chat" "tagents: that chat is not joined to another window" "$(msgs)"
ok "R11 nothing moved" "$W9" "$(wid "$P29")"
modrun end_agent "$P29"
ok "R10 only the second pane died" "yes:no" "$(paneok "$PA9"):$(paneok "$P29")"
ok "R10 the window stays" "$W9" "$(wid "$PA9")"
P29=$(tm split-window -d -h -t "$PA9" -P -F '#{pane_id}' "exec '$BIN/claude' 600"); chatrec "$P29" sid-second
tm kill-pane -t "$PA9"; settle
ok "R12 the window stays, holding the second chat" "$W9" "$(wid "$P29")"
ok "R12 the second row is live" working "$(line_of "$P29" | awk -F'\t' '{ print $3 }')"
ok "R12 the first row is closed under no window" "no window" "$(grp_of "$PA9")"
hasnt "R12 no dimmed row for the window" "$W9" "$(keys)"

t "R13 R14 R15 chats started and ended in windows of the user"
mkshell tatest-r1 plain; W13=$LASTWIN; P13=$LASTPANE
has "R13 a window without a chat is a dimmed row" "$W13" "$(keys)"
tm respawn-pane -k -t "$P13" "exec '$BIN/claude' 600"; chatrec "$P13" sid-13
has "R13 the pane is a chat row now" "$P13" "$(keys)"; hasnt "R13 the dimmed row is gone" "$W13" "$(keys)"
mkchat tatest-r1 withshell; W14=$LASTWIN; P14=$LASTPANE
SH14=$(tm split-window -d -h -t "$P14" -P -F '#{pane_id}' -c "$REPO/packages" "exec sleep 600")
tm kill-pane -t "$P14"; settle
has "R14 the window is a dimmed row" "$W14" "$(keys)"
ok "R14 its directory is the split's" "$REPO/packages" "$(line_of "$W14" | awk -F'\t' '{ print $5 }')"
ok "R14 the chat row is closed under no window" "no window" "$(grp_of "$P14")"
ok "R14 nothing moved" "$W14" "$(wid "$SH14")"
mkchat tatest-r1 mine; WM=$LASTWIN; PM=$LASTPANE; SIDM=$LASTSID
SHM=$(tm split-window -d -h -t "$PM" -P -F '#{pane_id}' "exec sleep 600")
act open "$PB" working "$SIDB" "$REPO"
ok "R15 the terminal is not on screen while B's window is" no "$([ "$(cwin)" = "$(wid "$SHM")" ] && echo yes || echo no)"
act open "$PM" working "$SIDM" "$REPO"
ok "R15 the same pane in the same window" "$WM" "$(wid "$SHM")"
ok "R15 carrying no tagents option" "" "$(tm show -p -t "$SHM" 2>/dev/null | grep tagents)"
ok "R15 and not resized by hand" "yes" "$(paneok "$SHM")"

t "R16 R17 R18 R20 R21 ctrl-s joins, ctrl-u breaks out"
newsess tatest-j1; mkchat tatest-j1 jb; JB=$LASTWIN; PJB=$LASTPANE; SJB=$LASTSID
newsess tatest-j2; mkchat tatest-j2 ja; JA=$LASTWIN; PJA=$LASTPANE; SJA=$LASTSID
newsess tatest-j3; mkchat tatest-j3 jc; JC=$LASTWIN; PJC=$LASTPANE; SJC=$LASTSID
to tatest-j2; tm select-window -t "$JA"
pid_before=$(tm display -p -t "$PJB" '#{pane_pid}'); act_active=$(active "$JA")
act beside "$PJB" working "$SJB" "$REPO"
has "R16 B is a pane of A's window" "$PJB" "$(tm list-panes -t "$JA" -F '#{pane_id}')"
ok "R16 B's old window is gone" no "$(winlive "$JB")"
ok "R16 the active pane did not change" "$act_active" "$(active "$JA")"
ok "R16 B is to the right of A" yes "$([ "$(tm display -p -t "$PJB" '#{pane_left}')" -gt "$(tm display -p -t "$PJA" '#{pane_left}')" ] && echo yes || echo no)"
ok "R16 @tagents_joined holds B's session" tatest-j1 "$(tm show -pv -t "$PJB" @tagents_joined 2>/dev/null)"
to tatest-j3; tm select-window -t "$JC"
act beside "$PJB" working "$SJB" "$REPO"
ok "R17 joined again: the first home is kept" tatest-j1 "$(tm show -pv -t "$PJB" @tagents_joined 2>/dev/null)"
act beside "$PJC" working "$SJC" "$REPO"
ok "R18 the chat on screen is only focused" "" "$(tm show -pv -t "$PJC" @tagents_joined 2>/dev/null)"
ok "R18 ...and it is the active pane" "$PJC" "$(active "$JC")"
tm kill-session -t =tatest-j1 2>/dev/null
ok "R21 the home session is gone" 1 "$(tm has-session -t =tatest-j1 2>/dev/null; echo $?)"
act undock "$PJB" working "$SJB" "$REPO"
ok "R21 broken out into the session it is in" tatest-j3 "$(tm display -p -t "$PJB" '#{session_name}')"
ok "R20 alone in a window of its own" 1 "$(npanes "$(wid "$PJB")")"
ok "R20 the same process" "$pid_before" "$(tm display -p -t "$PJB" '#{pane_pid}')"
ok "R20 no @tagents_joined" "" "$(tm show -pv -t "$PJB" @tagents_joined 2>/dev/null)"
ok "R20 the window it left no longer holds it" no "$(tm list-panes -t "$JC" -F '#{pane_id}' | grep -q "$PJB" && echo yes || echo no)"
newsess tatest-j4; mkchat tatest-j4 jd; PJD=$LASTPANE; SJD=$LASTSID
act beside "$PJD" working "$SJD" "$REPO"
act undock "$PJD" working "$SJD" "$REPO"
ok "R20 broken out into its home session" tatest-j4 "$(tm display -p -t "$PJD" '#{session_name}')"

t "R36 ctrl-s refuses a chat that is alone in the only window of its session"
tm new-session -d -s tatest-j5 -x 200 -y 50 -c "$REPO" "exec '$BIN/claude' 600" >/dev/null 2>&1
PJE=$(tm list-panes -t "=tatest-j5:" -F '#{pane_id}' | head -1); chatrec "$PJE" sid-je working
to tatest-j3; tm select-window -t "$JC"; tm display-message reset
act beside "$PJE" working sid-je "$REPO"
ok "R36 the session is still there" yes "$(tm has-session -t =tatest-j5 2>/dev/null && echo yes || echo no)"
ok "R36 the chat stayed in it" tatest-j5 "$(tm display -p -t "$PJE" '#{session_name}' 2>/dev/null)"
ok "R36 and carries no joined marker" "" "$(tm show -pv -t "$PJE" @tagents_joined 2>/dev/null)"
has "R36 the notice says why" "tagents: that chat is alone in its session" "$(msgs)"
tm kill-session -t =tatest-j5 2>/dev/null

t "R19 ctrl-s on a closed row resumes it first and then joins it"
chatrec "%997" sid-rj dead
resume_run --act beside "%997" dead sid-rj "$REPO"
RP=""; i=0; while [ "$i" -lt 30 ] && [ -z "$RP" ]; do RP=$(awk '$2 == "sid-rj" { p = $1 } END { print p }' "$RESUMED"); i=$((i+1)); sleep 0.1; done
ok "R19 resumed" yes "$([ -n "$RP" ] && echo yes || echo no)"
ok "R19 and joined into the window on screen" "$(cwin)" "$(wid "$RP")"

t "R22 ctrl-g on a closed row never resumes"
nw=$(nwins); tm display-message reset
act goto "%996" dead sid-rg "$REPO"
has "R22 notice" "tagents: that chat is closed — enter resumes it" "$(msgs)"
ok "R22 nothing started" "$nw" "$(nwins)"

t "R23 R24 R25 R27 ctrl-x"
newsess tatest-k1; KB=$LASTWIN
mkchat tatest-k1 k; KW=$LASTWIN; KP=$LASTPANE
to tatest-k1; tm select-window -t "$KB"; tm select-window -t "$KW"
modrun end_agent "$KP"
ok "R23 the window is closed" no "$(winlive "$KW")"
ok "R23 the client lands on another window" "$KB" "$(cwin)"
mkchat tatest-k1 k2; KW2=$LASTWIN; KP2=$LASTPANE
KSH=$(tm split-window -d -h -t "$KP2" -P -F '#{pane_id}' "exec sleep 600")
tm select-window -t "$KW2"
modrun end_agent "$KP2"
ok "R24 the window stays" yes "$(winlive "$KW2")"; ok "R24 with the terminal" yes "$(paneok "$KSH")"
ok "R24 and the client is still in it" "$KW2" "$(cwin)"
mkchat tatest-k1 k3; KW3=$LASTWIN; KP3=$LASTPANE
modrun end_agent "$KP3"
ok "R25 a chat in a window not on screen dies" no "$(paneok "$KP3")"
ok "R25 the client did not move" "$KW2" "$(cwin)"
SB=$(fake_sidebar "$KW2"); tm display-message reset
modrun kill_agent "$SB" sid-x
has "R27 the dashboard itself" "tagents: that is the dashboard itself" "$(msgs)"
ok "R27 the pane survives" 1 "$(nsbs)"
kill_sidebars; to tatest-work

t "R43 R44 R45 ctrl-x on a dimmed row asks about the window, and only y closes it"
newsess tatest-w1; XW1B=$LASTWIN
mkshell tatest-w1 dev "$REPO"; XW1=$LASTWIN; XW1P=$LASTPANE
XW1Q=$(tm split-window -d -h -t "$XW1P" -P -F '#{pane_id}' -c "$NREPO" "exec sleep 600")
to tatest-work
d1=$(tm display -p -t "$XW1P" '#{pane_current_path}'); d2=$(tm display -p -t "$XW1Q" '#{pane_current_path}')
q=$(printf 'n\n' | run --ask-kill "$XW1" "" | strip)
has "R43 the title" "kill this window?" "$q"
has "R43 the window name" "dev" "$q"
has "R43 session:index" "tatest-w1:$(tm display -p -t "$XW1" '#{window_index}')" "$q"
has "R43 first pane" "  0  sleep  $(modrun tilde_of "$d1")" "$q"
has "R43 second pane" "  1  sleep  $(modrun tilde_of "$d2")" "$q"
has "R43 the closing line" "the window closes with every pane in it." "$q"
hasnt "R43 not the last window of its session" "the session ends with it" "$q"
ok "R43 n keeps the window" yes "$(winlive "$XW1")"
printf '\n' | run --ask-kill "$XW1" "" >/dev/null
ok "R44 an empty line keeps the window" yes "$(winlive "$XW1")"
run --ask-kill "$XW1" "" </dev/null >/dev/null
ok "R44 a closed stdin keeps the window" yes "$(winlive "$XW1")"
ok "R44 and its panes" "2" "$(npanes "$XW1")"
NW=$(nwins)
printf 'y\n' | run --ask-kill "$XW1" "" >/dev/null
ok "R45 y closes the window" no "$(winlive "$XW1")"
ok "R45 and its panes" "no:no" "$(paneok "$XW1P"):$(paneok "$XW1Q")"
ok "R45 the other windows stay" "$((NW - 1))" "$(nwins)"
ok "R45 the session's other window stays" yes "$(winlive "$XW1B")"

t "R46 a list pane is no line of the question"
mkshell tatest-w1 dev2 "$REPO"; XW2=$LASTWIN; tm split-window -d -h -t "$LASTPANE" "exec sleep 600" >/dev/null
SB=$(fake_sidebar "$XW2")
q=$(printf 'n\n' | run --ask-kill "$XW2" "" | strip)
ok "R46 the window holds three panes" 3 "$(npanes "$XW2")"
ok "R46 two pane lines" 2 "$(printf '%s\n' "$q" | grep -c '^  [0-9]')"
kill_sidebars; tm kill-window -t "$XW2"

t "R47 fourteen panes print twelve lines and the rest counted"
newsess tatest-w3; mkshell tatest-w3 big "$REPO"; XW3=$LASTWIN
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13; do tm split-window -d -t "$XW3" "exec sleep 600"; tm select-layout -t "$XW3" tiled; done
ok "R47 fourteen panes" 14 "$(npanes "$XW3")"
q=$(printf 'n\n' | run --ask-kill "$XW3" "" | strip)
ok "R47 twelve pane lines" 12 "$(printf '%s\n' "$q" | grep -c '^  [0-9]')"
has "R47 the rest" "  … and 2 more" "$q"
tm kill-session -t =tatest-w3

t "R48 a window killed before the question is gone, and nothing is asked"
mkshell tatest-w1 gone; XWG=$LASTWIN; tm kill-window -t "$XWG"; tm display-message reset
q=$(printf 'y\n' | run --ask-kill "$XWG" "" | strip)
has "R48 notice" "tagents: that window is gone" "$(msgs)"
hasnt "R48 no question" "kill this window?" "$q"

t "R49 ctrl-x on the dimmed row of the window the client is in: the client lands in the session's other window"
newsess tatest-w4; XW4B=$LASTWIN; mkshell tatest-w4 dev4; XW4=$LASTWIN
to tatest-w4; tm select-window -t "$XW4"
printf 'y\n' | run --ask-kill "$XW4" "" >/dev/null; settle 0.3
ok "R49 the window is gone" no "$(winlive "$XW4")"
ok "R49 the client is still attached and lands in the other window" "$XW4B" "$(cwin)"
ok "R49 ...of the same session" tatest-w4 "$(csess)"

t "R51 the last window of another session: the session ends, the client stays"
to tatest-work
newsess tatest-w6; XW6=$LASTWIN; NC=$(nclients); CS=$(csess)
q=$(printf 'n\n' | run --ask-kill "$XW6" "" | strip)
has "R51 the question says so" "it is the last window of tatest-w6: the session ends with it." "$q"
printf 'y\n' | run --ask-kill "$XW6" "" >/dev/null; settle 0.3
ok "R51 the session is gone" 1 "$(tm has-session -t =tatest-w6 2>/dev/null; echo $?)"
ok "R51 no client lost" "$NC" "$(nclients)"
ok "R51 the client is where it was" "$CS" "$(csess)"

t "R52 ctrl-x on a window with only a list pane says so and kills nothing"
newsess tatest-w7; XW7=$LASTWIN; kill_sidebars
stamp_sidebar "$(tm list-panes -t "$XW7" -F '#{pane_id}')"
tm display-message reset
TA_MODE=popup act kill "$XW7" none "" "$REPO" </dev/null
has "R52 notice" "tagents: that is the dashboard itself" "$(msgs)"
ok "R52 the window survives" yes "$(winlive "$XW7")"
ok "R52 and the sidebar" 1 "$(nsbs)"
kill_sidebars; tm kill-session -t =tatest-w7

t "SH1-SH7 ctrl-a opens a shell: dimmed row, chat row, no window, directory gone, nothing left, by hand"
shnew() {  # <session> — the window with the highest index, the one a launch just made
  tm list-windows -t "=$1:" -F '#{window_index} #{window_id}' | sort -n | tail -1 | awk '{ print $2 }'
}
shcnt() { tm list-windows -t "=$1:" -F x | wc -l | tr -d ' '; }
shpwd() { ( cd "$1" && pwd -P ); }   # tmux reports the resolved path
mkdir -p "$WRROOT/shd" "$WRROOT/shown" "$WRROOT/shs4" "$WRROOT/shs5" "$WRROOT/shs6"
to tatest-work
tm new-session -d -s tatest-sh1 -x 200 -y 50 -c "$WRROOT/shd" "exec sleep 600" >/dev/null 2>&1; XSH1=$(wid =tatest-sh1:)
tm display-message reset
act shell "$XSH1" none "" "$WRROOT/shd"; settle 0.5
XSH1N=$(shnew tatest-sh1)
ok "SH1 ctrl-a on a dimmed row adds a window to its session" 2 "$(shcnt tatest-sh1)"
ok "SH1 it runs tmux's default shell" "" "$(tm display -p -t "$XSH1N" '#{pane_start_command}')"
ok "SH1 in the row's directory" "$(shpwd "$WRROOT/shd")" "$(tm display -p -t "$XSH1N" '#{pane_current_path}')"
ok "SH1 the client is in it" "tatest-sh1:$XSH1N" "$(csess):$(cwin)"
has "SH1 the notice names the directory, the session and the index" "tagents: new shell in shd (tatest-sh1:$(tm display -p -t "$XSH1N" '#{window_index}'))" "$(msgs)"
hasnt "SH1 and the window does not say it runs no chat" "runs no chat" "$(msgs_since reset)"
to tatest-work; tm kill-session -t =tatest-sh1

newsess tatest-sh2; mkchat tatest-sh2 shc; PSH2=$LASTPANE; WSH2=$LASTWIN; SSH2=$LASTSID
to tatest-work
n=$(shcnt tatest-sh2)
act shell "$PSH2" working "$SSH2" "$REPO"; settle 0.5
ok "SH2 ctrl-a on a chat row adds a window to the chat's session" "$((n + 1))" "$(shcnt tatest-sh2)"
ok "SH2 the new window runs a shell" "" "$(tm display -p -t "$(shnew tatest-sh2)" '#{pane_start_command}')"
ok "SH2 and the chat's window still holds the chat" "$WSH2" "$(wid "$PSH2")"
to tatest-work; tm kill-session -t =tatest-sh2

newsess tatest-sh3; mkchat tatest-sh3 own "$WRROOT/shown"; n=$(shcnt tatest-sh3); to tatest-work
act shell "%993" dead sid-sh3 "$WRROOT/shown"; settle 0.5
ok "SH3 ctrl-a on a no-window row goes to the session that owns the project" "$((n + 1))" "$(shcnt tatest-sh3)"
to tatest-work; tm kill-session -t =tatest-sh3

to tatest-work
tm new-session -d -s tatest-sh5 -x 200 -y 50 -c "$WRROOT/shs5" "exec sleep 600" >/dev/null 2>&1; XSH5=$(wid =tatest-sh5:)
act shell "$XSH5" none "" "$WRROOT/no-such-dir"; settle 0.5
ok "SH5 with the row's directory gone the shell starts in the session's" "$(shpwd "$WRROOT/shs5")" "$(tm display -p -t "$(shnew tatest-sh5)" '#{pane_current_path}')"
to tatest-work; tm kill-session -t =tatest-sh5

to tatest-work
tm new-session -d -s tatest-sh6 -x 200 -y 50 -c "$WRROOT/shs6" "exec sleep 600" >/dev/null 2>&1; XSH6=$(wid =tatest-sh6:)
rmdir "$WRROOT/shs6"; tm display-message reset
act shell "$XSH6" none "" "$WRROOT/no-such-dir"; settle 0.5
ok "SH6 with nothing left to start in the shell starts in the home directory" "$(shpwd "$HOME")" "$(tm display -p -t "$(shnew tatest-sh6)" '#{pane_current_path}')"
has "SH6 and the notice reads ~" "tagents: new shell in ~ (tatest-sh6:" "$(msgs)"
to tatest-work; tm kill-session -t =tatest-sh6

to tatest-work
mkdir -p "$WRROOT/shhand"; newsess tatest-sh7; XSH7=$LASTWIN
run --act shell "$XSH7" none '' "$WRROOT/shhand"; settle 0.5
ok "SH7 tagents --act shell @window none '' dir: a window of that window's session, in dir" "2 $(shpwd "$WRROOT/shhand")" "$(shcnt tatest-sh7) $(tm display -p -t "$(shnew tatest-sh7)" '#{pane_current_path}')"
to tatest-work; tm kill-session -t =tatest-sh7

t "TH1 TH2 the home directory itself reads ~"
ok "TH1 tilde_of writes ~ for the home directory" "~" "$(modrun tilde_of "$HOME")"
ok "TH1 and ~/x for a path in it" "~/x" "$(modrun tilde_of "$HOME/x")"
ok "TH1 and a path outside it untouched" "$HOME-x" "$(modrun tilde_of "$HOME-x")"
XTHH="$WRROOT/thhome"; mkdir -p "$XTHH"
newsess tatest-th1; mkshell tatest-th1 homewin "$XTHH"; XTHW=$LASTWIN
to tatest-work
q=$(printf 'n\n' | env HOME="$XTHH" TMUX="$WRSOCK,0,0" bash "$TA" --ask-kill "$XTHW" "" | strip)
ok "TH2 the window question shows ~ for a pane in the home directory" "  0  sleep  ~" "$(printf '%s\n' "$q" | grep '^  0  sleep  ')"
tm kill-session -t =tatest-th1

t "R53 act kill on a dimmed row goes through the question"
newsess tatest-w8; mkshell tatest-w8 dev8; XW8=$LASTWIN
printf 'y\n' | TA_MODE=popup act kill "$XW8" none "" "$REPO" >/dev/null
ok "R53 the window is closed" no "$(winlive "$XW8")"
tm kill-session -t =tatest-w1 2>/dev/null; tm kill-session -t =tatest-w4 2>/dev/null; tm kill-session -t =tatest-w5 2>/dev/null; tm kill-session -t =tatest-w8 2>/dev/null
to tatest-work

t "R29 headless and child rows: the notice says open, no window is made"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" working sid-hl "$REPO" "" hl "" >"$WRSTATE/s-abc.tsv"
nw=$(nwins); tm display-message reset
act open "%s-abc" working sid-hl "$REPO"
has "R29 notice" "headless session — no pane to open, type into or rename" "$(msgs)"
ok "R29 no window" "$nw" "$(nwins)"

t "R30 the user moves things by hand"
newsess tatest-h1; newsess tatest-h2
mkchat tatest-h1 x; HX=$LASTWIN; PX=$LASTPANE; SX=$LASTSID
mkchat tatest-h1 y; HY=$LASTWIN; PY=$LASTPANE; SY=$LASTSID
to tatest-h1; tm select-window -t "$HX"
tm swap-pane -d -s "$PX" -t "$PY"
ok "R30 swap-pane: rows follow the pane ids" "$HY" "$(wid "$PX")"
act open "$PX" working "$SX" "$REPO"; ok "R30 enter after a swap" "$HY" "$(cwin)"
NEWW=$(tm break-pane -d -P -F '#{window_id}' -s "$PX"); act open "$PX" working "$SX" "$REPO"
ok "R30 break-pane: enter goes to the new window" "$NEWW" "$(cwin)"
tm join-pane -d -s "$PX" -t "$PY"; act undock "$PX" working "$SX" "$REPO"
has "R30 a chat joined by hand has no home" "not joined" "$(msgs)"
mkchat tatest-h1 mv; HMV=$LASTWIN; PMV=$LASTPANE; SMV=$LASTSID       # a window of its own: HY is gone by now (its only pane was broken out and joined elsewhere)
tm move-window -d -s "$HMV" -t tatest-h2:
ok "R30 move-window to another session: the group follows" tatest-h2 "$(grp_of "$PMV")"
act open "$PMV" working "$SMV" "$REPO"; ok "R30 enter still selects after a move-window" "$(wid "$PMV")" "$(cwin)"
tm rename-session -t =tatest-h1 renamed-h1; mkchat renamed-h1 z; PZ=$LASTPANE; SZ=$LASTSID
ok "R30 rename-session: the header follows" renamed-h1 "$(grp_of "$PZ")"
act open "$PZ" working "$SZ" "$REPO"; ok "R30 enter still selects after a rename" "$(wid "$PZ")" "$(cwin)"
tm move-window -r -t =renamed-h1 2>/dev/null
has "R30 renumbered windows keep their rows" "$PZ" "$(keys)"
to tatest-work

t "R31 ctrl-n with the cursor in another group; on the no-window group"
newsess tatest-n1; mkchat tatest-n1 nn; PN=$LASTPANE; SN=$LASTSID
to tatest-work
nw1=$(tm list-windows -t =tatest-n1: -F x | wc -l | tr -d ' ')
TA_NEW_CMD="exec '$BIN/claude' 600" act new "$PN" working "$SN" "$REPO"
settle 0.5
ok "R31 a window was added to the row's session" "$((nw1 + 1))" "$(tm list-windows -t =tatest-n1: -F x | wc -l | tr -d ' ')"
ok "R31 the client is in the row's session" "tatest-n1" "$(csess)"
nw0=$(tm list-windows -t =tatest-n1: -F x | wc -l | tr -d ' '); to tatest-work
mkdir -p "$WRROOT/ndir" "$WRROOT/own"
TA_NEW_CMD="exec '$BIN/claude' 600" act new "%995" dead sid-x "$WRROOT/ndir"; settle 0.5
ok "R31 on no window, a project nobody owns: the new chat opens in the client's session" tatest-work "$(csess)"
ok "R31 not in the other" "$nw0" "$(tm list-windows -t =tatest-n1: -F x | wc -l | tr -d ' ')"
mkchat tatest-n1 own "$WRROOT/own"; nw0=$(tm list-windows -t =tatest-n1: -F x | wc -l | tr -d ' '); to tatest-work
TA_NEW_CMD="exec '$BIN/claude' 600" act new "%994" dead sid-y "$WRROOT/own"; settle 0.5
ok "R31 on no window, a project a session owns: the new chat opens there (chat-launch spec)" "$((nw0 + 1))" "$(tm list-windows -t =tatest-n1: -F x | wc -l | tr -d ' ')"
newsess tatest-n13; XN13W=$LASTWIN
to tatest-work
has "R31 the window of a session where no chat ever ran is a dimmed row" "$XN13W" "$(keys)"
XN13N=$(tm list-windows -t =tatest-n13: -F x | wc -l | tr -d ' ')
TA_NEW_CMD="exec '$BIN/claude' 600" act new "$XN13W" none "" "$REPO"; settle 0.5
ok "R31 ctrl-n on that dimmed row adds a window to its session" "$((XN13N + 1))" "$(tm list-windows -t =tatest-n13: -F x | wc -l | tr -d ' ')"
ok "R31 the client is in it" "tatest-n13:$(wid =tatest-n13:)" "$(csess):$(cwin)"
to tatest-work; tm kill-session -t =tatest-n13

t "R35 ctrl-y with the cursor in another group: the resumed chat opens in that group's session (the bind passes the row's key)"
newsess tatest-y1; mkchat tatest-y1 yy; PYY=$LASTPANE; SYY=$LASTSID
to tatest-work
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(( $(date +%s) - 300 ))" start sid-closed-y '%990' '' "$REPO" >>"$WRSTATE/history.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(( $(date +%s) - 200 ))" end   sid-closed-y '%990' '' "$REPO" >>"$WRSTATE/history.tsv"
nw1=$(tm list-windows -t =tatest-y1: -F x | wc -l | tr -d ' ')
: >"$RESUMED"
FZF_DEFAULT_OPTS='--filter=sid-closed-y' TA_MODE=popup resume_run --act closed "$PYY"
RY=""; i=0; while [ "$i" -lt 30 ] && [ -z "$RY" ]; do RY=$(awk '$2 == "sid-closed-y" { p = $1 } END { print p }' "$RESUMED"); i=$((i+1)); sleep 0.1; done
ok "R35 the closed session was resumed" yes "$([ -n "$RY" ] && echo yes || echo no)"
ok "R35 in the session of the row under the cursor" tatest-y1 "$(tm display -p -t "$RY" '#{session_name}' 2>/dev/null)"
ok "R35 as a new window of it" "$((nw1 + 1))" "$(tm list-windows -t =tatest-y1: -F x | wc -l | tr -d ' ')"
cockpit_down tatest-work; : >"$RESUMED"
FZF_DEFAULT_OPTS='--filter=sid-closed-y' TA_MODE=popup resume_run --act closed ""
RY2=""; i=0; while [ "$i" -lt 30 ] && [ -z "$RY2" ]; do RY2=$(awk '$2 == "sid-closed-y" { p = $1 } END { print p }' "$RESUMED"); i=$((i+1)); sleep 0.1; done
ok "R35 with no row under the cursor it opens in the client's session" tatest-work "$(tm display -p -t "$RY2" '#{session_name}' 2>/dev/null)"
cockpit_down tatest-work
# The ? window reaches the same picker (:closed): it is handed the row it was opened on, and fzf is a function that picks the closed key and then the one closed session.
to tatest-work; : >"$RESUMED"
TA_RESUME_CMD="$BIN/rec" WR_PRE='fzf() { case "$*" in *"keys>"*) grep -m1 ":closed" ;; *) head -1 ;; esac; }' modrun ask_keys "" "$PYY" working "$SYY" "$REPO" >/dev/null 2>&1
RY3=""; i=0; while [ "$i" -lt 30 ] && [ -z "$RY3" ]; do RY3=$(awk '$2 == "sid-closed-y" { p = $1 } END { print p }' "$RESUMED"); i=$((i+1)); sleep 0.1; done
ok "R35 the ? window's closed key opens it in the row's session as well" tatest-y1 "$(tm display -p -t "$RY3" '#{session_name}' 2>/dev/null)"
rm -f "$WRSTATE/history.tsv"
cockpit_down tatest-work; tm kill-session -t =tatest-y1; rm -f "$WRSTATE/${PYY#%}.tsv" "$WRSTATE/history.tsv"; ring

t "R37 a list marker whose process is gone does not make a chat pane the sidebar"
tm new-session -d -s tatest-st1 -x 200 -y 50 -c "$REPO" "exec '$BIN/claude' 600" >/dev/null 2>&1      # a session tagents did not create: every session is a group
PST=$(tm list-panes -t "=tatest-st1:" -F '#{pane_id}' | head -1); chatrec "$PST" sid-st working
ok "R37 the session is a group while the pane is unmarked" tatest-st1 "$(grp_of "$PST")"
GONE=$(sh -c 'echo $$')                                                                                  # the pid of a shell that has exited
tm set -p -t "$PST" @tagents_list "$GONE"
has "R37 a dead pid on the chat's pane: the chat still has its row" "$PST" "$(keys)"
ok "R37 and the session is still a group" tatest-st1 "$(grp_of "$PST")"
ok "R37 collect says the pane is not a sidebar" 0 "$(modrun collect | awk -F'\t' -v p="$PST" '$1 == "P" && $2 == p { print $7 }')"
tm set -p -t "$PST" @tagents_list "$$"
ok "R37 a live pid still reads as a sidebar" 1 "$(modrun collect | awk -F'\t' -v p="$PST" '$1 == "P" && $2 == p { print $7 }')"
tm kill-session -t =tatest-st1 2>/dev/null

t "R38 a list that exits takes the sidebar title off its pane, whether or not it still held the shared marker"
mkshell tatest-work rel1; RW1=$LASTWIN; RP1=$LASTPANE
stamp_sidebar "$RP1"
TMUX_PANE="$RP1" modrun release_dash
ok "R38 it held the marker: the title is gone" "" "$(tm display -p -t "$RP1" '#{pane_title}')"
ok "R38 ...and so are the marker and the stamp" "" "$(tm display -p -t "$RP1" '#{@tagents_dash}#{@tagents_list}')"
mkshell tatest-work rel2; RP2=$LASTPANE
stamp_sidebar "$RP2"; tm set -up -t "$RP2" @tagents_dash        # a newer list took the shared marker
TMUX_PANE="$RP2" modrun release_dash
ok "R38 a newer list holds the marker: the title still goes" "" "$(tm display -p -t "$RP2" '#{pane_title}')"
ok "R38 ...and the stamp" "" "$(tm display -p -t "$RP2" '#{@tagents_list}')"
mkshell tatest-work rel3; RP3=$LASTPANE
tm select-pane -T "someone else's title" -t "$RP3"; tm set -p -t "$RP3" @tagents_list "$$"
TMUX_PANE="$RP3" modrun release_dash
ok "R38 a title the list did not set is left alone" "someone else's title" "$(tm display -p -t "$RP3" '#{pane_title}')"
tm kill-window -t "$RW1" 2>/dev/null; tm kill-pane -t "$RP2" 2>/dev/null; tm kill-pane -t "$RP3" 2>/dev/null

t "R39 --new with no project window, no client and no tmux server at all starts a server with a session for the chat"
SOCKC="${WRSOCK%/*}/${WRS}c"                                   # no server listens here yet
mkdir -p "$WRROOT/nosrv"
TA_NEW_CMD="exec '$BIN/claude' 600" env TMUX="$SOCKC,0,0" bash "$TA" --new "$WRROOT/nosrv" >/dev/null 2>&1; rc=$?
ok "R39 exit 0" 0 "$rc"
ok "R39 a session exists, and it is the one the previous version made" agents "$(tmux -L "${WRS}c" list-sessions -F '#{session_name}' 2>/dev/null | head -1)"
ok "R39 with one pane" 1 "$(tmux -L "${WRS}c" list-panes -a -F x 2>/dev/null | wc -l | tr -d ' ')"
ok "R39 the chat started in the directory asked for" "$WRROOT/nosrv" "$(tmux -L "${WRS}c" list-panes -a -F '#{pane_current_path}' 2>/dev/null | head -1)"
TA_NEW_CMD="exec '$BIN/claude' 600" env TMUX="$SOCKC,0,0" bash "$TA" --new "$WRROOT/nosrv" >/dev/null 2>&1
ok "R39 a second one is a second window of that session" 2 "$(tmux -L "${WRS}c" list-windows -t =agents: -F x 2>/dev/null | wc -l | tr -d ' ')"
tmux -L "${WRS}c" kill-server >/dev/null 2>&1

t "R41 win_alive, client_window, client_session and live_set, the helpers the rows and the follow share"
to tatest-work
mkchat tatest-work hl; WHL=$LASTWIN; PHL=$LASTPANE
modrun win_alive "$WHL"; ok "R41 a window id that exists is alive" 0 $?
modrun win_alive "$PHL"; ok "R41 a pane id is not a window" 1 $?
modrun win_alive ""; ok "R41 an empty id is not a window" 1 $?
has "R41 live_set holds the chat's pane between spaces" " $PHL " "$(modrun live_set)"
tm kill-window -t "$WHL"
modrun win_alive "$WHL"; ok "R41 a window that is gone is not alive" 1 $?
ok "R41 client_window of the named client" "$(cwin)" "$(modrun client_window "$CLIENT")"
ok "R41 client_window of the most recently active one" "$(cwin)" "$(modrun client_window)"
ok "R41 client_session of the named client" "$(csess)" "$(modrun client_session "$CLIENT")"
ok "R41 client_session of the most recently active one" "$(csess)" "$(modrun client_session)"
ok "R41 a client that is not there has neither" "" "$(modrun client_window %nosuch)$(modrun client_session %nosuch)"

t "R42 the dashboard outside tmux says so and exits 1, with no session name to fall back on"
out=$(env TMUX="$WRSOCK-nowhere,0,0" bash "$TA" 2>&1 >/dev/null); rc=$?
ok "R42 exit 1" 1 "$rc"
has "R42 the message" "tagents: not inside tmux" "$out"

t "R34 the cursor goes to the row of a window"
# What cursor_to_window posts for a window is the line the list puts the key on. The list is read once by the code and once by the check, so a row still settling (a resumed chat writing its record) is waited for: the pair is taken again, up to ten times, and a number that stays wrong still fails.
cursor_agrees() {  # <name> <window> <key> <row|header>
  local n=0 posted want cond='index($2, "\342\226\276") == 0'
  [ "$4" = header ] && cond='index($2, "\342\226\276")'
  while :; do
    : >"$WRROOT/post.log"
    WR_PRE='post_fzf() { echo "$2" >>"'"$WRROOT"'/post.log"; }' modrun cursor_to_window "$2"
    posted=$(tail -1 "$WRROOT/post.log")
    want=$(lst | awk -F'\t' -v k="$3" "$cond"' && $1 == k { print NR; exit }')
    n=$((n + 1)); { [ "$posted" = "pos($want)" ] || [ "$n" -ge 10 ]; } && break
    sleep 0.3
  done
  ok "$1" "pos($want)" "$posted"
  CURSOR_LINE=$want
}
kill_sidebars; mkchat tatest-work cur; WCUR=$LASTWIN; PCUR=$LASTPANE
SB=$(fake_sidebar "$WCUR"); tm set -p -t "$SB" @tagents_port 9
cursor_agrees "R34 pos(n) is posted for the chat row of the window" "$WCUR" "$PCUR" row
cursor_agrees "R34 a window of a session without a chat posts the cursor onto its dimmed row" "$(wid =tatest-scratch:)" "$(wid =tatest-scratch:)" row
kill_sidebars

t "W1 window names: a chat's window is named after it, a window of a list pane alone keeps its name"
kill_sidebars; mkchat tatest-work; WN=$LASTWIN; PN1=$LASTPANE; SN1=$LASTSID             # no -n: the window keeps tmux's automatic name, which sync may replace
awk -F'\t' -v s="$SN1" '$1 != s' "$WRSTATE/labels.tsv" >"$WRROOT/labels.tmp"; cat "$WRROOT/labels.tmp" >"$WRSTATE/labels.tsv"    # a label would outrank the title
tm select-pane -T "✳ Search index rebuild" -t "$PN1"
run --sync-names; settle 0.3
ok "W1 a window with a chat is named after the chat" "Search index rebuild" "$(tm display -p -t "$WN" '#{window_name}')"
mkshell tatest-work sbonly; WSO=$LASTWIN; SB2=$(tm split-window -d -P -F '#{pane_id}' -t "$WSO" "exec sleep 600"); tm kill-pane -t "$LASTPANE"; stamp_sidebar "$SB2"
run --sync-names; ok "W1 a window of a list pane alone keeps its name" sbonly "$(tm display -p -t "$WSO" '#{window_name}')"
kill_sidebars
run --label "$SN1" "named by hand"
ok "W1 --label renames a window" "named by hand" "$(tm display -p -t "$WN" '#{window_name}')"

# ---------------------------------------------------------------------------------------------------------------------------------
t "L1 L2 L3 L12 sessions are groups; a directory does not group; a session without a chat is a group too; names with a space and a dot"
to tatest-work
pos() { hdrs | awk -v n="$1" '$0 == n { print NR; exit }'; }
mkdir -p "$WRROOT/d1" "$WRROOT/d2"
newsess tatest-l-work; mkchat tatest-l-work w1 "$WRROOT/d1"; LW1=$LASTPANE; SW1=$LASTSID
mkchat tatest-l-work w2 "$WRROOT/d2"; LW2=$LASTPANE
newsess tatest-l-personal; mkchat tatest-l-personal p1; LP1=$LASTPANE
has "L1 header work" tatest-l-work "$(hdrs)"; has "L1 header personal" tatest-l-personal "$(hdrs)"
ok "L1 personal before work" yes "$([ "$(pos tatest-l-personal)" -lt "$(pos tatest-l-work)" ] && echo yes || echo no)"
ok "L1 the personal chat is under personal" tatest-l-personal "$(grp_of "$LP1")"
ok "L2 two directories, one header" "tatest-l-work:tatest-l-work" "$(grp_of "$LW1"):$(grp_of "$LW2")"
has "L3 a session without a chat has a header" tatest-scratch "$(hdrs)"
ok "L3 over its dimmed row" tatest-scratch "$(grp_of "$(wid =tatest-scratch:)")"
newsess tatest-l-made; mkshell tatest-l-made devsrv; LDEV=$LASTWIN
has "L3 a session of a shell window only has a header" tatest-l-made "$(hdrs)"; has "L3 its window is listed" "$LDEV" "$(keys)"
has "L12 a session with a space in its name" "release notes" "$(hdrs)"
has "L12 a session with a dot in its name: tmux 3.7b keeps the dot, so the header is a.b" "a.b" "$(hdrs)"
ok "L12 its chat is under that header" "a.b" "$(grp_of "$DOTP")"
to 'a.b'; act open "$DOTP" working sid-dot "$REPO"
ok "L12 selection works in a session with a dot" "$(wid "$DOTP")" "$(cwin)"
to tatest-work

# A session tagents made for a chat that has since exited stays a group: the old version's leftover mark on a live session means nothing now.
newsess tatest-made; tm set -t =tatest-made @tagents_made 1; mkchat tatest-made; LMCP=$LASTPANE
mkshell tatest-made sh; LMSH=$LASTWIN
tm kill-pane -t "$LMCP"; settle 0.3
has "L12 a session whose chat exited is still a group" tatest-made "$(hdrs)"
has "L12 and its shell window is still listed" "$LMSH" "$(keys)"

t "L4 a dimmed window row"
ln=$(line_of "$LDEV")
ok "L4 key, state, empty session id" "$LDEV|none|" "$(printf '%s' "$ln" | awk -F'\t' '{ print $1 "|" $3 "|" $4 }')"
ok "L4 the directory is the first pane's" "$REPO" "$(printf '%s' "$ln" | awk -F'\t' '{ print $5 }')"
txt=$(printf '%s' "$ln" | awk -F'\t' '{ print $2 }')
has "L4 it shows the window name" devsrv "$txt"; hasnt "L4 no cost" '$' "$txt"; hasnt "L4 no state glyph" "●" "$txt"
hasnt "L4 absent from the flat list" "$LDEV" "$(TA_FLAT=1 keys)"

t "L5 L6 the order inside a group and the header's stand-in"
newsess tatest-l-ord; LBASE=$LASTWIN
mkchat tatest-l-ord oc; LOC=$LASTPANE
mkshell tatest-l-ord d1; LD1=$LASTWIN
mkshell tatest-l-ord d2; LD2=$LASTWIN
mkshell tatest-l-ord zz; LZP=$LASTPANE; chatrec "$LZP" sid-zz dead      # a pane left at a shell with a record: a closed row, and that row is its window's row
ok "L5 chats, dimmed windows in window order, closed rows" "$LOC $LBASE $LD1 $LD2 $LZP " "$(rows_of tatest-l-ord)"
hk=$(lst | strip | awk -F'\t' 'index($2, "\342\226\276") { g = substr($2, index($2, "\342\226\276") + 4); sub(/  .*$/, "", g); if (g == "tatest-l-ord") { print $1; exit } }')
ok "L6 the header carries the key of the first row" "$LOC" "$hk"
newsess tatest-l-only; LONLY=$LASTWIN
hl=$(lst | strip | awk -F'\t' 'index($2, "\342\226\276") { g = substr($2, index($2, "\342\226\276") + 4); sub(/  .*$/, "", g); if (g == "tatest-l-only") { print $1 "|" $3 "|" $4; exit } }')
ok "L6 a session of windows only: window id, state none, no session id" "$LONLY|none|" "$hl"

t "L7 L14 the no-window group is last; a closed-only session sinks below live ones; groups keep their place"
chatrec "%994" sid-ngone dead
newsess "no window"; mkchat "no window" nwc; LNW=$LASTPANE
tm new-session -d -s tatest-l-aaa -x 200 -y 50 -c "$REPO" "exec sleep 600"
AAP=$(tm list-panes -t =tatest-l-aaa: -F '#{pane_id}'); chatrec "$AAP" sid-aaa dead
ok "L7 a row whose pane is gone is under no window" "no window" "$(grp_of %994)"
ok "L7 the session called no window is a group of its own" 2 "$(hdrs | grep -c '^no window$')"
ok "L7 the last header is the trailing group" "no window" "$(hdrs | tail -1)"
ok "L7 the session's chat is listed before the trailing group's row" yes "$([ "$(groups | awk -F'\t' -v k="$LNW" '$1 == k { print NR; exit }')" -lt "$(groups | awk -F'\t' '$1 == "%994" { print NR; exit }')" ] && echo yes || echo no)"
ok "L14 a closed-only session sorts after a live one although its name sorts first" yes "$([ "$(pos tatest-l-aaa)" -gt "$(pos tatest-l-work)" ] && echo yes || echo no)"
ok "L14 ...and before the trailing group" yes "$([ "$(pos tatest-l-aaa)" -lt "$(hdrs | awk '$0 == "no window" { n = NR } END { print n }')" ] && echo yes || echo no)"
before=$(hdrs | tr '\n' ',')
chatrec "$LW1" "$SW1" blocked "$WRROOT/d1"
ok "L14 a blocked agent does not reorder the groups" "$before" "$(hdrs | tr '\n' ',')"

t "L8 the flat list carries the group in a column of its own"
has "L8 the flat row names its group" tatest-l-wo "$(TA_FLAT=1 TA_COLS=120 line_of "$LW1")"
run --toggle-col loc >/dev/null 2>&1
has "L8 ...also with loc hidden" tatest-l-wo "$(TA_FLAT=1 TA_COLS=120 line_of "$LW1")"
run --toggle-col loc >/dev/null 2>&1

t "L9 sessions that differ only in a Cyrillic letter"
newsess я; mkchat я a1; CA1=$LASTPANE; mkchat я a2; CA2=$LASTPANE
newsess ю; mkchat ю b1; CB1=$LASTPANE
has "L9 a header each" я "$(hdrs)"; has "L9 ...and the other" ю "$(hdrs)"
ok "L9 the rows of я sit together" "yes" "$(rows_of я | awk -v a="$CA1" -v b="$CA2" '{ f = 0; for (i = 1; i <= NF; i++) if ($i == a || $i == b) f++; print (f == 2) ? "yes" : "no" }')"
has "L9 the last row of я is drawn with └" "└" "$(line_of "$(rows_of я | awk '{ print $NF }')")"
has "L9 the last row of ю is drawn with └" "└" "$(line_of "$(rows_of ю | awk '{ print $NF }')")"

t "L10 no seat marks"
hasnt "L10 no ▶" "▶" "$(lst)"; hasnt "L10 no ▹" "▹" "$(lst)"
ok "L10 TA_MARKS=0 still prints rows" yes "$([ "$(TA_MARKS=0 lst | wc -l | tr -d ' ')" -gt 0 ] && echo yes || echo no)"

t "L11 a shell split before the chat: one chat row, no dimmed row, enter selects"
newsess tatest-l-b; mkchat tatest-l-b bchat; LBW=$LASTWIN; LBP=$LASTPANE; LBS=$LASTSID
tm split-window -d -b -h -t "$LBP" "exec sleep 600"
ok "L11 the chat is not the first pane" 1 "$(tm display -p -t "$LBP" '#{pane_index}')"
has "L11 one chat row" "$LBP" "$(keys)"; hasnt "L11 no dimmed row for that window" "$LBW" "$(keys)"
ok "L11 first_chat_pane finds the chat" "$LBP" "$(modrun first_chat_pane "$LBW")"
to tatest-l-b; act open "$LBP" working "$LBS" "$REPO"
ok "L11 enter selects the window" "$LBW" "$(cwin)"

t "L13 L15 the subdirectory, the header's path and badges"
mkchat tatest-l-work sub "$REPO/packages/client"
has "L13 the detail text starts with the subdirectory" "packages/client" "$(line_of "$LASTPANE")"
h92=$(TA_COLS=92 lst | strip | grep '▾ tatest-l-work' | awk -F'\t' '{ print $2 }'); h91=$(TA_COLS=91 lst | strip | grep '▾ tatest-l-work' | awk -F'\t' '{ print $2 }')    # the text field only: the fifth field is a directory; captured first because a grep -q at the end of a pipe under pipefail answers no on SIGPIPE
has "L15 the path is shown at 92 columns" "tagents-wr" "$h92"
hasnt "L15 ...and not at 91" "tagents-wr" "$h91"
newsess tatest-l-bdg; mkchat tatest-l-bdg e1; chatrec "$LASTPANE" sid-e1 blocked
mkchat tatest-l-bdg e2; chatrec "$LASTPANE" sid-e2 done
mkchat tatest-l-bdg e3; chatrec "$LASTPANE" sid-e3 working
has "L15 badges in the order blocked, idle, working" "⚠1 ✓1 ●1" "$(lst | strip | grep '▾ tatest-l-bdg')"
to tatest-work

# ---------------------------------------------------------------------------------------------------------------------------------
t "N1 N2 N3 the editor is an ordinary split of the chat's window"
newsess tatest-nt; mkchat tatest-nt chat "$NREPO"; NW=$LASTWIN; NP=$LASTPANE; NS=$LASTSID
mkchat tatest-nt other "$NREPO"; NOP=$LASTPANE; NOS=$LASTSID
to tatest-nt; tm select-window -t "$NW"; tm select-pane -t "$NP"
cw0=$(width_of "$NP")
tn toggle "$NP"; rc=$?
ED=$(tm show -pv -t "$NP" @ta_notes)
ok "N1 toggle exit 0" 0 "$rc"
ok "N1 the chat's window holds the editor" "$NW" "$(wid "$ED")"
ok "N1 the editor names the chat" "$NP" "$(tm show -pv -t "$ED" @ta_notes_for)"
ew=$(width_of "$ED"); ok "N1 about 45 percent of the chat's width" yes "$([ $(( ew * 100 / cw0 )) -ge 40 ] && [ $(( ew * 100 / cw0 )) -le 48 ] && echo yes || echo no)"
ok "N1 the cursor did not move" "$NP" "$(active "$NW")"
ok "N1 no ta-notes session" 1 "$(tm has-session -t =ta-notes 2>/dev/null; echo $?)"
act open "$NOP" working "$NOS" "$REPO"; act open "$NP" working "$NS" "$REPO"
ok "N2 the same editor pane after another row and back" "$ED" "$(tm show -pv -t "$NP" @ta_notes)"
ok "N2 with the width it had" "$ew" "$(width_of "$ED")"
ok "N2 no ta-notes session was ever made" 1 "$(tm has-session -t =ta-notes 2>/dev/null; echo $?)"
NT=$(tm split-window -d -v -t "$NP" -P -F '#{pane_id}' "exec sleep 600")
act open "$NP" working "$NS" "$REPO"
tn toggle "$NP"; ok "N3 toggle goes into the editor" "$ED" "$(active "$NW")"
tn toggle "$NP"; ok "N3 toggle again goes back into the chat" "$NP" "$(active "$NW")"
ok "N3 the extra terminal is untouched" yes "$(paneok "$NT")"

t "N4 N5 the user moved or killed the editor"
NEWW=$(tm break-pane -d -P -F '#{window_id}' -s "$ED")
tn toggle "$NP"
ok "N4 toggle selects the editor's window" "$NEWW" "$(cwin)"; ok "N4 with the cursor in the editor" "$ED" "$(active "$NEWW")"
tm select-window -t "$NW"; tm kill-pane -t "$ED"
tn toggle "$NP"; ED2=$(tm show -pv -t "$NP" @ta_notes)
ok "N5 a new editor is made" yes "$([ -n "$ED2" ] && [ "$ED2" != "$ED" ] && [ "$(paneok "$ED2")" = yes ] && echo yes || echo no)"

t "N6 N7 N9 sync only cleans up"
snap=$(tm list-panes -a -F '#{pane_id}:#{window_id}:#{pane_width}')
tn sync; rc1=$?; tn sync; rc2=$?; tn sync "%5"; rc3=$?
ok "N6 exit 0 three times" "0 0 0" "$rc1 $rc2 $rc3"
ok "N6 nothing moved (a pane given to sync is ignored)" "$snap" "$(tm list-panes -a -F '#{pane_id}:#{window_id}:#{pane_width}')"
ok "N9 no ta-notes session, and sync made none" 1 "$(tm has-session -t =ta-notes 2>/dev/null; echo $?)"
tm kill-pane -t "$NP"; tn sync
ok "N7 the editor of a dead chat is closed" no "$(paneok "$ED2")"

t "N8 editors parked in ta-notes by an older version come back"
newsess tatest-np; mkchat tatest-np pk "$NREPO"; PW=$LASTWIN; PP=$LASTPANE
mkchat tatest-np pk2 "$NREPO"; PW2=$LASTWIN; PP2=$LASTPANE
mkchat tatest-np pk3 "$NREPO"; PW3=$LASTWIN; PP3=$LASTPANE
cwp=$(width_of "$PP")                                       # the chat's whole width, before an editor takes its share
to tatest-np; tn toggle "$PP"; E1=$(tm show -pv -t "$PP" @ta_notes); tn toggle "$PP2"; E2=$(tm show -pv -t "$PP2" @ta_notes); tn toggle "$PP3"; E3=$(tm show -pv -t "$PP3" @ta_notes)
tm new-session -d -s ta-notes -n hold "exec sleep 600"
tm break-pane -d -s "$E1" -t ta-notes: -n park1; tm break-pane -d -s "$E2" -t ta-notes: -n park2; tm break-pane -d -s "$E3" -t ta-notes: -n park3
tm set -p -t "$E3" @ta_notes_for "$PP3"; tm set -p -t "$PP3" @ta_notes "$E3"; tm set -p -t "$E3" @ta_notes_pct 99
tm set -p -t "$E1" @ta_notes_for "$PP"; tm set -p -t "$PP" @ta_notes "$E1"; tm set -p -t "$E1" @ta_notes_pct 30
tm set -p -t "$E2" @ta_notes_for "$PP2"; tm set -p -t "$PP2" @ta_notes "$E2"
tm kill-pane -t "$PP2"
tn sync
ok "N8 the editor is a pane of its chat's window again" "$PW" "$(wid "$E1")"
ok "N8 at the share recorded in @ta_notes_pct" yes "$([ $(( $(width_of "$E1") * 100 / cwp )) -ge 26 ] && [ $(( $(width_of "$E1") * 100 / cwp )) -le 33 ] && echo yes || echo no)"
ok "N8 a share out of 10..90 falls back to 45" yes "$([ "$(wid "$E3")" = "$PW3" ] && [ $(( $(width_of "$E3") * 100 / cwp )) -ge 40 ] && [ $(( $(width_of "$E3") * 100 / cwp )) -le 48 ] && echo yes || echo no)"
ok "N8 the markers are intact" "$E1" "$(tm show -pv -t "$PP" @ta_notes)"
ok "N8 the parked editor of a dead chat is closed" no "$(paneok "$E2")"
ok "N8 the parking session is gone" 1 "$(tm has-session -t =ta-notes 2>/dev/null; echo $?)"
ok "N8 @ta_notes_pct is unset" "" "$(tm show -pv -t "$E1" @ta_notes_pct 2>/dev/null)"
to tatest-work

# ---------------------------------------------------------------------------------------------------------------------------------
t "Z1 Z2 a capture files each chat where its pane is, a list pane an earlier version left not counted"
kill_sidebars; newsess tatest-z1; mkchat tatest-z1 zc; ZW=$LASTWIN; ZP=$LASTPANE; ZS=$LASTSID
ZSH=$(tm split-window -d -h -t "$ZP" -P -F '#{pane_id}' "exec sleep 600")
to tatest-z1; tm select-window -t "$ZW"; SB=$(fake_sidebar "$ZW")
rows=$(modrun resurrect_rows)
arow=$(printf '%s\n' "$rows" | awk -F'\t' -v s="$ZS" '$1 == "A" && $2 == s')
f() { printf '%s' "$arow" | awk -F'\t' -v n="$1" '{ print $n }'; }
ok "Z1 14 columns" 14 "$(printf '%s' "$arow" | awk -F'\t' '{ print NF }')"
ok "Z1 session" tatest-z1 "$(f 5)"
ok "Z1 window index" "$(tm display -p -t "$ZW" '#{window_index}')" "$(f 6)"
ok "Z1 the list pane is left of the chat, so tmux's pane index is 1" 1 "$(tm display -p -t "$ZP" '#{pane_index}')"
ok "Z1 the place does not count the list pane: the chat is the first of the other panes" 0 "$(f 7)"
ok "Z1 the column that held the docked flag says the place skips the list" p "$(f 11)"
ok "Z1 the user's shell has no row" 1 "$(printf '%s\n' "$rows" | awk -F'\t' '$1 == "A" && $5 == "tatest-z1"' | wc -l | tr -d ' ')"
newsess tatest-z2a; mkchat tatest-z2a ja; ZA=$LASTPANE; newsess tatest-z2b; mkchat tatest-z2b jb; ZB=$LASTPANE; ZBS=$LASTSID
to tatest-z2a; tm select-window -t "$(wid "$ZA")"; kill_sidebars
act beside "$ZB" working "$ZBS" "$REPO"
jrow=$(modrun resurrect_rows | awk -F'\t' -v s="$ZBS" '$1 == "A" && $2 == s')
ok "Z2 a joined chat is filed under its home session" tatest-z2b "$(printf '%s' "$jrow" | awk -F'\t' '{ print $5 }')"
ok "Z2 with an empty window and an empty pane" "|" "$(printf '%s' "$jrow" | awk -F'\t' '{ print $6 "|" $7 }')"

t "Z4 Z5 Z6 Z7 Z9 Z10 a restore from an old-style snapshot (docked flag), with extra panes, a busy pane, a joined chat and leftovers"
CFGD="$WRROOT/cfg"; mkdir -p "$CFGD/projects/x" "$NREPO/.claude/notes"
for s in sid-r5 sid-r6 sid-r6n sid-r9; do : >"$CFGD/projects/x/$s.jsonl"; done
arow_() {  # sid session widx pidx dir [docked] [notes] -> an A row of 14 columns
  printf 'A\t%s\t%s\t1\t%s\t%s\t%s\tw\t\t%s\t%s\t%s\t\t\n' "$1" "$CFGD" "$2" "$3" "$4" "$5" "${6:-}" "${7:-}"
}
tm new-session -d -s tatest-z5 -x 200 -y 50 -c "$REPO"                       # an idle shell is pane 0
Z5A=$(tm list-panes -t =tatest-z5: -F '#{pane_id}' | head -1)
Z5B=$(tm split-window -d -h -t "$Z5A" -P -F '#{pane_id}' -c "$REPO")        # another idle shell beside it
Z5C=$(tm split-window -d -h -t "$Z5A" -P -F '#{pane_id}' -c "$NREPO/.claude/notes")   # an unlinked editor pane
Z5L1=$(tm split-window -d -h -t "$Z5A" -P -F '#{pane_id}' -c "$REPO"); tm select-pane -T tagents-sidebar -t "$Z5L1"   # leftovers
Z5L2=$(tm split-window -d -h -t "$Z5A" -P -F '#{pane_id}' "exec sleep 600"); tm select-pane -T tagents-sidebar -t "$Z5L2" # a busy pane with that title
tm new-session -d -s ta-notes -n hold "exec sleep 600"; tm new-window -d -t ta-notes: -n x "exec sleep 600"
tm new-session -d -s tatest-z6 -x 200 -y 50 -c "$REPO" "exec sleep 600"      # pane 0 is busy
Z6P=$(tm list-panes -t =tatest-z6: -F '#{pane_id}' | head -1)
snapf="$WRROOT/old.tsv"
{ arow_ sid-r5 tatest-z5 0 0 "$NREPO" 1 1           # docked flag 1 (ignored), editor beside it
  arow_ sid-r6 tatest-z6 0 0 "$REPO"                # the recorded pane is busy
  arow_ sid-r6n tatest-z6new 0 0 "$REPO"            # the session is gone
  arow_ sid-r9 tatest-z9gone "" "" "$REPO"          # a joined chat whose home session is gone
} >"$snapf"
# a live list that is also titled must survive the sweep
kill_sidebars; ZSB=$(tm new-window -d -P -F '#{pane_id}' -t =tatest-z6: "exec sleep 600"); stamp_sidebar "$ZSB"
out=$(resume_run --resurrect --from "$snapf" 2>&1); rc=$?
ok "Z4 exit 0" 0 "$rc"; has "Z4 the report counts the resumes" "4 resumed" "$out"
rp() { awk -v s="$1" '$2 == s { p = $1 } END { print p }' "$RESUMED"; }
settle 0.5
ok "Z5 the chat replaced the idle shell in place" "$Z5A" "$(rp sid-r5)"
ok "Z5 the shell beside it is untouched" yes "$(paneok "$Z5B")"
ok "Z6 a busy pane keeps running and the chat got a new window of that session" "yes:tatest-z6:new" "$(paneok "$Z6P"):$(tm display -p -t "$(rp sid-r6)" '#{session_name}'):$([ "$(wid "$(rp sid-r6)")" != "$(wid "$Z6P")" ] && echo new)"
tm has-session -t =tatest-z6new 2>/dev/null; ok "Z6 the missing session was created" 0 "$?"
ok "Z6 ...and the created session has a header" tatest-z6new "$(hdrs | grep -x tatest-z6new)"
tm has-session -t =tatest-z9gone 2>/dev/null; ok "Z9 a joined chat's missing home session was created" 0 "$?"
ok "Z7 the idle shell titled tagents-sidebar is closed" no "$(paneok "$Z5L1")"
ok "Z7 the busy pane with that title is left running" yes "$(paneok "$Z5L2")"
ok "Z7 the live list is left" "$ZSB" "$(sbpane)"
ok "Z10 the unlinked editor pane is closed" no "$(paneok "$Z5C")"
ok "Z10 the returned ta-notes session is closed" 1 "$(tm has-session -t =ta-notes 2>/dev/null; echo $?)"
has "Z10 tnotes was asked once for the chat whose editor was beside it" "notes" "$out"

t "Z7 Z8 a dry run closes nothing; --auto sweeps as well"
tm new-session -d -s tatest-z8 -x 200 -y 50 -c "$REPO"
Z8S=$(tm split-window -d -h -t =tatest-z8: -P -F '#{pane_id}'); tm select-pane -T tagents-sidebar -t "$Z8S"
resume_run --resurrect --dry-run --from "$snapf" >/dev/null 2>&1
ok "Z7 --dry-run closes no pane" yes "$(paneok "$Z8S")"
mkdir -p "$WRSTATE/resurrect"; cp "$snapf" "$WRSTATE/resurrect/$(( $(date +%s) - 3600 )).tsv"
: >"$RESUMED"; resume_run --resurrect --auto >/dev/null 2>&1; settle 0.5
ok "Z8 --resurrect --auto closes the leftover shell too" no "$(paneok "$Z8S")"
has "Z8 and logs the restore" "resumed" "$(cat "$WRSTATE/resurrect.log" 2>/dev/null)"

t "Z12 Z13 a snapshot taken with a list pane left of the chat restores the chat into its own pane; an older snapshot never takes the list's shell"
kill_sidebars; unhook
newsess tatest-z12; mkchat tatest-z12 zc; ZW12=$LASTWIN; ZP12=$LASTPANE; ZS12=$LASTSID
ZSH12=$(tm split-window -d -h -t "$ZP12" -P -F '#{pane_id}' "exec sleep 600")      # the user's shell, right of the chat
to tatest-z12; tm select-window -t "$ZW12"; SB=$(fake_sidebar "$ZW12")             # the sidebar, left of both: tmux's index of the chat is 1
rows12=$(modrun resurrect_rows)
row12=$(printf '%s\n' "$rows12" | awk -F'\t' -v s="$ZS12" '$1 == "A" && $2 == s')
ok "Z12 the capture says place 0 and marks it" "0|p" "$(printf '%s' "$row12" | awk -F'\t' '{ print $7 "|" $11 }')"
SNAP12="$WRROOT/z12.tsv"; : >"$CFGD/projects/x/$ZS12.jsonl"
printf '%s\n' "$row12" | awk -F'\t' -v OFS='\t' -v c="$CFGD" '{ $3 = c; $4 = 1; print }' >"$SNAP12"
# After the reboot tmux-resurrect has the window as it saved it: the sidebar was in another window then, so two idle shells.
to tatest-work; kill_sidebars; tm kill-session -t =tatest-z12
tm new-session -d -s tatest-z12 -x 200 -y 50 -c "$REPO"; tm new-window -d -t =tatest-z12:1 -c "$REPO"
Z12A=$(tm list-panes -t =tatest-z12:1 -F '#{pane_id}' | head -1)
Z12B=$(tm split-window -d -h -t "$Z12A" -P -F '#{pane_id}' -c "$REPO")
nwin=$(tm list-windows -t =tatest-z12: -F x | wc -l | tr -d ' '); SHC=$(tm display -p -t "$Z12B" '#{pane_current_command}')
: >"$RESUMED"; resume_run --resurrect --from "$SNAP12" >/dev/null 2>&1; settle 0.5
ok "Z12 the chat runs in the first pane of its window" "$Z12A" "$(rp "$ZS12")"
ok "Z12 the user's shell beside it is still the same shell" "$SHC" "$(tm display -p -t "$Z12B" '#{pane_current_command}' 2>/dev/null)"
ok "Z12 no window was added" "$nwin" "$(tm list-windows -t =tatest-z12: -F x | wc -l | tr -d ' ')"
# An older snapshot: a tmux pane index that points at the idle shell tmux-resurrect brought back titled tagents-sidebar.
tm kill-session -t =tatest-z12
tm new-session -d -s tatest-z12 -x 200 -y 50 -c "$REPO"; tm new-window -d -t =tatest-z12:1 -c "$REPO"
Z13S=$(tm list-panes -t =tatest-z12:1 -F '#{pane_id}' | head -1); tm select-pane -T tagents-sidebar -t "$Z13S"
Z13C=$(tm split-window -d -h -t "$Z13S" -P -F '#{pane_id}' -c "$REPO")
nwin=$(tm list-windows -t =tatest-z12: -F x | wc -l | tr -d ' ')
printf '%s\n' "$row12" | awk -F'\t' -v OFS='\t' -v c="$CFGD" '{ $3 = c; $4 = 1; $7 = 0; $11 = ""; print }' >"$WRROOT/z13.tsv"
: >"$RESUMED"; resume_run --resurrect --from "$WRROOT/z13.tsv" >/dev/null 2>&1; settle 0.5
RZ13=$(rp "$ZS12")
ok "Z13 the pane titled tagents-sidebar was not taken for the chat" yes "$([ -n "$RZ13" ] && [ "$RZ13" != "$Z13S" ] && echo yes || echo no)"
ok "Z13 the chat got a window of its own instead" "$((nwin + 1))" "$(tm list-windows -t =tatest-z12: -F x | wc -l | tr -d ' ')"
ok "Z13 the shell beside it is untouched" "$SHC" "$(tm display -p -t "$Z13C" '#{pane_current_command}' 2>/dev/null)"
tm kill-session -t =tatest-z12; to tatest-work

# ---------------------------------------------------------------------------------------------------------------------------------
t "M1 M2 M3 M4 the first start after the upgrade sends docked chats home and removes the old state"
kill_sidebars
newsess tatest-old; OLDW=$LASTWIN                                              # the old dashboard window
OSB=$(tm list-panes -t "$OLDW" -F '#{pane_id}' | head -1); stamp_sidebar "$OSB"
mkchat tatest-old homeA; HA=$LASTWIN; PAo=$LASTPANE; SAo=$LASTSID
mkchat tatest-old homeB; HB=$LASTWIN; PBo=$LASTPANE
mkchat tatest-old homeC; HC=$LASTWIN; PCo=$LASTPANE
for pair in "$PAo:$HA" "$PBo:$HB"; do c=${pair%%:*}; h=${pair##*:}
  seat=$(tm split-window -d -h -t "$OSB" -P -F '#{pane_id}' "exec sleep 600")      # the seat in the dashboard window
  tm set -p -t "$seat" @tagents_slot 1; tm swap-pane -d -s "$c" -t "$seat"          # the chat is in the seat, the placeholder at home
  tm set -p -t "$seat" @tagents_parked "$c"; tm set -p -t "$c" @tagents_docked "$OLDW"; done
PCpid=$(tm display -p -t "$PCo" '#{pane_pid}')
# C is docked too, and its placeholder is gone before the upgrade
seatC=$(tm split-window -d -h -t "$OSB" -P -F '#{pane_id}' "exec sleep 600"); tm swap-pane -d -s "$PCo" -t "$seatC"
tm set -p -t "$seatC" @tagents_slot 1; tm set -p -t "$seatC" @tagents_parked "$PCo"; tm set -p -t "$PCo" @tagents_docked "$OLDW"
tm kill-pane -t "$seatC" 2>/dev/null
tm set -w -t "$OLDW" @tagents_cur "$PAo"; tm set-hook -g "pane-focus-in[5]" "run-shell \"'$TA' --unpark #{pane_id}\""
tm set-hook -g "after-select-pane[6]" "run-shell \"'$TA' --poke #{pane_id}\""
modrun install_event_hooks
modrun migrate_seats; wait_syncs
ok "M1 chat A is in its home window" "$HA" "$(wid "$PAo")"; ok "M1 chat B is in its home window" "$HB" "$(wid "$PBo")"
ok "M1 no placeholder is left" 0 "$(tm list-panes -a -F '#{@tagents_slot}' | grep -c 1)"
ok "M1 the old dashboard window is an ordinary window with its own pane only" "$OLDW:1" "$(wid "$OSB"):$(npanes "$OLDW")"
ok "M2 the chat whose placeholder was gone has a window of its own" 1 "$(npanes "$(wid "$PCo")")"
ok "M2 ...and is the same process" "$PCpid" "$(tm display -p -t "$PCo" '#{pane_pid}')"
ok "M3 none of the five options is left on a pane" "" "$(tm list-panes -a -F '#{@tagents_slot}#{@tagents_parked}#{@tagents_docked}#{@tagents_seat}' | tr -d '\n')"
ok "M3 ...or on a window" "" "$(tm list-windows -a -F '#{@tagents_cur}#{@tagents_seat}' | tr -d '\n')"
hasnt "M3 the old unpark hook is gone" "--unpark" "$(hooks_of pane-focus-in)"
hasnt "M3 the old poke hook is gone" "--poke" "$(hooks_of after-select-pane)"
has "M3 the ring at [42] is intact" "[42]" "$(hooks_of pane-focus-in)"
ok "M4 the once-marker is set" 1 "$(tm show -gv @tagents_migrated)"
snap="$(tm list-panes -a -F '#{pane_id}:#{window_id}:#{pane_title}:#{@tagents_dash}')|$(tm show-hooks -g | md5)"
modrun migrate_seats
ok "M4 a second start changes nothing" "$snap" "$(tm list-panes -a -F '#{pane_id}:#{window_id}:#{pane_title}:#{@tagents_dash}')|$(tm show-hooks -g | md5)"
unhook; to tatest-work

t "M5 M6 a stale docked marker leaves a chat alone; a pass that stopped after the swap does not send the chat back"
kill_sidebars; unhook
newsess tatest-m5; M5D=$LASTWIN; M5SB=$(tm list-panes -t "$M5D" -F '#{pane_id}' | head -1); stamp_sidebar "$M5SB"
mkchat tatest-m5 busy; M5W=$LASTWIN; M5P=$LASTPANE
M5U=$(tm split-window -d -h -t "$M5P" -P -F '#{pane_id}' "exec sleep 600")       # the user's own pane beside the chat
tm set -p -t "$M5P" @tagents_docked "$M5D"                                        # a marker for a window the chat is not in
modrun migrate_seats; wait_syncs
ok "M5 the chat is still in its window" "$M5W" "$(wid "$M5P")"
ok "M5 beside the user's pane" 2 "$(npanes "$M5W")"
ok "M5 the user's pane is untouched" yes "$(paneok "$M5U")"
ok "M5 the stale marker is cleared" "" "$(tm show -pv -t "$M5P" @tagents_docked 2>/dev/null)"
# M6: the pass swapped the chat home and stopped before it took the markers off.
mkchat tatest-m5 seated; M6W=$LASTWIN; M6P=$LASTPANE
M6S=$(tm split-window -d -h -t "$M5SB" -P -F '#{pane_id}' "exec sleep 600")
tm set -p -t "$M6S" @tagents_slot 1; tm swap-pane -d -s "$M6P" -t "$M6S"            # the chat is in the seat, the placeholder at home
tm set -p -t "$M6S" @tagents_parked "$M6P"; tm set -p -t "$M6P" @tagents_docked "$M5D"
tm swap-pane -d -s "$M6P" -t "$M6S"                                                 # the swap home was done; the markers are still on
modrun migrate_seats; wait_syncs
ok "M6 the chat stays in its home window" "$M6W" "$(wid "$M6P")"
ok "M6 the placeholder is closed" no "$(paneok "$M6S")"
ok "M6 the sidebar's window is an ordinary window again" 1 "$(npanes "$M5D")"
ok "M6 no marker is left" "" "$(tm list-panes -a -F '#{@tagents_slot}#{@tagents_parked}#{@tagents_docked}' | tr -d '\n')"
unhook; to tatest-work

# =================================================================================================================================
# PART 2 INSERTS ITS SECTIONS (L, N, Z, M, H) ABOVE THIS LINE. Everything below installs real hooks on the scratch server and goes last.
# =================================================================================================================================
t "H1 H2 H3 the refresher's hooks and snapshot"
modrun install_event_hooks
evs=$(modrun eval 'echo $EV_EVENTS')
ok "H1 18 event hooks" 18 "$(echo $evs | wc -w | tr -d ' ')"
for ev in $evs; do
  h=$(hooks_of "$ev")
  has "H1 $ev carries the ring at [42]" "$ev[42]" "$h"; hasnt "H1 $ev has no tagents-panes" tagents-panes "$h"; hasnt "H1 $ev has no @tagents_gen" tagents_gen "$h"
done
fmt=$(modrun eval 'echo "$REFRESH_SNAP_FMT"')
has "H2 the snapshot covers @tagents_joined" "@tagents_joined" "$fmt"; has "H2 ...and @tagents_port" "@tagents_port" "$fmt"
has "H3 ...and whether a pane carries @ta_notes_for" "?@ta_notes_for" "$fmt"
hasnt "H2 no seat marker in it" "@tagents_docked" "$fmt"; hasnt "H2 nor the pane title" "pane_title" "$fmt"
HP=$(tm list-panes -t =tatest-work: -F '#{pane_id}' | head -1)
sA=$(tm list-panes -a -F "$fmt"); tm set -p -t "$HP" @tagents_joined tatest-x; sB=$(tm list-panes -a -F "$fmt"); sC=$(tm list-panes -a -F "$fmt")
ok "H2 @tagents_joined set between two passes changes the snapshot: one reload" yes "$([ "$sA" != "$sB" ] && echo yes || echo no)"
ok "H2 the next pass sees the same snapshot: quiet" "$sB" "$sC"
tm set -up -t "$HP" @tagents_joined; tm select-pane -T "a title the spinner changes" -t "$HP"
ok "H2 a pane title alone does not change the snapshot" "$sA" "$(tm list-panes -a -F "$fmt")"
ok "H3 a pane without @ta_notes_for reads 0 in the snapshot" 0 "$(tm display -p -t "$HP" '#{?@ta_notes_for,1,0}')"
tm set -p -t "$HP" @ta_notes_for %1; ok "H3 ...and a pane that has it reads 1" 1 "$(tm display -p -t "$HP" '#{?@ta_notes_for,1,0}')"; tm set -up -t "$HP" @ta_notes_for
ok "H3 an editor line in the snapshot" yes "$(modrun eval 'snap=$(printf "a|@|0\nb|@|1\n7"); snap_has_editor && echo yes || echo no')"
ok "H3 no editor line" no "$(modrun eval 'snap=$(printf "a|@|0\nb|@|0\n7"); snap_has_editor && echo yes || echo no')"
unhook

t "F16 the follow hooks: one each however often installed; the owner's hook kept; a wiped event gets its hook back"
modrun install_follow_hooks; modrun install_follow_hooks
for ev in session-window-changed client-session-changed; do
  ok "F16 one follow hook on $ev" 1 "$(hooks_of "$ev" | grep -c -- '--follow')"; done
tm set-hook -g "session-window-changed[7]" "run-shell 'true'"; modrun install_follow_hooks
has "F16 the owner's hook is kept" "[7]" "$(hooks_of session-window-changed)"
tm set-hook -g client-session-changed "run-shell 'true'"
ok "F16 a hook set without an index wipes the list" 0 "$(hooks_of client-session-changed | grep -c -- '--follow')"
modrun install_follow_hooks
ok "F16 the next install puts it back" 1 "$(hooks_of client-session-changed | grep -c -- '--follow')"
tm set-hook -gu "session-window-changed[7]"

t "F18 moving between ordinary panes starts no program"
modrun install_event_hooks
for ev in pane-focus-in after-select-pane after-select-window; do
  hasnt "F18 $ev starts nothing" "run-shell" "$(hooks_of "$ev")"; done
unhook

t "A leftover viewport shell"
kill_sidebars; unhook; to tatest-work
tm new-session -d -s tatest-lv -x 200 -y 50 -c "$REPO" "exec sleep 600"
tm new-window -d -t =tatest-lv:2 -c "$REPO"
LVA=$(tm list-panes -t =tatest-lv:2 -F '#{pane_id}' | head -1)                                 # the user's own shell
LVL=$(tm split-window -d -h -t "$LVA" -P -F '#{pane_id}' -c "$REPO"); tm select-pane -T tagents-viewport -t "$LVL"   # a leftover
LVB=$(tm split-window -d -h -t "$LVA" -P -F '#{pane_id}' "exec sleep 600"); tm select-pane -T tagents-viewport -t "$LVB"   # a busy pane with that title
LVV=$(tm split-window -d -h -t "$LVA" -P -F '#{pane_id}' -c "$REPO"); tm select-pane -T tagents-viewport -t "$LVV"; tm set -p -t "$LVV" @tagents_viewport 1   # a live viewport
printf 'A\tsid-lv-none\t%s\t1\ttatest-lv\t2\t0\tw\t\t%s\t\t\t\t\n' "$CFGD" "$REPO" >"$WRROOT/lv.tsv"
resume_run --resurrect --from "$WRROOT/lv.tsv" >/dev/null 2>&1
settle 0.5
ok "A leftover viewport shell: the idle shell titled tagents-viewport is closed" no "$(paneok "$LVL")"
ok "A leftover viewport shell: the other pane of work:2 is untouched" yes "$(paneok "$LVA")"
ok "A leftover viewport shell: a busy pane with that title is left running" yes "$(paneok "$LVB")"
ok "A leftover viewport shell: a live viewport is left" yes "$(paneok "$LVV")"
tm kill-session -t =tatest-lv

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
