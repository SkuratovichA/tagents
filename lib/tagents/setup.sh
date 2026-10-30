# lib/tagents/setup.sh — `tagents setup`: the hooks and the status line, registered in Claude Code's settings.json
#
# hooks/claude-settings.json is the registration (the block the README shows, with @HOOKS@ where the hooks directory goes) and setup_cmd puts it into the settings.json of every Claude Code config directory this machine uses: ~/.claude, $CLAUDE_CONFIG_DIR and the config_dir of each profile (prof_pairs). A file is processed once however many links lead to it: a profile whose settings.json is a link to ~/.claude/settings.json shares that one file with it.
#
# IT ONLY ADDS. An event is covered when any command of any of its groups names the registration's script as a whole file name, however the command is quoted or redirected and whichever folder it points at (`sh '/Users/x/.claude/hooks/tmux-agent-state.sh'`, `$HOME/.claude/hooks/tmux-agent-state.sh>/dev/null 2>&1` and `(sh ~/.claude/hooks/tmux-agent-state.sh)` count, `my-tmux-agent-state.sh` and `tmux-agent-state.sh.bak` do not), and a covered event is not touched; a missing one gets the registration's group appended at the end of its array. A group somebody wrote is never edited, reordered or removed, and neither is any other key. A status line that is not tagents' own is kept, and --statusline is the one way to replace it. When nothing is missing nothing is written: not the bytes, not the mtime, no backup. The decision comes from the computed plan (setup_jq_merge), never from comparing text.
#
# A SETTINGS FILE THAT BREAKS TAKES THE WHOLE OF CLAUDE CODE'S SETUP WITH IT, so everything that is not plainly an object with arrays under its events is refused and left byte for byte as it was: invalid JSON, a top level that is not an object, `hooks` that is not an object, an event that is not an array, a link to nothing. A write goes to a temp file beside the real file (a link is followed and stays a link) that keeps the old mode, is parsed again, and is renamed over the real file only after the real file is compared with the bytes the plan was made from: Claude Code writes this file too, and when it did meanwhile the plan is made again, three times at most. The old file is kept beside it as <file>.tagents-<UTC time>.bak.
#
# WHICH DIRECTORY THE COMMANDS NAME. For a config dir D it is the first of D/hooks, each --hooks-dir and ~/.claude/hooks that holds every script the registration names (read from it, not listed here). The hook scripts find their state through the CLAUDE_CONFIG_DIR of the session, not through where they sit, so one hooks directory serves every profile. It is written as $HOME/<rest> when it is under $HOME and as the absolute path otherwise, with " \ $ and ` escaped because the path sits inside double quotes of an sh command line.
#
# The loop that follows a link by hand (setup_real) is the one copy of the loop in the entry point of ./tagents that runs before any module is loaded and cannot be shared; tests/setup.sh pins the two against each other.
#
# Part of ./tagents; `tagents --help` is the model this implements.

SETUP_NL=$'\n'

setup_usage() {
  cat <<'EOF'
usage: tagents setup [--check] [--statusline] [--config-dir DIR]... [--hooks-dir DIR]... [--quiet]

Register tagents' Claude Code hooks and status line in settings.json, adding to what is there and never replacing it.

  --check           say what would be added and write nothing; exit 1 while anything is missing
  --statusline      replace a status line of your own with tagents' one (the old file is kept)
  --config-dir DIR  set up DIR/settings.json instead of ~/.claude, $CLAUDE_CONFIG_DIR and the profiles (repeatable)
  --hooks-dir DIR   a directory that may hold the hook scripts (repeatable; install.sh passes its own)
  --quiet           print only refusals and errors
EOF
}

setup_err() { printf 'tagents setup: %s\n' "$*" >&2; }
setup_usage_err() { setup_err "$1"; setup_usage >&2; }
setup_say() { [ "$SETUP_QUIET" = 1 ] || printf '%s\n' "$*"; }

# The definitions both jq programs share. A command names a script when no character that could belong to a longer file name (a letter, a digit, `.`, `_`, `+` or `-`) touches it on either side, so the start or end of the command, a /, a space, a quote, a redirection and a bracket all bound it, while `my-x.sh` and `x.sh.bak` are other files. $c is bound before any pipe that rebinds `.`, which is the trap of jq written this way.
setup_jq_defs() {
  cat <<'EOF'
def esc: gsub("(?<c>[^A-Za-z0-9_-])"; "\\" + .c);
def re($n): "(^|[^A-Za-z0-9._+-])" + ($n | esc) + "($|[^A-Za-z0-9._+-])";
def cmds: [ .[]? | objects | .hooks? | arrays | .[]? | objects | .command? | strings ];
def named($names): . as $c | any($names[]; . as $n | $c | test(re($n)));
def scripts: [ .. | .command? | strings | capture("@HOOKS@/(?<n>[^\" ']+)").n ];
EOF
}

# The whole decision, as a program over the settings file (slurped, so an empty file is [] and two values are two) with the registration in $tpl, the hooks directory as it is written in $hooks and $replace for --statusline. It prints one object: {refuse} when the file cannot be touched, otherwise {added, statusline, foreign, changed, doc} where doc is the file to write and changed says whether it differs from what was read.
setup_jq_merge() {
  setup_jq_defs
  cat <<'EOF'
def fill: walk(if type == "string" then split("@HOOKS@") | join($hooks) else . end);
. as $docs
| $tpl[0] as $t
| ($t.hooks | keys_unsorted) as $events
| ($t.statusLine | scripts) as $slnames
| (if ($docs | length) == 0 then {} elif ($docs | length) == 1 then $docs[0] else null end) as $in
| if ($docs | length) > 1 then {refuse: "it holds \($docs | length) JSON values, not one object"}
  elif ($in | type) != "object" then {refuse: "its top level is \($in | type), not an object"}
  elif ($in | has("hooks")) and ($in.hooks | type) != "object" then {refuse: "\"hooks\" is \($in.hooks | type), not an object"}
  else
    ([ $events[] | select(. as $e | ($in.hooks // {}) | has($e) and (.[$e] | type) != "array") ] | .[0]) as $bad
    | if $bad != null then {refuse: "\"hooks.\($bad)\" is \($in.hooks[$bad] | type), not an array"}
      else
        (reduce $events[] as $e ({hooks: ($in.hooks // {}), added: []};
           ($t.hooks[$e] | scripts) as $names
           | if any((.hooks[$e] // [] | cmds)[]; named($names)) then .
             else .hooks[$e] = ((.hooks[$e] // []) + ($t.hooks[$e] | fill)) | .added += [$e]
             end)) as $m
        | ($in | has("statusLine")) as $has
        | $in.statusLine as $sl
        | (if ($has | not) then "absent"
           elif any(($sl | objects | .command? | strings); named($slnames)) then "ours"
           else "foreign" end) as $kind
        | (if $kind == "absent" then "added"
           elif $kind == "foreign" and $replace == 1 then "replaced"
           elif $kind == "foreign" then "kept"
           else "ok" end) as $status
        | $m.added as $added
        | ($in
           | (if ($added | length) > 0 then .hooks = $m.hooks else . end)
           | (if $status == "added" or $status == "replaced" then .statusLine = ($t.statusLine | fill) else . end)) as $doc
        | {added: $added,
           statusline: $status,
           foreign: (if $kind == "foreign" then ($sl | if type == "object" then (.command // "" | tostring) else tojson end) else null end),
           changed: ((($added | length) > 0) or $status == "added" or $status == "replaced"),
           doc: $doc}
      end
  end
EOF
}

# A directory as the user typed it, made absolute without resolving anything: ~ expanded and the trailing slash dropped by the one rule the config uses, and the current directory put in front of a relative one. -> SETUP_ABS
setup_abs() {  # <dir>
  cfg_expand_dir_v "$1"
  case $CFG_EXPANDED in
    /*) SETUP_ABS=$CFG_EXPANDED ;;
    *)  SETUP_ABS=$PWD/$CFG_EXPANDED ;;
  esac
}

# The config directories to look at, one `kind<US>dir<US>where` line each. `named` is a --config-dir, whose absence is an error; `default` is every other, whose absence is a note.
setup_dirs() {
  local d nm pd _b
  if [ -n "$SETUP_CDIRS" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      setup_abs "$d"; printf 'named%s%s%s\n' "$US" "$SETUP_ABS" "$US"
    done <<EOF
$SETUP_CDIRS
EOF
    return 0
  fi
  printf 'default%s%s%s\n' "$US" "$HOME/.claude" "$US"
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    setup_abs "$CLAUDE_CONFIG_DIR"; printf 'default%s%s%sCLAUDE_CONFIG_DIR\n' "$US" "$SETUP_ABS" "$US"
  fi
  while IFS="$US" read -r nm pd _b; do
    [ -n "$nm" ] && [ -n "$pd" ] || continue
    setup_abs "$pd"; printf 'default%s%s%sprofile %s\n' "$US" "$SETUP_ABS" "$US" "$nm"
  done < <(prof_pairs | tr "$RS" '\n')
}

# A path escaped for the inside of the double quotes of an sh word.
setup_dq() {  # <text>
  printf '%s' "$1" | LC_ALL=C sed -e 's/[\\"$`]/\\&/g'
}

# What @HOOKS@ becomes for a hooks directory: a literal $HOME in front of what lies under it, so the file survives a move of the home directory and the same file serves every machine. -> SETUP_REF
setup_ref() {  # <hooks dir>
  case $1 in
    "$HOME"/*) SETUP_REF='$HOME/'$(setup_dq "${1#"$HOME"/}") ;;
    *)         SETUP_REF=$(setup_dq "$1") ;;
  esac
}

# The first of D/hooks, the --hooks-dir list and ~/.claude/hooks that holds every script the registration names. -> SETUP_HOOKS
setup_hooks_dir() {  # <config dir>
  local h s ok
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    ok=1
    for s in $SETUP_SCRIPTS; do
      [ -f "$h/$s" ] && [ -r "$h/$s" ] || { ok=0; break; }
    done
    if [ "$ok" = 1 ]; then SETUP_HOOKS=$h; return 0; fi
  done <<EOF
$1/hooks
$SETUP_HDIRS
$HOME/.claude/hooks
EOF
  return 1
}

# The file at the end of the links, found by hand because macOS ships no readlink -f: the loop of the entry point of ./tagents, bounded here because this one is given paths nobody has vetted. The directory is resolved to where it physically is, so two spellings of one file are one. Returns 1 with the reason in SETUP_WHY for a loop of links and for a link to nothing. -> SETUP_REAL
setup_real() {  # <file>
  local f=$1 n=0 l d
  while [ -L "$f" ]; do
    n=$((n + 1))
    if [ "$n" -gt 40 ]; then SETUP_WHY='is a loop of links'; return 1; fi
    l=$(readlink "$f")
    case $l in
      /*) f=$l ;;
      *)  case $f in
            */*) f=${f%/*}/$l ;;
            *)   f=$l ;;
          esac ;;
    esac
  done
  if [ "$n" -gt 0 ] && [ ! -e "$f" ]; then SETUP_WHY='is a link to nothing'; return 1; fi
  case $f in
    */*) d=${f%/*}; [ -n "$d" ] || d=/ ;;
    *)   d=. ;;
  esac
  d=$(setup_phys "$d")
  SETUP_REAL=${d%/}/${f##*/}
}

# A directory where it physically is, for setup_real and for the key that keeps a config dir from being done twice. Physical, where norm_dir is logical: the kernel takes a `..` against the directory a name really is, and cd without -P strips it off the name, which differs below a link (with ~/.claude -> dotfiles/claude, ~/.claude/../shared is ~/dotfiles/shared, not ~/shared). norm_dir stays as it is, the dashboard uses it; this falls back to it for a directory that cannot be entered.
setup_phys() {  # <dir>
  local r
  r=$(CDPATH= cd -P -- "$1" 2>/dev/null && pwd -P)
  if [ -n "$r" ]; then printf '%s' "$r"; else norm_dir "$1"; fi
}

# What a plan did or would do, in words. <would|did> <events added> <status line outcome> <what a status line of the user's runs>
setup_parts() {
  local add=added rep=replaced keep=kept out=''
  if [ "$1" = would ]; then add='would add'; rep='would replace'; keep='would keep'; fi
  [ -z "$2" ] || out="$add the hooks for $2"
  case $3 in
    added)    out=$out${out:+; }"$add the status line" ;;
    replaced) out=$out${out:+; }"$rep the status line it has (it runs: $4)" ;;
    kept)     out=$out${out:+; }"$keep the status line it has (it runs: $4); tagents setup --statusline replaces it" ;;
  esac
  printf '%s' "$out"
}

# Whatever an attempt left beside the settings file: the temp file, and a backup of a write that did not happen. The scratch directory goes with the run.
setup_drop() {
  if [ -n "${SETUP_TMPF:-}" ]; then rm -f "$SETUP_TMPF"; fi
  if [ -n "${SETUP_BAK:-}" ]; then rm -f "$SETUP_BAK"; fi
  SETUP_TMPF=''; SETUP_BAK=''
}
setup_cleanup() {
  setup_drop
  if [ -n "${SETUP_SCRATCH:-}" ]; then rm -rf "$SETUP_SCRATCH"; fi
  SETUP_SCRATCH=''
}

# One go at one settings file: read it, plan, and write when the plan changes anything. 0 is done or nothing to do; 1 is refused or failed, with the file as it was; 9 is that the file changed while this ran, so the caller asks again.
setup_attempt() {  # <label> <real file> <hooks ref>
  local label=$1 real=$2 ref=$3
  local snap=$SETUP_SCRATCH/snap plan=$SETUP_SCRATCH/plan err=$SETUP_SCRATCH/err
  local existed=0 refuse changed added status foreign tmpf bak='' ts n msg dir=${2%/*}

  if [ -e "$real" ]; then
    existed=1
    [ -f "$real" ] || { setup_err "$label: is not a regular file; left alone"; return 1; }
    [ -r "$real" ] || { setup_err "$label: cannot be read; left alone"; return 1; }
    cat "$real" >"$snap" 2>/dev/null || { setup_err "$label: cannot be read; left alone"; return 1; }
  else
    : >"$snap"
  fi

  if ! jq -c -s --arg hooks "$ref" --argjson replace "$SETUP_REPLACE" --slurpfile tpl "$SETUP_TPL" "$SETUP_PROG" "$snap" >"$plan" 2>"$err"; then
    setup_err "$label: is not valid JSON ($(sed -n 1p "$err")); left as it is"
    return 1
  fi
  refuse=$(jq -r '.refuse // empty' "$plan")
  if [ -n "$refuse" ]; then setup_err "$label: $refuse; left as it is"; return 1; fi
  changed=$(jq -r '.changed' "$plan")
  added=$(jq -r '.added | join(", ")' "$plan")
  status=$(jq -r '.statusline' "$plan")
  foreign=$(jq -r '(.foreign // "") | gsub("[\n\r\t]+"; " ") | if length > 70 then .[0:70] + "..." else . end' "$plan")

  if [ "$changed" != true ]; then
    if [ "$status" = kept ]; then
      setup_say "$label: the hooks are in place; the status line is your own (it runs: $foreign), tagents setup --statusline replaces it"
    else
      setup_say "$label: already set up"
    fi
    return 0
  fi
  # Whether it can be written is asked only of a file that needs something: a read-only one that already has everything (a dotfiles manager's link into a read-only store) is set up, not refused. --check asks too, so it says what the run would say.
  if [ "$existed" = 1 ] && [ ! -w "$real" ]; then setup_err "$label: is read-only; left alone"; return 1; fi
  [ -w "${dir:-/}" ] && [ -x "${dir:-/}" ] || { setup_err "$label: its directory cannot be written to; left alone"; return 1; }
  if [ "$SETUP_CHECK" = 1 ]; then
    setup_say "$label: $(setup_parts would "$added" "$status" "$foreign")"
    return 1
  fi

  tmpf=$(mktemp "$real.tagents-tmp.XXXXXX" 2>/dev/null) || { setup_err "$label: cannot write beside it; left as it is"; return 1; }
  SETUP_TMPF=$tmpf
  if [ "$existed" = 1 ]; then
    cp -p "$real" "$tmpf" 2>/dev/null || { setup_err "$label: cannot write beside it; left as it is"; setup_drop; return 1; }
  else
    chmod "$(printf '%o' $((0666 & ~0$(umask))))" "$tmpf" 2>/dev/null
  fi
  if ! jq '.doc' "$plan" >"$tmpf" 2>/dev/null || ! jq -e 'type == "object"' "$tmpf" >/dev/null 2>&1; then
    setup_err "$label: could not write the new settings; left as it is"
    setup_drop; return 1
  fi

  if [ "$existed" = 1 ]; then
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    bak=$real.tagents-$ts.bak; n=1
    while [ -e "$bak" ] || [ -L "$bak" ]; do n=$((n + 1)); bak=$real.tagents-$ts-$n.bak; done
    cp -p "$real" "$bak" 2>/dev/null || { setup_err "$label: cannot keep a backup beside it; left as it is"; setup_drop; return 1; }
    SETUP_BAK=$bak
    cmp -s "$real" "$snap" || { setup_drop; return 9; }
  else
    { [ ! -e "$real" ] && [ ! -L "$real" ]; } || { setup_drop; return 9; }
  fi
  SETUP_BAK=''
  if ! mv -f "$tmpf" "$real" 2>/dev/null; then
    setup_err "$label: could not replace it; left as it is"
    rm -f "$tmpf" ${bak:+"$bak"}; SETUP_TMPF=''
    return 1
  fi
  SETUP_TMPF=''

  msg=$(setup_parts did "$added" "$status" "$foreign")
  [ -z "$bak" ] || msg="$msg; the previous file is kept as $(tilde_of "$bak")"
  setup_say "$label: $msg"
  return 0
}

# One config directory: which file it really is, which hooks directory its commands name, and up to three goes at it.
setup_one() {  # <config dir>
  local d=$1 f=$1/settings.json label real names try=0 rc
  label=$(tilde_of "$f")
  if ! setup_real "$f"; then setup_err "$label: $SETUP_WHY; left alone"; return 1; fi
  real=$SETUP_REAL
  case "$SETUP_NL$SETUP_SEEN$SETUP_NL" in
    *"$SETUP_NL$real$SETUP_NL"*) setup_say "$label: the same file as one handled above"; return 0 ;;
  esac
  [ ! -L "$f" ] || label="$label (a link to $(tilde_of "$real"))"
  if ! setup_hooks_dir "$d"; then
    names=${SETUP_SCRIPTS% }
    setup_err "$label: no hooks directory holds ${names// / and } — run install.sh first (add --hooks-dir $(tilde_of "$d")/hooks to give this config dir a copy of its own)"
    return 1
  fi
  # Remembered only once there is a hooks directory to work with: a config dir that cannot be set up must not make the next one, which can, skip the same file as handled.
  SETUP_SEEN=$SETUP_SEEN${SETUP_SEEN:+$SETUP_NL}$real
  setup_ref "$SETUP_HOOKS"
  while [ "$try" -lt 3 ]; do
    try=$((try + 1))
    setup_attempt "$label" "$real" "$SETUP_REF"; rc=$?
    [ "$rc" = 9 ] || return "$rc"
  done
  setup_err "$label: kept changing while it was being worked on; left as it is"
  return 1
}

setup_cmd() {
  local check=0 quiet=0 sl=0 root kind dir why key list rc=0 found=0 seen_dirs=''
  SETUP_CDIRS=''; SETUP_HDIRS=''
  while [ $# -gt 0 ]; do
    case $1 in
      --check)      check=1 ;;
      --statusline) sl=1 ;;
      --quiet)      quiet=1 ;;
      --config-dir) [ $# -ge 2 ] && [ -n "$2" ] || { setup_usage_err "--config-dir needs a directory"; return 2; }
                    SETUP_CDIRS=$SETUP_CDIRS${SETUP_CDIRS:+$SETUP_NL}$2; shift ;;
      --hooks-dir)  [ $# -ge 2 ] && [ -n "$2" ] || { setup_usage_err "--hooks-dir needs a directory"; return 2; }
                    setup_abs "$2"; SETUP_HDIRS=$SETUP_HDIRS${SETUP_HDIRS:+$SETUP_NL}$SETUP_ABS; shift ;;
      -h|--help)    setup_usage; return 0 ;;
      -*)           setup_usage_err "unknown option $1"; return 2 ;;
      *)            setup_usage_err "unexpected argument $1"; return 2 ;;
    esac
    shift
  done
  SETUP_CHECK=$check; SETUP_QUIET=$quiet; SETUP_REPLACE=$sl
  SETUP_SEEN=''; SETUP_TMPF=''; SETUP_BAK=''; SETUP_SCRATCH=''

  command -v jq >/dev/null 2>&1 || { setup_err "jq is not installed, and it is what edits settings.json without breaking it (brew install jq)"; return 1; }
  case $TA_LIB in
    */lib/tagents) root=${TA_LIB%/lib/tagents} ;;
    *)             root=. ;;
  esac
  SETUP_TPL=$root/hooks/claude-settings.json
  [ -r "$SETUP_TPL" ] || { setup_err "cannot read $SETUP_TPL — this is the entry point of a checkout, not a file to copy alone"; return 1; }
  jq -e '(.hooks | type) == "object" and (.statusLine | type) == "object"' "$SETUP_TPL" >/dev/null 2>&1 \
    || { setup_err "$SETUP_TPL is not a registration (an object with hooks and statusLine)"; return 1; }
  SETUP_SCRIPTS=$(jq -r "$(setup_jq_defs)"$'\n''scripts | unique | .[]' "$SETUP_TPL" | tr '\n' ' ')
  [ -n "$SETUP_SCRIPTS" ] || { setup_err "$SETUP_TPL names no script"; return 1; }
  SETUP_PROG=$(setup_jq_merge)

  SETUP_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/tagents-setup.XXXXXX" 2>/dev/null) || { SETUP_SCRATCH=''; setup_err "cannot make a temporary directory"; return 1; }
  trap 'setup_cleanup; exit 130' INT
  trap 'setup_cleanup; exit 143' TERM
  trap 'setup_cleanup; exit 129' HUP

  # The program is run once on an empty file before any real one is read, so a jq that cannot run it (one without walk/1, say) is reported once as what it is. jq exits 5 for a parse error and for a runtime error alike, so afterwards a failure on a file cannot tell the two apart and says "not valid JSON".
  if ! jq -c -s --arg hooks x --argjson replace 0 --slurpfile tpl "$SETUP_TPL" "$SETUP_PROG" </dev/null >/dev/null 2>"$SETUP_SCRATCH/err"; then
    setup_err "this jq ($(jq --version 2>/dev/null || echo unknown)) cannot run setup: $(sed -n 1p "$SETUP_SCRATCH/err")"
    setup_cleanup; trap - INT TERM HUP; return 1
  fi

  list=$(setup_dirs)
  while IFS="$US" read -r kind dir why <&3; do
    [ -n "$dir" ] || continue
    key=$(setup_phys "$dir")
    case "$SETUP_NL$seen_dirs$SETUP_NL" in *"$SETUP_NL$key$SETUP_NL"*) continue ;; esac
    seen_dirs=$seen_dirs${seen_dirs:+$SETUP_NL}$key
    if [ ! -d "$dir" ]; then
      if [ "$kind" = named ]; then
        setup_err "$(tilde_of "$dir"): there is no such directory"; rc=1
      else
        setup_say "$(tilde_of "$dir")${why:+ ($why)}: no such directory, skipped"
      fi
      continue
    fi
    found=1
    setup_one "$dir" || rc=1
  done 3<<EOF
$list
EOF
  [ "$found" = 1 ] || [ "$rc" = 1 ] || setup_say "no Claude Code config directory found, so nothing was set up: start Claude Code once, then run tagents setup"

  setup_cleanup
  trap - INT TERM HUP
  return "$rc"
}
