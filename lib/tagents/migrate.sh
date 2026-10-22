# lib/tagents/migrate.sh — the one pass that turns the seat model of the previous version into windows
#
# The previous version swapped a chat into a seat of the dashboard window and left a placeholder pane (@tagents_slot, @tagents_parked) in the chat's home window. Nothing swaps any more, so on the first start after the upgrade — and on every start while a placeholder or a docked chat remains — each docked chat is sent home with that old swap (kept here, for this pass only), a chat whose placeholder is gone is broken out into a window of its own, the placeholders are closed, the old options and focus hooks are removed, and tnotes is asked to bring parked editors back. The window the dashboard lived in stays as an ordinary window holding the sidebar. The state it leaves is one the previous version handles (every chat in its home window, no placeholder): that is the rollback path.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# Every docked chat back into the window of the placeholder that stands in for it. The pane stays the same pane throughout: a swap moves panes, it never restarts them.
migrate_send_home() {
  local p sp
  tmux list-panes -a -F '#{pane_id} #{@tagents_docked}' 2>/dev/null | LC_ALL=C awk '$2 != "" { print $1 }' |
    while IFS= read -r p; do
      sp=$(tmux list-panes -a -F '#{pane_id} #{@tagents_slot} #{@tagents_parked}' 2>/dev/null |
             LC_ALL=C awk -v a="$p" '$2 == "1" && $3 == a { print $1; exit }')
      tmux set -up -t "$p" @tagents_docked 2>/dev/null
      if [ -n "$sp" ] && [ "$sp" != "$p" ] && tmux swap-pane -d -s "$p" -t "$sp" 2>/dev/null; then
        tmux set -up -t "$sp" @tagents_parked 2>/dev/null
      else
        # Nowhere to go back to: a window of its own, in the session it is in, out of the way of the sidebar.
        tmux break-pane -d -s "$p" -t "$(tmux display -p -t "$p" '#{session_id}' 2>/dev/null):" 2>/dev/null
      fi
    done
}

# ...and now every placeholder is a shell nobody needs: the ones the swap brought into the sidebar window, the empty seats, the strays.
migrate_close_placeholders() {
  local sp
  tmux list-panes -a -F '#{pane_id} #{@tagents_slot}' 2>/dev/null | LC_ALL=C awk '$2 == "1" { print $1 }' |
    while IFS= read -r sp; do tmux kill-pane -t "$sp" 2>/dev/null; done
}

# Only what carries one of the old options is touched, so a server with nothing left to clean costs two list calls.
migrate_clear_options() {
  local p w mark rest
  tmux list-panes -a -F '#{pane_id} #{@tagents_slot}#{@tagents_parked}#{@tagents_docked}#{@tagents_seat}' 2>/dev/null |
    LC_ALL=C awk 'NF == 2 { print $1 }' |
    while IFS= read -r p; do
      tmux set -up -t "$p" @tagents_slot \; set -up -t "$p" @tagents_parked \; set -up -t "$p" @tagents_docked \; set -up -t "$p" @tagents_seat 2>/dev/null
    done
  tmux list-windows -a -F '#{window_id}|#{@tagents}|#{@tagents_cur}#{@tagents_seat}' 2>/dev/null |
    while IFS='|' read -r w mark rest; do
      [ -n "$mark$rest" ] || continue
      # The border labels and the fixed name belonged to the window the dashboard lived in.
      [ "$mark" = 1 ] && tmux set -uw -t "$w" pane-border-status \; set -uw -t "$w" automatic-rename 2>/dev/null
      tmux set -uw -t "$w" @tagents_cur \; set -uw -t "$w" @tagents_seat \; set -uw -t "$w" @tagents 2>/dev/null
    done
  return 0
}

# The focus hooks of the previous version were appended to the four focus events (unpark, the @tagents_cur stamp, the poke, tnotes sync); the ring at [42] and the follow hooks stay. A hook's text says which it is.
migrate_unhook() {
  local ev line idx
  for ev in pane-focus-in after-select-pane after-select-window client-session-changed; do
    tmux show-hooks -g "$ev" 2>/dev/null | while IFS= read -r line; do
      case $line in
        *" --unpark "*|*" --poke "*|*@tagents_cur*|*@ta_notes_any*)
          idx=${line%%]*}; idx=${idx#*[}
          tmux set-hook -gu "$ev[$idx]" 2>/dev/null ;;
      esac
    done
  done
  return 0
}

# Idempotent: with the server marked and nothing of the seat model left it returns after one option read and one pane listing. The lock keeps two starters (a list, the refresher and a status bar run can start together) from sending the same chat home twice; the one that waits finds nothing left to do.
migrate_seats() {
  local locked=""
  [ "$(tmux show -gv @tagents_migrated 2>/dev/null)" = 1 ] && ! legacy_seats_present && return 0
  lock_dir "$STATE_DIR/.migrate.lock" 30 100 3 && locked=1
  if [ "$(tmux show -gv @tagents_migrated 2>/dev/null)" = 1 ] && ! legacy_seats_present; then
    [ "$locked" = 1 ] && unlock_dir "$STATE_DIR/.migrate.lock"
    return 0
  fi
  migrate_send_home
  migrate_close_placeholders
  migrate_clear_options
  migrate_unhook
  tmux set -g @tagents_migrated 1 2>/dev/null
  [ -x "${SELF%/*}/tnotes" ] && { "${SELF%/*}/tnotes" sync >/dev/null 2>&1 & }
  [ "$locked" = 1 ] && unlock_dir "$STATE_DIR/.migrate.lock"
  signal_ev
  return 0
}
