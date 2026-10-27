#!/bin/bash
# docs/demo/world.sh — builds and tears down the made-up machine the recordings run on.
#
#   world.sh up        build $DEMO_ROOT from scratch and start the scratch tmux server with the chats
#   world.sh down      kill the scratch server
#   world.sh ctl WIN CMD…   send a command to the fake agent in tmux window WIN (see fake-claude.sh)
#   world.sh dash-when-attached [DELAY] [zoom]   wait for a client, then bring up the dashboard and take that client to it; zoom fills the window with the list
#
# Isolation: env.sh moves HOME, TMUX_TMPDIR, TA_STATE_DIR and TA_CONFIG under $DEMO_ROOT, and every tmux call below goes to the server in $TMUX_TMPDIR.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"

tm() { env -u TMUX -u TMUX_PANE tmux "$@"; }

guard() {
  case $HOME in "$DEMO_ROOT"/*) ;; *) echo "world.sh: HOME is not under $DEMO_ROOT, refusing" >&2; exit 1 ;; esac
  [ "$TA_STATE_DIR" = "$DEMO_ROOT/state" ] || { echo "world.sh: state dir is not the demo one" >&2; exit 1; }
}

down() {
  tm kill-server 2>/dev/null
  # anything the server left behind: fake agents and their sleeps live under the DEMO_ROOT paths
  pkill -f "$DEMO_SRC/fake-claude.sh" 2>/dev/null
  return 0
}

now=$(date +%s)
ago() { echo $(( now - $1 * 60 )); }   # <minutes>

# A chat's content: sourced by fake-claude.sh when it starts with --resume <sid>.
chat() {  # <sid>   (conf on stdin)
  mkdir -p "$DEMO_CHATS"; cat >"$DEMO_CHATS/$1.conf"
}

make_home() {
  rm -rf "$DEMO_ROOT/home" "$DEMO_ROOT/state" "$DEMO_ROOT/ctl" "$DEMO_ROOT/chats" "$DEMO_ROOT/usage" "$DEMO_ROOT/tmux"
  mkdir -p "$HOME/.claude" "$HOME/.claude-personal" "$HOME/.config/tagents" "$TA_STATE_DIR" "$TMUX_TMPDIR"
  local p
  for p in storefront payments-api docs-site mobile-app; do mkdir -p "$HOME/code/$p/.git"; done
  printf '{}\n' >"$HOME/.claude-personal/.claude.json"; printf '{}\n' >"$HOME/.claude.json"
  printf 'PS1="\\$ "\n' >"$HOME/.bashrc"; cp "$HOME/.bashrc" "$HOME/.bash_profile"
  cat >"$TA_CONFIG" <<CFG
claude:
  args: --dangerously-skip-permissions
  profiles:
    work:
    personal:
      config_dir: $HOME/.claude-personal
  rules:
    - dir: $HOME/code/docs-site
      profile: personal
    - dir: $HOME/code/mobile-app
      profile: personal
    - dir: $HOME/code
      profile: work
usage:
  watch: work
  monthly_limit_usd: 850
resurrect:
  every: 0
CFG
  : >"$TA_STATE_DIR/events.on"
}

make_chats() {
  chat demo-sf-web <<'C'
title="Product page: lazy-load images"; model_id=claude-sonnet-5; model_name="Sonnet 5"; ctx=38000; cost=9.1
convo="u:lazy-load the gallery images on the product page
a:The gallery renders every image eagerly. I will switch the thumbnails to loading=lazy and keep the hero eager.
t:Read(src/components/Gallery.tsx)
t:Edit(src/components/Gallery.tsx)"
script="prompt run the image audit again and compare the numbers
tool Bash pnpm lighthouse --page product"
C
  chat demo-sf-api <<'C'
title="Checkout API: rate limiting"; model_id=claude-opus-5; model_name="Opus 5"; ctx=142000; cost=38.3
convo="u:add a per-customer rate limit to POST /checkout
a:There is a token bucket in src/middleware/limit.ts that nothing uses. I will wire it in and add a test.
t:Read(src/middleware/limit.ts)
t:Edit(src/routes/checkout.ts)"
script="prompt wire it in and make the limit configurable per plan
tool Edit src/routes/checkout.ts
tool Read src/config/plans.ts"
C
  chat demo-pay <<'C'
title="Webhooks: retry with backoff"; model_id=claude-haiku-4-5; model_name="Haiku 4.5"; ctx=12000; cost=2.7
convo="u:retry failed webhook deliveries with exponential backoff
a:Done. Deliveries now retry five times, 30 seconds apart at first and doubling, and the attempts are logged.
t:Edit(src/webhooks/deliver.ts)
t:Bash(pnpm test webhooks)"
script="stop"
C
  chat demo-docs <<'C'
title="Docs: move to the new theme"; model_id=claude-opus-5; model_name="Opus 5"; ctx=71000; cost=14.2
convo="u:move the docs to the new theme and keep the old URLs working
a:The new theme needs the sidebar config in a different shape. I am converting it page by page.
t:Read(docs/.vitepress/config.ts)"
script="prompt convert the remaining guides, then check every link
tool Edit docs/guide/install.md"
C
  chat demo-mob <<'C'
title="Offline mode for the feed"; model_id=claude-sonnet-5; model_name="Sonnet 5"; ctx=96000; cost=21.6
convo="u:make the feed readable offline
a:The feed already caches responses in memory. For offline reading it needs to survive a restart.
t:Read(src/feed/cache.ts)"
script="ask Which store should the offline feed cache use?"
C
  # sessions that ended: only their history and their cost remain
}

# history.jsonl lines: display, project, session id, time (ms)
jline() {  # <file> <sid> <minutes ago> <project> <text>
  printf '{"display":"%s","project":"%s","sessionId":"%s","timestamp":%s000}\n' "$5" "$4" "$2" "$(ago "$3")" >>"$1"
}
# history.tsv: epoch, kind, sid, pane, label, cwd
hline() {  # <minutes ago> <kind> <sid> <cwd>
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(ago "$1")" "$2" "$3" "" "" "$4" >>"$TA_STATE_DIR/history.tsv"
}

make_history() {
  local W=$HOME/code
  local hw=$HOME/.claude/history.jsonl hp=$HOME/.claude-personal/history.jsonl
  # closed sessions (work)
  jline $hw demo-old-idem 1500 $W/payments-api "add idempotency keys to the charge endpoint"
  jline $hw demo-old-idem 1430 $W/payments-api "also reject a reused key with a different amount"
  jline $hw demo-old-idem 1390 $W/payments-api "write the migration and run it on staging"
  jline $hw demo-old-react 3000 $W/storefront "upgrade the storefront to React 19"
  jline $hw demo-old-react 2900 $W/storefront "fix the type errors from the new ref types"
  jline $hw demo-old-react 2880 $W/storefront "run the e2e suite and list what broke"
  # closed (personal)
  jline $hp demo-old-anchors 1100 $W/docs-site "fix the broken anchors in the API reference"
  jline $hp demo-old-anchors 1060 $W/docs-site "add a check for them to CI"
  jline $hp demo-old-swipe 2500 $W/mobile-app "the swipe-to-archive gesture lags on older phones"
  jline $hp demo-old-swipe 2470 $W/mobile-app "profile it and tell me what is slow"
  for s in "demo-old-idem 1500 1385 $W/payments-api" "demo-old-react 3000 2870 $W/storefront" "demo-old-anchors 1100 1055 $W/docs-site" "demo-old-swipe 2500 2460 $W/mobile-app"; do
    set -- $s; hline "$2" start "$1" "$4"; hline "$(( ($2 + $3) / 2 ))" turn "$1" "$4"; hline "$3" end "$1" "$4"
  done
  printf 'demo-old-idem\tIdempotency keys for charges\ndemo-old-react\tReact 19 upgrade\ndemo-old-anchors\tFix API reference anchors\ndemo-old-swipe\tSwipe-to-archive lag\n' >"$TA_STATE_DIR/labels.tsv"
  mkdir -p "$DEMO_USAGE"
  local sid c n
  for s in "demo-old-idem 6.42 118" "demo-old-react 18.90 402" "demo-old-anchors 3.15 71" "demo-old-swipe 8.07 160"; do
    set -- $s
    printf 'session %s\n  total       $%s   (%s requests)\n  main chain  $%s\n  subagents   $0.00\n' "$1" "$2" "$3" "$2" >"$DEMO_USAGE/$1.txt"
  done
  # a believable day for --timeline: earlier sessions, a few hours each
  local day=(
    "demo-t1 960 840 $W/storefront" "demo-t2 930 700 $W/payments-api" "demo-t3 880 610 $W/docs-site"
    "demo-t4 600 470 $W/storefront" "demo-t5 540 300 $W/mobile-app" "demo-t6 420 250 $W/payments-api"
    "demo-t7 330 120 $W/docs-site" "demo-t8 240 40 $W/storefront"
  )
  # their names, the first thing each was asked and what it cost: the closed picker and the timeline read these
  local names=(
    "demo-t1|Cart drawer a11y fixes|work|make the cart drawer keyboard accessible|2.38|61"
    "demo-t2|Refund endpoint tests|work|add tests for partial refunds|4.11|97"
    "demo-t3|Search index rebuild|personal|rebuild the docs search index on deploy|1.74|40"
    "demo-t4|Image CDN headers|work|set cache headers for the product images|0.96|23"
    "demo-t5|Push token refresh|personal|refresh the push token when the app resumes|5.62|133"
    "demo-t6|Ledger rounding bug|work|the ledger is off by a cent on split payments|7.30|171"
    "demo-t7|Changelog page|personal|add a changelog page to the docs|2.05|52"
    "demo-t8|Order emails in plain text|work|send the order emails as plain text too|3.44|88"
  )
  local nm
  for nm in "${names[@]}"; do
    IFS='|' read -r sid title prof ask cost reqs <<<"$nm"
    local pf=$hw; [ "$prof" = personal ] && pf=$hp
    local proj; proj=$(printf '%s\n' "${day[@]}" | awk -v k="$sid" '$1 == k { print $4 }')
    jline "$pf" "$sid" "$(printf '%s\n' "${day[@]}" | awk -v k="$sid" '$1 == k { print $2 }')" "$proj" "$ask"
    printf '%s\t%s\n' "$sid" "$title" >>"$TA_STATE_DIR/labels.tsv"
    printf 'session %s\n  total       $%s   (%s requests)\n  main chain  $%s\n  subagents   $0.00\n' "$sid" "$cost" "$reqs" "$cost" >"$DEMO_USAGE/$sid.txt"
  done
  for s in "${day[@]}"; do
    set -- $s
    hline "$2" start "$1" "$4"
    local a=$2 step=$(( ($2 - $3) / 6 )) i
    for i in 1 2 3 4 5; do hline $(( a - step * i )) turn "$1" "$4"; done
    hline "$3" end "$1" "$4"
  done
}

cmd_for() {  # <sid> [work|personal] — what tagents itself would run
  local prof=${2:-work}
  if [ "$prof" = personal ]; then
    printf 'env CLAUDE_CONFIG_DIR=%s claude --dangerously-skip-permissions --resume %s' "$HOME/.claude-personal" "$1"
  else
    printf 'claude --dangerously-skip-permissions --resume %s' "$1"
  fi
}

# Every tmux server of the demo reads this, the one a recording restarts too (HOME is the demo home).
write_tmux_conf() {
  cat >"$HOME/.tmux.conf" <<TMUXCONF
set -g default-shell /bin/bash
set -g escape-time 0
set -g status-interval 1
set -g status-position bottom
set -g status-style 'bg=colour236,fg=colour250'
set -g status-left ' #S '
set -g status-left-style 'bg=colour24,fg=colour255'
set -g status-left-length 30
set -g status-right ' demo '
set -g status-right-length 60
set -g window-status-current-style 'bg=colour238,fg=colour255'
set -g window-status-format ' #I #W '
set -g window-status-current-format ' #I #W '
set -g pane-border-style 'fg=colour238'
set -g pane-active-border-style 'fg=colour67'
set -g set-titles off
TMUXCONF
}

start_server() {
  local first=1 s
  tm start-server
  tm new-session -d -s storefront -n web -x 200 -y 50 -c "$HOME/code/storefront" "$(cmd_for demo-sf-web)"
  tm new-window -d -t storefront: -n api -c "$HOME/code/storefront" "$(cmd_for demo-sf-api)"
  tm new-session -d -s payments-api -n main -x 200 -y 50 -c "$HOME/code/payments-api" "$(cmd_for demo-pay)"
  tm new-session -d -s docs-site -n docs -x 200 -y 50 -c "$HOME/code/docs-site" "$(cmd_for demo-docs personal)"
  tm new-session -d -s mobile-app -n app -x 200 -y 50 -c "$HOME/code/mobile-app" "$(cmd_for demo-mob personal)"
}

backdate() {  # make the "since you last typed" column read like a working day
  local ages="demo-sf-web:8 demo-sf-api:134 demo-pay:1022 demo-docs:41 demo-mob:362" a sid sec f
  for a in $ages; do
    sid=${a%%:*}; sec=${a##*:}
    f=$(grep -l -F "$sid" "$TA_STATE_DIR"/*.tsv 2>/dev/null | head -1)
    [ -n "$f" ] || continue
    printf '%s\n' $(( $(date +%s) - sec )) >"$TA_STATE_DIR/prompt/$(basename "${f%.tsv}")"
  done
  # the chats that are open started a while ago, so --timeline draws them as bars and not as a dot at "now"
  local began="demo-sf-web:5700 demo-sf-api:10800 demo-pay:15300 demo-docs:3600 demo-mob:8400" now h="$TA_STATE_DIR/history.tsv"
  now=$(date +%s)
  for a in $began; do
    awk -F'\t' -v OFS='\t' -v sid="${a%%:*}" -v t=$(( now - ${a##*:} )) '$2 == "start" && $3 == sid { $1 = t } { print }' "$h" >"$h.new" && mv "$h.new" "$h"
  done
  # the names the list shows for them, which is what the timeline calls them too
  printf 'demo-sf-web\tProduct page: lazy-load images\ndemo-sf-api\tCheckout API: rate limiting\ndemo-pay\tWebhooks: retry with backoff\ndemo-docs\tDocs: move to the new theme\ndemo-mob\tOffline mode for the feed\n' >>"$TA_STATE_DIR/labels.tsv"
}

ctl() {  # <window name> <cmd…>
  local win=$1 pane; shift
  pane=$(tm list-panes -a -F '#{window_name} #{pane_id}' | awk -v w="$win" '$1 == w { print $2; exit }')
  [ -n "$pane" ] || { echo "world.sh: no window $win" >&2; return 1; }
  printf '%s\n' "$*" >"$DEMO_CTL/${pane#%}.fifo"
}

up() {
  guard
  down
  rm -f "$DEMO_ROOT/resumed"
  make_home; write_tmux_conf; make_chats; make_history
  start_server
  sleep 3
  backdate
}

case ${1:-} in
  up) up ;;
  down) down ;;
  ctl) shift; ctl "$@" ;;
  save) tm run-shell "$REPO/tagents --resurrect-save" ;;
  dash-when-attached)
    i=0; while [ -z "$(tm list-clients 2>/dev/null)" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    sleep "${2:-0.5}"; tm run-shell "$REPO/tagents --ensure-dash"
    # the keys go to whichever pane of the dashboard is active: put the cursor of the terminal in the list
    p=$(tm list-panes -a -F '#{pane_id} #{@tagents_dash}' | awk '$2 == 1 { print $1; exit }')
    [ -n "$p" ] && tm select-pane -t "$p"
    # the prefix typed in the list goes on to the viewport, so a recording cannot zoom the list itself
    [ -n "$p" ] && [ "${3:-}" = zoom ] && tm resize-pane -Z -t "$p"
    # what tmux-resurrect's save hook would run, so a later --resurrect has a snapshot with the list in it
    tm run-shell "$REPO/tagents --resurrect-save"
    # the chats come back from a snapshot as resumed sessions: they do not replay their opening script
    touch "$DEMO_ROOT/resumed" ;;
  statusbar-when-attached)
    i=0; while [ -z "$(tm list-clients 2>/dev/null)" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    sleep "${2:-0.5}"
    # the line the README tells you to add to the tmux config
    tm set -g status-right-length 80
    tm set -g status-right "#{?@tagents_counts,#{@tagents_counts},#($REPO/tagents --counts)} " ;;
  *) echo "usage: world.sh up|down|ctl WIN CMD…|dash-when-attached|statusbar-when-attached" >&2; exit 2 ;;
esac
