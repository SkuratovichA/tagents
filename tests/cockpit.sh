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
tm set-hook -gu 'client-session-changed[44]'
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
CPCONF="$CPROOT/config.yaml"
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
unset TA_MODE TA_FLAT TA_COLS TA_NEW_CMD TA_RESUME_CMD TA_HOME TA_SESSION TA_FOLLOW_WINDOW TA_WIDTH CLAUDE_CONFIG_DIR CLAUDE_PID

ta()    { env TMUX="$CPSOCK,0,0" bash "$TA" "$@"; }
cpcfg() { if [ "$1" = none ]; then rm -f "$CPCONF"; else printf 'dashboard:\n  layout: %s\n' "$1" >"$CPCONF"; fi; }   # <cockpit|follow|none>
cplist() { tm list-sessions -F '#{session_name}' 2>/dev/null | sort | tr '\n' ' '; }

# A fresh server with work (windows 1 and 2, the second one a shell), personal and scratch, no client and no hooks.
cpstart() {
  local k
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

t "Cockpit chosen, A new dashboard, From another session, The pane and its client"
cpcfg cockpit; cpstart
kclient 11 work;                                           U=$KC
ta --ensure-dash >"$CPROOT/ed.out" 2>&1; rc=$?
ok "Cockpit chosen: --ensure-dash exits 0" 0 "$rc"
ok "Cockpit chosen: the session tagents exists beside the others" "personal scratch tagents work " "$(cplist)"
has "Cockpit chosen: the list is on its left" tagents "$(tm display -p -t "$(lpane)" '#{pane_start_command}')"
hasnt "Cockpit chosen: ...and is not the viewport" --viewport "$(tm display -p -t "$(lpane)" '#{pane_start_command}')"
has "Cockpit chosen: the viewport is on its right" --viewport "$(tm display -p -t "$(vpane)" '#{pane_start_command}')"
ok "A new dashboard: one window" 1 "$(tm list-windows -t '=tagents:' | wc -l | tr -d ' ')"
near "A new dashboard: the list is 90 columns wide" 90 "$(tm display -p -t "$(lpane)" '#{pane_width}')"
ok "A new dashboard: @tagents_cockpit is 1" 1 "$(tm show -qv -t '=tagents:' @tagents_cockpit)"
ok "A new dashboard: the status line is off" off "$(tm show -v -t '=tagents:' status)"
ok "A new dashboard: the sidebar flag was not set" "" "$(opt @tagents_sidebar_on)"
ok "From another session: the viewport shows work:2" work:2 "$(wait_eq work:2 vwin)"
ok "From another session: the terminal shows the session tagents" tagents "$(wait_eq tagents csess "$U")"
ok "The pane and its client: the right pane is titled tagents-viewport" tagents-viewport "$(wait_eq tagents-viewport tm display -p -t "$(vpane)" '#{pane_title}')"
ok "The pane and its client: @tagents_viewport is 1" 1 "$(tm display -p -t "$(vpane)" '#{@tagents_viewport}')"
ok "The pane and its client: the viewport's client is on work and its tty is @tagents_viewport_tty" work "$(vshows)"
ok "The pane and its client: that tty is the pane's own" "$(tm display -p -t "$(vpane)" '#{pane_tty}')" "$(vtty)"

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

t "Changed while the cockpit is up, Its terminals outlive it"
cpcfg follow
ta --ensure-dash >/dev/null 2>&1; rc=$?
ok "Changed while the cockpit is up: --ensure-dash still exits 0" 0 "$rc"
ok "Changed while the cockpit is up: the cockpit stays" 1 "$(tm show -qv -t '=tagents:' @tagents_cockpit)"
ok "Changed while the cockpit is up: no sidebar went into work:2" 0 "$(left_of '=work:2')"
tm kill-session -t '=tagents:'
ok "Its terminals outlive it: the terminal is still attached" 1 "$(wait_eq 1 present "$U")"
ok "Its terminals outlive it: it shows work" work "$(wait_eq work csess "$U")"
ta --ensure-dash >/dev/null 2>&1
ok "Changed while the cockpit is up: the next list uses the follow layout, a sidebar in the client's window" 1 "$(wait_eq_long 1 left_of '=work:2')"
ok "Changed while the cockpit is up: ...and no session tagents exists" 0 "$(tm list-sessions -F '#{session_name}' | grep -cx tagents)"

t "No dashboard section"
cpcfg none; cpstart
kclient 12 work
ta --ensure-dash >/dev/null 2>&1
ok "No dashboard section: the sidebar is the leftmost pane of work:2" 1 "$(wait_eq_long 1 left_of '=work:2')"
ok "No dashboard section: no session tagents exists" 0 "$(tm list-sessions -F '#{session_name}' | grep -cx tagents)"

t "Someone else's session"
cpcfg cockpit; cpstart
kclient 13 work
tm new-session -d -s tagents -x 200 -y 50 "exec '$BIN/vim'"
vpid=$(tm display -p -t '=tagents:' '#{pane_pid}')
err=$(ta --ensure-dash 2>&1 >/dev/null); rc=$?
ok "Someone else's session: the refusal line on standard error" "tagents: session tagents is taken — rename it or set dashboard.layout: follow" "$err"
ok "Someone else's session: exit 1" 1 "$rc"
has "Someone else's session: that session still runs vim" "/bin/vim" "$(tm display -p -t '=tagents:' '#{pane_start_command}')"
ok "Someone else's session: ...in the same process" "$vpid" "$(tm display -p -t '=tagents:' '#{pane_pid}')"
ok "Someone else's session: no session was created" "personal scratch tagents work " "$(cplist)"
ok "Someone else's session: no window was added to it" 1 "$(tm list-panes -t '=tagents:' | wc -l | tr -d ' ')"

t "tagents typed in a shell"
shell_idle() { tm display -p -t '=work:2' '#{pane_current_command}' | grep -cE '^(sh|bash)$'; }
cpcfg cockpit; cpstart
kclient 14 work;                                           U=$KC
tm send-keys -t '=work:2' 'tagents' Enter
ok "tagents typed in a shell: the session tagents exists" tagents "$(wait_eq_long tagents tm list-sessions -F '#{session_name}' | grep -x tagents)"
ok "tagents typed in a shell: the viewport shows work:2" work:2 "$(wait_eq_long work:2 vwin)"
ok "tagents typed in a shell: the terminal shows the session tagents" tagents "$(wait_eq tagents csess "$U")"
ok "tagents typed in a shell: the shell pane is back at its prompt" 1 "$(wait_eq 1 shell_idle)"

t "No client"
cpcfg cockpit; cpstart
err=$(ta --ensure-dash 2>&1 >/dev/null); rc=$?
ok "No client: exit 1" 1 "$rc"
ok "No client: no session tagents exists" 0 "$(tm list-sessions -F '#{session_name}' | grep -cx tagents)"

t "Detach and come back"
cpcfg cockpit; cpstart
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
# Stand-in for the guard of the dashboard's hooks: a viewport client that lands on tagents is marked idle and detached.
GUARD='if -F "#{&&:#{==:#{hook_client},#{@tagents_viewport_tty}},#{==:#{session_name},tagents}}" "run-shell -C \"set -g @tagents_viewport_idle 1 ; detach-client -t #{hook_client}\""'
tm set-hook -g 'client-session-changed[44]' "$GUARD"
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
headers()  { ta --list 2>/dev/null | cut -f2 | grep '▾' | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/[^[:alpha:] ]//g' | tr -s ' ' | tr '\n' ' '; }
allsess()  { tm list-clients -F '#{client_name}=#{session_name}' | sort | tr '\n' ' '; }
vact()     { tm display -p -t '=tagents:' '#{pane_id}'; }                                  # the dashboard's active pane

# work (two windows, the viewport on the second), personal with a chat in a window of its own ($PCW); the dashboard's terminal on tagents.
cpselect_up() {
  cpcfg cockpit; cpstart
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
