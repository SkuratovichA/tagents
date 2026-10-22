#!/usr/bin/env bash
#
# tests/window-rows.sh — a row is a tmux window: the sidebar moving into the window on screen, selecting rows, joined chats, the list
# of sessions and windows, tnotes beside a chat, resurrect, the migration from seats, and the panes that belong to the user.
#
# NOTHING HERE MAY TOUCH THE DEFAULT TMUX SOCKET. The server is `tmux -L tatest-$$ -f /dev/null`, torn down in the trap, and tagents is
# pointed at it by exporting $TMUX in the test process (`run`) — never by a `tmux` shim on $PATH. Run as
#   env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$(mktemp -d)" bash tests/window-rows.sh
#
# The sidebar is a FAKE one in most sections (a pane with a live pid in @tagents_list and @tagents_dash 1: that is all dash_pane asks);
# the sections that need a real list (F15 F21 R32 R33) start one. The agents are a copy of /bin/sleep named `claude`, so the process walk
# in live_panes counts them. bash 3.2, any cwd.

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
trap 'tmux -L "$WRS" kill-server >/dev/null 2>&1; tmux -L "${WRS}b" kill-server >/dev/null 2>&1
      for f in "$WRROOT"/keeper*.pid; do [ -s "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
      [ -n "$WRSOCK" ] && rm -f "$WRSOCK"; [ -n "$WRSOCKB" ] && rm -f "$WRSOCKB"
      rm -rf "$WRROOT"' EXIT INT TERM

pass=0; fail=0
ok()   { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
         else fail=$((fail+1)); printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"; fi; }
has()  { case "$3" in *"$2"*) pass=$((pass+1)); printf '  ok   %s\n' "$1" ;;
         *) fail=$((fail+1)); printf '  FAIL %s\n       expected to contain: %s\n       actual: %s\n' "$1" "$2" "$3" ;; esac; }
hasnt(){ case "$3" in *"$2"*) fail=$((fail+1)); printf '  FAIL %s\n       must not contain: %s\n       actual: %s\n' "$1" "$2" "$3" ;;
         *) pass=$((pass+1)); printf '  ok   %s\n' "$1" ;; esac; }
t()    { printf '\n%s\n' "$1"; }
near() {  # <name> <expected> <actual> — within one column
  local d=$(( $2 - $3 )); [ "$d" -lt 0 ] && d=$(( -d ))
  if [ "$d" -le 1 ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s\n       expected: %s (±1)\n       actual:   %s\n' "$1" "$2" "$3"; fi; }

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
unset TMUX TMUX_PANE TA_MODE TA_FLAT TA_COLS TA_NEW_CMD TA_RESUME_CMD TA_HOME TA_SESSION TA_FOLLOW_WINDOW TA_WIDTH CLAUDE_CONFIG_DIR CLAUDE_PID

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
tm set -t =tatest-work: @tagents_made 1; tm set -t =tatest-personal: @tagents_made 1
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
wait_eq() {  # <expected> <cmd...> — polls ~3 s, prints the last value seen
  local want=$1 got i=0; shift
  while :; do got=$("$@"); [ "$got" = "$want" ] && break; i=$((i + 1)); [ "$i" -ge 30 ] && break; sleep 0.1; done
  printf '%s' "$got"
}
settle() { sleep "${1:-0.6}"; }
hooks_of() {  # <event> — the lines of one event, from the session and the window scope: a pane or a window hook is shown by -gw only
  { tm show-hooks -g; tm show-hooks -gw; } 2>/dev/null | awk -v e="$1" 'index($0, e "[") == 1'
}

wid()    { tm display -p -t "${1:-}" '#{window_id}' 2>/dev/null; }
sbwin()  { tm list-panes -a -F '#{window_id} #{@tagents_dash}' 2>/dev/null | awk '$2 == 1 { print $1; exit }'; }
sbpane() { tm list-panes -a -F '#{pane_id} #{@tagents_dash}' 2>/dev/null | awk '$2 == 1 { print $1; exit }'; }
nsb()    { tm list-panes -t "${1:-}" -F '#{@tagents_dash}' 2>/dev/null | grep -c 1; }
nsbs()   { tm list-panes -a -F '#{@tagents_dash}' 2>/dev/null | grep -c 1; }
npanes() { tm list-panes -t "${1:-}" -F x 2>/dev/null | wc -l | tr -d ' '; }
nwins()  { tm list-windows -a -F x 2>/dev/null | wc -l | tr -d ' '; }
winlive() { tm list-windows -a -F '#{window_id}' 2>/dev/null | awk -v w="${1:-}" '$1 == w { f = 1 } END { print f ? "yes" : "no" }'; }
paneok() { tm list-panes -a -F '#{pane_id}' 2>/dev/null | awk -v p="${1:-}" '$1 == p { f = 1 } END { print f ? "yes" : "no" }'; }
cwin()   { tm list-clients -F '#{client_name} #{window_id}' 2>/dev/null | awk -v c="${1:-$CLIENT}" '$1 == c { print $2; exit }'; }
csess()  { tm list-clients -F '#{client_name} #{session_name}' 2>/dev/null | awk -v c="${1:-$CLIENT}" '$1 == c { print substr($0, index($0, $2)); exit }'; }
nclients() { tm list-clients 2>/dev/null | wc -l | tr -d ' '; }
active() { tm display -p -t "${1:-}" '#{pane_id}' 2>/dev/null; }           # the active pane of a window
msgs()   { tm show-messages 2>/dev/null | grep -E ' /dev/[^ ]+ message: ' | tail -30; }   # the message log also holds every command and every error: only what a client's status line showed
widths() {  # <window> [sidebar pane] — "id:width " of every pane except the sidebar, left to right
  tm list-panes -t "$1" -F '#{pane_left} #{pane_id} #{pane_width}' | sort -n | awk -v sb="${2:-}" '$2 != sb { printf "%s:%s ", $2, $3 }'
}
width_of() { tm display -p -t "$1" '#{pane_width}'; }

stamp_sidebar() {  # <pane> — make an existing pane count as the sidebar
  local pid; pid=$(tm display -p -t "$1" '#{pane_pid}')
  tm set -p -t "$1" @tagents_list "$pid" \; set -p -t "$1" @tagents_dash 1 \; select-pane -T tagents-sidebar -t "$1"
}
fake_sidebar() {  # <window> -> its pane id (leftmost, full height, 45 percent)
  local p
  p=$(tm split-window -d -f -b -h -l 45% -P -F '#{pane_id}' -t "$1" "exec sleep 600")
  stamp_sidebar "$p"; printf '%s' "$p"
}
kill_sidebars() { local p; for p in $(tm list-panes -a -F '#{pane_id} #{@tagents_dash}' 2>/dev/null | awk '$2 == 1 { print $1 }'); do tm kill-pane -t "$p" 2>/dev/null; done; }
unhook() {
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
newsess() {  # <name> — a made session with one shell-less window. Sets LASTWIN.
  tm new-session -d -s "$1" -x 200 -y 50 -c "$REPO" "exec sleep 600" >/dev/null 2>&1
  tm set -t "=$1:" @tagents_made 1
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
t "F1 F2 follow moves the sidebar into the window on screen; already there moves nothing"
W1=$(wid tatest-work:home)
SB=$(fake_sidebar "$W1")
ok "the sidebar starts in window 1" "$W1" "$(sbwin)"
mkchat tatest-work two; W2=$LASTWIN; P2=$LASTPANE
tm select-window -t "$W2"
run --follow "$CLIENT"; rc=$?
ok "F1 exit 0" 0 "$rc"
ok "F1 the sidebar is in window 2" "$W2" "$(wait_eq "$W2" sbwin)"
ok "F1 window 1 has none" 0 "$(nsb "$W1")"
set -- $(tm list-panes -t "$W2" -F '#{pane_left} #{pane_id} #{pane_height} #{window_height}' | sort -n | head -1)
ok "F1 leftmost pane is the sidebar" "$SB" "$2"
ok "F1 as tall as the window" "$4" "$3"
before=$(tm list-panes -t "$W2" -F '#{pane_id}:#{pane_left}:#{pane_width}')
run --follow "$CLIENT"; rc=$?
ok "F2 exit 0" 0 "$rc"
ok "F2 nothing moved" "$before" "$(tm list-panes -t "$W2" -F '#{pane_id}:#{pane_left}:#{pane_width}')"

t "F3 a window of a session that is not a group is left alone"
to tatest-scratch
run --follow "$CLIENT"; rc=$?
ok "F3 exit 0" 0 "$rc"
ok "F3 the sidebar stays" "$W2" "$(sbwin)"
to tatest-work; tm select-window -t "$W2"

t "F4 the width is TA_WIDTH percent of the window; F5 out and back gives the other panes their widths"
mkchat tatest-work three; W3=$LASTWIN; P3=$LASTPANE
tm split-window -d -h -t "$P3" "exec sleep 600"
tm select-window -t "$W3"; run --follow "$CLIENT"
ww=$(tm display -p -t "$W3" '#{window_width}')
near "F4 45 percent" "$(( ww * 45 / 100 ))" "$(width_of "$SB")"
before=$(widths "$W3" "$SB")
tm select-window -t "$W2"; run --follow "$CLIENT"
ok "F5 the sidebar left window 3" 0 "$(nsb "$W3")"
tm select-window -t "$W3"; run --follow "$CLIENT"
after=$(widths "$W3" "$SB")
set -- $before; b1=${1#*:}; set -- $after; a1=${1#*:}
near "F5 the first pane has its width again" "$b1" "$a1"
set -- $(widths "$W3" "$SB"); near "F5 the sidebar is still 45 percent" "$(( ww * 45 / 100 ))" "$(width_of "$SB")"
mkchat tatest-work four; W4=$LASTWIN
tm select-window -t "$W4"; TA_WIDTH=30 run --follow "$CLIENT"
ww=$(tm display -p -t "$W4" '#{window_width}')
near "F4 TA_WIDTH=30 gives 30 percent" "$(( ww * 30 / 100 ))" "$(width_of "$SB")"

t "F6 the title is tagents-sidebar after a move"
tm select-pane -T something-else -t "$SB"
tm select-window -t "$W2"; run --follow "$CLIENT"
ok "F6 title" "tagents-sidebar" "$(tm display -p -t "$SB" '#{pane_title}')"

t "F7 the window closes first: nothing moves, one line on stderr, exit 0, the next switch moves the sidebar"
err=$(TA_FOLLOW_WINDOW=@9999 run --follow "$CLIENT" 2>&1 >/dev/null); rc=$?
ok "F7 exit 0" 0 "$rc"
has "F7 the line says the window is gone" "gone" "$err"
ok "F7 exactly one line" 1 "$(printf '%s\n' "$err" | wc -l | tr -d ' ')"
ok "F7 the sidebar stayed" "$W2" "$(sbwin)"
tm select-window -t "$W3"; run --follow "$CLIENT"
ok "F7 the next real switch moves it" "$W3" "$(sbwin)"

t "F8 a zoomed window; a zoomed sidebar"
mkchat tatest-work five; W5=$LASTWIN; P5=$LASTPANE
tm split-window -d -h -t "$P5" "exec sleep 600"; tm resize-pane -Z -t "$P5"
tm select-window -t "$W5"; run --follow "$CLIENT"
ok "F8 the sidebar is in the zoomed window" "$W5" "$(sbwin)"
ok "F8 the window is not left zoomed (the sidebar is visible)" 0 "$(tm display -p -t "$W5" '#{window_zoomed_flag}')"
tm resize-pane -Z -t "$SB"
ok "F8 the sidebar is zoomed now" 1 "$(tm display -p -t "$W5" '#{window_zoomed_flag}')"
tm select-window -t "$W2"; run --follow "$CLIENT"
ok "F8 the window it left is not zoomed" 0 "$(tm display -p -t "$W5" '#{window_zoomed_flag}')"
ok "F8 nor is the one it entered" 0 "$(tm display -p -t "$W2" '#{window_zoomed_flag}')"
ww=$(tm display -p -t "$W2" '#{window_width}')
near "F8 the sidebar has its width" "$(( ww * 45 / 100 ))" "$(width_of "$SB")"

t "F20 old seats still standing: follow does nothing"
tm set -p -t "$P5" @tagents_slot 1
tm select-window -t "$W3"; run --follow "$CLIENT"
ok "F20 the sidebar stays" "$W2" "$(sbwin)"
tm set -up -t "$P5" @tagents_slot
run --follow "$CLIENT"
ok "F20 and moves once they are gone" "$W3" "$(sbwin)"

t "F10 two clients on different sessions: the sidebar goes with the client named; the other is untouched"
keeper 2 tatest-personal
C2=$(tm list-clients -F '#{client_name}' | grep -v -F "$CLIENT" | head -1)
mkchat tatest-personal pp; WP=$LASTWIN
tm select-window -t "$WP"
run --follow "$C2"
ok "F10 the sidebar is in the second client's window" "$WP" "$(sbwin)"
ok "F10 the first client is still in window 3" "$W3" "$(cwin "$CLIENT")"
ok "F10 ...and in its session" "tatest-work" "$(csess "$CLIENT")"
tm select-window -t "$W2"; run --follow "$CLIENT"
ok "F10 the first client brings it back" "$W2" "$(sbwin)"
ok "F10 the second client is still in its window" "$WP" "$(cwin "$C2")"

t "F12 a client detaches: the sidebar stays and a follow for it is silent"
tm detach-client -t "$C2"; settle 0.3
out=$(run --follow "$C2" 2>&1); rc=$?
ok "F12 exit 0" 0 "$rc"; ok "F12 silent" "" "$out"; ok "F12 the sidebar stays" "$W2" "$(sbwin)"

t "F11 a client attaches to a group session that has no sidebar: attaching moves nothing, a follow for it does"
keeper 3 tatest-personal
C3=$(tm list-clients -F '#{client_name}' | grep -v -F "$CLIENT" | head -1)
ok "F11 attaching moved nothing" "$W2" "$(sbwin)"
tm select-window -t "$WP"; run --follow "$C3"
ok "F11 the follow brings it" "$WP" "$(sbwin)"
tm detach-client -t "$C3"; settle 0.3
tm select-window -t "$W2"; run --follow "$CLIENT"

t "F14 five follows at once settle on one sidebar in the window on screen"
tm select-window -t "$W3"
for i in 1 2 3 4 5; do run --follow "$CLIENT" & done; wait
ok "F14 one sidebar" 1 "$(nsbs)"
ok "F14 in the window on screen" "$W3" "$(sbwin)"
ok "F14 no lock left" no "$([ -d "$WRSTATE/.follow.lock" ] && echo yes || echo no)"

t "F9 no sidebar: follow is silent"
kill_sidebars
out=$(run --follow "$CLIENT" 2>&1); rc=$?
ok "F9 exit 0" 0 "$rc"; ok "F9 silent" "" "$out"

t "F19 the sidebar alone in the only window of its session, enter on a row elsewhere: the client stays attached"
newsess tatest-solo; SOLO=$LASTWIN
SB=$(tm list-panes -t "$SOLO" -F '#{pane_id}' | head -1); stamp_sidebar "$SB"
to tatest-solo
mkchat tatest-work tgt; WT=$LASTWIN; PT=$LASTPANE; ST=$LASTSID
act open "$PT" working "$ST" "$REPO"
ok "F19 the client is still attached" 1 "$(nclients)"
ok "F19 it is in the row's session" tatest-work "$(csess)"
ok "F19 the sidebar is in the row's window" "$WT" "$(sbwin)"
tm has-session -t =tatest-solo 2>/dev/null; ok "F19 the emptied session went with its window" 1 "$?"

t "F21 F22 the sidebar pane, its window and its session killed by hand; ensure-dash starts a new one (R33)"
tm kill-pane -t "$SB"; settle 0.3
out=$(run --follow "$CLIENT" 2>&1); rc=$?
ok "F21 follow after the kill: exit 0" 0 "$rc"; ok "F21 silent" "" "$out"
ok "F21 no pane is a sidebar" 0 "$(nsbs)"
run --ensure-dash; rc=$?
ok "R33 ensure-dash exit 0" 0 "$rc"
ok "R33 a list runs in the client's window" "$(cwin)" "$(wait_eq "$(cwin)" sbwin)"
set -- $(tm list-panes -t "$(cwin)" -F '#{pane_left} #{pane_id} #{pane_height} #{window_height} #{@tagents_list}' | sort -n | head -1)
ok "R33 it is the leftmost pane" "$(sbpane)" "$2"; ok "R33 as tall as the window" "$4" "$3"
ok "R33 it has claimed the sidebar (a live pid)" yes "$([ -n "${5:-}" ] && kill -0 "${5:-0}" 2>/dev/null && echo yes || echo no)"
ok "R33 titled" tagents-sidebar "$(tm display -p -t "$(sbpane)" '#{pane_title}')"
LIST1=$(sbpane)
mkchat tatest-work elsewhere; WE=$LASTWIN
tm select-window -t "$WE"
run --ensure-dash
ok "R33 a sidebar elsewhere is moved, the same pane" "$LIST1" "$(sbpane)"
ok "R33 ...into the client's window" "$WE" "$(wait_eq "$WE" sbwin)"
ok "R33 no second list" 1 "$(nsbs)"
tm kill-window -t "$WE"; settle 0.4
ok "F22 the window killed: the client is still attached" 1 "$(nclients)"
ok "F22 no sidebar left" 0 "$(nsbs)"
tm new-session -d -s tatest-extra -x 200 -y 50 -c "$REPO" "exec sleep 600"; tm set -t =tatest-extra: @tagents_made 1
XW=$(wid =tatest-extra:); stamp_sidebar "$(tm list-panes -t "$XW" -F '#{pane_id}' | head -1)"
tm kill-session -t =tatest-extra; settle 0.4
ok "F22 the session killed: the client stays on its session" tatest-work "$(csess)"
run --ensure-dash
ok "F22 ensure-dash starts a new one" "$(cwin)" "$(wait_eq "$(cwin)" sbwin)"
tm kill-pane -t "$(sbpane)"; unhook

t "R33 no client: nothing is started or moved and the exit status is 1"
tmb -f /dev/null new-session -d -s solo -x 100 -y 30 "exec sleep 600"
WRSOCKB=$(tmb display -p '#{socket_path}')
n1=$(tmb list-panes -a -F x | wc -l | tr -d ' ')
runb --ensure-dash; rc=$?
ok "R33 exit 1" 1 "$rc"
ok "R33 nothing started" "$n1" "$(tmb list-panes -a -F x | wc -l | tr -d ' ')"

t "F23 F24 F25 the user moves the sidebar by hand"
mkchat tatest-work hand; WH=$LASTWIN; PH=$LASTPANE; SH=$LASTSID
SB=$(fake_sidebar "$WH")
NB=$(tm break-pane -d -P -F '#{window_id}' -s "$SB")
ok "F23 broken out: still the sidebar" "$NB" "$(sbwin)"
tm select-window -t "$WH"; run --follow "$CLIENT"
ok "F23 follow moves it back into the window on screen" "$WH" "$(sbwin)"
mkchat tatest-work swap; WS=$LASTWIN; PS=$LASTPANE; SS=$LASTSID
tm swap-pane -d -s "$SB" -t "$PS"
ok "F24 after a hand swap the sidebar is where the swap put it" "$WS" "$(sbwin)"
ok "F24 the chat's window follows its pane id" "$WH" "$(wid "$PS")"
act open "$PS" working "$SS" "$REPO"
ok "F24 enter moves the sidebar to the chat's window" "$(wid "$PS")" "$(sbwin)"
tm resize-pane -x 20 -t "$SB"; run --follow "$CLIENT"
ok "F25 a hand resize is left alone while it stays" 20 "$(width_of "$SB")"
tm select-window -t "$W3"; run --follow "$CLIENT"; tm select-window -t "$WH"; run --follow "$CLIENT"
ww=$(tm display -p -t "$WH" '#{window_width}')
near "F25 back at TA_WIDTH percent after out and back" "$(( ww * 45 / 100 ))" "$(width_of "$SB")"

t "F26 session names with a space and with a dot"
tm new-session -d -s 'release notes' -x 200 -y 50 -c "$REPO" "exec '$BIN/claude' 600"
RNP=$(tm list-panes -t '=release notes:' -F '#{pane_id}' | head -1); chatrec "$RNP" sid-rn
to 'release notes'; run --follow "$CLIENT"
ok "F26 follow into 'release notes'" "$(wid '=release notes:')" "$(wait_eq "$(wid '=release notes:')" sbwin)"
tm new-session -d -s 'a.b' -x 200 -y 50 -c "$REPO" "exec '$BIN/claude' 600"; tm set -t '=a.b:' @tagents_made 1
DOTP=$(tm list-panes -t '=a.b:' -F '#{pane_id}' | head -1); chatrec "$DOTP" sid-dot
to 'a.b'; run --follow "$CLIENT"                 # tmux 3.7b keeps the dot in a session name (probed); a name with a dot must still be a usable target
ok "F26 follow into a session named a.b" "$(wid '=a.b:')" "$(wait_eq "$(wid '=a.b:')" sbwin)"
to tatest-work

t "F27 a made session whose only window holds just the sidebar has no header and no row"
newsess tatest-empty; EW=$LASTWIN; stamp_sidebar "$(tm list-panes -t "$EW" -F '#{pane_id}' | head -1)"
hasnt "F27 no header" tatest-empty "$(hdrs)"
tm kill-session -t =tatest-empty

# ---------------------------------------------------------------------------------------------------------------------------------
t "R1 R2 R3 enter on a row: the sidebar and the client go to its window"
newsess tatest-r1; RB=$LASTWIN
mkchat tatest-r1 a; RA=$LASTWIN; PA=$LASTPANE; SIDA=$LASTSID
mkchat tatest-r1 b; RB2=$LASTWIN; PB=$LASTPANE; SIDB=$LASTSID
newsess tatest-r2; mkchat tatest-r2 c; RC=$LASTWIN; PC=$LASTPANE; SIDC=$LASTSID
kill_sidebars; to tatest-r1; tm select-window -t "$RA"
SB=$(fake_sidebar "$RA")
act open "$PB" working "$SIDB" "$REPO"
ok "R1 the sidebar is in the row's window" "$RB2" "$(sbwin)"
ok "R1 window A has none" 0 "$(nsb "$RA")"
ok "R1 the client shows it" "$RB2" "$(cwin)"
ok "R1 the active pane is the chat" "$PB" "$(active "$RB2")"
act open "$PC" working "$SIDC" "$REPO"
ok "R2 another session: the client is switched" tatest-r2 "$(csess)"
ok "R2 the sidebar is in the row's window" "$RC" "$(sbwin)"
before=$(tm list-panes -t "$RC" -F '#{pane_id}:#{pane_left}:#{pane_width}')
act open "$PC" working "$SIDC" "$REPO"
ok "R3 already there: nothing moved" "$before" "$(tm list-panes -t "$RC" -F '#{pane_id}:#{pane_left}:#{pane_width}')"
ok "R3 the active pane is the chat" "$PC" "$(active "$RC")"

t "R4 enter on a window row whose window closed after the list was drawn"
mkshell tatest-r1 tmp; WTMP=$LASTWIN
tm kill-window -t "$WTMP"
err=$(run --act open "$WTMP" none "" "$REPO" 2>&1 >/dev/null); rc=$?
ok "R4 exit 0" 0 "$rc"; has "R4 a line says the window is gone" "gone" "$err"
ok "R4 the sidebar stayed" "$RC" "$(sbwin)"; ok "R4 the client stayed" tatest-r2 "$(csess)"
has "R4 the notice was shown" "that window is gone" "$(msgs)"

t "R5 R6 R7 L16 headers and dimmed rows"
mkshell tatest-r1 devserver; WD=$LASTWIN
tm select-window -t "$RA"                       # the selected window of tatest-r1
act open "$PB" working "$SIDB" "$REPO" "▾ tatest-r1"
ok "R5 the header shows the session's selected window" "$RA" "$(sbwin)"
ok "R5 the client is in that session" tatest-r1 "$(csess)"
ok "R5 the session's selected window is unchanged" "$RA" "$(wid '=tatest-r1:')"
act open "$PC" working "$SIDC" "$REPO"
act open "$PB" working "$SIDB" "$REPO"
ok "L16 without the line text the call opens the row" "$RB2" "$(sbwin)"
act open "$WD" none "" "$REPO"
ok "R7 enter on a dimmed row selects the window" "$WD" "$(sbwin)"
act open "$PC" working "$SIDC" "$REPO"; act goto "$WD" none "" "$REPO"
ok "R7 ctrl-g on a dimmed row selects the window" "$WD" "$(sbwin)"
CWIN=$(tm display -p -t "$WD" '#{window_id}'); np=$(npanes "$WD"); nw=$(nwins)
for v in beside undock send rename kill; do
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
kill_sidebars; to tatest-r9; tm select-window -t "$W9"; SB=$(fake_sidebar "$W9")
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
ok "R10 the window and the sidebar stay" "$W9:$W9" "$(wid "$PA9"):$(sbwin)"
P29=$(tm split-window -d -h -t "$PA9" -P -F '#{pane_id}' "exec '$BIN/claude' 600"); chatrec "$P29" sid-second
tm kill-pane -t "$PA9"; settle
ok "R12 the window stays with the sidebar" "$W9" "$(sbwin)"
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
kill_sidebars; to tatest-j2; tm select-window -t "$JA"; SB=$(fake_sidebar "$JA")
pid_before=$(tm display -p -t "$PJB" '#{pane_pid}'); act_active=$(active "$JA")
act beside "$PJB" working "$SJB" "$REPO"
has "R16 B is a pane of A's window" "$PJB" "$(tm list-panes -t "$JA" -F '#{pane_id}')"
ok "R16 B's old window is gone" no "$(winlive "$JB")"
ok "R16 the active pane did not change" "$act_active" "$(active "$JA")"
ok "R16 B is to the right of A" yes "$([ "$(tm display -p -t "$PJB" '#{pane_left}')" -gt "$(tm display -p -t "$PJA" '#{pane_left}')" ] && echo yes || echo no)"
ok "R16 @tagents_joined holds B's session" tatest-j1 "$(tm show -pv -t "$PJB" @tagents_joined 2>/dev/null)"
to tatest-j3; tm select-window -t "$JC"; run --follow "$CLIENT"
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

t "R19 ctrl-s on a closed row resumes it first and then joins it"
chatrec "%997" sid-rj dead
resume_run --act beside "%997" dead sid-rj "$REPO"
RP=""; i=0; while [ "$i" -lt 30 ] && [ -z "$RP" ]; do RP=$(awk '$2 == "sid-rj" { p = $1 } END { print p }' "$RESUMED"); i=$((i+1)); sleep 0.1; done
ok "R19 resumed" yes "$([ -n "$RP" ] && echo yes || echo no)"
ok "R19 and joined into the window on screen" "$(sbwin)" "$(wid "$RP")"

t "R22 ctrl-g on a closed row never resumes"
nw=$(nwins); tm display-message reset
act goto "%996" dead sid-rg "$REPO"
has "R22 notice" "tagents: that chat is closed — enter resumes it" "$(msgs)"
ok "R22 nothing started" "$nw" "$(nwins)"

t "R23 R24 R25 R26 R27 R28 ctrl-x"
newsess tatest-k1; KB=$LASTWIN
mkchat tatest-k1 k; KW=$LASTWIN; KP=$LASTPANE
kill_sidebars; to tatest-k1; tm select-window -t "$KB"; tm select-window -t "$KW"; SB=$(fake_sidebar "$KW")
modrun end_agent "$KP"
ok "R23 the window is closed" no "$(winlive "$KW")"
ok "R23 the client lands on another window" "$KB" "$(cwin)"
ok "R23 the sidebar is in it" "$KB" "$(sbwin)"
mkchat tatest-k1 k2; KW2=$LASTWIN; KP2=$LASTPANE
KSH=$(tm split-window -d -h -t "$KP2" -P -F '#{pane_id}' "exec sleep 600")
tm select-window -t "$KW2"; run --follow "$CLIENT"
modrun end_agent "$KP2"
ok "R24 the window stays" yes "$(winlive "$KW2")"; ok "R24 with the terminal" yes "$(paneok "$KSH")"
ok "R24 and the sidebar" "$KW2" "$(sbwin)"
mkchat tatest-k1 k3; KW3=$LASTWIN; KP3=$LASTPANE
modrun end_agent "$KP3"
ok "R25 a chat in a window not on screen dies" no "$(paneok "$KP3")"
ok "R25 the sidebar did not move" "$KW2" "$(sbwin)"
tm new-session -d -s tatest-k2 -x 200 -y 50 -c "$REPO" "exec '$BIN/claude' 600"; tm set -t =tatest-k2: @tagents_made 1
K2P=$(tm list-panes -t =tatest-k2: -F '#{pane_id}'); chatrec "$K2P" sid-k2
to tatest-k2; run --follow "$CLIENT"
modrun end_agent "$K2P"; settle 0.3
ok "R26 the session survives" 0 "$(tm has-session -t =tatest-k2 2>/dev/null; echo $?)"
ok "R26 the client is still attached" 1 "$(nclients)"
ok "R26 the sidebar is in the shell window made for it" tatest-k2 "$(tm display -p -t "$(sbpane)" '#{session_name}')"
tm display-message reset
modrun kill_agent "$(sbpane)" sid-x
has "R27 the dashboard itself" "tagents: that is the dashboard itself" "$(msgs)"
ok "R27 the pane survives" 1 "$(nsbs)"
to tatest-work

t "R28 a chat exits by itself in a window of the chat and the sidebar: the sidebar stays, a later follow moves it out"
newsess tatest-k3; K3B=$LASTWIN; mkchat tatest-k3 k3c; K3W=$LASTWIN; K3P=$LASTPANE
kill_sidebars; to tatest-k3; tm select-window -t "$K3W"; SB=$(fake_sidebar "$K3W")
tm kill-pane -t "$K3P"; settle 0.3
ok "R28 the window and the sidebar are still there" "$K3W" "$(sbwin)"
tm select-window -t "$K3B"; run --follow "$CLIENT"
ok "R28 the sidebar moved out" "$K3B" "$(sbwin)"; ok "R28 the emptied window went" no "$(winlive "$K3W")"

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
kill_sidebars; to tatest-h1; tm select-window -t "$HX"; SB=$(fake_sidebar "$HX")
tm swap-pane -d -s "$PX" -t "$PY"
ok "R30 swap-pane: rows follow the pane ids" "$HY" "$(wid "$PX")"
act open "$PX" working "$SX" "$REPO"; ok "R30 enter after a swap" "$HY" "$(sbwin)"
NEWW=$(tm break-pane -d -P -F '#{window_id}' -s "$PX"); act open "$PX" working "$SX" "$REPO"
ok "R30 break-pane: enter goes to the new window" "$NEWW" "$(sbwin)"
tm join-pane -d -s "$PX" -t "$PY"; act undock "$PX" working "$SX" "$REPO"
has "R30 a chat joined by hand has no home" "not joined" "$(msgs)"
mkchat tatest-h1 mv; HMV=$LASTWIN; PMV=$LASTPANE; SMV=$LASTSID       # a window of its own: HY is gone by now (its only pane was broken out and joined elsewhere)
tm move-window -d -s "$HMV" -t tatest-h2:
ok "R30 move-window to another session: the group follows" tatest-h2 "$(grp_of "$PMV")"
act open "$PMV" working "$SMV" "$REPO"; ok "R30 enter still selects after a move-window" "$(wid "$PMV")" "$(sbwin)"
tm rename-session -t =tatest-h1 renamed-h1; mkchat renamed-h1 z; PZ=$LASTPANE; SZ=$LASTSID
ok "R30 rename-session: the header follows" renamed-h1 "$(grp_of "$PZ")"
act open "$PZ" working "$SZ" "$REPO"; ok "R30 enter still selects after a rename" "$(wid "$PZ")" "$(sbwin)"
tm move-window -r -t =renamed-h1 2>/dev/null
has "R30 renumbered windows keep their rows" "$PZ" "$(keys)"
to tatest-work

t "R31 ctrl-n with the cursor in another group; on the no-window group"
newsess tatest-n1; mkchat tatest-n1 nn; PN=$LASTPANE; SN=$LASTSID
kill_sidebars; to tatest-work; SB=$(fake_sidebar "$(wid =tatest-work:)")
nw1=$(tm list-windows -t =tatest-n1: -F x | wc -l | tr -d ' ')
TA_NEW_CMD="exec '$BIN/claude' 600" act new "$PN" working "$SN" "$REPO"
settle 0.5
ok "R31 a window was added to the row's session" "$((nw1 + 1))" "$(tm list-windows -t =tatest-n1: -F x | wc -l | tr -d ' ')"
ok "R31 the sidebar and the client are in it" "tatest-n1" "$(csess)"
nw0=$(tm list-windows -t =tatest-n1: -F x | wc -l | tr -d ' '); to tatest-work
mkdir -p "$WRROOT/ndir" "$WRROOT/own"
TA_NEW_CMD="exec '$BIN/claude' 600" act new "%995" dead sid-x "$WRROOT/ndir"; settle 0.5
ok "R31 on no window, a project nobody owns: the new chat opens in the client's session" tatest-work "$(csess)"
ok "R31 not in the other" "$nw0" "$(tm list-windows -t =tatest-n1: -F x | wc -l | tr -d ' ')"
mkchat tatest-n1 own "$WRROOT/own"; nw0=$(tm list-windows -t =tatest-n1: -F x | wc -l | tr -d ' '); to tatest-work
TA_NEW_CMD="exec '$BIN/claude' 600" act new "%994" dead sid-y "$WRROOT/own"; settle 0.5
ok "R31 on no window, a project a session owns: the new chat opens there (chat-launch spec)" "$((nw0 + 1))" "$(tm list-windows -t =tatest-n1: -F x | wc -l | tr -d ' ')"

t "R32 popup enter with no sidebar starts one first"
kill_sidebars; to tatest-work
TA_MODE=popup act open "$PN" working "$SN" "$REPO"; settle 0.8
ok "R32 a sidebar exists" 1 "$(nsbs)"
ok "R32 it is in the chat's window" "$(wid "$PN")" "$(sbwin)"
tm kill-pane -t "$(sbpane)"; unhook

t "R34 the cursor follows the window on screen"
kill_sidebars; mkchat tatest-work cur; WCUR=$LASTWIN; PCUR=$LASTPANE
SB=$(fake_sidebar "$WCUR"); tm set -p -t "$SB" @tagents_port 9
: >"$WRROOT/post.log"
WR_PRE='post_fzf() { echo "$2" >>"'"$WRROOT"'/post.log"; }' modrun cursor_to_window "$WCUR"
want=$(lst | awk -F'\t' -v k="$PCUR" 'index($2, "\342\226\276") == 0 && $1 == k { print NR; exit }')
ok "R34 pos(n) is posted for the chat row of the window" "pos($want)" "$(tail -1 "$WRROOT/post.log")"
to tatest-scratch; : >"$WRROOT/post.log"; WR_PRE='post_fzf() { echo "$2" >>"'"$WRROOT"'/post.log"; }' modrun follow "$CLIENT"
ok "R34 a window outside every group posts nothing" "" "$(cat "$WRROOT/post.log")"
to tatest-work

t "W1 window names: the sidebar does not stop a window being named"
kill_sidebars; mkchat tatest-work; WN=$LASTWIN; PN1=$LASTPANE; SN1=$LASTSID             # no -n: the window keeps tmux's automatic name, which sync may replace
awk -F'\t' -v s="$SN1" '$1 != s' "$WRSTATE/labels.tsv" >"$WRROOT/labels.tmp"; cat "$WRROOT/labels.tmp" >"$WRSTATE/labels.tsv"    # a label would outrank the title
tm select-pane -T "✳ Search index rebuild" -t "$PN1"
SB=$(fake_sidebar "$WN"); run --sync-names; settle 0.3
ok "W1 a window with the sidebar is named after its chat" "Search index rebuild" "$(tm display -p -t "$WN" '#{window_name}')"
mkshell tatest-work sbonly; WSO=$LASTWIN; kill_sidebars; SB2=$(tm split-window -d -P -F '#{pane_id}' -t "$WSO" "exec sleep 600"); tm kill-pane -t "$LASTPANE"; stamp_sidebar "$SB2"
run --sync-names; ok "W1 a window of the sidebar alone keeps its name" sbonly "$(tm display -p -t "$WSO" '#{window_name}')"
nm1=$(tm display -p -t "$WN" '#{window_name}'); tm select-window -t "$WN"; run --follow "$CLIENT"
ok "W1 moving the sidebar renames nothing" "$nm1" "$(tm display -p -t "$WN" '#{window_name}')"
run --label "$SN1" "named by hand"
ok "W1 --label renames a window that holds the sidebar" "named by hand" "$(tm display -p -t "$WN" '#{window_name}')"

# =================================================================================================================================
# PART 2 INSERTS ITS SECTIONS (L, N, Z, M, H) ABOVE THIS LINE. Everything below installs real hooks on the scratch server and goes last.
# =================================================================================================================================
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

t "F17 F13 the move starts no further follow; a storm of window switches settles on the window on screen"
kill_sidebars; to tatest-work; modrun install_follow_hooks
SB=$(fake_sidebar "$W2"); tm select-window -t "$W2"; settle 1
tm set-hook -g "session-window-changed[50]" "run-shell \"echo x >> '$WRROOT/swc.count'\""
tm set-hook -g "client-session-changed[50]" "run-shell \"echo x >> '$WRROOT/csc.count'\""
: >"$WRROOT/swc.count"; : >"$WRROOT/csc.count"
tm join-pane -h -b -f -d -l 45% -s "$SB" -t "$W5"                  # moved by hand: fires neither hook
run --follow "$CLIENT"; settle 0.8                                # moved back by tagents
ok "F17 the move fired no session-window-changed" 0 "$(wc -l <"$WRROOT/swc.count" | tr -d ' ')"
ok "F17 ...and no client-session-changed" 0 "$(wc -l <"$WRROOT/csc.count" | tr -d ' ')"
tm select-window -t "$W5"; settle 0.6                              # control: the counting hook does count a real switch
ok "F17 control: a real window switch is counted" yes "$([ "$(wc -l <"$WRROOT/swc.count" | tr -d ' ')" -ge 1 ] && echo yes || echo no)"
tm set-hook -gu "session-window-changed[50]"; tm set-hook -gu "client-session-changed[50]"
i=0; while [ "$i" -lt 15 ]; do tm next-window -t tatest-work; i=$((i + 1)); done
want=$(cwin); settle 2
ok "F13 one sidebar" 1 "$(nsbs)"
ok "F13 in the window on screen" "$(cwin)" "$(wait_eq "$(cwin)" sbwin)"
ok "F13 no lock directory left" no "$([ -d "$WRSTATE/.follow.lock" ] && echo yes || echo no)"
unhook

t "F15 a list that is still starting when the user switches window ends up in the window on screen (review focus 4)"
kill_sidebars; to tatest-work
tm select-window -t "$W2"
LP=$(tm new-window -d -t =tatest-work: -P -F '#{pane_id}' "sleep 1.5; exec '$TA'")
run --follow "$CLIENT"; rc=$?
ok "F15 a follow before the claim: exit 0" 0 "$rc"; ok "F15 ...and nothing to move" 0 "$(nsbs)"
tm select-window -t "$W3"
ok "F15 once the list claims, it is in the window on screen" "$W3" "$(wait_eq "$W3" sbwin)"
ok "F15 it is the pane that was started" "$LP" "$(sbpane)"
tm kill-pane -t "$(sbpane)"; unhook

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
