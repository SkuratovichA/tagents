#!/bin/bash
# docs/demo/fake-claude.sh — a pretend agent for the demo recordings. It draws a modest chat screen in its pane and sends the REAL state hook (hooks/tmux-agent-state.sh) and the REAL status line hook (hooks/claude-statusline.sh) the JSON Claude Code would send, so the dashboard's states change for real.
#
# Started as `claude [--resume ID] [flags…]`. Flags it does not know are ignored. Per-chat content is read from $DEMO_CHATS/<session id>.conf (a sourced file); a chat started without a known id gets a fresh one and an empty conversation.
#
# It is steered through a FIFO, one command per line, so a recording can make a chat work, ask or finish at an exact moment:
#   prompt TEXT | tool NAME ARG | reply TEXT | ask QUESTION | permit COMMAND | answer | stop TEXT | sleep N | title TEXT | end
# The chat's `script` variable is run through the same commands at start.

export LC_ALL=${LC_ALL:-en_US.UTF-8}
sid=""; prev=""
for a in "$@"; do [ "$prev" = --resume ] && sid=$a; prev=$a; done
pane=${TMUX_PANE#%}
fresh=0; [ -n "$sid" ] || { sid="demo-new-$pane-$$"; fresh=1; }

title="New chat"; model_id=claude-sonnet-5; model_name="Sonnet 5"; ctx=2000; cost=0.0; script=""; transcript_lines=""
convo=""      # lines of "u:text" / "a:text" / "t:Tool(arg)" kept in $LINES_*
[ -r "$DEMO_CHATS/$sid.conf" ] && . "$DEMO_CHATS/$sid.conf"

cwd=$PWD
short_cwd=$cwd; case "$cwd" in "$HOME"/*) short_cwd="~${cwd#"$HOME"}" ;; esac

# ---------------------------------------------------------------- hooks
send() {  # <hook payload as JSON>
  printf '%s' "$1" | sh "$DEMO_HOOK" >/dev/null 2>&1
}
ev() {  # <event> [jq filter merged in]
  local e=$1 extra=${2:-'{}'}
  send "$(jq -nc --arg e "$e" --arg sid "$sid" --arg cwd "$cwd" --argjson x "$extra" \
    '{hook_event_name:$e, session_id:$sid, cwd:$cwd, transcript_path:"", permission_mode:"default"} + $x')"
}
statusline() {
  jq -nc --arg sid "$sid" --arg id "$model_id" --arg nm "$model_name" --argjson cost "$cost" --argjson pct "$(( ctx / 2000 ))" \
    '{session_id:$sid, model:{id:$id, display_name:$nm}, cost:{total_cost_usd:$cost}, context_window:{used_percentage:$pct}}' |
    sh "$DEMO_STATUSLINE" >/dev/null 2>&1
}
usage_row() {  # what the stand-in tusage reports for this session
  mkdir -p "$DEMO_USAGE"
  printf '%s\t%s\t1\t%s\t0\tslug\t0\t0\t%s\t%s\t%s\t%s\t0\t0\n' \
    "$sid" "$cost" "$ctx" "$(awk -v c="$cost" 'BEGIN{printf "%.2f", c*0.4}')" "$model_id" "$cost" \
    "$(awk -v c="$cost" 'BEGIN{printf "%.2f", c*0.4}')" >"$DEMO_USAGE/$sid.tsv"
}

# ---------------------------------------------------------------- screen
state=new; question=""; options=""; started=$(date +%s); spin=0
declare -a L; nl=0
add() { L[$nl]="$1"; nl=$((nl + 1)); }
load_convo() {
  local line
  while IFS= read -r line; do [ -n "$line" ] && add "$line"; done <<EOT
$convo
EOT
}
D=$'\033[2m'; B=$'\033[1m'; R=$'\033[0m'; C1=$'\033[38;5;110m'; C2=$'\033[38;5;179m'; C3=$'\033[38;5;108m'; RED=$'\033[38;5;174m'
frames=("✻" "✽" "✶" "✢")
clip() { local s=$1 w=$2; if [ "${#s}" -gt "$w" ]; then printf '%s…' "${s:0:$((w - 1))}"; else printf '%s' "$s"; fi; }
at() { printf '\033[%d;1H\033[2K' "$1"; }
redraw() {
  local cols rows w r i first n line kind txt bottom
  local IFS=$' \t\n'   # a WINCH that lands inside `IFS= read` would otherwise see an empty IFS
  read -r rows cols < <(stty size 2>/dev/null) || { rows=40; cols=80; }
  w=$((cols - 3)); [ "$w" -lt 20 ] && w=20
  printf '\033[?25l\033[H\033[2J'
  printf ' %s●%s %s%s%s %s· %s%s' "$C2" "$R" "$B" "agent" "$R" "$D" "$model_name" "$R"
  printf '\033[2;1H %s%s%s' "$D" "$(clip "$short_cwd" "$w")" "$R"
  # box (3 rows) and footer sit at the bottom; the conversation fills what is above, newest last
  bottom=$((rows - 4))
  local avail=$((bottom - 5)); first=$((nl - avail)); [ "$first" -lt 0 ] && first=0
  r=4
  for ((i = first; i < nl; i++)); do
    line=${L[$i]}; kind=${line%%:*}; txt=${line#*:}
    case $kind in
      u) at $r; printf ' %s>%s %s' "$C1" "$R" "$(clip "$txt" "$((w - 2))")" ;;
      a) at $r; printf ' %s●%s %s' "$C3" "$R" "$(clip "$txt" "$((w - 2))")" ;;
      t) at $r; printf '   %s⎿ %s%s' "$D" "$(clip "$txt" "$((w - 4))")" "$R" ;;
      *) at $r; printf ' %s' "$(clip "$line" "$w")" ;;
    esac
    r=$((r + 1))
    case $kind in u) r=$((r + 1)) ;; esac
  done
  # the live line: working spinner, or the question the chat is blocked on
  case $state in
    working)
      at $((bottom - 4)); printf ' %s%s%s Working… %s(%ss · esc to interrupt)%s' "$C2" "${frames[$((spin % 4))]}" "$R" "$D" "$(( $(date +%s) - started ))" "$R" ;;
    ask)
      at $((bottom - 4)); printf ' %s?%s %s%s%s' "$C2" "$R" "$B" "$(clip "$question" "$((w - 3))")" "$R"
      at $((bottom - 3)); printf '   %s' "$options" ;;
    permit)
      at $((bottom - 5)); printf ' %sBash command%s' "$B" "$R"
      at $((bottom - 4)); printf '   %s%s%s' "$C1" "$(clip "$question" "$((w - 4))")" "$R"
      at $((bottom - 3)); printf ' Do you want to proceed?   %s❯ 1. Yes%s  2. Always  3. No' "$C3" "$R" ;;
  esac
  # prompt box
  local rule; rule=$(printf '%*s' "$((cols - 2))" '' | tr ' ' '─')
  at $((bottom - 1)); printf ' %s╭%s╮%s' "$D" "${rule:0:$((cols - 5))}" "$R"
  at $bottom;         printf ' %s│%s %s>%s %*s%s│%s' "$D" "$R" "$C1" "$R" "$((cols - 8))" "" "$D" "$R"
  at $((bottom + 1)); printf ' %s╰%s╯%s' "$D" "${rule:0:$((cols - 5))}" "$R"
  at $((bottom + 2)); printf '   %s? for shortcuts%s' "$D" "$R"
  printf '\033[%d;7H\033[?25h' "$bottom"
}
settitle() { printf '\033]2;%s\007' "$1"; }

# ---------------------------------------------------------------- commands
t0() { started=$(date +%s); }
run_cmd() {
  local cmd=$1 rest=${2:-} a b
  case $cmd in
    prompt) add "u:$rest"; state=working; t0; redraw
            ev UserPromptSubmit "$(jq -nc --arg p "$rest" '{prompt:$p}')"; statusline ;;
    tool)   a=${rest%% *}; b=${rest#* }; [ "$a" = "$rest" ] && b=""
            add "t:$a($b)"; state=working; redraw
            ev PreToolUse "$(jq -nc --arg n "$a" --arg b "$b" '{tool_name:$n, tool_input:{command:$b, file_path:$b}}')"
            ev PostToolUse "$(jq -nc --arg n "$a" '{tool_name:$n}')"; statusline ;;
    reply)  add "a:$rest"; redraw ;;
    ask)    question=$rest; options="1. Redis   2. In-memory   3. Type something else"; state=ask; redraw
            ev PreToolUse "$(jq -nc --arg q "$rest" '{tool_name:"AskUserQuestion", tool_input:{questions:[{question:$q}]}}')"
            ev Notification "$(jq -nc --arg q "$rest" '{notification_type:"elicitation_dialog", message:$q}')" ;;
    permit) question=$rest; state=permit; redraw
            ev Notification "$(jq -nc --arg c "$rest" '{notification_type:"permission_prompt", message:("Allow Bash: " + $c + "?")}')" ;;
    answer) state=working; t0; redraw
            ev PostToolUse "$(jq -nc '{tool_name:"AskUserQuestion"}')" ;;
    stop)   [ -n "$rest" ] && add "a:$rest"; state=idle; redraw
            ev Stop "$(jq -nc --arg m "$rest" '{last_assistant_message:$m}')"; statusline ;;
    title)  title=$rest; settitle "$title" ;;
    sleep)  sleep "$rest" ;;
    cost)   cost=$rest; ctx=$((ctx + 3000)); usage_row; statusline ;;
    end)    finish ;;
  esac
}
run_line() {  # "cmd rest of the line"
  local rest=""
  case $1 in *" "*) rest=${1#* } ;; esac
  run_cmd "${1%% *}" "$rest"
}
finished=0
finish() {
  [ "$finished" = 1 ] && return; finished=1
  ev SessionEnd "$(jq -nc '{reason:"other"}')"
  rm -f "$fifo" "$DEMO_USAGE/$sid.tsv"
  printf '\033[?25h'
  exit 0
}
# TERM is a polite hang-up and ends the session on the record; HUP (the tmux server dying, a reboot) just stops the process, which is what leaves a chat for --resurrect to bring back.
trap finish TERM
trap 'rm -f "$fifo"; exit 0' HUP INT
trap 'redraw' WINCH

# ---------------------------------------------------------------- go
mkdir -p "$DEMO_CTL" "$DEMO_USAGE"
fifo="$DEMO_CTL/$pane.fifo"; rm -f "$fifo"; mkfifo "$fifo"
exec 3<>"$fifo"
stty -echo 2>/dev/null
export CLAUDE_PID=$$

settitle "$title"
load_convo
usage_row
redraw
# the transcript a later --resume (and tagents --resurrect) looks for
tdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$cwd" | tr '/.' '--')"
mkdir -p "$tdir" && [ -e "$tdir/$sid.jsonl" ] || printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$title" >"$tdir/$sid.jsonl"
ev SessionStart "$(jq -nc '{source:"startup"}')"; statusline

# the chat's own script (skipped on a resume after a crash: the chat comes back idle), then wait for commands
[ "$fresh" = 0 ] && [ -e "$DEMO_ROOT/resumed" ] && { script=""; add "a:Session resumed. Ready when you are."; redraw; ev Stop '{}'; }
while IFS= read -r line; do
  [ -n "$line" ] || continue
  run_line "$line"
done <<EOT
$script
EOT
while :; do
  if IFS= read -r -t 1 -u 3 line; then
    [ -n "$line" ] && run_line "$line"
  else
    spin=$((spin + 1)); [ "$state" = working ] && redraw
  fi
done
