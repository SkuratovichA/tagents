# lib/tagents/accounts.sh — which Claude login an agent runs on
#
# The profile layer above the parser, keeping the two questions apart that the comments insist on keeping apart: profile_for/profile_named/profile_args pick a login for a NEW agent from claude.rules and claude.default, while profile_claiming/profile_of_cfg/resume_profile answer which login a RECORDED session actually belongs to (resume must never recompute from rules). agent_cmd is the single place the `env -u CLAUDE_CONFIG_DIR … claude …` string is assembled for both new and resume; prof_pairs is the badge/config-dir table list() and usage_env read.
#
# Part of ./tagents; `tagents --help` is the model this implements.

profile_exists() {  # <name>
  local p=${1:-} c
  [ -n "$p" ] || return 1
  for c in $(cfg_children claude.profiles); do
    [ "$c" = "$p" ] && return 0
  done
  return 1
}

# A rule that names a profile nobody configured is a typo, and the expensive way
# to find out is an agent quietly running on the wrong login. Say so and skip it.
profile_named() {  # <name> <where> -> 0 when usable
  local p=${1:-} where=${2:-}
  # Nothing at all is the likeliest typo of the lot: a `profile:` line indented
  # one column short of its `- dir:` item parses as a rule of its own, and both
  # halves then go quietly missing. Its own wording, so it does not read as
  # "unknown profile" with an empty name.
  if [ -z "$p" ]; then
    echo "tagents: config: $where names no profile — skipped" >&2
    return 1
  fi
  [ "$p" = ask ] && return 0
  profile_exists "$p" && return 0
  echo "tagents: config: $where names unknown profile \"$p\" — skipped" >&2
  return 1
}

# WHICH ACCOUNT A DIRECTORY BELONGS TO. Prints a profile name, or "ask" when the
# config wants to be asked; returns 1 with no output when there are no profiles
# at all, which is the caller signal to launch exactly as it always did.
profile_for() {  # <dir> [tmux-session-name]
  local dir=${1:-} sess=${2:-} nd i s d p
  cfg_load
  [ -n "$(cfg_children claude.profiles)" ] || return 1
  nd=$(norm_dir "$dir")
  for i in $(cfg_children claude.rules); do
    s=$(cfg_get "claude.rules.$i.session") || s=""
    d=$(cfg_get "claude.rules.$i.dir") || d=""
    p=$(cfg_get "claude.rules.$i.profile") || p=""
    # A session is matched by containment: tmux session names are short and get
    # suffixed (work, work-2, personal-old), and nobody wants a rule per suffix.
    if [ -n "$s" ]; then
      case "$sess" in *"$s"*) ;; *) continue ;; esac
    fi
    # ...a directory by path component, so ~/git/personalx is NOT under
    # ~/git/personal however much of a prefix it looks like.
    if [ -n "$d" ]; then
      d=$(norm_dir "$(cfg_expand_dir "$d")")
      case "$nd" in "$d"|"$d"/*) ;; *) continue ;; esac
    fi
    profile_named "$p" "rule $i" || continue
    printf '%s' "$p"
    return 0
  done
  p=$(cfg_get claude.default) || p="ask"
  [ -n "$p" ] || p="ask"
  profile_named "$p" "default" || p="ask"
  printf '%s' "$p"
  return 0
}

# The arguments a profile launches with: its own, else the global ones, else the
# flag this script has always used. A scalar goes in verbatim — those are the
# shell words the user wrote, and requoting them would turn `--model opus` into
# a single argument — while a list is quoted item by item, which is the way to
# pass an argument that contains a space.
profile_args() {  # <profile>
  local prof=${1:-} v i out=""
  if v=$(cfg_get "claude.profiles.$prof.args"); then printf '%s' "$v"; return 0; fi
  if cfg_get "claude.profiles.$prof.args.0" >/dev/null 2>&1; then
    i=0
    while v=$(cfg_get "claude.profiles.$prof.args.$i"); do
      out="${out:+$out }$(cfg_quote "$v")"; i=$((i + 1))
    done
    printf '%s' "$out"; return 0
  fi
  if v=$(cfg_get claude.args); then printf '%s' "$v"; return 0; fi
  if cfg_get claude.args.0 >/dev/null 2>&1; then
    i=0
    while v=$(cfg_get "claude.args.$i"); do
      out="${out:+$out }$(cfg_quote "$v")"; i=$((i + 1))
    done
    printf '%s' "$out"; return 0
  fi
  printf '%s' '--dangerously-skip-permissions'
}

# THE COMMAND STRING A LAUNCH ACTUALLY RUNS. One string, because both callers
# need one: tmux new-window hands it to /bin/sh, and the resume-in-place path
# types it into a shell with send-keys.
#
# With no profile it is byte for byte what this script produced before any of
# this existed — that is what makes a missing config a no-op rather than a
# behaviour change.
#
# `env -u CLAUDE_CONFIG_DIR` comes first unconditionally, even when a config dir
# follows it. An inherited value is a different login, and clearing it with
# CLAUDE_CONFIG_DIR= would not do: empty is not unset, and only unset means the
# default account (see LEARNING.md, "claude accounts").
#
# A profile of the form `dir:<path>` is not a configured profile at all but a
# raw config dir — the account a closed session was recorded as having run on,
# which no profile claims any more. Resume builds one of those so a conversation
# still comes back on the login that holds it. `dir:` with nothing after it is
# the default account, stated explicitly.
agent_cmd() {  # <profile> <new|resume> [sid]
  local prof=${1:-} what=${2:-new} sid=${3:-}
  local cdir="" cdset=0 cmd="" args="" pre="" k v out

  if [ -z "$prof" ]; then
    if [ "$what" = resume ]; then printf '%s %s' "$RESUME_CMD" "$sid"
    else printf '%s' "$NEW_CMD"; fi
    return 0
  fi

  case $prof in
    dir:*)
      cdir=$(cfg_expand_dir "${prof#dir:}"); cdset=1 ;;
    ask)
      # "ask" is the instruction to open the dialog, not an account. Building a
      # command for it would look up claude.profiles.ask, find nothing, and
      # produce a launch on the DEFAULT login — a wrong account, silently.
      echo "tagents: \"ask\" is not a profile" >&2
      return 1 ;;
    *)
      # Everything inside this script hands over a name that came out of the
      # config; --new and --agent-cmd take one from a human, and a typo there
      # used to render as plain `env -u CLAUDE_CONFIG_DIR claude …` — the wrong
      # login, with nothing said. Refuse rather than guess.
      profile_exists "$prof" || {
        echo "tagents: no claude profile \"$prof\" in $CONFIG_FILE" >&2
        return 1
      }
      if v=$(cfg_get "claude.profiles.$prof.config_dir"); then
        cdir=$(cfg_expand_dir "$v"); cdset=1
      fi
      cmd=$(cfg_get "claude.profiles.$prof.command") || cmd="" ;;
  esac
  [ -n "$cmd" ] || cmd=claude

  pre='env -u CLAUDE_CONFIG_DIR'
  [ "$cdset" = 1 ] && [ -n "$cdir" ] && pre="$pre CLAUDE_CONFIG_DIR=$(cfg_quote "$cdir")"
  case $prof in
    dir:*) ;;
    *)
      for k in $(cfg_children "claude.profiles.$prof.env"); do
        v=$(cfg_get "claude.profiles.$prof.env.$k") || v=""
        pre="$pre $k=$(cfg_quote "$v")"
      done ;;
  esac

  # TA_NEW_CMD / TA_RESUME_CMD replace the binary and its arguments but never
  # the account prefix: they exist to point tagents at a wrapper, and a wrapper
  # still has to be started on the right login.
  if [ "$what" = resume ]; then
    if [ -n "${TA_RESUME_CMD:-}" ]; then out="$RESUME_CMD"
    else
      args=$(profile_args "$prof")
      out="$cmd${args:+ $args} --resume"
    fi
    printf '%s %s %s' "$pre" "$out" "$sid"
  else
    if [ -n "${TA_NEW_CMD:-}" ]; then out="$NEW_CMD"
    else
      args=$(profile_args "$prof")
      out="$cmd${args:+ $args}"
    fi
    printf '%s %s' "$pre" "$out"
  fi
}

# WHICH PROFILE REALLY CLAIMS A CONFIG DIR — a name only when one does, and a
# non-zero return when none does. This is the identity question, kept apart from
# the display question below on purpose: profile_of_cfg has to print SOMETHING
# for a column, so it falls back to the literal word "default" and to the
# directory basename, and a config with a profile actually named `default` (or
# named after somebody else basename) would otherwise hand those labels back as
# if a profile had matched, and resume the conversation on a login it never ran
# on. Takes the dir already expanded.
profile_claiming() {  # <expanded config dir, empty for the default account>
  local cd=${1:-} p pd nodef="" ndn=0
  cfg_load
  for p in $(cfg_children claude.profiles); do
    if pd=$(cfg_get "claude.profiles.$p.config_dir"); then
      pd=$(cfg_expand_dir "$pd")
      [ -n "$cd" ] && [ "$pd" = "$cd" ] && { printf '%s' "$p"; return 0; }
    else
      nodef=$p; ndn=$((ndn + 1))
    fi
  done
  # An empty value is CLAUDE_CONFIG_DIR unset, which is the account of the one
  # profile that has no config_dir — and only when there is exactly one, since
  # two of them are two names for the same login and neither is the answer.
  [ -z "$cd" ] && [ "$ndn" = 1 ] && { printf '%s' "$nodef"; return 0; }
  return 1
}

# The account a state record names, as a NAME FOR DISPLAY rather than a path. An
# old record has no such field at all, and hascfg=0 means exactly that: print
# nothing, because "unset" and "we never wrote it down" would otherwise both
# read as the default account. Nothing may launch on what this returns — see
# profile_claiming.
profile_of_cfg() {  # <recorded config dir> <hascfg>
  local cd=${1:-} has=${2:-0} p
  [ "$has" = 1 ] || return 0
  cfg_load
  [ -n "$cd" ] && cd=$(cfg_expand_dir "$cd")
  p=$(profile_claiming "$cd") && { printf '%s' "$p"; return 0; }
  [ -n "$cd" ] || { printf 'default'; return 0; }
  # No profile claims it: name it after the directory, which is at least the
  # login it is. ~/.claude-personal reads as "claude-personal".
  cd=${cd##*/}
  printf '%s' "${cd#.}"
}

# WHICH ACCOUNT A CLOSED SESSION COMES BACK ON — the one it ran on, never the
# rules. A conversation resumed on a different login is not there at all:
# --resume looks in that config dir and finds nothing, so the rules are only the
# fallback for a record written before the account was being recorded.
resume_profile() {  # <recorded cfg dir> <hascfg> <dir> <session> -> profile/ask
  local cd=${1:-} has=${2:-0} dir=${3:-} sess=${4:-} p
  if [ "$has" = 1 ]; then
    [ -n "$cd" ] && cd=$(cfg_expand_dir "$cd")
    # profile_claiming, never profile_of_cfg: the latter is a label for a
    # column and answers "default" or a basename when nothing matches, and
    # spelling a profile like a label is not the same as being one.
    p=$(profile_claiming "$cd") && { printf '%s' "$p"; return 0; }
    # Recorded, but no profile claims it. With no profiles configured at all
    # there is nothing to say, so the launch stays exactly as it always was.
    [ -n "$(cfg_children claude.profiles)" ] || return 0
    printf 'dir:%s' "$cd"
    return 0
  fi
  profile_for "$dir" "$sess" || return 0
}

# The profile table list() renders the account and badge columns from, joined
# with $RS because awk -v cannot take a newline. Empty second field = the
# default account.
#
# The badge is the one- or two-character stand-in for that account — the whole
# of the acct column, on a row narrow enough that the acct column is not there.
# It defaults to the profile's first character, so `personal` and `work` render
# as p and w with nothing configured at all, and `badge:` is only for the day
# two profiles start with the same letter. Keys are ASCII by the parser's own
# character class, so the first byte is the first character.
prof_pairs() {
  local p pd bd
  cfg_load
  for p in $(cfg_children claude.profiles); do
    if pd=$(cfg_get "claude.profiles.$p.config_dir"); then pd=$(cfg_expand_dir "$pd")
    else pd=""; fi
    bd=$(cfg_get "claude.profiles.$p.badge") || bd=""
    [ -n "$bd" ] || bd=${p%"${p#?}"}
    printf '%s%s%s%s%s%s' "$p" "$US" "$pd" "$US" "$bd" "$RS"
  done
}
