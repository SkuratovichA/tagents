#!/usr/bin/env bash
#
# tests/cockpit.sh — the cockpit: a second tmux client (a nested `tmux attach` in a pane) beside the dashboard.
#
# The first section pins the tmux 3.7b behaviour the design measured and the later sections build on, so that a different tmux fails here
# before it fails in the product. Later sections are appended below the marked "contract" section; the trailer prints the summary.
#
# NOTHING HERE MAY TOUCH THE DEFAULT TMUX SOCKET. The server is `tmux -L tatest-cockpit-$$ -f /dev/null`, torn down in the trap, and the
# clients are real ones on ptys (`script`). Run as
#   env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$(mktemp -d)" bash tests/cockpit.sh
#
# bash 3.2, any cwd.

set -uo pipefail

[ "${TERM:-dumb}" = dumb ] && TERM=xterm-256color
export TERM
[ -n "${LC_ALL:-}${LC_CTYPE:-}" ] || export LC_CTYPE=en_US.UTF-8

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/scratch-guard.sh" && scratch_guard cockpit.sh || exit 1
. "$HERE/wait.sh"

command -v tmux >/dev/null 2>&1 || { echo "cockpit.sh: no tmux"; exit 1; }

CPS=tatest-cockpit-$$
CPSOCK=""
CPROOT=$(mktemp -d "${TMPDIR:-/tmp}/tagents-cp.XXXXXX") || exit 1
CPROOT=$(cd "$CPROOT" && pwd -P) || exit 1
trap 'tmux -L "$CPS" kill-server >/dev/null 2>&1
      for f in "$CPROOT"/keeper*.pid; do [ -s "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
      rm -rf "$CPROOT"' EXIT INT TERM

unset TMUX TMUX_PANE

tm() { tmux -L "$CPS" "$@"; }

tm -f /dev/null new-session -d -s alpha -x 200 -y 50 "exec sleep 600" || exit 1
tm set -g default-shell /bin/sh >/dev/null 2>&1
tm set -g default-command '' >/dev/null 2>&1
for s in beta gamma delta; do tm new-session -d -s "$s" -x 200 -y 50 "exec sleep 600" >/dev/null 2>&1; done
CPSOCK=$(tm display -p '#{socket_path}' 2>/dev/null)
[ -n "$CPSOCK" ] || { echo "cockpit.sh: no socket for $CPS"; exit 1; }

skip() { printf '  SKIP %s\n' "$1"; }                                  # <name (reason)> — counts as neither pass nor fail

clients()  { tm list-clients -F '#{client_name}' 2>/dev/null | sort; }
nclients() { tm list-clients 2>/dev/null | wc -l | tr -d ' '; }
csess()    { tm list-clients -F '#{client_name} #{client_session}' 2>/dev/null | awk -v c="$1" '$1 == c { print $2 }'; }
present()  { tm list-clients -F '#{client_name}' 2>/dev/null | grep -cxF "$1"; }   # <client> — 1 while attached, 0 once gone
opt()      { tm show -gqv "$1" 2>/dev/null; }
# W,NB when every descriptor the server holds on <tty> is writable and non-blocking (lsof prints the flags as R,W,NB,...), otherwise how many of how many are.
srv_nb()   { lsof +fg -a -p "$(tm display -p '#{pid}')" -- "$1" 2>/dev/null |
               awk 'NR > 1 { n++; if ($6 ~ /(^|,)W(,|$)/ && $6 ~ /(^|,)NB(,|;|$)/) ok++ } END { if (n && n == ok) print "W,NB"; else printf "%d of %d writable and non-blocking\n", ok, n }'; }

# A client on a pty, attached to <session> by the nested route: TMUX unset, the socket by path. <n> numbers its pid file, <session> is a
# bare name (the target gets the colon, `=name` alone is not an exact match), <attach flags…> go to `attach` (-f no-detach-on-destroy).
# Its stdin is a sleep, so it never detaches by itself. KC is set to the new client's name.
KC=""
kclient() {  # <n> <session> [attach flags…]
  local n=$1 s=$2 before i=0 after; shift 2
  before=$(clients)
  ( { sleep 300 & printf '%s\n' "$!" >"$CPROOT/keeper$n.pid"; wait; } |
      script -q /dev/null sh -c 'stty cols 200 rows 50; exec env -u TMUX tmux -S "$0" attach "$@"' "$CPSOCK" "$@" -t "=$s:" >/dev/null 2>&1 & ) >/dev/null 2>&1
  KC=""
  while [ "$i" -lt 40 ]; do
    after=$(clients)
    KC=$(printf '%s\n' "$after" | grep -vxFf <(printf '%s\n' "$before") | head -1)
    [ -n "$KC" ] && break
    i=$((i + 1)); sleep 0.1
  done
  sleep 0.5
}
dropclient() { [ -s "$CPROOT/keeper$1.pid" ] && kill "$(cat "$CPROOT/keeper$1.pid")" 2>/dev/null; }   # <n>

# ---------------------------------------------------------------------------------------------------------------------------------
# tmux contract
# ---------------------------------------------------------------------------------------------------------------------------------

t "contract (a): a client attached from a pane with TMUX unset"
kclient 1 alpha;                                           X=$KC
kclient 2 beta -f no-detach-on-destroy;                    N=$KC
ok "a: two clients" 2 "$(nclients)"
ok "a: the first is on alpha" alpha "$(csess "$X")"
ok "a: the nested one is on beta" beta "$(csess "$N")"
has "a: the nested client is a different tty" /dev/ "$N"

t "contract (b): switch-client -c moves only the named client"
tm send-keys -K -c "$X" F12                                # the other client is the most recently active one: a switch-client without -c would move it
tm switch-client -c "$N" -t '=gamma:'
ok "b: the named client moved" gamma "$(wait_eq gamma csess "$N")"
ok "b: the other client stayed" alpha "$(csess "$X")"
tm switch-client -c "$N" -t '=beta:'
wait_eq beta csess "$N" >/dev/null

t "contract (c): the shown session is killed"
tm switch-client -c "$N" -t '=gamma:'
wait_eq gamma csess "$N" >/dev/null
tm kill-session -t '=gamma:'
now=$(wait_eq 1 present "$N")
ok "c: with no-detach-on-destroy the client stays attached" 1 "$now"
other=$(csess "$N")
[ -n "$other" ] && [ "$other" != gamma ] && tm has-session -t "=$other:" 2>/dev/null; ok "c: it moved to a session that still exists" 0 "$?"
tm new-session -d -s gamma -x 200 -y 50 "exec sleep 600"
tm switch-client -c "$N" -t '=beta:'
wait_eq beta csess "$N" >/dev/null
tm new-session -d -s eps -x 200 -y 50 "exec sleep 600"
kclient 3 eps;                                             Z=$KC
ok "c: a client without the flag is on eps" eps "$(csess "$Z")"
tm kill-session -t '=eps:'
ok "c: without no-detach-on-destroy the client is gone" 0 "$(wait_eq 0 present "$Z")"
ok "c: the other two stayed" 2 "$(nclients)"

t "contract (d): a key table forwards the keys it does not bind"
KTF="$CPROOT/kt.out"; : >"$KTF"
tm new-session -d -s kt -x 200 -y 50 "stty raw -echo; exec cat >$KTF"
tm set -t '=kt:' prefix None
tm set -t '=kt:' key-table cx
tm bind -T cx C-a set -g @kt hit
tm set -g @kt none
tm switch-client -c "$N" -t '=kt:'
wait_eq kt csess "$N" >/dev/null
tm send-keys -K -c "$N" C-a
ok "d: a bound key of the table runs its command" hit "$(wait_eq hit opt @kt)"
tm send-keys -K -c "$N" q
ok "d: a key the root table does not bind reaches the active pane" q "$(wait_eq q cat "$KTF")"
tm switch-client -c "$N" -t '=beta:'
wait_eq beta csess "$N" >/dev/null
tm unbind -T cx C-a; tm set -gu @kt; tm kill-session -t '=kt:'

t "contract (e): a hook's if -F action is not format-expanded, run-shell -C expands its argument"
tm set -gu @probe
tm set-hook -g 'client-session-changed[44]' "if -F \"#{==:#{hook_client},$N}\" \"run-shell -C \\\"set -g @probe #{session_name}\\\"\""
tm switch-client -c "$N" -t '=delta:'
probe=$(wait_eq delta opt @probe)
hasnt "e: the probe is not the literal format" '#{' "$probe"
ok "e: the probe holds the name of the session switched to" delta "$probe"
tm set -gu @probe
tm switch-client -c "$N" -t '=beta:'
wait_eq beta csess "$N" >/dev/null

t "contract (f): the client loop reads the hook client's own last session"
# Y (the nested client) has last session gamma and is on beta, and is the most recently active client. X moves alpha to delta by a key of Y's
# (the command's client is Y, the hook client is X): both forms name delta. Then X's session is killed: the hook client's own last session is
# empty, and a bare #{client_last_session} names another client's, which is the hazard (Y's [gamma] on 3.7b, recorded in BARE, not asserted).
tm switch-client -c "$N" -t '=gamma:'
wait_eq gamma csess "$N" >/dev/null
tm switch-client -c "$N" -t '=beta:'
wait_eq beta csess "$N" >/dev/null
tm new-session -d -s doom -x 200 -y 50 "exec sleep 600"
kclient 6 alpha -f no-detach-on-destroy;                   F=$KC
tm bind -n F11 switch-client -c "$F" -t '=delta:'
tm bind -n F10 kill-session -t '=doom:'
LOOPFMT='#{L:#{?#{==:#{client_name},#{hook_client}},#{client_last_session},}}'
tm set -gu @bare; tm set -gu @loop
tm set-hook -g 'client-session-changed[45]' "if -F \"#{==:#{hook_client},$F}\" \"run-shell -C \\\"set -g @bare [#{client_last_session}] ; set -g @loop [$LOOPFMT]\\\"\""
tm send-keys -K -c "$N" F11
wait_eq delta csess "$F" >/dev/null
ok "f: the loop names the hook client's own last session" "[alpha]" "$(wait_eq "[alpha]" opt @loop)"
tm switch-client -c "$F" -t '=doom:'
wait_eq doom csess "$F" >/dev/null
tm set -gu @bare; tm set -gu @loop
tm set -g @loop unset
tm send-keys -K -c "$N" F10
now=$(wait_eq 1 present "$F")
wait_eq "[]" opt @loop >/dev/null
ok "f: the client stayed attached when its session was killed" 1 "$now"
ok "f: the loop names the hook client's own last session, which is empty once it was closed" "[]" "$(opt @loop)"
BARE=$(opt @bare)
tm set-hook -gu 'client-session-changed[45]'
tm unbind -n F11; tm unbind -n F10
tm set -gu @bare; tm set -gu @loop
dropclient 6

t "contract (g): a session-level hook shadows the global hook of the same index"
tm set -gu @g42; tm set -gu @s42
tm set-hook -g 'after-new-window[42]' 'set -g @g42 hit'
tm set-hook -t '=alpha:' 'after-new-window[42]' 'set -g @s42 hit'
tm new-window -d -t '=alpha:' "exec sleep 600"
ok "g: the session's hook ran" hit "$(wait_eq hit opt @s42)"
ok "g: the global one did not" "" "$(opt @g42)"
tm new-window -d -t '=beta:' "exec sleep 600"
ok "g: another session still runs the global one" hit "$(wait_eq hit opt @g42)"
tm set-hook -gu 'after-new-window[42]'; tm set-hook -u -t '=alpha:' 'after-new-window[42]'
tm set -gu @g42; tm set -gu @s42

t "contract (h): prefix d detaches the client and keeps the session; killing the session removes the client"
tm new-session -d -s pd -x 200 -y 50 "exec sleep 600"
kclient 4 pd -f no-detach-on-destroy;                      D=$KC
ok "h: the client is on pd" pd "$(csess "$D")"
tm send-keys -K -c "$D" C-b
tm send-keys -K -c "$D" d
ok "h: prefix d: the client is gone" 0 "$(wait_eq 0 present "$D")"
ok "h: prefix d: the session is still there" pd "$(tm list-sessions -F '#{session_name}' | grep -x pd)"
tm kill-session -t '=pd:'
tm new-session -d -s pk -x 200 -y 50 "exec sleep 600"
kclient 5 pk;                                              K=$KC
ok "h: the client is on pk" pk "$(csess "$K")"
tm kill-session -t '=pk:'
ok "h: killing the session removes the client" 0 "$(wait_eq 0 present "$K")"

t "contract (i): after-kill-pane fires on kill-pane"
tm set -g @kpn 0
tm set-hook -g 'after-kill-pane[42]' 'run-shell -C "set -g @kpn #{e|+:#{@kpn},1}"'
tm split-window -d -t '=delta:' "exec sleep 600"
pane=$(tm list-panes -t '=delta:' -F '#{pane_id}' | tail -1)
tm kill-pane -t "$pane"
ok "i: the counter moved" 1 "$(wait_eq 1 opt @kpn)"
tm set-hook -gu 'after-kill-pane[42]'; tm set -gu @kpn

# ---------------------------------------------------------------------------------------------------------------------------------
# end of the contract section; later sections go here
# ---------------------------------------------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------------------------------------------------
# the cockpit itself: tagents run against the server above, restarted for every section so that no session or hook is left over
# ---------------------------------------------------------------------------------------------------------------------------------

TA="$HERE/../tagents"
BIN="$CPROOT/bin";       mkdir -p "$BIN"
CPSTATE="$CPROOT/state"; mkdir -p "$CPSTATE"
CPCONF="$CPROOT/config.toml"
printf '#!/bin/sh\nexit 0\n' >"$BIN/tusage"
printf '#!/bin/sh\nexec sleep 600\n' >"$BIN/vim"
cp /bin/sleep "$BIN/claude" || exit 1
codesign --remove-signature "$BIN/claude" >/dev/null 2>&1
codesign -f -s - "$BIN/claude" >/dev/null 2>&1
chmod +x "$BIN/tusage" "$BIN/vim" "$BIN/claude"
ln -sf "$TA" "$BIN/tagents"
export PATH="$BIN:$PATH"
export TA_STATE_DIR="$CPSTATE"
export TA_CONFIG="$CPCONF"
unset TA_MODE TA_FLAT TA_COLS TA_NEW_CMD TA_RESUME_CMD TA_HOME TA_SESSION TA_WIDTH CLAUDE_CONFIG_DIR CLAUDE_PID

ta()    { env TMUX="$CPSOCK,0,0" bash "$TA" "$@"; }
cplist() { tm list-sessions -F '#{session_name}' 2>/dev/null | sort | tr '\n' ' '; }

# A fresh server with work (windows 1 and 2, the second one a shell), personal and scratch, no client, no hooks and no config file.
cpstart() {
  local k
  rm -f "$CPCONF"
  for k in "$CPROOT"/keeper*.pid; do [ -s "$k" ] && kill "$(cat "$k")" 2>/dev/null; done
  rm -f "$CPROOT"/keeper*.pid
  tm kill-server >/dev/null 2>&1; sleep 0.3
  rm -rf "$CPSTATE"; mkdir -p "$CPSTATE"
  tm -f /dev/null new-session -d -s work -x 200 -y 50 -n one "exec sleep 600" || exit 1
  tm set -g default-shell /bin/sh >/dev/null 2>&1
  tm set -g default-command '' >/dev/null 2>&1
  tm new-window -d -t '=work:2' -n two
  tm select-window -t '=work:2'
  for k in personal scratch; do tm new-session -d -s "$k" -x 200 -y 50 "exec sleep 600" >/dev/null 2>&1; done
}
vpane()  { tm list-panes -t '=tagents:' -F '#{pane_at_left} #{pane_id}' 2>/dev/null | awk '$1 == 0 { print $2 }'; }
lpane()  { tm list-panes -t '=tagents:' -F '#{pane_at_left} #{pane_id}' 2>/dev/null | awk '$1 == 1 { print $2 }'; }
vtty()   { opt @tagents_viewport_tty; }
vshows() { csess "$(vtty)"; }                                    # the session the viewport's client is on
vwin()   { tm list-clients -F '#{client_name} #{session_name}:#{window_index}' 2>/dev/null | awk -v c="$(vtty)" '$1 == c { print $2 }'; }
left_of() {  # <window target> — 1 when its leftmost pane runs the list
  tm list-panes -t "$1" -F '#{pane_at_left} #{pane_start_command}' 2>/dev/null | awk '$1 == 1 && $0 ~ /tagents/ && $0 !~ /--viewport/ { n = 1 } END { print n + 0 }'
}

t "A cockpit made, A new dashboard, From another session, The pane and its client"
cpstart
kclient 11 work;                                           U=$KC
ta --ensure-dash >"$CPROOT/ed.out" 2>&1; rc=$?
ok "A cockpit made: --ensure-dash exits 0" 0 "$rc"
ok "A cockpit made: the session tagents exists beside the others" "personal scratch tagents work " "$(cplist)"
has "A cockpit made: the list is on its left" tagents "$(tm display -p -t "$(lpane)" '#{pane_start_command}')"
hasnt "A cockpit made: ...and is not the viewport" --viewport "$(tm display -p -t "$(lpane)" '#{pane_start_command}')"
has "A cockpit made: the viewport is on its right" --viewport "$(tm display -p -t "$(vpane)" '#{pane_start_command}')"
ok "A new dashboard: one window" 1 "$(tm list-windows -t '=tagents:' | wc -l | tr -d ' ')"
near "A new dashboard: the list is 90 columns wide" 90 "$(tm display -p -t "$(lpane)" '#{pane_width}')"
ok "A new dashboard: @tagents_cockpit is 1" 1 "$(tm show -qv -t '=tagents:' @tagents_cockpit)"
ok "A new dashboard: the status line is off" off "$(tm show -v -t '=tagents:' status)"
ok "From another session: the viewport shows work:2" work:2 "$(wait_eq work:2 vwin)"
ok "From another session: the terminal shows the session tagents" tagents "$(wait_eq tagents csess "$U")"
ok "The pane and its client: the right pane is titled tagents-viewport" tagents-viewport "$(wait_eq tagents-viewport tm display -p -t "$(vpane)" '#{pane_title}')"
ok "The pane and its client: @tagents_viewport is 1" 1 "$(tm display -p -t "$(vpane)" '#{@tagents_viewport}')"
ok "The pane and its client: the viewport's client is on work and its tty is @tagents_viewport_tty" work "$(vshows)"
ok "The pane and its client: that tty is the pane's own" "$(tm display -p -t "$(vpane)" '#{pane_tty}')" "$(vtty)"

t "A cockpit made from another directory"
cpstart
kclient 64 work;                                           U=$KC
ELSEWHERE="$CPROOT/elsewhere"; mkdir -p "$ELSEWHERE"
( cd "$ELSEWHERE" && ta --ensure-dash >/dev/null 2>&1 )
ok "A cockpit made from another directory: the list pane starts in the home directory" "$HOME" "$(wait_eq "$HOME" tm display -p -t "$(lpane)" '#{pane_current_path}')"
ok "...and the viewport pane starts there too" "$HOME" "$(wait_eq "$HOME" tm display -p -t "$(vpane)" '#{pane_current_path}')"

t "A title set from inside"
tm set -g set-titles on
tm switch-client -c "$(vtty)" -t '=work:1'
wait_eq work:1 vwin >/dev/null
tm switch-client -c "$(vtty)" -t '=work:2'
wait_eq work:2 vwin >/dev/null
settle
ok "A title set from inside: the pane keeps its title" tagents-viewport "$(tm display -p -t "$(vpane)" '#{pane_title}')"
tm set -g set-titles off

t "Anywhere else"
wp=$(tm list-panes -t '=work:2' -F '#{pane_id}' | head -1)
for who in "$(lpane)" "$wp" ""; do
  err=$(env TMUX="$CPSOCK,0,0" TMUX_PANE="$who" bash "$TA" --viewport 2>&1 >/dev/null); rc=$?
  ok "Anywhere else: pane [${who:-none}] is refused with the line" "tagents: --viewport runs only in the cockpit's viewport pane" "$err"
  ok "Anywhere else: pane [${who:-none}] exits 1" 1 "$rc"
done

t "From the viewport"
tm bind -n F9 run-shell "bash '$TA' --ensure-dash"
tm select-pane -t "$(vpane)"
tm send-keys -K -c "$(vtty)" F9
ok "From the viewport: the list is the active pane" "$(lpane)" "$(wait_eq "$(lpane)" tm display -p -t '=tagents:' '#{pane_id}')"
ok "From the viewport: the viewport still shows the window it showed" work:2 "$(vwin)"
ok "From the viewport: no second dashboard was made" "personal scratch tagents work " "$(cplist)"
tm unbind -n F9

t "Its terminals outlive it"
tm kill-session -t '=tagents:'
ok "Its terminals outlive it: the terminal is still attached" 1 "$(wait_eq 1 present "$U")"
ok "Its terminals outlive it: it shows work" work "$(wait_eq work csess "$U")"
ta --ensure-dash >/dev/null 2>&1
ok "Its terminals outlive it: the next list is the cockpit again" 1 "$(wait_eq_long 1 tm show -qv -t '=tagents:' @tagents_cockpit)"
ok "Its terminals outlive it: ...and no sidebar went into work:2" 0 "$(left_of '=work:2')"

t "No dashboard section"
cpstart
kclient 12 work
ta --ensure-dash >/dev/null 2>&1
ok "No dashboard section: the session tagents is the cockpit" 1 "$(wait_eq_long 1 tm show -qv -t '=tagents:' @tagents_cockpit)"
ok "No dashboard section: the list is the leftmost pane of tagents" 1 "$(left_of '=tagents:')"
ok "No dashboard section: no sidebar went into work:2" 0 "$(left_of '=work:2')"

t "A dashboard.layout left in the file"
cpstart
printf '[dashboard]\nlayout = "follow"\n' >"$CPCONF"
kclient 20 work
ta --ensure-dash >/dev/null 2>&1
ok "A dashboard.layout left in the file: the session tagents is the cockpit" 1 "$(wait_eq_long 1 tm show -qv -t '=tagents:' @tagents_cockpit)"
ok "A dashboard.layout left in the file: ...and no sidebar went into work:2" 0 "$(left_of '=work:2')"

t "Someone else's session"
cpstart
kclient 13 work
tm new-session -d -s tagents -x 200 -y 50 "exec '$BIN/vim'"
vpid=$(tm display -p -t '=tagents:' '#{pane_pid}')
err=$(ta --ensure-dash 2>&1 >/dev/null); rc=$?
ok "Someone else's session: the refusal line on standard error" "tagents: session tagents is taken — rename it, and the dashboard can start" "$err"
ok "Someone else's session: exit 1" 1 "$rc"
has "Someone else's session: that session still runs vim" "/bin/vim" "$(tm display -p -t '=tagents:' '#{pane_start_command}')"
ok "Someone else's session: ...in the same process" "$vpid" "$(tm display -p -t '=tagents:' '#{pane_pid}')"
ok "Someone else's session: no session was created" "personal scratch tagents work " "$(cplist)"
ok "Someone else's session: no window was added to it" 1 "$(tm list-panes -t '=tagents:' | wc -l | tr -d ' ')"

t "tagents typed in a shell"
shell_idle() { tm display -p -t '=work:2' '#{pane_current_command}' | grep -cE '^(sh|bash)$'; }
cpstart
kclient 14 work;                                           U=$KC
tm send-keys -t '=work:2' 'tagents' Enter
ok "tagents typed in a shell: the session tagents exists" tagents "$(wait_eq_long tagents tm list-sessions -F '#{session_name}' | grep -x tagents)"
ok "tagents typed in a shell: the viewport shows work:2" work:2 "$(wait_eq_long work:2 vwin)"
ok "tagents typed in a shell: the terminal shows the session tagents" tagents "$(wait_eq tagents csess "$U")"
ok "tagents typed in a shell: the shell pane is back at its prompt" 1 "$(wait_eq 1 shell_idle)"

t "No client"
cpstart
err=$(ta --ensure-dash 2>&1 >/dev/null); rc=$?
ok "No client: exit 1" 1 "$rc"
ok "No client: no session tagents exists" 0 "$(tm list-sessions -F '#{session_name}' | grep -cx tagents)"

t "Detach and come back"
cpstart
kclient 15 work;                                           U=$KC
ta --ensure-dash >/dev/null 2>&1
wait_eq work:2 vwin >/dev/null
VT=$(vtty)
tm send-keys -K -c "$VT" C-b
tm send-keys -K -c "$VT" d
ok "Detach and come back: the user's terminal is detached" 0 "$(wait_eq 0 present "$U")"
ok "Detach and come back: the session tagents has a viewport attached to work again" work "$(wait_eq work csess "$VT")"
ok "Detach and come back: the viewport kept its tty" "$VT" "$(vtty)"
kclient 16 tagents;                                        U=$KC
ok "Detach and come back: after attach the user is on tagents" tagents "$(csess "$U")"
ok "Detach and come back: ...with the viewport on work:2" work:2 "$(vwin)"

t "Nothing else to show"
vp_text() { tm capture-pane -p -t "$(vpane)" | grep -o 'tagents: no session to show' | head -1; }
# The wait-for clients this server has: `ring_wait` runs a plain `tmux if-shell` inside a pane, which reaches the server through the pane's TMUX, so the argv carries no -L; ps -E appends the environment, whose TMUX names the socket. Only a client (`tmux if-shell`) counts, not the server whose argv holds the command.
cpwaiters() { ps -A -ww -E -o command= 2>/dev/null | grep -F 'tmux if-shell' | grep -F 'wait-for tagents-ev' | grep -cF "TMUX=$CPSOCK,"; }
cporphans() { ps -A -ww -E -o ppid=,command= 2>/dev/null | awk '$1 == 1' | grep -F 'tmux if-shell' | grep -F 'wait-for tagents-ev' | grep -cF "TMUX=$CPSOCK,"; }   # the waiters whose parent is gone: a leaked client is reparented to pid 1
cpwaiting() { [ "$(cpwaiters)" -ge 1 ] && echo 1; }
settle
for s in personal scratch work; do tm kill-session -t "=$s:"; done
ok "Nothing else to show: the viewport reads that there is no session" "tagents: no session to show" "$(wait_eq_long "tagents: no session to show" vp_text)"
ok "Nothing else to show: the user's terminal stayed attached" 1 "$(present "$U")"
tm new-session -d -s scratch -x 200 -y 50 "exec sleep 600"
ok "Nothing else to show: once scratch exists the viewport shows it" scratch "$(wait_eq_long scratch vshows)"
tm set-hook -gu 'client-session-changed[44]'


# ---------------------------------------------------------------------------------------------------------------------------------
# selecting a row: the viewport's client moves, no pane does
# ---------------------------------------------------------------------------------------------------------------------------------

mkwin()    { tm new-window -d -P -F '#{pane_id}' -t "=$1:" -n "$2" "exec '$BIN/claude' 600"; }   # <session> <name> -> the new pane
panes_of() { tm list-panes -a -F '#{pane_id}=#{window_id}' | sort | tr '\n' ' '; }       # every pane with the window it is in
headers()  { TA_COLS=80 ta --list 2>/dev/null | cut -f2 | grep '▾' | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/[^[:alpha:] ]//g' | tr -s ' ' | tr '\n' ' '; }   # 80 wide: from 92 a header also shows its path, and the suite must not depend on the terminal it runs in
cwin()     { tm list-clients -F '#{client_name} #{session_name}:#{window_index}' 2>/dev/null | awk -v c="$1" '$1 == c { print $2 }'; }   # <client> -> the window it shows
allsess()  { tm list-clients -F '#{client_name}=#{session_name}' | sort | tr '\n' ' '; }
vact()     { tm display -p -t '=tagents:' '#{pane_id}'; }                                  # the dashboard's active pane
vmsg()    { tm show-messages 2>/dev/null | grep -F " $(vtty) message: " | head -1 | sed 's/.* message: //'; }   # the newest message the viewport's client was shown (tmux lists them newest first)

# work (two windows, the viewport on the second), personal with a chat in a window of its own ($PCW); the dashboard's terminal on tagents.
cpselect_up() {
  cpstart
  PCHAT=$(mkwin personal chat)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" working sid-sel "$HOME" "" "agent sel" "" >"$CPSTATE/${PCHAT#%}.tsv"
  kclient "$1" work;                                       U=$KC
  ta --ensure-dash >/dev/null 2>&1
  wait_eq work:2 vwin >/dev/null
  wait_eq tagents csess "$U" >/dev/null
  PCW=personal:$(tm display -p -t "$PCHAT" '#{window_index}')
}

t "Enter on a chat, Nothing moves"
cpselect_up 21
before=$(panes_of)
ta --act open "$PCHAT" working sid-sel "$HOME" >/dev/null 2>&1; rc=$?
ok "Enter on a chat: exit 0" 0 "$rc"
ok "Enter on a chat: the viewport shows the chat's window" "$PCW" "$(wait_eq $PCW vwin)"
ok "Enter on a chat: the chat's pane is active in its window" "$PCHAT" "$(tm display -p -t "=$PCW" '#{pane_id}')"
ok "Enter on a chat: the viewport is the dashboard's active pane" "$(vpane)" "$(vact)"
ok "Enter on a chat: the user's terminal still shows the session tagents" tagents "$(csess "$U")"
ok "Nothing moves: every pane is in the window it was in" "$before" "$(panes_of)"
ok "Nothing moves: the list is still the dashboard's left pane" 1 "$(left_of '=tagents:')"
ok "Nothing moves: the dashboard has two panes" 2 "$(tm list-panes -t '=tagents:' | wc -l | tr -d ' ')"

t "A header"
tm select-pane -t "$(lpane)"
tm select-window -t '=work:one'
hk=$(ta --list 2>/dev/null | awk -F'\t' '$2 ~ /▾/ && $2 ~ /work/ { print $1; exit }')
ta --act open "$hk" none "" "" "▾ work" >/dev/null 2>&1
ok "A header: the viewport shows the current window of work" work:0 "$(wait_eq work:0 vwin)"
ok "A header: the viewport is the dashboard's active pane" "$(vpane)" "$(vact)"
ok "A header: the terminal still shows tagents" tagents "$(csess "$U")"

t "Window names with the cockpit up"
ta --sync-names >/dev/null 2>&1
ok "Window names with the cockpit up: a sync leaves the dashboard's window named dashboard" dashboard "$(tm display -p -t '=tagents:' '#{window_name}')"

t "ctrl-g goes there"
vbefore=$(vwin)
ta --act goto "$PCHAT" working sid-sel "$HOME" >/dev/null 2>&1; rc=$?
ok "ctrl-g on a chat: exit 0" 0 "$rc"
ok "ctrl-g on a chat: the terminal shows the chat's window" "$PCW" "$(wait_eq "$PCW" cwin "$U")"
ok "ctrl-g on a chat: ...in the chat's own session" personal "$(csess "$U")"
ok "ctrl-g on a chat: the chat's pane is active" "$PCHAT" "$(tm display -p -t "=$PCW" '#{pane_id}')"
ok "ctrl-g on a chat: the viewport did not move" "$vbefore" "$(vwin)"
ok "ctrl-g on a chat: the list is still the dashboard's left pane" 1 "$(left_of '=tagents:')"
tm switch-client -c "$U" -t '=tagents:'
wait_eq tagents csess "$U" >/dev/null
ta --act goto "$hk" none "" "" "▾ work" >/dev/null 2>&1
ok "ctrl-g on a header: the terminal shows the session's current window" work:0 "$(wait_eq work:0 cwin "$U")"
tm switch-client -c "$U" -t '=tagents:'
wait_eq tagents csess "$U" >/dev/null
ta --act goto "$PCHAT" dead sid-sel "$HOME" >/dev/null 2>&1
ok "ctrl-g on a closed row: the terminal stays on the dashboard" tagents "$(csess "$U")"
GONE=$(mkwin personal gone); tm kill-pane -t "$GONE"
ta --act goto "$GONE" working sid-gone "$HOME" >/dev/null 2>&1
ok "ctrl-g on a window that is gone: the terminal stays on the dashboard" tagents "$(csess "$U")"
ok "ctrl-g on a window that is gone: the viewport did not move" "$vbefore" "$(vwin)"

t "ctrl-g in the session the viewport shows"
VW=$(vwin)
SAMEP=$(mkwin "${VW%%:*}" samesess)
SAMEW="${VW%%:*}:$(tm display -p -t "$SAMEP" '#{window_index}')"
ta --act goto "$SAMEP" working sid-same "$HOME" >/dev/null 2>&1
ok "ctrl-g in the viewport's session: the terminal shows that window" "$SAMEW" "$(wait_eq "$SAMEW" cwin "$U")"
ok "...and the viewport shows it too, a session having one current window" "$SAMEW" "$(wait_eq "$SAMEW" vwin)"
tm switch-client -c "$U" -t '=tagents:'
wait_eq tagents csess "$U" >/dev/null
tm select-window -t "=$VW"
tm kill-pane -t "$SAMEP"

t "ctrl-g with no terminal but the viewport's"
VT=$(vtty); VB=$(vwin); VSB=$(vshows)
tm detach-client -t "$U"
ok "ctrl-g with no terminal: the user's terminal is detached" 0 "$(wait_eq 0 present "$U")"
tm display-message -c "$VT" "nothing yet"
ta --act goto "$PCHAT" working sid-sel "$HOME" >/dev/null 2>&1
ok "ctrl-g with no terminal: it says there is none to take there" "tagents: no terminal to take there" "$(wait_eq "tagents: no terminal to take there" vmsg)"
ok "...and the viewport stayed on its window" "$VB" "$(vwin)"
ok "...and in its session" "$VSB" "$(vshows)"
kclient 65 tagents;                                        U=$KC
ok "ctrl-g with no terminal: the terminal that comes back is on the dashboard" tagents "$(csess "$U")"

t "Not listed, Still two panes"
ok "Not listed: the headers are work and personal and scratch" "personal scratch work " "$(headers | tr ' ' '\n' | grep . | sort | tr '\n' ' ')"
hasnt "Not listed: no header tagents" tagents "$(headers)"
wk=$(tm list-panes -t '=work:2' -F '#{pane_id}' | head -1)
nwin_before=$(tm list-windows -a | wc -l | tr -d ' ')
TA_NEW_CMD="sleep 600" ta --new "$HOME" >/dev/null 2>&1
ta --act shell "$wk" none "" "$HOME" >/dev/null 2>&1
nwin_after=$(tm list-windows -a | wc -l | tr -d ' ')
ta --act beside "$PCHAT" working sid-sel "$HOME" >/dev/null 2>&1
ok "Still two panes: a chat and a shell were made elsewhere" 2 "$((nwin_after - nwin_before))"
ok "Still two panes: the session tagents has one window" 1 "$(tm list-windows -t '=tagents:' | wc -l | tr -d ' ')"
ok "Still two panes: ...with the list and the viewport only" 2 "$(tm list-panes -t '=tagents:' | wc -l | tr -d ' ')"
ok "Still two panes: the list is still on the left" 1 "$(left_of '=tagents:')"

t "ctrl-s"
cpselect_up 22
tm select-window -t '=work:2'
tm switch-client -c "$(vtty)" -t '=work:2'
wait_eq work:2 vwin >/dev/null
ta --act beside "$PCHAT" working sid-sel "$HOME" >/dev/null 2>&1
ok "ctrl-s: the chat's pane is in the window work:2" "$(tm display -p -t '=work:2' '#{window_id}')" "$(wait_eq "$(tm display -p -t '=work:2' '#{window_id}')" tm display -p -t "$PCHAT" '#{window_id}')"
ok "ctrl-s: nothing was added to the dashboard" 2 "$(tm list-panes -t '=tagents:' | wc -l | tr -d ' ')"

t "A new chat from outside tmux"
cpselect_up 23
tm switch-client -c "$(vtty)" -t '=work:2'
wait_eq work:2 vwin >/dev/null
nd="$CPROOT/proj"; mkdir -p "$nd"
nw_before=$(tm list-windows -t '=work:' | wc -l | tr -d ' ')
TA_NEW_CMD="sleep 600" ta --new "$nd" >/dev/null 2>&1
ok "A new chat from outside tmux: work gained a window" "$((nw_before + 1))" "$(wait_eq_long "$((nw_before + 1))" sh -c "tm() { tmux -L $CPS \"\$@\"; }; tm list-windows -t '=work:' | wc -l | tr -d ' '")"
ok "A new chat from outside tmux: no window was made in tagents" 1 "$(tm list-windows -t '=tagents:' | wc -l | tr -d ' ')"
ok "A new chat from outside tmux: the viewport shows work" work "$(wait_eq work vshows)"

t "A popup's enter"
cpselect_up 24
TA_MODE=popup ta --act open "$PCHAT" working sid-sel "$HOME" >/dev/null 2>&1
ok "A popup's enter: the viewport shows the chat's window" "$PCW" "$(wait_eq "$PCW" vwin)"
ok "A popup's enter: the list is still the dashboard's left pane" 1 "$(left_of '=tagents:')"
ok "A popup's enter: no extra list was started" 2 "$(tm list-panes -t '=tagents:' | wc -l | tr -d ' ')"

t "A popup from another session"
cpselect_up 25
kclient 26 scratch;                                        W=$KC
tm send-keys -K -c "$W" F12
TA_MODE=popup ta --act open "$PCHAT" working sid-sel "$HOME" >/dev/null 2>&1
ok "A popup from another session: the viewport shows the chat's window" "$PCW" "$(wait_eq $PCW vwin)"
ok "A popup from another session: that terminal shows the session tagents" tagents "$(wait_eq tagents csess "$W")"
ok "A popup from another session: the dashboard's terminal stayed" tagents "$(csess "$U")"

t "A notification clicked"
cpselect_up 27
tm send-keys -K -c "$U" F12
sess_before=$(allsess)
ta --goto "$PCHAT" >/dev/null 2>&1
ok "A notification clicked: the viewport shows the window of the chat" "$PCW" "$(wait_eq "$PCW" vwin)"
ok "A notification clicked: no client changed session except the viewport's" "$(printf '%s' "$sess_before" | sed "s|$(vtty)=[a-z]* |$(vtty)=personal |")" "$(allsess)"


# ---------------------------------------------------------------------------------------------------------------------------------
# the viewport never shows the dashboard (the guard at client-session-changed[44]) and --follow in the cockpit
# ---------------------------------------------------------------------------------------------------------------------------------

LISTED_MODS=$(awk '/^[[:space:]]*for ta_mod in/ { grab = 1 } grab { l = $0; sub(/^[[:space:]]*for ta_mod in[[:space:]]*/, "", l); fin = (l ~ /;[[:space:]]*do[[:space:]]*$/); sub(/;[[:space:]]*do[[:space:]]*$/, "", l); sub(/\\[[:space:]]*$/, "", l); printf "%s ", l; if (fin) exit }' "$TA")
cpmods() {  # <code> — runs it in a shell with every module sourced, against this suite's server and state
  env TMUX="$CPSOCK,0,0" TA_STATE_DIR="$CPSTATE" TA_CONFIG="$CPCONF" SELF="$TA" \
      /bin/bash -c 'for m in '"$LISTED_MODS"'; do . "'"$HERE"'/../lib/tagents/$m.sh"; done; '"$1" >/dev/null 2>&1
}
cpout() {  # <function> [args…] — runs it with every module sourced and prints what it prints, against this suite's server and state
  env TMUX="$CPSOCK,0,0" TA_STATE_DIR="$CPSTATE" TA_CONFIG="$CPCONF" SELF="$TA" \
      /bin/bash -c 'for m in '"$LISTED_MODS"'; do . "'"$HERE"'/../lib/tagents/$m.sh"; done; "$@"' cpout "$@" 2>/dev/null
}
hook44() { tm show-hooks -g 2>/dev/null | grep -c '^client-session-changed\[44\]'; }
wid()    { tm display -p -t "$1" '#{window_id}'; }                       # <window target>
vwid()   { tm list-clients -F '#{client_name} #{window_id}' 2>/dev/null | awk -v c="$(vtty)" '$1 == c { print $2 }'; }
# The line number (counted from 1 in `ta --list`) under the list's cursor, as fzf reports it on its listen port.
curpos() {
  local port j; port=$(tm show -pv -t "$(lpane)" @tagents_port 2>/dev/null)
  [ -n "$port" ] || return 0
  j=$(curl -s "http://127.0.0.1:$port" 2>/dev/null)
  [ -n "${CP_DEBUG:-}" ] && printf '%s\n' "$j" | cut -c1-300 >&2
  printf '%s' "$j" | sed -n 's/.*"current":{"index":\([0-9]*\).*/\1/p' | awk '{ print $1 + 1 }'
}
# 1 once the list has read its input: a cursor posted before that is lost.
listready() {
  local port; port=$(tm show -pv -t "$(lpane)" @tagents_port 2>/dev/null)
  [ -n "$port" ] && curl -s "http://127.0.0.1:$port" 2>/dev/null | grep -c '"reading":false'
}
# The line the cursor must be on for a window, by the rule of cursor_to_window: the first of its panes with a row, else the window's own row, else the header standing in for it.
rowof() {  # <window target>
  local w panes; w=$(wid "$1"); panes=$(tm list-panes -t "$1" -F '#{pane_id}' | tr '\n' ' ')
  ta --list 2>/dev/null | LC_ALL=C awk -F'\t' -v keys="$panes" -v w="$w" '
    BEGIN { nk = split(keys, K, " ") }
    index($2, "\342\226\276") == 0 && !($1 in line) { line[$1] = NR }
    index($2, "\342\226\276") > 0 && !($1 in hline) { hline[$1] = NR }
    END { for (i = 1; i <= nk; i++) if (K[i] in line) { print line[K[i]]; exit }
          if (w in line) print line[w]; else if (w in hline) print hline[w] }'
}
# The sessions work, personal and tagents with a terminal on work, the dashboard up, the hooks as the refresher sets them.
cpguard_up() {  # <n>
  cpstart
  tm kill-session -t '=scratch:'
  kclient "$1" work;                                       U=$KC
  ta --ensure-dash >/dev/null 2>&1
  wait_eq work:2 vwin >/dev/null
  wait_eq_long 1 listready >/dev/null; sleep 1
  cpmods install_event_hooks
}
vgo() { tm switch-client -c "$(vtty)" -t "=$1:"; }                       # <session> — the viewport's client, named as a key binding names it
vkeys() { tm send-keys -K -c "$(vtty)" C-b "$@"; }

t "Next, past the dashboard, Previous, past the dashboard, Picked in the chooser"
cpguard_up 31
ok "the real guard is installed at client-session-changed[44]" 1 "$(hook44)"
vgo personal; wait_eq personal vshows >/dev/null
vkeys ')'
ok "Next, past the dashboard: the viewport shows work" work "$(wait_eq_long work vshows)"
vkeys '('
ok "Previous, past the dashboard: from work the viewport shows personal" personal "$(wait_eq_long personal vshows)"
vgo work; wait_eq work vshows >/dev/null
vkeys '('
ok "Previous, past the dashboard: the viewport shows personal" personal "$(wait_eq_long personal vshows)"
vgo work; wait_eq work vshows >/dev/null
vgo tagents
ok "Picked in the chooser: a pick of tagents from work shows personal" personal "$(wait_eq_long personal vshows)"
ok "Picked in the chooser: the dashboard's terminal stayed on tagents" tagents "$(csess "$U")"

t "Round the end of the order"
cpstart
tm new-session -d -s alpha -x 200 -y 50 "exec sleep 600"; tm new-session -d -s beta -x 200 -y 50 "exec sleep 600"
kclient 32 beta;                                           U=$KC
for s in work personal scratch; do tm kill-session -t "=$s:"; done
ta --ensure-dash >/dev/null 2>&1
wait_eq beta vshows >/dev/null
cpmods install_event_hooks
vkeys ')'
ok "Round the end of the order: past the dashboard the viewport wraps to alpha" alpha "$(wait_eq_long alpha vshows)"
vkeys '('
ok "Round the end of the order: a prefix ( next shows beta again" beta "$(wait_eq_long beta vshows)"

t "The shown session is closed"
cpguard_up 33
vgo personal; wait_eq "$(tm display -p -t '=personal:' '#{session_id}')" sh -c "tmux -L $CPS show -gqv @tagents_viewport_shown | cut -d' ' -f1" >/dev/null
vgo work;     wait_eq "$(tm display -p -t '=work:' '#{session_id}')" sh -c "tmux -L $CPS show -gqv @tagents_viewport_shown | cut -d' ' -f1" >/dev/null
ok "the shown ids are work then personal" "$(tm display -p -t '=work:' '#{session_id}') $(tm display -p -t '=personal:' '#{session_id}')" "$(opt @tagents_viewport_shown | cut -d' ' -f1-2)"
tm kill-session -t '=work:'
ok "The shown session is closed: the viewport shows personal" personal "$(wait_eq_long personal vshows)"
ok "The shown session is closed: the dashboard's terminal stayed on tagents" tagents "$(csess "$U")"

t "A tab click"
cpguard_up 34
before=$(panes_of)
vkeys 0
ok "A tab click: the viewport shows window 0 of work" work:0 "$(wait_eq_long work:0 vwin)"
ok "A tab click: the recorded window is the viewport's" "$(vwid)" "$(wait_eq "$(vwid)" opt @tagents_viewport_window)"
ok "A tab click: the cursor is on the row of the window" "$(rowof '=work:0')" "$(wait_eq_long "$(rowof '=work:0')" curpos)"
ok "A tab click: every pane is in the window it was in" "$before" "$(panes_of)"

t "Another terminal, The shown session changes window elsewhere"
cpguard_up 35
vgo personal; wait_eq "$(wid '=personal:')" opt @tagents_viewport_window >/dev/null
row_before=$(wait_eq_long "$(rowof '=personal:')" curpos)
before=$(panes_of)
kclient 36 work;                                           V=$KC
tm send-keys -K -c "$V" C-b 0
ok "Another terminal: the other terminal changed window" work:0 "$(wait_eq work:0 sh -c "tmux -L $CPS list-clients -F '#{client_name} #{session_name}:#{window_index}' | awk -v c=$V '\$1 == c { print \$2 }'")"
sleep 1
ok "Another terminal: the viewport still shows personal" personal "$(vshows)"
ok "Another terminal: the cursor stays on the row of personal" "$row_before" "$(curpos)"
ok "Another terminal: no pane changed window" "$before" "$(panes_of)"
vgo work; wait_eq "$(wid '=work:0')" opt @tagents_viewport_window >/dev/null
tm send-keys -K -c "$V" C-b 2
ok "The shown session changes window elsewhere: the viewport shows work:2" work:2 "$(wait_eq_long work:2 vwin)"
ok "The shown session changes window elsewhere: the cursor is on its row" "$(rowof '=work:2')" "$(wait_eq_long "$(rowof '=work:2')" curpos)"

# Only the session tagents is left and the viewport is idle: a client's session and the session of a command run from a pane both read tagents. The viewport's shell is stopped for the case, so that a session made here is not picked up and the dashboard stays the only one a lookup can name.
t "The dashboard is never where a chat or a shell lands"
cpstart
kclient 41 work;                                           U=$KC
ta --ensure-dash >/dev/null 2>&1
wait_eq work:2 vwin >/dev/null
for s in personal scratch work; do tm kill-session -t "=$s:"; done
wait_eq_long "tagents: no session to show" vp_text >/dev/null
VPID=$(tm display -p -t "$(vpane)" '#{pane_pid}')
kill -STOP "$VPID"
TA_NEW_CMD="sleep 600" ta --new "$HOME" >/dev/null 2>&1
ok "No home for a chat: the session tagents still has one window" 1 "$(tm list-windows -t '=tagents:' | wc -l | tr -d ' ')"
ok "No home for a chat: ...with the list and the viewport only" 2 "$(tm list-panes -t '=tagents:' | wc -l | tr -d ' ')"
ok "No home for a chat: it went to the last resort session" "agents tagents " "$(cplist)"
ok "No home for a chat: launch_session does not answer tagents" agents "$(cpout launch_session '')"
tm new-session -d -s scratch -x 200 -y 50 "exec sleep 600"; tm new-window -d -t '=scratch:' "exec sleep 600"
SPANE=$(tm list-panes -t '=scratch:' -F '#{pane_id}' | head -1)
cpout open_beside "$SPANE"
ok "No window to put it beside: the dashboard keeps its two panes" 2 "$(tm list-panes -t '=tagents:' | wc -l | tr -d ' ')"
ok "No window to put it beside: the chat's pane stayed in its session" scratch "$(tm display -p -t "$SPANE" '#{session_name}')"
kill -CONT "$VPID"
tm set-hook -gu 'client-session-changed[44]'

t "A session named with a space, A session named 0"
cpguard_up 37
tm new-session -d -s "my work" -x 200 -y 50 "exec sleep 600"
vgo "my work"
vshows_whole() { tm list-clients -F "#{client_name}"$'\t'"#{session_name}" 2>/dev/null | awk -F'\t' -v c="$(vtty)" '$1 == c { print $2 }'; }   # the whole name, spaces and all
ok "A session named with a space: the viewport shows it" "my work" "$(wait_eq_long "my work" vshows_whole)"
ok "A session named with a space: the recorded window is the window id alone" "$(tm display -p -t '=my work:' '#{window_id}')" "$(wait_eq_long "$(tm display -p -t '=my work:' '#{window_id}')" opt @tagents_viewport_window)"

cpstart
tm new-session -d -s 0 -x 200 -y 50 "exec sleep 600"; tm new-session -d -s 1 -x 200 -y 50 "exec sleep 600"
kclient 38 0;                                              U=$KC
for s in work personal scratch; do tm kill-session -t "=$s:"; done
ta --ensure-dash >/dev/null 2>&1
wait_eq 0 vshows >/dev/null
cpmods install_event_hooks
vkeys '('
ok "A session named 0: previous from 0 lands on tagents and the guard steps on to 1, not back to 0" 1 "$(wait_eq_long 1 vshows)"

# client_raw (cockpit.sh) and client_attr (follow.sh) are two copies of the rule "the most recently active client"; with no viewport stored they must name the same client, with and without a name. Three clients of different activity times, the last two of the same second.
t "client_raw and client_attr agree"
cpstart
tm set -g status off
touch_client() { tm send-keys -K -c "$1" x; }                                    # <client> — activity is stamped by a key
kclient 61 work;     CA=$KC
kclient 62 personal; CB=$KC
kclient 63 scratch;  CC=$KC
tie=0; tries=0
while [ "$tie" != 1 ] && [ "$tries" -lt 6 ]; do
  tries=$((tries + 1))
  touch_client "$CA"; sleep 1.1
  tm send-keys -K -c "$CB" x \; send-keys -K -c "$CC" x
  acts=$(tm list-clients -F '#{client_name} #{client_activity}' | awk -v b="$CB" -v c="$CC" '$1 == b { x = $2 } $1 == c { y = $2 } $1 != b && $1 != c { z = $2 } END { print (x == y && x > z) ? 1 : 0 }')
  tie=$acts
done
ok "client_raw and client_attr: the clients are set up with the last two tied and the first older" 1 "$tie"
ok "client_raw and client_attr: no viewport is stored" "" "$(opt @tagents_viewport_tty)"
ok "client_raw and client_attr: the same client is the most recently active" "$(cpout client_attr '#{client_name}')" "$(cpout client_raw '#{client_name}')"
hasnt "client_raw and client_attr: ...and it is not the oldest one" "$CA" "$(cpout client_raw '#{client_name}')"
for c in "$CA" "$CB" "$CC"; do
  ok "client_raw and client_attr: with the name $c both name its session" "$(csess "$c")" "$(cpout client_raw '#{session_name}' "$c")"
  ok "client_raw and client_attr: with the name $c the two agree" "$(cpout client_attr '#{session_name}' "$c")" "$(cpout client_raw '#{session_name}' "$c")"
done

# viewport_wait on its own, on a server with no refresher and no ring hooks: nothing rings the channel, so only the loop's own look at the sessions ends the wait, and the waiter (a tmux client, the child of the backgrounded ring_wait) has to be stopped by the loop. A waiter left behind has lost its parent and is the child of pid 1. The window keeps running afterwards, because the death of a pane would hang the leftover up.
t "The viewport's wait stops its waiter"
tm kill-server >/dev/null 2>&1; sleep 0.3
tm -f /dev/null new-session -d -s tagents -x 200 -y 50 "exec sleep 600" || exit 1
tm set -t '=tagents:' @tagents_cockpit 1
tm set -g @tagents_viewport_tty /dev/none
rm -f "$CPROOT/vw.done"
tm new-window -d -t '=tagents:' "env TA_STATE_DIR='$CPSTATE' bash -c 'for m in $LISTED_MODS; do . \"$HERE/../lib/tagents/\$m.sh\"; done; viewport_wait /dev/none; : >\"$CPROOT/vw.done\"; sleep 30'"
ok "The viewport's wait stops its waiter: the wait has its waiter while there is nothing to show" 1 "$(wait_eq 1 cpwaiting)"
tm new-session -d -s other -x 200 -y 50 "exec sleep 600"
vw_done() { [ -e "$CPROOT/vw.done" ] && echo 1 || echo 0; }
ok "The viewport's wait stops its waiter: a session made ends the wait" 1 "$(wait_eq_long 1 vw_done)"
ok "The viewport's wait stops its waiter: no waiter of this server is left without its parent" 0 "$(sleep 0.5; cporphans)"
ok "The viewport's wait stops its waiter: ...and none is left at all" 0 "$(wait_eq 0 cpwaiters)"

# ---------------------------------------------------------------------------------------------------------------------------------
# messages and popups: the dashboard's own status line is off, so a message appears on the viewport's client; a popup is on the user's terminal
# ---------------------------------------------------------------------------------------------------------------------------------

# kclient with the client's output kept in a file ($CPROOT/u<n>.log), so that a test can read what reached that terminal. KC is the new client.
kclientlog() {  # <n> <session>
  local n=$1 s=$2 before i=0 after
  before=$(clients)
  ( { sleep 300 & printf '%s\n' "$!" >"$CPROOT/keeper$n.pid"; wait; } |
      script -q "$CPROOT/u$n.log" sh -c 'stty cols 200 rows 50; exec env -u TMUX tmux -S "$0" attach -t "$1"' "$CPSOCK" "=$s:" >/dev/null 2>&1 & ) >/dev/null 2>&1
  KC=""
  while [ "$i" -lt 40 ]; do
    after=$(clients)
    KC=$(printf '%s\n' "$after" | grep -vxFf <(printf '%s\n' "$before") | head -1)
    [ -n "$KC" ] && break
    i=$((i + 1)); sleep 0.1
  done
  sleep 0.5
}
vscreen() { tm capture-pane -p -t "$(vpane)" 2>/dev/null; }                     # what the viewport's client draws, its status line included
keysshown() { grep -c 'every key' "$CPROOT/u$1.log" 2>/dev/null; }

t "The keys window"
cpstart
kclientlog 51 work;                                        U=$KC
ta --ensure-dash >/dev/null 2>&1
wait_eq work:2 vwin >/dev/null
wait_eq tagents csess "$U" >/dev/null
settle
: >"$CPROOT/u51.log"
TMUX_PANE=$(lpane) ta --act keys "$(lpane)" none "" "" >/dev/null 2>&1 &
ok "The keys window: it opens on the user's terminal" 1 "$(wait_eq_long 1 sh -c "[ \"\$(grep -c 'every key' '$CPROOT/u51.log')\" -gt 0 ] && echo 1 || echo 0")"
hasnt "The keys window: ...and not in the viewport" 'every key' "$(vscreen)"
tm send-keys -K -c "$U" Escape
wait; sleep 0.3

t "A new shell's message"
cpselect_up 52
tm set -g display-time 20000
tm kill-session -t '=scratch:'
mkdir -p "$CPROOT/app"
tm new-session -d -s scratch -x 200 -y 50 -c "$CPROOT/app" "exec sleep 600"
SP=$(tm list-panes -t '=scratch:' -F '#{pane_id}' | head -1)
# From the list's pane, as the key runs: a plain display-message from there lands on the client of the session tagents, the user's terminal.
TMUX_PANE=$(lpane) ta --act shell "$SP" none "" "$CPROOT/app" >/dev/null 2>&1; rc=$?
ok "A new shell's message: exit 0" 0 "$rc"
SW=$(tm list-windows -t '=scratch:' -F '#{window_index}' | sort -n | tail -1)
ok "A new shell's message: scratch gained a window" 1 "$SW"
ok "A new shell's message: the viewport shows it" scratch:$SW "$(wait_eq_long scratch:$SW vwin)"
has "A new shell's message: the viewport's client was shown it" "tagents: new shell in app (scratch:$SW)" "$(wait_eq_long "tagents: new shell in app (scratch:$SW)" vmsg)"
has "A new shell's message: ...and its status line draws it" "tagents: new shell in app (scratch:$SW)" "$(wait_eq_long "tagents: new shell in app (scratch:$SW)" sh -c "tmux -L $CPS capture-pane -p -t $(vpane) | grep -o 'tagents: new shell in app (scratch:$SW)' | head -1")"
ok "A new shell's message: the user's terminal still shows the session tagents" tagents "$(csess "$U")"
tm set -gu display-time

t "tnotes toggle"
cpselect_up 53
NCH=$(mkwin work notes-chat)
NED=$(tm split-window -d -P -F '#{pane_id}' -t "$NCH" "exec sleep 600")
tm set -p -t "$NCH" @ta_notes "$NED"; tm set -p -t "$NED" @ta_notes_for "$NCH"
NWIN=work:$(tm display -p -t "$NCH" '#{window_index}')
tm switch-client -c "$(vtty)" -t '=work:0'
ok "tnotes toggle: the viewport shows work:0 first" work:0 "$(wait_eq work:0 vwin)"
ok "tnotes toggle: the editor is not the active pane of its window" "$NCH" "$(tm display -p -t "=$NWIN" '#{pane_id}')"
env TMUX="$CPSOCK,0,0" bash "$HERE/../tnotes" toggle "$NCH" >/dev/null 2>&1; rc=$?
ok "tnotes toggle: exit 0" 0 "$rc"
ok "tnotes toggle: the viewport shows the editor's window" "$NWIN" "$(wait_eq_long "$NWIN" vwin)"
ok "tnotes toggle: the editor's pane is active in it" "$NED" "$(wait_eq "$NED" tm display -p -t "=$NWIN" '#{pane_id}')"
ok "tnotes toggle: the user's terminal still shows the session tagents" tagents "$(csess "$U")"

# ---------------------------------------------------------------------------------------------------------------------------------
# the dashboard's keys: the prefix is forwarded to the viewport, every other key reaches the active pane, the mouse bindings come along
# ---------------------------------------------------------------------------------------------------------------------------------

# A terminal whose keys the test types: kclientlog with a fifo read by a cat as stdin (script refuses a fifo itself), so that bytes written to $CPROOT/in<n> reach the client as typed. KC is the client.
kclientio() {  # <n> <session>
  local n=$1 s=$2 before i=0 after
  before=$(clients)
  rm -f "$CPROOT/in$n"; mkfifo "$CPROOT/in$n"
  ( { sleep 300 >"$CPROOT/in$n" & printf '%s\n' "$!" >"$CPROOT/keeper$n.pid"; }
    cat <"$CPROOT/in$n" | script -q "$CPROOT/u$n.log" sh -c 'stty cols 200 rows 50; exec env -u TMUX tmux -S "$0" attach -t "$1"' "$CPSOCK" "=$s:" >/dev/null 2>&1 & ) >/dev/null 2>&1
  KC=""
  while [ "$i" -lt 40 ]; do
    after=$(clients)
    KC=$(printf '%s\n' "$after" | grep -vxFf <(printf '%s\n' "$before") | head -1)
    [ -n "$KC" ] && break
    i=$((i + 1)); sleep 0.1
  done
  sleep 0.5
}
typed() { printf "$2" >"$CPROOT/in$1"; }                                  # <n> <printf format> — bytes the user types at terminal n
# work:2 in the viewport, the list ready, a terminal that takes typed keys on the session tagents.
cpkeys_up() {  # <n> [tmux command to run before the cockpit starts]
  local n=$1
  cpstart
  [ -z "${2:-}" ] || tm $2
  tm set-environment -g TA_NEW_CMD "sleep 600"
  kclientio "$n" work;                                     U=$KC
  ta --ensure-dash >/dev/null 2>&1
  wait_eq work:2 vwin >/dev/null
  wait_eq tagents csess "$U" >/dev/null
  wait_eq_long 1 listready >/dev/null; sleep 1
}

t "Prefix from the list"
cpkeys_up 61
tm select-pane -t "$(lpane)"
ok "Prefix from the list: the list is the active pane" "$(lpane)" "$(vact)"
nw=$(tm list-windows -t '=work:' | wc -l | tr -d ' ')
typed 61 '\002'; sleep 0.5; typed 61 'c'     # a person types the second key after the first has acted; one write would race the table
ok "Prefix from the list: work gained a window" "$((nw + 1))" "$(wait_eq_long "$((nw + 1))" sh -c "tmux -L $CPS list-windows -t '=work:' | wc -l | tr -d ' '")"
NWI=$(tm display -p -t '=work:' '#{window_index}')
ok "Prefix from the list: the new window is not work:2" 1 "$([ "$NWI" != 2 ] && echo 1 || echo 0)"
ok "Prefix from the list: the viewport shows the new window" work:$NWI "$(wait_eq_long work:$NWI vwin)"
ok "Prefix from the list: the viewport is the active pane" "$(vpane)" "$(vact)"
ok "Prefix from the list: the user's terminal still shows tagents" tagents "$(csess "$U")"

t "The list's own keys"
cpkeys_up 62
tm select-pane -t "$(lpane)"
nall=$(tm list-windows -a -F '#{session_name}' | grep -vc '^tagents$')
typed 62 '\016'
ok "The list's own keys: ctrl-n started a chat in a new window" "$((nall + 1))" "$(wait_eq_long "$((nall + 1))" sh -c "tmux -L $CPS list-windows -a -F '#{session_name}' | grep -vc '^tagents\$'")"
ok "The list's own keys: no window was made in tagents" 1 "$(tm list-windows -t '=tagents:' | wc -l | tr -d ' ')"

t "A click on the list"
cpkeys_up 63 "set -g mouse on"
tm select-pane -t "$(vpane)"
ok "A click on the list: the viewport is the active pane" "$(vpane)" "$(vact)"
# The screen row of a list line is found from the list's own text: the first group header is the list's first line, the window one is the row to click.
CLKTOP=$(tm capture-pane -p -t "$(lpane)" | grep -n '▾' | head -1 | cut -d: -f1)
CLK=$(tm capture-pane -p -t "$(lpane)" | grep -n '├─ one' | head -1 | cut -d: -f1)
CLKROW=$((CLK - CLKTOP + 1))
ok "A click on the list: the cursor starts on another row" 1 "$(curpos)"
typed 63 "\033[<0;6;${CLK}M\033[<0;6;${CLK}m"
ok "A click on the list: the list is the active pane" "$(lpane)" "$(wait_eq "$(lpane)" vact)"
ok "A click on the list: the cursor is on the clicked row" "$CLKROW" "$(wait_eq "$CLKROW" curpos)"

t "A root binding"
cpkeys_up 64 "bind -n M-h set -wF @mh #{window_id}"
tm select-pane -t "$(vpane)"
W2=$(wid work:2)
typed 64 '\033h'
ok "A root binding: the binding ran in the window the viewport shows" "$W2" "$(wait_eq_long "$W2" sh -c "tmux -L $CPS show -wqv -t '=work:2' @mh")"
ok "A root binding: ...and not in the dashboard window" "" "$(tm show -wqv -t '=tagents:' @mh)"

# ---------------------------------------------------------------------------------------------------------------------------------
# ctrl-q takes the cockpit down, and a killed half comes back
# ---------------------------------------------------------------------------------------------------------------------------------

qleft() {  # what the cockpit installs on the server, one line each; empty when nothing is left
  tm show-hooks -g 2>/dev/null | grep '^client-session-changed\[44\]'
  tm show -g 2>/dev/null | grep '^@tagents_viewport'
  tm list-keys -T tagents-cockpit 2>/dev/null
}

t "Quit"
cpkeys_up 71
tm select-pane -t "$(lpane)"
ok "Quit: the viewport shows work:2 first" work:2 "$(vwin)"
typed 71 '\021'
ok "Quit: the user's terminal shows work:2" work:2 "$(wait_eq_long work:2 cwin "$U")"
ok "Quit: no session tagents is left" "personal scratch work " "$(wait_eq_long "personal scratch work " cplist)"
ok "Quit: the table tagents-cockpit lists nothing" "" "$(tm list-keys -T tagents-cockpit 2>/dev/null)"
ok "Quit: @tagents_viewport_tty is unset" "" "$(opt @tagents_viewport_tty)"
ok "Quit: no sidebar wish, option or hook of the cockpit is left" "" "$(qleft)"
sleep 1
ok "Quit: ...and nothing comes back a second later" "personal scratch work " "$(cplist)"

t "Quit with no window to show"
cpkeys_up 72
tm select-pane -t "$(lpane)"
tm set -g @tagents_viewport_tty /dev/none     # a name no client has: the window to show cannot be read
typed 72 '\021'
ok "Quit with no window to show: the user's terminal is detached" 0 "$(wait_eq_long 0 present "$U")"
ok "Quit with no window to show: no session tagents is left" "personal scratch work " "$(wait_eq_long "personal scratch work " cplist)"
ok "Quit with no window to show: nothing of the cockpit is left" "" "$(qleft)"

t "The viewport's loop after the tty is cleared"
cpkeys_up 73
OLDV=$(vtty)
tm set -gu @tagents_viewport_tty
tm detach-client -t "$OLDV"
sleep 2
# A quit clears the tty and the session goes a moment later; a loop that ignored the cleared tty would attach again in that moment. The detach stands for the end of the attach.
ok "The viewport's loop after the tty is cleared: the viewport's client does not attach again" 0 "$(present "$OLDV")"

t "The viewport is killed"
cpkeys_up 74
OLDV=$(vpane); OLDL=$(lpane)
tm kill-pane -t "$OLDV"
ok "The viewport is killed: a new viewport is the right pane" 1 "$(wait_eq_long 1 sh -c "[ -n \"\$(tmux -L $CPS list-panes -t '=tagents:' -F '#{pane_at_left} #{pane_id}' | awk '\$1 == 0 && \$2 != \"$OLDV\" { print 1 }')\" ] && echo 1")"
ok "The viewport is killed: it shows work:2 again" work:2 "$(wait_eq_long work:2 vwin)"
ok "The viewport is killed: the list is the one it was" "$OLDL" "$(lpane)"
ok "The viewport is killed: the dashboard has two panes" 2 "$(tm list-panes -t '=tagents:' | wc -l | tr -d ' ')"
has "The viewport is killed: the key table points at the new pane" "select-pane -t \"$(vpane)\"" "$(tm list-keys -T tagents-cockpit | grep 'C-b')"

t "The list is killed"
cpkeys_up 75
OLDV=$(vpane); OLDL=$(lpane)
tm kill-pane -t "$OLDL"
ok "The list is killed: a new list is the left pane" 1 "$(wait_eq_long 1 sh -c "[ -n \"\$(tmux -L $CPS list-panes -t '=tagents:' -F '#{pane_at_left} #{pane_id} #{pane_start_command}' | awk '\$1 == 1 && \$2 != \"$OLDL\" && \$0 !~ /--viewport/ { print 1 }')\" ] && echo 1")"
ok "The list is killed: the viewport is the one it was" "$OLDV" "$(vpane)"
near "The list is killed: the new list is 90 columns wide" 90 "$(tm display -p -t "$(lpane)" '#{pane_width}')"
ok "The list is killed: the new list has claimed the sidebar" 1 "$(wait_eq_long 1 sh -c "p=\$(tmux -L $CPS display -p -t '$(lpane)' '#{@tagents_list}'); [ -n \"\$p\" ] && kill -0 \"\$p\" 2>/dev/null && echo 1")"
# The split that brought the list back ran in the viewport's pane with stdout on its terminal, and a tmux client sets its stdin, stdout and stderr back to blocking when it exits. The server writes to the viewport's client through a dup of that client's stdin; had it been the pane's descriptor, the split left it blocking and the server, the only reader of that pane, hangs on its next large write.
ok "The list is killed: the server still writes to the viewport's client without blocking" W,NB "$(srv_nb "$(vtty)")"

t "A quit leaves no waiter behind"
cpkeys_up 76
tm select-pane -t "$(lpane)"
ok "A quit leaves no waiter behind: while the cockpit is up the list's watcher has a waiter, so the count can see one" 1 "$(wait_eq 1 cpwaiting)"
typed 76 '\021'
wait_eq_long "personal scratch work " cplist >/dev/null
sleep 1
ok "A quit leaves no waiter behind: no wait-for client of this server is left" 0 "$(wait_eq 0 cpwaiters)"

# ---------------------------------------------------------------------------------------------------------------------------------
# a dashboard tmux-resurrect left behind is rebuilt in the cockpit
# ---------------------------------------------------------------------------------------------------------------------------------

# What tmux-resurrect brings back of a cockpit: the session tagents of one window and two idle shells, titled as the list and the viewport were, with none of the options the dashboard carries, and a terminal attached to it. LS and LV are the shells.
cpleft() {  # <n>
  cpstart
  # The lists of the server before this one are still exiting, and the exit trap of one clears the title of a pane id the new server has handed out again: let them finish first.
  sleep 2
  tm new-session -d -s tagents -x 200 -y 50 -n dashboard
  LS=$(tm list-panes -t '=tagents:' -F '#{pane_id}' | head -1)
  LV=$(tm split-window -d -h -t "$LS" -P -F '#{pane_id}')
  # A shell that sets its own title would overwrite the one the restore left on the pane.
  tm set -p -t "$LS" allow-set-title off; tm set -p -t "$LV" allow-set-title off
  tm select-pane -T tagents-sidebar -t "$LS"; tm select-pane -T tagents-viewport -t "$LV"
  kclientio "$1" tagents; U=$KC
  printf 'D\twork\t2\n' >"$CPROOT/snap.tsv"
}
lrunning() {  # the list runs in the left pane of the dashboard
  local pid; pid=$(tm display -p -t "$(lpane)" '#{@tagents_list}' 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo 1
}
vrunning() { tm display -p -t "$(vpane)" '#{@tagents_viewport}' 2>/dev/null; }
# What a rebuild in place has to leave: the two shells now run the halves, nothing was made or detached, the terminal is still on the dashboard.
leftover_rebuilt() {  # <label> <n>
  ok "$1: the left pane runs the list" 1 "$(wait_eq_long 1 lrunning)"
  ok "$1: the right pane runs the viewport" 1 "$(wait_eq_long 1 vrunning)"
  ok "$1: @tagents_cockpit is 1" 1 "$(tm show -qv -t '=tagents:' @tagents_cockpit)"
  ok "$1: the same two panes are there" "$LS $LV" "$(lpane) $(vpane)"
  ok "$1: the dashboard has two panes" 2 "$(tm list-panes -t '=tagents:' | wc -l | tr -d ' ')"
  ok "$1: the terminal is still listed, on the session tagents" tagents "$(csess "$U")"
  ok "$1: ...and was never detached" 0 "$(grep -c 'detached' "$CPROOT/u$2.log" 2>/dev/null)"
}

t "Restored in the cockpit"
cpleft 81
ta --resurrect --from "$CPROOT/snap.tsv" >"$CPROOT/r81.log" 2>&1
leftover_rebuilt "Restored in the cockpit" 81
ok "Restored in the cockpit: the viewport shows work:2" work:2 "$(wait_eq_long work:2 vwin)"
has "Restored in the cockpit: the report says dashboard" "✓ dashboard" "$(cat "$CPROOT/r81.log")"

t "Restored in the cockpit through --ensure-dash"
cpleft 83
ta --ensure-dash >"$CPROOT/r83.log" 2>&1; ok "Restored in the cockpit through --ensure-dash: exit 0" 0 "$?"
leftover_rebuilt "Restored in the cockpit through --ensure-dash" 83
ok "Restored in the cockpit through --ensure-dash: the viewport has a client" 1 "$(present "$(vtty)")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
