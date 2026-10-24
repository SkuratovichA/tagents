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
      script -q /dev/null env -u TMUX tmux -S "$CPSOCK" attach "$@" -t "=$s:" >/dev/null 2>&1 & ) >/dev/null 2>&1
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
