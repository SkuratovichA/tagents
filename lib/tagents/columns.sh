# lib/tagents/columns.sh — which columns are on screen
#
# The one table that names a toggleable column (COLS_TABLE), the persisted hidden set with its TA_HIDE_COLS override, and the self-reloading ctrl-w picker — including columns_window, moved here from the keys section so the picker and its entry point sit together. The banner at 1886-1901 (hiding frees width for the detail column, it never reorders) heads the file.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# ---------------------------------------------------------------------------
# columns: which of them are on screen
#
# The money is what this exists for — a dollar figure on every row is a
# distraction when you are not currently spending against a limit — but any
# column that does not answer "which agent and how urgent" can go the same way.
# One hidden key per line in $STATE_DIR/cols, the same idiom as .flat, so the
# choice survives a restart. TA_HIDE_COLS (comma separated) OVERRIDES the file
# rather than adding to it: it is a one-off for a test or a single run, not a
# second place the state lives, so a toggle made while it is set is written down
# and not seen.
#
# Hiding never reorders anything. fitcols() zeroes the column's width before it
# adds up what the row costs, so the freed width flows into the detail column
# exactly as it does when the pane itself is narrow.
# ---------------------------------------------------------------------------
COLS_FILE="$STATE_DIR/cols"
# key<TAB>what hiding it takes away. The picker rows are built from this, and it
# is the only place a toggleable column is named.
COLS_TABLE="badge${TAB}the account indicator before the name
ctx${TAB}the live context size
cost${TAB}every figure in dollars — the column, the ⑂ share, the /5h total
model${TAB}which model the session is set to
acct${TAB}the account name, on the widest lists
loc${TAB}which pane the agent is in"

# WITH NO usage.watch THERE IS NO MONEY TO SHOW, so cost is neither offered nor
# drawn: it drops out of the picker and reads as hidden, while $STATE_DIR/cols
# is left exactly as it was, so switching the feature back on brings back the
# choice made while it was on.
cols_table() {
  if usage_on; then printf '%s\n' "$COLS_TABLE"
  else printf '%s\n' "$COLS_TABLE" | awk -F"$TAB" '$1 != "cost"'
  fi
}

col_keys() { cols_table | cut -f1; }

hidden_cols() {  # the effective hidden set, one key per line
  usage_on || echo cost
  if [ -n "${TA_HIDE_COLS:-}" ]; then
    printf '%s' "$TA_HIDE_COLS" | tr ',' '\n' | awk 'NF { print $1 }'
    return 0
  fi
  [ -e "$COLS_FILE" ] || return 0
  awk 'NF { print $1 }' "$COLS_FILE" 2>/dev/null
}

# NOT `... | grep -q`: this script runs under pipefail and -q closes the pipe on
# the first match, so the producer dies of SIGPIPE and the pipeline fails on
# exactly the runs that FOUND the key (see is_agent_pane).
toggle_col() {  # <key> [fzf port of the list behind the picker]
  local key=${1:-} port=${2:-} known now tmpf
  # -F as well as -x: without it the key is a REGULAR EXPRESSION, so `co.t`
  # matched `cost`, passed this guard as a real column and was written into the
  # state file as a hidden column nothing renders and the picker cannot offer
  # back. The key comes from the picker's own {1} today; --toggle-col takes one
  # from a human, and that is the entry point the header advertises.
  known=$(col_keys | grep -xF -- "$key")
  [ -n "$known" ] || return 0
  now=$(hidden_cols | grep -xF -- "$key")
  mkdir -p "$STATE_DIR" 2>/dev/null
  tmpf="$STATE_DIR/.cols.$$"
  { [ -e "$COLS_FILE" ] && awk -v k="$key" 'NF && $1 != k { print $1 }' "$COLS_FILE"; } \
    >"$tmpf" 2>/dev/null
  [ -n "$now" ] || printf '%s\n' "$key" >>"$tmpf"
  mv -f "$tmpf" "$COLS_FILE" 2>/dev/null || rm -f "$tmpf"
  post_fzf "$port" "reload-sync($SELF --list)"
  return 0
}

# The picker's own rows, reloaded after every toggle so the checkmark flips
# under the cursor. [x] is a column you can see; membership is tested with a
# case over a padded string rather than a pipe into grep, for the SIGPIPE reason
# above.
col_rows() {  # key<TAB>the row as it is read
  local hidden key desc mark
  hidden=" $(hidden_cols | tr '\n' ' ')"
  cols_table | while IFS="$TAB" read -r key desc; do
    [ -n "$key" ] || continue
    case $hidden in *" $key "*) mark=' ' ;; *) mark=x ;; esac
    printf '%s\t[%s] %-5s  %s\n' "$key" "$mark" "$key" "$desc"
  done
}

# THE COLUMN PICKER — ctrl-w, normally the body of a popup and inline when there
# is no popup to be had (including inside one; see prompt()). Enter toggles the
# row under the cursor and the picker STAYS OPEN: fzf runs the toggle as a child
# and then reloads its own rows, so the checkmark flips where you are looking
# and the list behind reloads through its listen port. There is nothing to
# confirm, so esc is the only way out and it is not a cancel.
ask_columns() {  # <fzf port of the list, empty when there is none>
  local port=${1:-} rows pick
  rows=$(col_rows)
  [ -n "$rows" ] || return 0
  # Not piped into `cut`: under pipefail an esc (fzf exits 130) would take the
  # whole pipeline down with it, and esc is the ordinary way out of here.
  pick=$(printf '%s\n' "$rows" | fzf --delimiter="$TAB" --with-nth=2 \
           --layout=reverse --height=100% --no-info --prompt='columns> ' \
           --header="show or hide a column
enter toggles it · esc closes" \
           --bind="enter:execute-silent($SELF --toggle-col {1} $port)+reload($SELF --col-rows)")
  # Interactively nothing ever arrives here — the binding above is what enter
  # does, and it keeps the picker up. A --filter run has no bindings at all,
  # which is how this is driven from a test, and is the only way this is reached.
  pick=${pick%%$TAB*}
  [ -n "$pick" ] && toggle_col "$pick" "$port"
  return 0
}

# Tall enough for the columns plus the two header lines, the prompt and a little
# air, the same arithmetic ask_height does for the profiles.
col_height() {
  local n
  n=$(col_keys | wc -l | tr -d ' ')
  printf '%s' "$(( ${n:-0} + 6 ))"
}

# ctrl-w, and the one key whose binding does NOT carry the popup mode +abort:
# every other key acts on an agent and a popup list closes once it has acted,
# while this one changes what the list looks like, and closing the list you just
# changed is the opposite of what was asked. The ? window keeps the +abort,
# since what it runs is those other keys.
columns_window() {
  local port=${FZF_PORT:-}
  prompt "$(col_height)" --ask-columns "$port" && return 0
  ask_columns "$port"
}
