# lib/tagents/config.sh — config.yaml, flattened
#
# The deliberate-YAML-subset awk parser (cfg_parse, 165 lines), the once-per-process load with its per-hostname overlay, the accessors everything else is built on (cfg_get/cfg_children/cfg_list), the three path transforms that must not be confused (cfg_expand_dir textually, never realpath, because the keychain is keyed by the literal string; cfg_quote for the /bin/sh command; norm_dir for rule matching), and --config. The section banner at 445-457 heads the file verbatim.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# ---------------------------------------------------------------------------
# config: which Claude account an agent is started on
#
# Everything here is inert without ~/.config/tagents/config.yaml. No file means
# no profiles, which means agent_cmd falls back to exactly the strings this
# script has always used and nothing ever asks you anything.
#
# The parser is one awk program over a deliberate subset of YAML — mappings,
# sequences, quoted scalars, comments — flattened to `path<TAB>value`, one line
# per leaf, in file order. yq is not installed anywhere this has to run, and a
# config that decides which LOGIN an agent gets is not worth a python start-up
# on every keypress. Sequence items are `path.N`, so a rule is claude.rules.0.dir
# and the whole thing stays greppable by hand: that is what --config prints.
# ---------------------------------------------------------------------------
CONFIG_FILE=${TA_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/tagents/config.yaml}
CFG=""          # the flattened config, parsed at most once per process
CFG_LOADED=0
RS=$'\036'      # record separator: awk -v cannot take a value with a newline in
                # it (BWK awk errors out and prints nothing), so the profile
                # table handed to list() is joined with this instead

cfg_parse() {  # [file name for warnings] stdin: yaml -> stdout: path<TAB>value, warnings on stderr
  awk -v FNAME="${1:-$CONFIG_FILE}" '
    function warn(wn, wy) {
      printf "tagents: config: %s:%d: %s\n", FNAME, wn, wy > "/dev/stderr"
    }
    # A # only starts a comment outside quotes and at the start of a word, so
    # `note: "a # b"` and `url: http://x#y` both survive intact.
    function stripc(sc,   si, sh, sq, so, sp) {
      sq = ""; so = ""; sp = " "
      for (si = 1; si <= length(sc); si++) {
        sh = substr(sc, si, 1)
        if (sq == "") {
          if (sh == "#" && (si == 1 || sp == " " || sp == "\t")) return so
          # A quote opens a scalar only at the start of a word, the same rule
          # the # above follows. Without it an apostrophe anywhere in a plain
          # value opened a scalar that never closed, so the trailing comment was
          # taken as part of the value — which for a config_dir is a path that
          # does not exist and a login that silently is not the one asked for.
          # (No apostrophe in this comment: the program is one quoted string.)
          if ((sh == DQ || sh == SQ) &&
              (si == 1 || sp == " " || sp == "\t" || sp == ":")) sq = sh
        } else if (sq == DQ) {
          if (sh == "\\" && si < length(sc)) {
            so = so sh; si++; sh = substr(sc, si, 1); so = so sh; sp = sh; continue
          }
          if (sh == DQ) sq = ""
        } else if (sh == SQ) sq = ""
        so = so sh; sp = sh
      }
      return so
    }
    function unq(uv,   ui, uh, uo, un) {
      if (length(uv) >= 2 && substr(uv, 1, 1) == DQ && substr(uv, length(uv), 1) == DQ) {
        uv = substr(uv, 2, length(uv) - 2); uo = ""
        for (ui = 1; ui <= length(uv); ui++) {
          uh = substr(uv, ui, 1)
          if (uh == "\\" && ui < length(uv)) {
            un = substr(uv, ui + 1, 1)
            if (un == DQ || un == "\\") { uo = uo un; ui++; continue }
          }
          uo = uo uh
        }
        return uo
      }
      if (length(uv) >= 2 && substr(uv, 1, 1) == SQ && substr(uv, length(uv), 1) == SQ)
        return substr(uv, 2, length(uv) - 2)
      return uv
    }
    # A key is a key only when the colon is followed by a space or ends the
    # line; otherwise `- ~/x:y` would parse as a mapping. Env var names have to
    # work as keys, hence the character class.
    function keyof(ks,   kp, kk) {
      kp = index(ks, ":")
      if (kp < 2) return ""
      if (kp < length(ks) && substr(ks, kp + 1, 1) != " ") return ""
      kk = substr(ks, 1, kp - 1)
      if (kk !~ /^[A-Za-z0-9_.-]+$/) return ""
      return kk
    }
    function valof(vs,   vp) {
      vp = substr(vs, index(vs, ":") + 1)
      sub(/^ +/, "", vp)
      return vp
    }
    # Refused rather than half-understood: a flow mapping read as a scalar, or a
    # block scalar read as the character that introduces it, is a config that
    # silently means something other than what it says.
    function badval(bv, bn) {
      if (bv ~ /^\{/ || bv ~ /^\[/) { warn(bn, "flow style is not supported"); return 1 }
      if (bv ~ /^\|/ || bv ~ /^>/)  { warn(bn, "multi-line scalars are not supported"); return 1 }
      if (bv ~ /^&/ || bv ~ /^\*/)  { warn(bn, "anchors are not supported"); return 1 }
      return 0
    }
    function push(pp, pi, pk, pn) {
      np++; cpath[np] = pp; cind[np] = pi; ckey[np] = pk; ckind[np] = pn; ccnt[np] = 0
    }
    # A `key:` on its own opens a container whose kind and indentation are not
    # known until the NEXT line: it may be a mapping, a sequence at the same
    # column or deeper, or nothing at all — in which case the key was a leaf with
    # an empty value and is emitted as one here, on the way back out.
    function resolve(ri, rd) {
      while (np > 1 || cind[np] == -1) {
        if (cind[np] == -1) {
          if (ri > ckey[np] || (rd && ri == ckey[np])) {
            cind[np] = ri; ckind[np] = rd ? "s" : "m"; ccnt[np] = 0
            return
          }
          print cpath[np] "\t"
          np--
          continue
        }
        if (ri < cind[np]) { np--; continue }
        # A key back at the sequence own column ends the sequence.
        if (!rd && ckind[np] == "s" && ri == cind[np]) { np--; continue }
        return
      }
    }
    BEGIN {
      # Built with %c: the whole program is one single-quoted shell string, so a
      # literal apostrophe anywhere in it would end that string.
      SQ = sprintf("%c", 39); DQ = sprintf("%c", 34)
      np = 1; cpath[1] = ""; cind[1] = 0; ckey[1] = -1; ckind[1] = "m"; ccnt[1] = 0
    }
    {
      ln = $0
      # A CRLF file is not rejected, it is mis-parsed: the \r sits between the
      # colon and the end of the line, so every `key:` fails keyof() while every
      # `key: value` keeps the \r inside the value — a config_dir nothing can
      # open, and no error anywhere to say why.
      sub(/\r$/, "", ln)
      # Only a tab in the INDENT is fatal; one inside a value is just a character.
      if (ln ~ /^[ \t]*\t/) {
        if (ln ~ /[^ \t]/) warn(NR, "tab indentation is not supported")
        next
      }
      ln = stripc(ln)
      sub(/[ \t]+$/, "", ln)
      if (ln ~ /^ *$/) next
      ind = match(ln, /[^ ]/) - 1
      body = substr(ln, ind + 1)
      isdash = (body ~ /^- / || body == "-")
      resolve(ind, isdash)

      if (isdash) {
        if (ckind[np] != "s") { warn(NR, "unexpected sequence item"); next }
        ipath = (cpath[np] == "") ? (ccnt[np] "") : (cpath[np] "." ccnt[np])
        ccnt[np]++
        rest = body
        # Dash then ZERO or more spaces: with a `- ` required, a bare `-` on its
        # own line could never become the empty rest the branch below is for, so
        # the item parsed as the scalar string "-" and every key underneath it
        # was warned away and lost. off is computed from the lengths either way,
        # so `- dir: x` and `-   dir: x` still land on their own columns.
        sub(/^- */, "", rest)
        # A mapping item carries its further keys at the column after the dash.
        off = ind + (length(body) - length(rest))
        if (rest == "") { push(ipath, -1, ind, "m"); next }
        ik = keyof(rest)
        if (ik == "") {
          if (!badval(rest, NR)) print ipath "\t" unq(rest)
          next
        }
        push(ipath, off, -2, "m")
        iv = valof(rest)
        if (iv == "") push(ipath "." ik, -1, off, "m")
        else if (!badval(iv, NR)) print ipath "." ik "\t" unq(iv)
        next
      }

      if (ckind[np] == "s") { warn(NR, "unexpected mapping inside a sequence"); next }
      k = keyof(body)
      if (k == "") { warn(NR, "not a key: value line"); next }
      kpath = (cpath[np] == "") ? k : (cpath[np] "." k)
      v = valof(body)
      if (v == "") { push(kpath, -1, ind, "m"); next }
      if (badval(v, NR)) next
      print kpath "\t" unq(v)
    }
    END {
      while (np > 1) {
        if (cind[np] == -1) print cpath[np] "\t"
        np--
      }
    }'
}

# Parsed once per process, however many lookups follow: every key press runs a
# fresh copy of this script, so the cost that matters is one awk, not one per
# cfg_get. A missing file is not an error anywhere but --config.
cfg_load() {
  [ "$CFG_LOADED" = 1 ] && return 0
  CFG_LOADED=1
  # -f as well as -r: a directory is readable, and feeding one to awk gets a
  # raw "i/o error occurred on /dev/stdin" on every single invocation.
  { [ -f "$CONFIG_FILE" ] && [ -r "$CONFIG_FILE" ]; } || return 1
  CFG=$(cfg_parse <"$CONFIG_FILE")
  cfg_overlay
  return 0
}

# ONE CONFIG, SEVERAL MACHINES. The file is shared through dotfiles, and the
# one thing in it that cannot be shared is the account table: on one laptop the
# default login is the employer's and ~/.claude-personal is the second one, on
# another the default is the personal account and the second is a client's.
# The same profile name pointing at a directory that does not exist on this
# machine starts a logged-out Claude — silently, from a picker that looked fine.
#
# So config.<hostname>.yaml beside config.yaml is laid over it, per machine and
# still in the repo. Granularity is the `a.b` subtree: every one the overlay
# mentions (claude.profiles, claude.rules, claude.default, notes.send, …)
# REPLACES the base subtree wholesale, the rest is inherited. Wholesale, not
# merged, because profiles and rules are tables: a union would keep the base
# laptop's ~/.claude-personal row in this machine's picker, which is the exact
# thing being fixed, and rule indices from two files would collide.
#
# Overlay lines go FIRST: cfg_get takes the first match and cfg_children keeps
# file order, so no lookup needs to know an overlay exists. TA_HOST stands in
# for the hostname so a test can have one.
cfg_overlay() {
  local host over top
  host=${TA_HOST:-$(hostname -s 2>/dev/null)}
  [ -n "$host" ] || return 0
  over="${CONFIG_FILE%.yaml}.$host.yaml"
  { [ -f "$over" ] && [ -r "$over" ]; } || return 0
  top=$(cfg_parse "$over" <"$over")
  [ -n "$top" ] || return 0
  CFG=$(printf '%s\n%s\n%s\n' "$top" "$RS" "$CFG" | awk -F"$TAB" -v rs="$RS" '
    function sub2(p,   a, b) {       # the a.b prefix of a path
      a = index(p, ".")
      if (a == 0) return p
      b = index(substr(p, a + 1), ".")
      return (b == 0) ? p : substr(p, 1, a + b - 1)
    }
    $0 == rs { base = 1; next }
    !base    { keep[sub2($1)] = 1; print; next }
    !(sub2($1) in keep) { print }
  ')
}

# Return 1 for "absent", 0 with empty output for "present and empty" — the two
# are different answers, and `config_dir:` written blank must not read as
# ~/.claude-personal having been left out.
cfg_get() {  # <path>
  local out
  cfg_load
  out=$(printf '%s\n' "$CFG" | awk -F"$TAB" -v k="$1" '$1 == k { print "=" $2; exit }')
  [ -n "$out" ] || return 1
  printf '%s' "${out#=}"
  return 0
}

cfg_children() {  # <path> -> direct child names, file order, no repeats
  cfg_load
  printf '%s\n' "$CFG" | awk -F"$TAB" -v k="$1" '
    BEGIN { pre = k "."; pl = length(pre) }
    index($1, pre) == 1 {
      ch = substr($1, pl + 1)
      dot = index(ch, ".")
      if (dot > 0) ch = substr(ch, 1, dot - 1)
      if (ch != "" && !(ch in seen)) { seen[ch] = 1; print ch }
    }'
}

cfg_list() {  # <path> -> a scalar as one line, or a sequence as one line each
  local v i=0
  if v=$(cfg_get "$1"); then printf '%s\n' "$v"; return 0; fi
  while v=$(cfg_get "$1.$i"); do printf '%s\n' "$v"; i=$((i + 1)); done
  [ "$i" -gt 0 ] || return 1
  return 0
}

# THE ONE PLACE A ~ IS EXPANDED, and it expands to $HOME textually — never
# realpath, never `cd`. The keychain item Claude Code logs into is
# sha256(the literal string), so ~/.claude-personal and the resolved path of a
# symlinked ~/.claude-personal are two different logins. The .zshrc exports
# $HOME/..., so that is exactly what has to be exported here.
cfg_expand_dir() {  # <value>
  local d=${1:-}
  case $d in
    '~')   d=$HOME ;;
    '~/'*) d=$HOME/${d#'~/'} ;;
  esac
  while [ ${#d} -gt 1 ] && [ "${d%/}" != "$d" ]; do d=${d%/}; done
  printf '%s' "$d"
}

# Single-quote a value for the command string tmux hands to /bin/sh. Done in
# bash rather than through sed because it runs several times per launch and a
# config dir with a quote in it is not a reason to fork.
cfg_quote() {  # <value>
  local s=${1:-} out=""
  while [ "${s#*\'}" != "$s" ]; do
    out=$out${s%%\'*}"'\\''"
    s=${s#*\'}
  done
  printf "'%s'" "$out$s"
}

# A directory as the rules compare it. Resolved through the filesystem when it
# exists, so a symlinked checkout still matches the rule naming its real path,
# and left textual when it does not — a rule about a directory you have not
# cloned yet is not a reason to stop matching the ones you have.
# CDPATH= because a `cd` that resolves through CDPATH PRINTS where it went, so
# with the usual `export CDPATH` in a .zshrc — inherited by the tmux server and
# by every agent under it — a relative directory came back as two lines and
# every dir rule quietly stopped matching. `--` for a directory starting with a
# dash.
norm_dir() {  # <dir>
  local d=${1:-} r
  r=$(CDPATH= cd -- "$d" 2>/dev/null && pwd -P)
  if [ -n "$r" ]; then printf '%s' "$r"; return 0; fi
  while [ ${#d} -gt 1 ] && [ "${d%/}" != "$d" ]; do d=${d%/}; done
  printf '%s' "$d"
}

config_cmd() {
  if ! { [ -f "$CONFIG_FILE" ] && [ -r "$CONFIG_FILE" ]; }; then
    echo "tagents: no config at $CONFIG_FILE" >&2
    return 1
  fi
  cfg_load
  [ -n "$CFG" ] && printf '%s\n' "$CFG"
  return 0
}
