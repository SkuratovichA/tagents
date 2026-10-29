# lib/tagents/config.sh — config.toml (and config.yaml, its fallback), flattened
#
# Two deliberate-subset awk parsers (cfg_parse for YAML, cfg_parse_toml for TOML) that emit the same `path<TAB>value` stream, the once-per-process load with its per-hostname overlay, the accessors everything else is built on (cfg_get/cfg_children/cfg_list), the three path transforms that must not be confused (cfg_expand_dir textually, never realpath, because the keychain is keyed by the literal string; cfg_quote for the /bin/sh command; norm_dir for rule matching), --config, and --check: cfg_check collects what is wrong with the file into CFG_NOTES the way keys.sh collects KEY_NOTES — the parsers' refusals (carried in their stream and sifted out by cfg_sift), the format notes (a YAML config is deprecated, a config.toml shadowing a config.yaml), the values, accounts_check's profiles and rules, the key notes — for the dashboard header, the status bar and the verb. The section banner at the top of "what is wrong with the config" heads that part verbatim.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# ---------------------------------------------------------------------------
# config: which Claude account an agent is started on
#
# Everything here is inert without ~/.config/tagents/config.toml. No file means no profiles, which means agent_cmd falls back to exactly the strings this script has always used and nothing ever asks you anything.
#
# Each parser is one awk program over a deliberate subset of its format — tables, sequences, quoted scalars, comments — flattened to `path<TAB>value`, one line per leaf, in file order. yq is not installed anywhere this has to run, and a config that decides which LOGIN an agent gets is not worth a python start-up on every keypress. Sequence items (a YAML list, a TOML array, a TOML [[table]]) are `path.N`, so a rule is claude.rules.0.dir and the whole thing stays greppable by hand: that is what --config prints.
#
# WHICH FILE. cfg_resolve below. $TA_CONFIG names the file and its extension picks the reader. Without it the directory is searched: config.toml, else config.yaml (read as it always was, and reported as deprecated by --check and the status bar), else config.toml as the place a new one would go.
# ---------------------------------------------------------------------------
CFG_TWIN=''     # the config.yaml that a config.toml beside it hides, if any
cfg_readable() { [ -f "$1" ] && [ -r "$1" ]; }
cfg_resolve() {  # -> CONFIG_FILE, CFG_TWIN
  local d
  CFG_TWIN=''
  if [ -n "${TA_CONFIG:-}" ]; then CONFIG_FILE=$TA_CONFIG; return 0; fi
  d=${XDG_CONFIG_HOME:-$HOME/.config}/tagents
  if cfg_readable "$d/config.toml"; then
    CONFIG_FILE=$d/config.toml
    ! cfg_readable "$d/config.yaml" || CFG_TWIN=$d/config.yaml
  elif cfg_readable "$d/config.yaml"; then CONFIG_FILE=$d/config.yaml
  else CONFIG_FILE=$d/config.toml
  fi
}
cfg_resolve
CFG=""          # the flattened config, parsed at most once per process
CFG_LOADED=0
RS=$'\036'      # record separator: LC_ALL=C awk -v cannot take a value with a newline in
                # it (BWK awk errors out and prints nothing), so the profile
                # table handed to list() is joined with this instead
CFG_NL='
'
# WHAT IS WRONG WITH THE CONFIG, collected once per process by cfg_check the way
# resolve_keys collects KEY_NOTES: one line per problem, the count beside it,
# and the one-item summary the dashboard header and the status bar show.
CFG_NOTES=''
CFG_NPROBLEMS=0
CFG_SUMMARY=''
CFG_CHECKED=0
# Where the status bar remembers the last verdict — see cfg_count_cached.
CFG_STAMP="$STATE_DIR/.cfg-check"
# How long a verdict may stand when the config itself has not changed.
CFG_CHECK_EVERY=${TA_CFG_CHECK_EVERY:-60}
CFG_PARSE_NOTES=''  # the lines the parser refused, kept on the way through cfg_load
CFG_OVER_FILE=''    # the per-host overlay in effect, so a note can name the file a key is in
CFG_OVER_TWIN=''    # ...and the config.<host>.yaml that a config.<host>.toml hides, if any
CFG_OVL=''          # cfg_overlay_for's answer
CFG_OVER_TOPS=' '   # ...and the a.b subtrees it replaced, space-delimited
CFG_SIFTED=''       # cfg_sift's answer
CFG_EXPANDED=''     # cfg_expand_dir_v's answer
CFG_TOP=''          # cfg_top_of's answer

cfg_parse() {  # [file name for warnings] stdin: yaml -> stdout: path<TAB>value, refusals as !<TAB>file:line: why
  LC_ALL=C awk -v FNAME="${1:-$CONFIG_FILE}" '
    # A refusal travels IN the stream, on a line no key can begin with: the
    # stream is read out of a command substitution, and stderr is the one thing
    # a substitution cannot capture — which is how these went unseen for as
    # long as they did. cfg_sift takes them back out.
    function warn(wn, wy) {
      printf "!\t%s:%d: %s\n", FNAME, wn, wy
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

# THE TOML READER: a deliberate subset of TOML 1.0, flattened to the same `path<TAB>value` stream cfg_parse makes, so nothing downstream knows which format a file was in. What it reads: comments, bare / "quoted" / 'literal' / dotted keys, [tables], [[arrays of tables]], strings (basic with the escapes \" and \\ only, and literal), decimal integers and simple decimal floats, true / false, and arrays and inline tables of those. Everything else is refused on its own line with file:line — multi-line strings, any other escape (a decoded newline or tab cannot live in a line-oriented stream), dates and times, hex / octal / binary / exponent / inf / nan, arrays of tables or of arrays, nested inline tables — exactly as cfg_parse refuses flow style: a value half-understood is a login that silently is not the one asked for. A refused table header skips the keys under it, because keys given to the wrong table are worse than keys dropped.
#
# A table with no key and no sub-table is emitted as `path<TAB>` (a profile that is only a name: `[claude.profiles.work]`), the way YAML's `work:` is. The program is one single-quoted shell string: no apostrophe anywhere in it, SQ and DQ are built with sprintf.
cfg_parse_toml() {  # [file name for warnings] stdin: toml -> stdout: path<TAB>value, refusals as !<TAB>file:line: why
  LC_ALL=C awk -v FNAME="${1:-$CONFIG_FILE}" '
    function warn(wn, wy) {
      printf "!\t%s:%d: %s\n", FNAME, wn, wy
    }
    function ltrim(ts) { sub(/^[ \t]+/, "", ts); return ts }
    function trim(ts) { sub(/^[ \t]+/, "", ts); sub(/[ \t]+$/, "", ts); return ts }
    function skipws(ss, si) {
      while (substr(ss, si, 1) == " " || substr(ss, si, 1) == "\t") si++
      return si
    }
    # A # starts a comment only outside a string.
    function stripc(sc,   si, sh, sq, so) {
      sq = ""; so = ""
      for (si = 1; si <= length(sc); si++) {
        sh = substr(sc, si, 1)
        if (sq == "") {
          if (sh == "#") return so
          if (sh == DQ || sh == SQ) sq = sh
        } else if (sq == DQ) {
          if (sh == "\\" && si < length(sc)) { so = so sh; si++; sh = substr(sc, si, 1) }
          else if (sh == DQ) sq = ""
        } else if (sh == SQ) sq = ""
        so = so sh
      }
      return so
    }
    # How many [ are still open at the end of the text: an array that has not closed carries on onto the next line.
    function depth(ds,   di, dh, dq, dd) {
      dq = ""; dd = 0
      for (di = 1; di <= length(ds); di++) {
        dh = substr(ds, di, 1)
        if (dq == "") {
          if (dh == DQ || dh == SQ) dq = dh
          else if (dh == "[") dd++
          else if (dh == "]") dd--
        } else if (dq == DQ) {
          if (dh == "\\") di++
          else if (dh == DQ) dq = ""
        } else if (dh == SQ) dq = ""
      }
      return dd
    }
    # A dotted key from the start of ks: the parts in KC[1..KN], the text after it in KR. 0 when there is no key to read.
    function scankey(ks,   kp, kc1, kj, kq, kout, kch) {
      KN = 0; kp = 1
      while (1) {
        kp = skipws(ks, kp)
        kc1 = substr(ks, kp, 1)
        if (kc1 == DQ) {
          kout = ""; kp++
          while (1) {
            kch = substr(ks, kp, 1)
            if (kch == "") return 0
            if (kch == "\\") {
              kq = substr(ks, kp + 1, 1)
              if (kq != DQ && kq != "\\") return 0
              kout = kout kq; kp += 2; continue
            }
            if (kch == DQ) break
            kout = kout kch; kp++
          }
          kp++
        } else if (kc1 == SQ) {
          kj = index(substr(ks, kp + 1), SQ)
          if (kj == 0) return 0
          kout = substr(ks, kp + 1, kj - 1); kp += kj + 1
        } else {
          kj = kp
          while (substr(ks, kj, 1) ~ /[A-Za-z0-9_-]/) kj++
          if (kj == kp) return 0
          kout = substr(ks, kp, kj - kp); kp = kj
        }
        if (kout == "") return 0
        KN++; KC[KN] = kout
        kp = skipws(ks, kp)
        if (substr(ks, kp, 1) == ".") { kp++; continue }
        break
      }
      KR = substr(ks, kp)
      return 1
    }
    function keypath(kb,   ki) {
      for (ki = 1; ki <= KN; ki++) kb = (kb == "") ? KC[ki] : (kb "." KC[ki])
      return kb
    }
    # The path of a [table] header. A part that names an array of tables stands for the element being filled: [[a]] then [a.b] is a.0.b.
    function hdrpath(   hi, hp) {
      hp = ""
      for (hi = 1; hi <= KN; hi++) {
        hp = (hp == "") ? KC[hi] : (hp "." KC[hi])
        if (hi < KN && (hp in arr)) hp = hp "." (acnt[hp] - 1)
      }
      return hp
    }
    # Does md, the closing delimiter of a multi-line string, occur in ms? In a basic string a backslash escapes the character after it, so \""" is no end.
    function mlclosed(ms, md,   mi) {
      for (mi = 1; mi <= length(ms); mi++) {
        if (md == DQ DQ DQ && substr(ms, mi, 1) == "\\") { mi++; continue }
        if (substr(ms, mi, 3) == md) return 1
      }
      return 0
    }
    # One scalar from position ri of rs: its value in SV, the position after it in SPOS, or the reason it is refused in SERR.
    function readscalar(rs, ri,   rc, rj, ro, rn, rt) {
      SERR = ""; SV = ""
      rc = substr(rs, ri, 1)
      if (rc == DQ) {
        if (substr(rs, ri, 3) == DQ DQ DQ) { SERR = "multi-line strings are not supported"; if (!mlclosed(substr(rs, ri + 3), DQ DQ DQ)) MLD = DQ DQ DQ; return }
        ro = ""; rj = ri + 1
        while (1) {
          rn = substr(rs, rj, 1)
          if (rn == "") { SERR = "unterminated string"; return }
          if (rn == "\\") {
            rt = substr(rs, rj + 1, 1)
            if (rt != DQ && rt != "\\") { SERR = "the escape \\" rt " is not supported"; return }
            ro = ro rt; rj += 2; continue
          }
          if (rn == DQ) break
          ro = ro rn; rj++
        }
        SV = ro; SPOS = rj + 1
        return
      }
      if (rc == SQ) {
        if (substr(rs, ri, 3) == SQ SQ SQ) { SERR = "multi-line strings are not supported"; if (!mlclosed(substr(rs, ri + 3), SQ SQ SQ)) MLD = SQ SQ SQ; return }
        rj = index(substr(rs, ri + 1), SQ)
        if (rj == 0) { SERR = "unterminated string"; return }
        SV = substr(rs, ri + 1, rj - 1); SPOS = ri + rj + 1
        return
      }
      rj = ri
      while ((rn = substr(rs, rj, 1)) != "" && index(" \t,]}", rn) == 0) rj++
      rt = substr(rs, ri, rj - ri); SPOS = rj
      if (rt == "true" || rt == "false") { SV = rt; return }
      if (rt ~ /^[+-]?(0|[1-9][0-9]*(_[0-9]+)*)$/) { gsub(/_/, "", rt); sub(/^\+/, "", rt); SV = rt; return }
      if (rt ~ /^[+-]?(0|[1-9][0-9]*)\.[0-9]+$/) { sub(/^\+/, "", rt); SV = rt; return }
      SERR = "not a string, a decimal number or a boolean: " rt
    }
    # A multi-line string opened on a line that is refused, or on a line of a skipped table, still has a body, which must not be read as tables and keys: this is the one place that steps over it.
    function swallow(sl,   sr, sp, sv) {
      sr = scankey(sl) ? KR : sl
      sp = index(sr, "=")
      if (sp == 0) return
      sv = trim(substr(sr, sp + 1))
      if (substr(sv, 1, 3) == DQ DQ DQ || substr(sv, 1, 3) == SQ SQ SQ) readscalar(sv, 1)
    }
    # A key is defined once.
    function claim(cp, cn, ck) {
      if (cp in seenk) { warn(cn, "duplicate key " ck); return 0 }
      seenk[cp] = 1
      return 1
    }
    # An array: [ ... ] of scalars, already joined into one line. Nothing of it is printed unless all of it is understood.
    function putarray(pa, va, vn, rk,   ai, an, ac, ao) {
      ai = 2; an = 0; ao = ""
      while (1) {
        ai = skipws(va, ai)
        ac = substr(va, ai, 1)
        if (ac == "") { warn(vn, "unterminated array or inline table"); return }
        if (ac == "]") { ai++; break }
        if (ac == "[" || ac == "{") { warn(vn, "nested arrays and tables inside an array are not supported"); return }
        readscalar(va, ai)
        if (SERR != "") { warn(vn, SERR); return }
        ao = ao pa "." an "\t" SV "\n"; an++
        ai = skipws(va, SPOS)
        ac = substr(va, ai, 1)
        if (ac == ",") { ai++; continue }
        if (ac == "]") { ai++; break }
        warn(vn, ac == "" ? "unterminated array or inline table" : "unexpected text in the array"); return
      }
      if (trim(substr(va, ai)) != "") { warn(vn, "unexpected text after the value"); return }
      if (!claim(pa, vn, rk)) return
      if (an == 0) print pa "\t"; else printf "%s", ao
    }
    # An inline table: { k = v, ... } of scalars, on one line.
    function putinline(pp, vs, vn, rk,   io, n, c, ik) {
      vs = ltrim(substr(vs, 2)); io = ""; n = 0
      if (substr(vs, 1, 1) == "}") {
        vs = substr(vs, 2)
      } else {
        while (1) {
          if (!scankey(vs)) { warn(vn, "not a valid key in the inline table"); return }
          if (substr(KR, 1, 1) != "=") { warn(vn, "not a key = value pair in the inline table"); return }
          ik = keypath(pp)
          vs = ltrim(substr(KR, 2))
          c = substr(vs, 1, 1)
          if (c == "[" || c == "{") { warn(vn, "only plain values are supported inside an inline table"); return }
          readscalar(vs, 1)
          if (SERR != "") { warn(vn, SERR); return }
          io = io ik "\t" SV "\n"; n++
          vs = ltrim(substr(vs, SPOS))
          c = substr(vs, 1, 1)
          if (c == ",") {
            vs = ltrim(substr(vs, 2))
            if (substr(vs, 1, 1) == "}") { warn(vn, "a trailing comma is not allowed in an inline table"); return }
            continue
          }
          if (c == "}") { vs = substr(vs, 2); break }
          warn(vn, c == "" ? "unterminated array or inline table" : "unexpected text in the inline table"); return
        }
      }
      if (trim(vs) != "") { warn(vn, "unexpected text after the value"); return }
      if (!claim(pp, vn, rk)) return
      if (n == 0) print pp "\t"; else printf "%s", io
    }
    function putvalue(pp, vs, vn, rk,   vc) {
      vc = substr(vs, 1, 1)
      if (vc == "") { warn(vn, "no value after ="); return }
      if (vc == "[") { putarray(pp, vs, vn, rk); return }
      if (vc == "{") { putinline(pp, vs, vn, rk); return }
      readscalar(vs, 1)
      if (SERR != "") { warn(vn, SERR); return }
      if (trim(substr(vs, SPOS)) != "") { warn(vn, "unexpected text after the value"); return }
      if (claim(pp, vn, rk)) print pp "\t" SV
    }
    # A table that got neither a key nor a sub-table is a leaf of its own.
    function flushpend(np) {
      if (pend != "" && index(np, pend ".") != 1) print pend "\t"
      pend = ""
    }
    # A header that cannot be read: what is under it is not given to another table.
    function bad() { flushpend(""); skip = 1; tpath = "" }
    BEGIN {
      SQ = sprintf("%c", 39); DQ = sprintf("%c", 34)
      tpath = ""; pend = ""; skip = 0; acc = ""; MLD = ""
    }
    {
      ln = $0
      sub(/\r$/, "", ln)
      # The body of a refused multi-line string is not config: drop it up to its closing delimiter.
      if (MLD != "") { if (mlclosed(ln, MLD)) MLD = ""; next }
      if (acc != "") {
        acc = acc " " trim(stripc(ln))
        if (depth(acc) <= 0) { putvalue(accpath, acc, accln, acckey); acc = "" }
        next
      }
      ln = trim(stripc(ln))
      if (ln == "") next

      if (substr(ln, 1, 1) == "[") {
        isa = (substr(ln, 2, 1) == "[")
        tl = isa ? "]]" : "]"
        if (!scankey(substr(ln, isa ? 3 : 2))) { warn(NR, "not a valid table name"); bad(); next }
        if (substr(KR, 1, length(tl)) != tl) { warn(NR, "the table header is not closed with " tl); bad(); next }
        if (trim(substr(KR, length(tl) + 1)) != "") { warn(NR, "unexpected text after the table header"); bad(); next }
        hp = hdrpath()
        if (isa) {
          acnt[hp]++; arr[hp] = 1
          hp = hp "." (acnt[hp] - 1)
        } else {
          if (hp in thdr) { warn(NR, "table [" hp "] is defined twice"); bad(); next }
          thdr[hp] = 1
        }
        flushpend(hp)
        tpath = hp; pend = hp; skip = 0
        next
      }

      # The lines of a skipped table are not read, but a multi-line string opened in one still swallows its body.
      if (skip) { swallow(ln); next }
      if (!scankey(ln)) { warn(NR, "not a valid key"); swallow(ln); next }
      if (substr(KR, 1, 1) != "=") { warn(NR, "not a key = value line"); swallow(ln); next }
      vs = trim(substr(KR, 2))
      kfull = keypath(tpath); krel = keypath("")
      pend = ""
      if (substr(vs, 1, 1) == "[" && depth(vs) > 0) { acc = vs; accpath = kfull; accln = NR; acckey = krel; next }
      putvalue(kfull, vs, NR, krel)
    }
    END {
      if (acc != "") warn(accln, "unterminated array or inline table")
      flushpend("")
    }'
}

# A file through the reader its extension names: .toml is TOML, anything else is YAML, which is what every file was before there was a TOML reader.
cfg_read() {  # <file> -> the leaves, refusals as !<TAB>file:line: why
  case $1 in
    *.toml) cfg_parse_toml "$1" <"$1" ;;
    *)      cfg_parse "$1" <"$1" ;;
  esac
}

# Parsed once per process, however many lookups follow: every key press runs a fresh copy of this script, so the cost that matters is one awk, not one per cfg_get. A missing file is not an error anywhere but --config.
cfg_load() {
  [ "$CFG_LOADED" = 1 ] && return 0
  CFG_LOADED=1
  # -f as well as -r: a directory is readable, and feeding one to awk gets a raw "i/o error occurred on /dev/stdin" on every single invocation.
  cfg_readable "$CONFIG_FILE" || return 1
  CFG=$(cfg_read "$CONFIG_FILE")
  cfg_sift "$CFG"; CFG=$CFG_SIFTED
  cfg_overlay
  return 0
}

# EVERYTHING THE LOAD AND THE CHECK REMEMBER, PUT BACK TO WHAT A PROCESS STARTS WITH. Each of those memos is written for a process that lives for one run: the load is parsed once, cfg_check guards itself with CFG_CHECKED and adds to CFG_NPROBLEMS and CFG_NOTES rather than setting them, and the parse and overlay notes only ever grow. A refresher lives as long as its list, so when it reads the config again it clears them here first — otherwise the old load's refusals and overlay stay in, a problem count is never worked out again, and the next check adds to the last one's. usage_env's exports go too: it sets them only when there is something to set, so a rule removed from the config would otherwise stay in the environment of every tusage the refresher starts.
cfg_reset() {
  CFG=''; CFG_LOADED=0
  CFG_PARSE_NOTES=''; CFG_OVER_FILE=''; CFG_OVER_TOPS=' '; CFG_OVER_TWIN=''
  # A config.toml written beside the config.yaml that was being read is a different file now, and so is one that was deleted.
  cfg_resolve
  CFG_NOTES=''; CFG_NPROBLEMS=0; CFG_SUMMARY=''; CFG_CHECKED=0
  # resolve_keys is run by cfg_check and remembers its own verdict (keys.sh).
  KEYS_RESOLVED=''
  unset TU_ACCOUNTS TU_ACCOUNT_RULES
}

# THE PARSER'S REFUSALS, TAKEN BACK OUT OF ITS STREAM. Each goes to stderr in the line it has always been — a scripted --config reads it there — and into CFG_PARSE_NOTES for cfg_check, which is how it reaches a dashboard that has no stderr anybody sees. A stream with no refusal in it is handed back untouched: the loop is only paid for by a file with something wrong in it.
cfg_sift() {  # <parsed stream> -> CFG_SIFTED: the leaves alone
  local ln
  CFG_SIFTED=$1
  case "$CFG_NL$1" in *"$CFG_NL!$TAB"*) ;; *) return 0 ;; esac
  CFG_SIFTED=''
  while IFS= read -r ln; do
    case $ln in
      "!$TAB"*)
        ln=${ln#"!$TAB"}
        echo "tagents: config: $ln" >&2
        case $ln in "$HOME"/*) ln="~${ln#$HOME}" ;; esac
        CFG_PARSE_NOTES="$CFG_PARSE_NOTES${CFG_PARSE_NOTES:+$CFG_NL}$ln" ;;
      *) CFG_SIFTED="$CFG_SIFTED${CFG_SIFTED:+$CFG_NL}$ln" ;;
    esac
  done <<EOF
$1
EOF
  return 0
}

# The a.b prefix of a path — the unit the overlay replaces — for the bash
# callers; the merge in cfg_overlay has the same rule in awk, as sub2.
cfg_top_of() {  # <path> -> CFG_TOP
  local rest=${1#*.}
  if [ "$rest" = "$1" ]; then CFG_TOP=$1; else CFG_TOP=${1%%.*}.${rest%%.*}; fi
}

# ONE CONFIG, SEVERAL MACHINES. The file is shared through dotfiles, and the
# one thing in it that cannot be shared is the account table: on one laptop the
# default login is the employer's and ~/.claude-personal is the second one, on
# another the default is the personal account and the second is a client's.
# The same profile name pointing at a directory that does not exist on this
# machine starts a logged-out Claude — silently, from a picker that looked fine.
#
# So config.<hostname>.toml (or .yaml) beside the config is laid over it, per machine and still in the repo, each file read by its own format. Granularity is the `a.b` subtree: every one the overlay mentions (claude.profiles, claude.rules, claude.default, notes.send, …) REPLACES the base subtree wholesale, the rest is inherited. Wholesale, not merged, because profiles and rules are tables: a union would keep the base laptop's ~/.claude-personal row in this machine's picker, which is the exact thing being fixed, and rule indices from two files would collide.
#
# Overlay lines go FIRST: cfg_get takes the first match and cfg_children keeps
# file order, so no lookup needs to know an overlay exists. TA_HOST stands in
# for the hostname so a test can have one. Which names the overlay is looked
# for under is cfg_hosts, below.
# The real hostname, asked of the system once per process: HOST_S is what the
# list's host column and the window-name sweep read too. TA_HOST is not in it.
# HOST_F is the FULL name, which is what tmux puts in a default pane title (see
# host_title): a title equal to either one names nothing. One `hostname` for
# both: the short name is the full one up to its first dot, which is all that
# `hostname -s` does.
host_once() {
  [ -n "${HOST_S+x}" ] && [ -n "${HOST_F+x}" ] && return 0
  HOST_F=$(hostname 2>/dev/null)
  HOST_S=${HOST_F%%.*}
}
# The overlay for one host name: config.<host>.toml, else config.<host>.yaml, beside the config in use. CFG_OVL is the file found, or where the TOML one would go (the refresher watches that path for a file to appear); a config.<host>.yaml hidden by a config.<host>.toml is CFG_OVER_TWIN. Returns 1 when there is none.
cfg_overlay_for() {  # <host> -> CFG_OVL, CFG_OVER_TWIN
  local stem=${CONFIG_FILE%.toml}
  stem=${stem%.yaml}; stem=${stem%.yml}
  CFG_OVL=$stem.$1.toml; CFG_OVER_TWIN=''
  if cfg_readable "$stem.$1.toml"; then
    ! cfg_readable "$stem.$1.yaml" || CFG_OVER_TWIN=$stem.$1.yaml
    return 0
  fi
  if cfg_readable "$stem.$1.yaml"; then CFG_OVL=$stem.$1.yaml; return 0; fi
  return 1
}
cfg_overlay() {
  local host over="" top k v
  host_once
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    cfg_overlay_for "$host" && { over=$CFG_OVL; break; }
  done <<EOF
$(cfg_hosts)
EOF
  [ -n "$over" ] || { CFG_OVER_TWIN=''; return 0; }
  top=$(cfg_read "$over")
  cfg_sift "$top"; top=$CFG_SIFTED
  [ -n "$top" ] || return 0
  # Remembered for cfg_check: a note about a key has to name the file the key
  # is in, and after the merge below nothing else knows which that was.
  CFG_OVER_FILE=$over
  while IFS="$TAB" read -r k v; do
    cfg_top_of "$k"
    case $CFG_OVER_TOPS in *" $CFG_TOP "*) ;; *) CFG_OVER_TOPS="$CFG_OVER_TOPS$CFG_TOP " ;; esac
  done <<EOF
$top
EOF
  CFG=$(printf '%s\n%s\n%s\n' "$top" "$RS" "$CFG" | LC_ALL=C awk -F"$TAB" -v rs="$RS" '
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

# THE MACHINE HAS MORE THAN ONE NAME. `hostname -s` is not an identity on a Mac whose HostName was never set (`scutil --get HostName` says "not set"): it is whatever macOS derived last, and the same laptop answered alex-MBP for weeks and alex-MacBook-Pro after a reboot. The overlay was not found, the base profiles applied without a word, and every chat on the second login was resumed logged out. So the overlay is looked for under each name the machine answers to: the reported one first, so that an overlay found today is the one found tomorrow, then the LocalHostName, which moves only when somebody renames the Mac. scutil is macOS only; elsewhere it is not there and adds nothing. TA_HOST is exactly one name, never a first guess.
cfg_hosts() {
  [ -n "${TA_HOST:-}" ] && { printf '%s\n' "$TA_HOST"; return 0; }
  { printf '%s\n' "$HOST_S"; scutil --get LocalHostName; } 2>/dev/null | LC_ALL=C awk 'NF && !seen[$0]++'
  return 0
}

# Return 1 for "absent", 0 with empty output for "present and empty" — the two
# are different answers, and `config_dir:` written blank must not read as
# ~/.claude-personal having been left out.
#
# A loop over the parsed text in the shell, not an awk over it: callers ask for
# one key after another inside $(…), and a process per lookup is what one status
# bar tick used to pay a dozen times over. The value stops at a tab, as awk's $2
# did, and the first match wins.
cfg_get() {  # <path>
  local k v
  cfg_load
  while IFS="$TAB" read -r k v; do
    [ "$k" = "$1" ] || continue
    printf '%s' "${v%%"$TAB"*}"
    return 0
  done <<EOF
$CFG
EOF
  return 1
}

cfg_children() {  # <path> -> direct child names, file order, no repeats
  cfg_load
  printf '%s\n' "$CFG" | LC_ALL=C awk -F"$TAB" -v k="$1" '
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
#
# Two forms of the one rule: the printing one every caller uses, and the one
# that sets a variable, for a loop that cannot pay a subshell per row.
cfg_expand_dir_v() {  # <value> -> CFG_EXPANDED
  local d=${1:-}
  case $d in
    '~')   d=$HOME ;;
    '~/'*) d=$HOME/${d#'~/'} ;;
  esac
  while [ ${#d} -gt 1 ] && [ "${d%/}" != "$d" ]; do d=${d%/}; done
  CFG_EXPANDED=$d
}
cfg_expand_dir() {  # <value>
  cfg_expand_dir_v "${1:-}"
  printf '%s' "$CFG_EXPANDED"
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

# ---------------------------------------------------------------------------
# what is wrong with the config
#
# A wrong config used to fail in silence. The parser's refusals and "rule 0
# names unknown profile" went to a stderr that nothing under fzf, tmux
# run-shell or the status bar ever shows, and a profile whose config_dir is not
# on this machine was never looked at at all — so the picker looked fine and
# the agent it started was logged out. cfg_check is the one place that looks,
# once per process and kept, the way resolve_keys keeps KEY_NOTES; the header,
# the status bar and --check all read what it found.
#
# Only what cannot be what it claims is a problem. An unknown key is not one:
# the file is shared across machines and versions, and a key this version does
# not read may be another's. Neither is a rule about a directory that is not
# cloned here (see norm_dir), nor a good config, which produces nothing at all.
# ---------------------------------------------------------------------------

# One problem, in the shape every surface shows: the file it is in, the key,
# what is wrong and what to do about it. The file is worked out per key because
# the overlay owns some subtrees and the base the rest, and "config.yaml" for a
# profile that lives in config.mbp.yaml sends the reader to the wrong file. No
# key at all is a line the parser refused, which names its own file and line.
cfg_note() {  # <key, or empty> <what is wrong — and what to do> [<the file it is about, when no key says>]
  local f=${3:-} p=''
  if [ -n "${1:-}" ]; then
    cfg_top_of "$1"
    case $CFG_OVER_TOPS in *" $CFG_TOP "*) f=$CFG_OVER_FILE ;; *) f=$CONFIG_FILE ;; esac
    p="$1: "
  fi
  if [ -n "$f" ]; then
    case $f in "$HOME"/*) f="~${f#$HOME}" ;; esac
    p="$f: $p"
  fi
  CFG_NOTES="$CFG_NOTES${CFG_NOTES:+$CFG_NL}$p$2"
  CFG_NPROBLEMS=$((CFG_NPROBLEMS + 1))
}

# Everything here is one pass over the flattened config in bash alone — no awk,
# no cfg_get, no subshell per row — because --counts runs it on every
# status-bar tick. The profiles and the rules are accounts_check's, which knows
# what a profile is; the file's own values are checked here.
# WHAT THE STATUS BAR PAYS FOR THE CHECK, AND WHY IT DOES NOT PAY IT TWICE.
# cfg_check parses the file and stats every profile directory: measured at ~50 ms on every tick of every attached client, spent almost always to conclude that nothing changed. So the count is remembered against the config's own identity — is any config*.toml or config*.yaml in that directory newer than the stamp — which is a glob and a file test. The config's mtime is the main key: a config you have just fixed clears the marker the next time the bar is recomputed (COUNTS_EVERY seconds at most) rather than when a timer gets round to it. An age ceiling sits behind it because a problem can be fixed WITHOUT touching the config — creating the login directory the profile names is the obvious one — and a marker that outlives its problem is its own lie.
cfg_count_cached() {  # sets CFG_NPROBLEMS, cheaply, for the status bar
  local f n when now path ident stale=0
  # No file at all is no problem, and the stamp of a config that has been
  # deleted would otherwise keep a marker on screen forever.
  if [ ! -e "$CONFIG_FILE" ]; then
    CFG_NPROBLEMS=0
    rm -f "$CFG_STAMP" 2>/dev/null
    return 0
  fi
  # A config.yaml hidden by a config.toml is part of the verdict, and deleting it touches nothing newer than the stamp: it is named in the stamp instead.
  ident=$CONFIG_FILE${CFG_TWIN:+ $CFG_TWIN}
  if [ -r "$CFG_STAMP" ]; then
    for f in "${CONFIG_FILE%/*}"/config*.toml "${CONFIG_FILE%/*}"/config*.yaml; do
      [ -e "$f" ] || continue
      if [ "$f" -nt "$CFG_STAMP" ]; then stale=1; break; fi
    done
    if [ "$stale" = 0 ]; then
      when=''; n=''; path=''
      # The stamp NAMES the config it describes: one state directory serves
      # whatever config a run was pointed at — the suites do exactly that, and
      # so does anyone with TA_CONFIG — and a verdict about one file is not a
      # verdict about another.
      IFS=' ' read -r when n path < "$CFG_STAMP" 2>/dev/null || n=''
      now=$(date +%s)
      case ${when:-x}${n:-x} in
        *[!0-9]*) ;;
        *) if [ "$path" = "$ident" ] &&
             [ "$(( now - when ))" -lt "$CFG_CHECK_EVERY" ]; then
             CFG_NPROBLEMS=$n; return 0
           fi ;;
      esac
    fi
  fi
  cfg_check
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s %s %s\n' "$(date +%s)" "$CFG_NPROBLEMS" "$ident" >"$CFG_STAMP" 2>/dev/null
  return 0
}

# WHICH FORMAT THE FILES ARE IN. A YAML config still works and is read exactly as before; it is one problem per file so that it shows in --check, the header and the status bar until it is converted. A config.toml beside a config.yaml wins outright — the YAML file is not read, so it is not called deprecated, it is called ignored — and the same goes for an overlay pair.
cfg_format_notes() {
  local f=${CONFIG_FILE##*/}
  case $CONFIG_FILE in
    *.toml) [ -z "$CFG_TWIN" ] ||
              cfg_note '' "${CFG_TWIN##*/} is also there — $f is read and ${CFG_TWIN##*/} is ignored; delete ${CFG_TWIN##*/} once $f is right" "$CONFIG_FILE" ;;
    *) cfg_note '' "YAML config is deprecated — run: tagents config convert (it prints the TOML and changes nothing; --write saves it beside this file)" "$CONFIG_FILE" ;;
  esac
  [ -n "$CFG_OVER_FILE" ] || return 0
  f=${CFG_OVER_FILE##*/}
  case $CFG_OVER_FILE in
    *.toml) [ -z "$CFG_OVER_TWIN" ] ||
              cfg_note '' "${CFG_OVER_TWIN##*/} is also there — $f is read and ${CFG_OVER_TWIN##*/} is ignored; delete ${CFG_OVER_TWIN##*/} once $f is right" "$CFG_OVER_FILE" ;;
    *) cfg_note '' "YAML config is deprecated — run: tagents config convert --all (it prints the TOML and changes nothing; --write saves it beside this file)" "$CFG_OVER_FILE" ;;
  esac
}

cfg_check() {
  local k v i n
  [ "$CFG_CHECKED" = 1 ] && return 0
  CFG_CHECKED=1
  cfg_load || return 0
  cfg_format_notes
  if [ -n "$CFG_PARSE_NOTES" ]; then
    while IFS= read -r v; do
      [ -n "$v" ] && cfg_note '' "$v"
    done <<EOF
$CFG_PARSE_NOTES
EOF
  fi
  # The profiles before the values: a login that is not there is the problem
  # worth reading first, and the list is read from the top.
  accounts_check
  while IFS="$TAB" read -r k v; do
    case $k in
      usage.monthly_limit_usd|usage.safety_margin_pct)
        # awk reads "850 dollars" as 850 and "abc" as 0, and the month would be
        # measured against a limit nobody set.
        case $v in
          ''|.|*[!0-9.]*|*.*.*) cfg_note "$k" "\"$v\" is not a number"; continue ;;
        esac
        i=${v%%.*}
        if [ "$k" = usage.safety_margin_pct ] && [ -n "$i" ] && [ "$i" -gt 100 ]; then
          cfg_note "$k" "$v is not a percentage — 0 to 100"
        fi ;;
      usage.workdays|resurrect.auto)
        # Anything but the four words for "off" counts as on: for usage.workdays a False or a typo is a working week nobody asked for, and for resurrect.auto on is the safer misreading (resurrect_auto_on says why).
        case $v in
          true|false|yes|no|on|off|0|1) ;;
          *) cfg_note "$k" "\"$v\" is not true or false — read as true" ;;
        esac ;;
      notes.send)
        case $v in
          reference|paste|submit) ;;
          *) cfg_note "$k" "\"$v\" is not one of reference, paste, submit — tnotes uses reference" ;;
        esac ;;
      resurrect.every)
        # due_every reads anything but a positive number as off, so a "5m"
        # would quietly stop the capture a reboot depends on.
        case $v in ''|*[!0-9]*) cfg_note "$k" "\"$v\" is not a number of seconds" ;; esac ;;
      resurrect.notes)
        case $v in
          reopen|off) ;;
          *) cfg_note "$k" "\"$v\" is not one of reopen, off — read as reopen" ;;
        esac ;;
    esac
  done <<EOF
$CFG
EOF
  # The keys are config too, and theirs were the one kind of note already
  # shown — as a message that fades. Folded in, so the count is the whole truth
  # and --check is the one list.
  resolve_keys
  if [ -n "$KEY_NOTES" ]; then
    while IFS= read -r n; do
      [ -n "$n" ] && cfg_note "${n%%:*}" "${n#*: }"
    done <<EOF
$KEY_NOTES
EOF
  fi
  if [ "$CFG_NPROBLEMS" -eq 1 ]; then CFG_SUMMARY='config: 1 problem (tagents --check)'
  elif [ "$CFG_NPROBLEMS" -gt 1 ]; then CFG_SUMMARY="config: $CFG_NPROBLEMS problems (tagents --check)"
  fi
  return 0
}

# THE ONE PLACE THE PROBLEMS ARE REPORTED — key_warn's shape. With no argument
# it is one tmux display-message at dashboard start, a nudge rather than the
# list: the list is what --check is for, and the header keeps the count on
# screen for as long as the problem lasts, which a message that fades cannot.
cfg_warn() {  # [prefix] — no argument means tmux display-message
  local n pre=${1:-}
  cfg_check
  [ -n "$CFG_NOTES" ] || return 0
  if [ $# -eq 0 ]; then
    notice "tagents: $CFG_SUMMARY" || true
    return 0
  fi
  while IFS= read -r n; do
    [ -n "$n" ] && printf '%s%s\n' "$pre" "$n"
  done <<EOF
$CFG_NOTES
EOF
  return 0
}

# `tagents --check`: the list itself, and an exit code a script can act on.
# --config keeps its contract — the flattened leaves on stdout, exit 0 —
# because tnotes and the tests read it as data, and diagnostics mixed into
# data are a second thing to parse. No file is not a problem: that is the
# config that switches the whole feature off, on purpose.
check_cmd() {
  if ! { [ -f "$CONFIG_FILE" ] && [ -r "$CONFIG_FILE" ]; }; then
    echo "tagents: no config at $CONFIG_FILE — nothing to check" >&2
    return 0
  fi
  cfg_warn ''
  [ "$CFG_NPROBLEMS" -eq 0 ]
}
