# lib/tagents/tags.sh — the words a session is found by
#
# Up to ten short tags per session, kept in tags.tsv keyed by session id, set from outside (`tagents --tags`, `--tags-add`, `--tags-set`, which the plugin turns into MCP tools) and read by the list, which hides them past the right edge of a row so the dashboard's search matches them. The SessionEnd hook drops a session's line on /clear (hooks/tmux-agent-state.sh keeps its own copy of the file name; tests/tags.sh pins the two).
#
# Part of ./tagents; `tagents --help` is the model this implements.

TAGS="$STATE_DIR/tags.tsv"
TAGS_MAX=10

# ONE LINE OF TAGS PER SESSION, read back as the stored text: tags joined by single spaces.
tags_of() { tsv_get "$TAGS" "$1"; }

# THE TAGS A TEXT HOLDS, one per line: split on spaces, commas, tabs and newlines, lowercased, duplicates dropped with the first one winning. An invalid tag is printed as `!tag` (as typed) and ends the program with 1, so the caller refuses the whole call.
tags_parse() {  # <text>
  T=$1 LC_ALL=C awk '
    BEGIN {
      n = split(ENVIRON["T"], a, /[ ,\t\n]+/)
      for (i = 1; i <= n; i++) {
        if (a[i] == "") continue
        t = tolower(a[i])
        if (length(t) > 32 || t !~ "^[a-z0-9][a-z0-9._:/-]*$") { print "!" a[i]; exit 1 }
        if (!(t in seen)) { seen[t] = 1; print t }
      }
    }'
}

# THE ENTRY POINT of --tags, --tags-add and --tags-set. K is a session id or a pane id, as for --label; a pane is resolved to the session its record names, because tags belong to the session and never to the pane.
tags_cmd() {  # <show|add|set> <k> [tags]
  local verb=$1 keyv=${2:-} text=${3:-} flag sid= cur new line tag n=0 bad lk="$STATE_DIR/.tags.lock"
  flag=--tags; [ "$verb" = show ] || flag=--tags-$verb
  [ -n "$keyv" ] || { echo "tagents $flag: need a session id or pane id" >&2; return 2; }
  if is_pane_id "$keyv"; then
    sid=$(pane_sid "$keyv")
    [ -n "$sid" ] || { echo "tagents $flag: no session in pane $keyv" >&2; return 2; }
  else
    case "$keyv" in
      *[[:space:]]*) echo "tagents $flag: a session id has no whitespace in it: $keyv" >&2; return 2 ;;
    esac
    sid=$keyv
  fi
  if [ "$verb" = show ]; then
    cur=$(tags_of "$sid")
    [ -z "$cur" ] || printf '%s\n' "$cur"
    return 0
  fi
  new=$(tags_parse "$text"); bad=$?
  if [ "$bad" -ne 0 ]; then
    new=${new##*$'\n'}
    echo "tagents $flag: invalid tag \"${new#!}\": a tag is 1 to 32 characters, the first a letter or digit, the rest letters, digits or . _ : / -" >&2
    return 2
  fi
  [ "$verb" != add ] || [ -n "$new" ] || { echo "tagents $flag: no tag in \"$text\"" >&2; return 2; }
  # THE READ AND THE WRITE ARE ONE STEP: tsv_put rewrites the whole file, so two sessions tagging themselves at once (many start together after a restart) would each read the file before the other wrote and one line would be lost. A state directory nobody may write to is a failed write and not a busy file. Every way out below this line lets go of the lock.
  if ! lock_dir "$lk" 10 100 3; then
    if [ -d "$STATE_DIR" ] && [ ! -w "$STATE_DIR" ]; then echo "tagents $flag: cannot write $TAGS" >&2
    else echo "tagents $flag: the tags file is busy" >&2; fi
    return 1
  fi
  cur=$(tags_of "$sid")
  if [ "$verb" = add ]; then
    new=$(printf '%s\n%s\n' "${cur// /$'\n'}" "$new" | LC_ALL=C awk 'NF && !seen[$0]++')
  fi
  line=
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    line=${line:+$line }$tag; n=$((n + 1))
  done <<EOF2
$new
EOF2
  if [ "$n" -gt "$TAGS_MAX" ]; then
    unlock_dir "$lk"
    echo "tagents $flag: a session keeps at most $TAGS_MAX tags, and that would make $n; session $sid has: ${cur:-none}; replace them with tagents --tags-set" >&2
    return 2
  fi
  tsv_put "$TAGS" "$sid" "$line" 2>/dev/null || { unlock_dir "$lk"; echo "tagents $flag: cannot write $TAGS" >&2; return 1; }
  unlock_dir "$lk"
  signal_ev   # tags are drawn, and the file is not a tmux event
  [ -z "$line" ] || printf '%s\n' "$line"
  return 0
}
