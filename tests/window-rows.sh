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
wait_eq_long() {  # <expected> <cmd...> — the same, up to ~8 s: for a list that a hook starts, which is a fresh fzf and a fresh bash
  local want=$1 got i=0; shift
  while :; do got=$("$@"); [ "$got" = "$want" ] && break; i=$((i + 1)); [ "$i" -ge 80 ] && break; sleep 0.1; done
  printf '%s' "$got"
}
lockheld() { [ -d "$WRSTATE/.follow.lock" ] && echo yes || echo no; }
settle() { sleep "${1:-0.6}"; }
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
kill_sidebars() { local p; for p in $(tm list-panes -a -F '#{pane_id} #{@tagents_dash}' 2>/dev/null | awk '$2 == 1 { print $1 }'); do tm kill-pane -t "$p" 2>/dev/null; done; tm set -gu @tagents_sidebar_on 2>/dev/null; }   # and the wish for one: only a real list sets it (claim_dash)
unhook() {   # the hooks a real list's refresher installs, and the wish for a sidebar its claim made
  local ev; for ev in $(modrun eval 'echo $EV_EVENTS') session-window-changed client-session-changed; do
    tm set-hook -gu "$ev[42]" 2>/dev/null; tm set-hook -gu "$ev[43]" 2>/dev/null; done
  tm set -gu @tagents_sidebar_on 2>/dev/null
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
ok "F14 no lock left" no "$(wait_eq_long no lockheld)"

t "F28 a move waits for the follow lock and reads where the sidebar is once it has it"
SBL=$(sbpane); mkchat tatest-work lk; WLK=$LASTWIN
tm set -w -t "$W2" @tagents_widths "%0:1 "                # a saved split that is not the real one
mkdir "$WRSTATE/.follow.lock"                              # another follow is in the middle of its move
modrun sidebar_move "$WLK" & MV=$!
sleep 0.6
ok "F28 nothing moved while the lock was held" "$W3" "$(sbwin)"
tm join-pane -h -b -f -d -l 45% -s "$SBL" -t "$W2"         # meanwhile the sidebar is put into window 2
want=$(widths "$W2" "$SBL")
rmdir "$WRSTATE/.follow.lock"
wait "$MV"
ok "F28 then the sidebar went to the window asked for" "$WLK" "$(wait_eq "$WLK" sbwin)"
ok "F28 the widths saved are those of the window it was really in" "$want" "$(tm show -wv -t "$W2" @tagents_widths)"
ok "F28 the lock is free again" no "$([ -d "$WRSTATE/.follow.lock" ] && echo yes || echo no)"
tm select-window -t "$W3"; run --follow "$CLIENT"

t "F29 a join tmux refuses is told on the client's status line, and the sidebar stays"
tm new-session -d -s tatest-tiny -x 6 -y 3 "exec sleep 600"; tm set -t =tatest-tiny: @tagents_made 1
while tm split-window -d -h -t =tatest-tiny: "exec sleep 600" 2>/dev/null; do :; done
WTINY=$(wid =tatest-tiny:); before=$(sbwin)
tm display-message reset
err=$(modrun sidebar_move "$WTINY" 2>&1 >/dev/null); rc=$?
ok "F29 the move fails" 1 "$rc"
has "F29 standard error says why" "no space for a new pane" "$err"
has "F29 so does the client's status line" "no space for a new pane" "$(msgs)"
ok "F29 the sidebar stayed" "$before" "$(sbwin)"
tm kill-session -t =tatest-tiny

t "F35 a lock whose holder died is taken at once, not after the stale time"
DEADPID=$(bash -c 'echo $$')
mkdir "$WRSTATE/.follow.lock"; printf '%s\n' "$DEADPID" >"$WRSTATE/.follow.lock/owner"
s0=$SECONDS; modrun follow_lock; rc=$?
ok "F35 the lock is had" 0 "$rc"
ok "F35 without waiting for it" yes "$([ $((SECONDS - s0)) -le 1 ] && echo yes || echo no)"
mkdir -p "$WRSTATE/.follow.lock"; rm -rf "$WRSTATE/.follow.lock"
mkdir "$WRSTATE/.follow.lock"                        # a lock with no owner written yet is held
s0=$SECONDS; modrun follow_lock; rc=$?
ok "F35 a lock with no owner file is waited for, and the move then goes on without it" 1 "$rc"
rmdir "$WRSTATE/.follow.lock"

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
ok "F21 follow after the kill, no sidebar wanted (a fake one never claimed a pane): exit 0" 0 "$rc"; ok "F21 silent" "" "$out"
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
modrun install_follow_hooks                          # the refresher puts them back on its own; not waited for here
tm kill-window -t "$WE"; settle 0.4
ok "F22 the window killed: the client is still attached" 1 "$(nclients)"
ok "F22 the list claimed a pane, so the follow hook brings a sidebar back where the client landed" "$(cwin)" "$(wait_eq_long "$(cwin)" sbwin)"
ok "F22 one list" 1 "$(nsbs)"
kill_sidebars; unhook                                # no list, no wish, no hooks: the same kills now leave nothing behind
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

t "F30 F31 the window or the session on screen killed with the sidebar in it: the next follow brings a sidebar back, one list, where the client lands"
nlists() { tm list-panes -a -F '#{@tagents_list}' 2>/dev/null | grep -c .; }
mkchat tatest-work fa; WFA=$LASTWIN; mkchat tatest-work fb; WFB=$LASTWIN
to tatest-work; tm select-window -t "$WFA"
modrun install_follow_hooks                          # the real hooks, as the refresher puts them
run --ensure-dash
ok "F30 a real list runs in the window on screen" "$WFA" "$(wait_eq "$WFA" sbwin)"
ok "F30 a sidebar is wanted from the claim on" 1 "$(tm show -gv @tagents_sidebar_on 2>/dev/null)"
tm kill-window -t "$WFA"
LAND=$(cwin)
ok "F30 the client landed in another window" yes "$([ -n "$LAND" ] && [ "$LAND" != "$WFA" ] && echo yes || echo no)"
ok "F30 a list runs there, started by the hook" "$LAND" "$(wait_eq_long "$LAND" sbwin)"
ok "F30 exactly one list" 1 "$(nlists)"
ok "F30 as the leftmost full-height pane" "$(sbpane)" "$(tm list-panes -t "$LAND" -F '#{pane_left} #{pane_id}' | sort -n | head -1 | cut -d' ' -f2)"
newsess tatest-f31; mkchat tatest-f31 fc
to tatest-f31; run --follow "$CLIENT"
ok "F31 the sidebar went with the client to the other session" tatest-f31 "$(tm display -p -t "$(sbpane)" '#{session_name}')"
tm set -g detach-on-destroy off                      # tmux moves the client to another session instead of detaching it
tm kill-session -t =tatest-f31
ok "F31 the client is still attached" 1 "$(nclients)"
LAND=$(cwin)
ok "F31 a list runs in the window it landed in" "$LAND" "$(wait_eq_long "$LAND" sbwin)"
ok "F31 exactly one list" 1 "$(nlists)"
tm set -gu detach-on-destroy

t "F32 ctrl-q ends the wish: a window switch brings no sidebar back; ensure-dash wants one again"
ready() { tm capture-pane -p -t "$(sbpane)" 2>/dev/null | grep -c 'agents>'; }   # fzf is up: before that the tty is still in flow control and swallows ctrl-q
i=0; while [ "$i" -lt 100 ] && [ "$(ready)" != 1 ]; do i=$((i + 1)); sleep 0.1; done
ok "F32 the list is up" 1 "$(ready)"
tm send-keys -t "$(sbpane)" C-q
ok "F32 the list is gone" 0 "$(wait_eq_long 0 nlists)"
ok "F32 no sidebar is wanted" "" "$(tm show -gv @tagents_sidebar_on 2>/dev/null)"
tm select-window -t "$WFB"; run --follow "$CLIENT"; settle 0.5
ok "F32 a follow starts none" 0 "$(nlists)"
run --ensure-dash
ok "F32 ensure-dash starts one" "$(cwin)" "$(wait_eq_long "$(cwin)" sbwin)"
ok "F32 and a sidebar is wanted again" 1 "$(tm show -gv @tagents_sidebar_on 2>/dev/null)"

t "F33 a storm of follows with a wanted sidebar and none running starts one list"
tm kill-pane -t "$(sbpane)"; settle 0.3
ok "F33 none runs" 0 "$(nlists)"
unhook                                               # the storm below is the follows we start ourselves
tm set -g @tagents_sidebar_on 1
for i in 1 2 3 4 5; do run --follow "$CLIENT" & done; wait
ok "F33 one list" 1 "$(wait_eq_long 1 nlists)"
ok "F33 in the window on screen" "$(cwin)" "$(wait_eq_long "$(cwin)" sbwin)"
ok "F33 no lock left" no "$(wait_eq_long no lockheld)"
tm select-window -t "$WFB"; kill_sidebars; settle 0.3; unhook

t "F34 a window of a session that is not a group gets no new sidebar either"
tm set -g @tagents_sidebar_on 1; to tatest-scratch
run --follow "$CLIENT"; settle 0.5
ok "F34 none started" 0 "$(nlists)"
to tatest-work; tm set -gu @tagents_sidebar_on

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

t "R36 ctrl-s refuses a chat that is alone in the only window of its session"
tm new-session -d -s tatest-j5 -x 200 -y 50 -c "$REPO" "exec '$BIN/claude' 600" >/dev/null 2>&1
tm set -t "=tatest-j5:" @tagents_made 1
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

t "R35 ctrl-y with the cursor in another group: the resumed chat opens in that group's session (the bind passes the row's key)"
newsess tatest-y1; mkchat tatest-y1 yy; PYY=$LASTPANE; SYY=$LASTSID
kill_sidebars; to tatest-work
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(( $(date +%s) - 300 ))" start sid-closed-y '%990' '' "$REPO" >>"$WRSTATE/history.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(( $(date +%s) - 200 ))" end   sid-closed-y '%990' '' "$REPO" >>"$WRSTATE/history.tsv"
nw1=$(tm list-windows -t =tatest-y1: -F x | wc -l | tr -d ' ')
: >"$RESUMED"
FZF_DEFAULT_OPTS='--filter=sid-closed-y' TA_MODE=popup resume_run --act closed "$PYY"
RY=""; i=0; while [ "$i" -lt 30 ] && [ -z "$RY" ]; do RY=$(awk '$2 == "sid-closed-y" { p = $1 } END { print p }' "$RESUMED"); i=$((i+1)); sleep 0.1; done
ok "R35 the closed session was resumed" yes "$([ -n "$RY" ] && echo yes || echo no)"
ok "R35 in the session of the row under the cursor" tatest-y1 "$(tm display -p -t "$RY" '#{session_name}' 2>/dev/null)"
ok "R35 as a new window of it" "$((nw1 + 1))" "$(tm list-windows -t =tatest-y1: -F x | wc -l | tr -d ' ')"
to tatest-work; : >"$RESUMED"
FZF_DEFAULT_OPTS='--filter=sid-closed-y' TA_MODE=popup resume_run --act closed ""
RY2=""; i=0; while [ "$i" -lt 30 ] && [ -z "$RY2" ]; do RY2=$(awk '$2 == "sid-closed-y" { p = $1 } END { print p }' "$RESUMED"); i=$((i+1)); sleep 0.1; done
ok "R35 with no row under the cursor it opens in the client's session" tatest-work "$(tm display -p -t "$RY2" '#{session_name}' 2>/dev/null)"
# The ? window reaches the same picker (:closed): it is handed the row it was opened on, and fzf is a function that picks the closed key and then the one closed session.
to tatest-work; : >"$RESUMED"
TA_RESUME_CMD="$BIN/rec" WR_PRE='fzf() { case "$*" in *"keys>"*) grep -m1 ":closed" ;; *) head -1 ;; esac; }' modrun ask_keys "" "$PYY" working "$SYY" "$REPO" >/dev/null 2>&1
RY3=""; i=0; while [ "$i" -lt 30 ] && [ -z "$RY3" ]; do RY3=$(awk '$2 == "sid-closed-y" { p = $1 } END { print p }' "$RESUMED"); i=$((i+1)); sleep 0.1; done
ok "R35 the ? window's closed key opens it in the row's session as well" tatest-y1 "$(tm display -p -t "$RY3" '#{session_name}' 2>/dev/null)"
rm -f "$WRSTATE/history.tsv"
to tatest-work; tm kill-session -t =tatest-y1; rm -f "$WRSTATE/${PYY#%}.tsv" "$WRSTATE/history.tsv"; ring

t "R32 popup enter with no sidebar starts one first"
kill_sidebars; to tatest-work
TA_MODE=popup act open "$PN" working "$SN" "$REPO"; settle 0.8
ok "R32 a sidebar exists" 1 "$(nsbs)"
ok "R32 it is in the chat's window" "$(wid "$PN")" "$(sbwin)"
tm kill-pane -t "$(sbpane)"; unhook

t "R37 a list marker whose process is gone does not make a chat pane the sidebar"
tm new-session -d -s tatest-st1 -x 200 -y 50 -c "$REPO" "exec '$BIN/claude' 600" >/dev/null 2>&1      # not made by tagents: only a live chat makes it a group
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

# ---------------------------------------------------------------------------------------------------------------------------------
t "L1 L2 L3 L12 sessions are groups; a directory does not group; scratch sessions stay out; names with a space and a dot"
kill_sidebars; to tatest-work
pos() { hdrs | awk -v n="$1" '$0 == n { print NR; exit }'; }
mkdir -p "$WRROOT/d1" "$WRROOT/d2"
newsess tatest-l-work; mkchat tatest-l-work w1 "$WRROOT/d1"; LW1=$LASTPANE; SW1=$LASTSID
mkchat tatest-l-work w2 "$WRROOT/d2"; LW2=$LASTPANE
newsess tatest-l-personal; mkchat tatest-l-personal p1; LP1=$LASTPANE
has "L1 header work" tatest-l-work "$(hdrs)"; has "L1 header personal" tatest-l-personal "$(hdrs)"
ok "L1 personal before work" yes "$([ "$(pos tatest-l-personal)" -lt "$(pos tatest-l-work)" ] && echo yes || echo no)"
ok "L1 the personal chat is under personal" tatest-l-personal "$(grp_of "$LP1")"
ok "L2 two directories, one header" "tatest-l-work:tatest-l-work" "$(grp_of "$LW1"):$(grp_of "$LW2")"
hasnt "L3 a scratch session has no header" tatest-scratch "$(hdrs)"
newsess tatest-l-made; mkshell tatest-l-made devsrv; LDEV=$LASTWIN
has "L3 a made session without a chat is a group" tatest-l-made "$(hdrs)"; has "L3 its window is listed" "$LDEV" "$(keys)"
has "L12 a session with a space in its name" "release notes" "$(hdrs)"
has "L12 a session with a dot in its name: tmux 3.7b keeps the dot, so the header is a.b" "a.b" "$(hdrs)"
ok "L12 its chat is under that header" "a.b" "$(grp_of "$DOTP")"
kill_sidebars; to 'a.b'; SB=$(fake_sidebar "$(wid '=a.b:')"); act open "$DOTP" working sid-dot "$REPO"
ok "L12 selection works in a session with a dot" "$(wid "$DOTP")" "$(sbwin)"
to tatest-work

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
tm new-session -d -s tatest-l-aaa -x 200 -y 50 -c "$REPO" "exec sleep 600"; tm set -t =tatest-l-aaa: @tagents_made 1
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
kill_sidebars; to tatest-l-b; SB=$(fake_sidebar "$(wid =tatest-l-b:)"); act open "$LBP" working "$LBS" "$REPO"
ok "L11 enter selects the window" "$LBW" "$(sbwin)"

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
kill_sidebars; newsess tatest-nt; mkchat tatest-nt chat "$NREPO"; NW=$LASTWIN; NP=$LASTPANE; NS=$LASTSID
mkchat tatest-nt other "$NREPO"; NOP=$LASTPANE; NOS=$LASTSID
to tatest-nt; tm select-window -t "$NW"; SB=$(fake_sidebar "$NW"); tm select-pane -t "$NP"
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
t "Z1 Z2 Z3 a capture files each chat where its pane is"
kill_sidebars; newsess tatest-z1; mkchat tatest-z1 zc; ZW=$LASTWIN; ZP=$LASTPANE; ZS=$LASTSID
ZSH=$(tm split-window -d -h -t "$ZP" -P -F '#{pane_id}' "exec sleep 600")
to tatest-z1; tm select-window -t "$ZW"; SB=$(fake_sidebar "$ZW")
rows=$(modrun resurrect_rows)
arow=$(printf '%s\n' "$rows" | awk -F'\t' -v s="$ZS" '$1 == "A" && $2 == s')
f() { printf '%s' "$arow" | awk -F'\t' -v n="$1" '{ print $n }'; }
ok "Z1 14 columns" 14 "$(printf '%s' "$arow" | awk -F'\t' '{ print NF }')"
ok "Z1 session" tatest-z1 "$(f 5)"
ok "Z1 window index" "$(tm display -p -t "$ZW" '#{window_index}')" "$(f 6)"
ok "Z1 the sidebar is left of the chat, so tmux's pane index is 1" 1 "$(tm display -p -t "$ZP" '#{pane_index}')"
ok "Z1 the place does not count the sidebar: the chat is the first of the other panes" 0 "$(f 7)"
ok "Z1 the column that held the docked flag says the place skips the sidebar" p "$(f 11)"
ok "Z1 the user's shell has no row" 1 "$(printf '%s\n' "$rows" | awk -F'\t' '$1 == "A" && $5 == "tatest-z1"' | wc -l | tr -d ' ')"
ok "Z3 the D row is the window the sidebar is in" "D	tatest-z1	$(tm display -p -t "$ZW" '#{window_index}')" "$(printf '%s\n' "$rows" | awk '$1 == "D"')"
newsess tatest-z2a; mkchat tatest-z2a ja; ZA=$LASTPANE; newsess tatest-z2b; mkchat tatest-z2b jb; ZB=$LASTPANE; ZBS=$LASTSID
to tatest-z2a; tm select-window -t "$(wid "$ZA")"; kill_sidebars; SB=$(fake_sidebar "$(wid "$ZA")")
act beside "$ZB" working "$ZBS" "$REPO"
jrow=$(modrun resurrect_rows | awk -F'\t' -v s="$ZBS" '$1 == "A" && $2 == s')
ok "Z2 a joined chat is filed under its home session" tatest-z2b "$(printf '%s' "$jrow" | awk -F'\t' '{ print $5 }')"
ok "Z2 with an empty window and an empty pane" "|" "$(printf '%s' "$jrow" | awk -F'\t' '{ print $6 "|" $7 }')"

t "Z4 Z5 Z6 Z7 Z9 Z10 a restore from an old-style snapshot (docked flag, old D row), with extra panes, a busy pane, a joined chat and leftovers"
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
{ printf 'D\ttatest-z5\t0\n'
  arow_ sid-r5 tatest-z5 0 0 "$NREPO" 1 1           # docked flag 1 (ignored), editor beside it
  arow_ sid-r6 tatest-z6 0 0 "$REPO"                # the recorded pane is busy
  arow_ sid-r6n tatest-z6new 0 0 "$REPO"            # the session is gone
  arow_ sid-r9 tatest-z9gone "" "" "$REPO"          # a joined chat whose home session is gone
} >"$snapf"
# the fake sidebar (a live list that is also titled) must survive the sweep
kill_sidebars; ZSB=$(tm new-window -d -P -F '#{pane_id}' -t =tatest-z6: "exec sleep 600"); stamp_sidebar "$ZSB"
out=$(resume_run --resurrect --from "$snapf" 2>&1); rc=$?
ok "Z4 exit 0" 0 "$rc"; has "Z4 the report counts the resumes" "4 resumed" "$out"
rp() { awk -v s="$1" '$2 == s { p = $1 } END { print p }' "$RESUMED"; }
settle 0.5
ok "Z5 the chat replaced the idle shell in place" "$Z5A" "$(rp sid-r5)"
ok "Z5 the shell beside it is untouched" yes "$(paneok "$Z5B")"
ok "Z6 a busy pane keeps running and the chat got a new window of that session" "yes:tatest-z6:new" "$(paneok "$Z6P"):$(tm display -p -t "$(rp sid-r6)" '#{session_name}'):$([ "$(wid "$(rp sid-r6)")" != "$(wid "$Z6P")" ] && echo new)"
tm has-session -t =tatest-z6new 2>/dev/null; ok "Z6 the missing session was created" 0 "$?"
ok "Z6 ...and marked as made by tagents" 1 "$(tm show -v -t =tatest-z6new: @tagents_made)"
tm has-session -t =tatest-z9gone 2>/dev/null; ok "Z9 a joined chat's missing home session was created" 0 "$?"
ok "Z7 the idle shell titled tagents-sidebar is closed" no "$(paneok "$Z5L1")"
ok "Z7 the busy pane with that title is left running" yes "$(paneok "$Z5L2")"
ok "Z7 the live list is still the sidebar" "$ZSB" "$(sbpane)"
ok "Z4 the sidebar was moved to the D row's window" "$(wid =tatest-z5:)" "$(sbwin)"
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

t "Z11 the sidebar comes back as a list when none runs"
kill_sidebars; unhook; to tatest-z5; tm select-window -t "$(wid =tatest-z5:0)"      # the claim runs one follow, so the list ends in the client's window: the recorded one
drow=$(printf 'D\ttatest-z5\t0\n'); printf '%s\n' "$drow" >"$WRROOT/d.tsv"; arow_ sid-r5 tatest-z5 0 5 "$REPO" >>"$WRROOT/d.tsv"
out=$(resume_run --resurrect --from "$WRROOT/d.tsv" 2>&1)
has "Z11 the report says dashboard" "✓ dashboard" "$out"
ok "Z11 a list runs in the recorded window" "$(wid =tatest-z5:0)" "$(wait_eq "$(wid =tatest-z5:0)" sbwin)"
tm kill-pane -t "$(sbpane)" 2>/dev/null; unhook; to tatest-work

t "Z12 Z13 a snapshot taken with the sidebar left of the chat restores the chat into its own pane; an older snapshot never takes the sidebar's shell"
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
# What M tests is the migration, not the follow: a follow hook that ran after it would move the fake sidebar to the client's window, as it should, and M1 would read that.
tm set-hook -gu 'session-window-changed[43]'; tm set-hook -gu 'client-session-changed[43]'
modrun migrate_seats; wait_syncs
ok "M1 chat A is in its home window" "$HA" "$(wid "$PAo")"; ok "M1 chat B is in its home window" "$HB" "$(wid "$PBo")"
ok "M1 no placeholder is left" 0 "$(tm list-panes -a -F '#{@tagents_slot}' | grep -c 1)"
ok "M1 the dashboard window is an ordinary window holding the sidebar" "$OLDW" "$(sbwin)"
ok "M1 ...alone in it" 1 "$(npanes "$OLDW")"
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
ok "F13 no lock directory left" no "$(wait_eq_long no lockheld)"
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
