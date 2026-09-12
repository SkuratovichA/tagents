# lib/tagents/usage.sh — the monthly limit, on screen
#
# Everything gated by usage.watch: the TU_ACCOUNTS/TU_ACCOUNT_RULES env handed to tusage, the one budget calculation rendered three ways (status segment, fzf footer with sparkline, table summary) so they agree to the cent, the day table, and the $ popup with its less/inline fallback. The section banner at 1038-1059 heads the file.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# ---------------------------------------------------------------------------
# usage: the monthly limit, on screen
#
# THE LIMIT IS NOT IN THE TRANSCRIPTS. Claude prices what it did, but the number
# that decides whether the month ends against a wall — the plan's monthly cap —
# lives in an admin console and nowhere a script can read it. So it is config: a
# constant somebody types once and edits by hand when the plan changes. The
# whole feature is off until `usage.watch` names the profile whose spend to
# track, and with no such key every surface here prints nothing, so a dashboard
# with no usage block is byte-for-byte the one that shipped before it.
#
# The estimate runs a few percent UNDER the bill — transcripts price requests,
# an invoice prices a contract — so the daily allowance is measured against
# limit×(1−margin) rather than against the limit itself. Being told to slow down
# a day early is cheap; finding out a day late is not.
# ---------------------------------------------------------------------------

# What tusage cannot work out for itself: the accounts exist only in tagents'
# config, and which transcript belongs to which of them is a question about
# directories, which is the same question the launch rules already answer. Both
# travel as environment rather than as flags because every call site here is a
# pipeline somebody else wrote — collect(), counts(), the refresher — and an
# extra argument on each of them is an extra place to forget one.
usage_env() {
  local nm dir accts="" rules="" i d p
  cfg_load
  [ -n "$(cfg_children claude.profiles)" ] || return 0
  while IFS="$US" read -r nm dir _; do
    [ -n "$nm" ] || continue
    accts="${accts:+$accts;}$nm=$dir"
  done < <(prof_pairs | tr "$RS" '\n')
  for i in $(cfg_children claude.rules); do
    d=$(cfg_get "claude.rules.$i.dir") || d=""
    p=$(cfg_get "claude.rules.$i.profile") || p=""
    [ -n "$d" ] && [ -n "$p" ] || continue
    rules="${rules:+$rules;}$(cfg_expand_dir "$d")=$p"
  done
  [ -n "$accts" ] && export TU_ACCOUNTS="$accts"
  [ -n "$rules" ] && export TU_ACCOUNT_RULES="$rules"
  return 0
}

usage_watch() {  # the watched profile, or exit 1 — the feature's on/off switch
  local w
  w=$(cfg_get usage.watch) || return 1
  [ -n "$w" ] || return 1
  printf '%s' "$w"
}

usage_days() {  # the month so far for the watched account, one day per line
  usage_watch >/dev/null || return 1
  usage_env
  command -v tusage >/dev/null 2>&1 || return 1
  if [ -n "${1:-}" ]; then
    tusage --no-update --daily --since month --until "$1" 2>/dev/null
  else
    tusage --no-update --daily --since month 2>/dev/null
  fi
}

# THE ESTIMATE IS STEADILY HIGH, AND NOT FOR A REASON IT CAN SEE. With the
# duplicated transcripts gone the month still read $807 against a meter of $733,
# and the day before $758 against $685 — the same ~0.90 both days. None of the
# cache-rate hypotheses reproduce it (the 1h premium off gives $707, every cache
# write at input rate $674), so it is not something the transcripts know. What
# the account does know is its own meter, and a meter reading is one number a
# human can copy out of /usage in five seconds. The ratio between the two at
# that instant is the correction, and it is applied to everything on screen.
#
# It is deliberately narrow: a reading from a month other than this one says
# nothing about this month's ratio, and a factor outside 0.5–1.5 means the
# reading was mistyped or belongs to the other account. Both are ignored out
# loud — a wrong figure worn with a ~ is worse than an uncorrected one.
usage_calibration() {  # -> "<factor><TAB><label><TAB><note>"
  local raw when amt epoch mtd out
  raw=$(cfg_get usage.meter) || raw=""
  [ -n "$raw" ] || { printf '1\t\t'; return 0; }
  case "$raw" in
    *=*) when=${raw%%=*}; amt=${raw##*=} ;;
    *)   printf '1\t\tmeter reading unusable'; return 0 ;;
  esac
  when=$(printf '%s' "$when" | sed 's/^[[:space:]"]*//; s/[[:space:]"]*$//')
  amt=$(printf '%s' "$amt" | tr -d ' "$,')
  case "$when" in "$(date +%Y-%m)"-*) ;; *) printf '1\t\tmeter reading unusable'; return 0 ;; esac
  case "$amt" in ''|*[!0-9.]*) printf '1\t\tmeter reading unusable'; return 0 ;; esac
  # BSD date wants the format spelt out; GNU date parses it as written.
  epoch=$(date -j -f '%Y-%m-%d %H:%M' "$when" +%s 2>/dev/null) ||
    epoch=$(date -d "$when" +%s 2>/dev/null) || epoch=""
  case "$epoch" in ''|*[!0-9]*) printf '1\t\tmeter reading unusable'; return 0 ;; esac
  mtd=$(usage_days "$epoch" | awk -F"$TAB" -v w="$(usage_watch)" '$2 == w { s += $3 } END { printf "%.6f", s + 0 }')
  out=$(awk -v a="$amt" -v m="$mtd" -v lbl="${when#*-}" '
    BEGIN {
      if (m + 0 <= 0) { printf "1\t\tmeter reading unusable"; exit }
      f = a / m
      if (f < 0.5 || f > 1.5) { printf "1\t\tmeter reading unusable"; exit }
      printf "%.6f\t%s\t", f, lbl
    }')
  printf '%s' "$out"
}

# THREE RENDERINGS OF ONE ARITHMETIC, which is why they are one function: the
# status bar, the fzf footer and the last line of the $ table have to agree to
# the cent, and two of them are read side by side. `summary` is `footer` without
# the sparkline — the table draws the days itself, right above it.
usage_line() {  # <status|footer|summary>
  local mode=${1:-status} watch limit margin badge
  watch=$(usage_watch) || return 0
  limit=$(cfg_get usage.monthly_limit_usd) || limit=""
  margin=$(cfg_get usage.safety_margin_pct) || margin=""
  badge=$(cfg_get "claude.profiles.$watch.badge") || badge=""
  [ -n "$badge" ] || badge=${watch%"${watch#?}"}
  # THE MONTH HAS FIVE WORKING DAYS A WEEK, NOT SEVEN. An allowance spread over
  # every calendar day is money a Saturday will never spend, handed to no one:
  # on the working days that actually cost, the figure reads a third too low,
  # and the pace it is compared with reads a third too high. Unless
  # usage.workdays says otherwise, both are counted over Monday to Friday.
  workdays=$(cfg_get usage.workdays) || workdays=""
  case "$workdays" in false|no|0|off) workdays=0 ;; *) workdays=1 ;; esac
  # Split by hand: tab is IFS whitespace, so `read` would fold the empty middle
  # field of "1<TAB><TAB>note" away and hand the note to the label.
  local cal rest factor label note
  cal=$(usage_calibration); rest=${cal#*$TAB}
  factor=${cal%%$TAB*}; label=${rest%%$TAB*}; note=${rest#*$TAB}
  usage_days | awk -F"$TAB" \
    -v mode="$mode" -v watch="$watch" -v badge="$badge" \
    -v factor="${factor:-1}" -v meter="${label:-}" -v mnote="${note:-}" \
    -v limit="${limit:-0}" -v margin="${margin:-0}" -v workdays="$workdays" \
    -v y="$(date +%Y)" -v mo="$(date +%m)" -v dy="$(date +%d)" -v mon="$(date +%b)" \
    -v wd="$(date +%u)" \
    -v esc="$(printf '\033')" -v bars='▁ ▂ ▃ ▄ ▅ ▆ ▇ █' '
    # $459, not $458.7392: this is a number read out of the corner of an eye.
    # Under ten dollars the cents are the whole of the information, so they stay.
    function m(x) { return (x >= 10 ? sprintf("%d", x + 0.5) : sprintf("%.2f", x)) }
    function mdays(yy, mm) {
      if (mm == 4 || mm == 6 || mm == 9 || mm == 11) return 30
      if (mm != 2) return 31
      return (((yy % 4 == 0 && yy % 100 != 0) || yy % 400 == 0) ? 29 : 28)
    }
    BEGIN { split(bars, bar, " "); y += 0; mo += 0; dy += 0 }
    $1 != "" && NF >= 3 {
      seen = 1
      if ($2 != watch) next
      # CALIBRATED ONCE, AT THE DOOR. Every figure below — the month, today, the
      # sparkline scale, the allowance left in limit−mtd — is a sum of these
      # rows, so scaling the rows is the only place the factor has to appear.
      per[int(substr($1, 9, 2))] += $3 * factor
      mtd += $3 * factor
    }
    END {
      # No index, no tusage, or a month with nothing in it yet. The status bar
      # says nothing at all rather than showing a zero somebody has to interpret;
      # the footer is a line that exists either way, so it says why it is empty.
      if (!seen) {
        if (mode != "status") printf "%s%s · no usage data%s\n", esc "[90m", watch, esc "[0m"
        exit 0
      }
      dim = mdays(y, mo)
      left = dim - dy + 1
      done = dy
      unit = "d"
      if (workdays) {
        # Weekday of day i, from the weekday of today (1 = Monday), counted in both
        # directions; a weekend today has no working day of its own to spend on.
        wleft = 0; wdone = 0
        for (i = 1; i <= dim; i++) {
          k = ((wd - 1 + (i - dy)) % 7 + 7) % 7 + 1
          if (k > 5) continue
          if (i >= dy) wleft++
          if (i <= dy) wdone++
        }
        # A month whose last days are a weekend: nothing left to budget over,
        # so fall back to the calendar rather than divide by nothing.
        if (wleft > 0) { left = wleft; unit = "wd" }
        if (wdone > 0) done = wdone
      }
      budget = limit * (1 - margin / 100)
      rem = budget - mtd
      if (rem < 0) rem = 0
      allowed = (left > 0 ? rem / left : 0)
      pace = (done > 0 ? mtd / done : 0)
      frac = (limit > 0 ? mtd / limit : 0)
      # Yellow is "the month ends over budget at this rate", which is a warning
      # long before the total itself looks alarming — that is the whole point of
      # a pace: 70% spent on the 20th is fine, 70% spent on the 8th is not.
      if (frac >= 0.9)                    { tc = "red";       ac = "[31m" }
      else if (frac >= 0.7 || pace > allowed) { tc = "yellow"; ac = "[33m" }
      else                                { tc = "colour244"; ac = "[90m" }

      if (mode == "status") {
        printf "#[fg=%s]%s %s$%s/%s ·$%s/d #[default]", tc, badge,
               (meter != "" ? "~" : ""), m(mtd), m(limit), m(allowed)
        exit 0
      }
      spark = ""
      if (mode == "footer") {
        # The last seven days of THIS month: no date arithmetic, because the
        # data is month-to-date anyway and a cell for the 29th of last month
        # would be a cell that can never be filled.
        start = dy - 6
        if (start < 1) start = 1
        for (i = start; i <= dy; i++) if (per[i] + 0 > mx) mx = per[i] + 0
        for (i = start; i <= dy; i++) {
          v = per[i] + 0
          spark = spark bar[(mx > 0 ? int(v / mx * 7 + 0.5) + 1 : 1)]
        }
        spark = " · " spark
      }
      cal = (meter != "" ? " · ~meter " meter : (mnote != "" ? " · " mnote : ""))
      printf "%s%s · %s $%s of $%s · today $%s · $%s/day left (%d%s)%s%s%s\n",
             esc ac, watch, mon, m(mtd), m(limit), m(per[dy] + 0), m(allowed), left, unit,
             cal, spark, esc "[0m"
    }'
}

# $ — THE MONTH, A DAY PER ROW. Only the watched account: with `watch: work` the
# personal login's spend is somebody else's business and putting it here would
# invite adding the two totals together, which is exactly the sum the monthly
# limit is not about.
usage_rows() {
  local watch
  watch=$(usage_watch) || return 0
  usage_days | awk -F"$TAB" -v w="$watch" '
    $1 != "" && $2 == w {
      if (!($1 in u)) o[++k] = $1
      u[$1] += $3; r[$1] += $4; n[$1] += $5
    }
    # Newest first: today is the row being looked for, and it is the one that
    # would otherwise be at the bottom of a scrolled page.
    END { for (i = k; i >= 1; i--) printf "  %s   $%8.2f   %5d%s\n", o[i], u[o[i]], r[o[i]], (n[o[i]] > 0 ? "  ~" : "") }'
}

ask_usage() {  # the body of the $ popup
  local watch mon ans
  watch=$(usage_watch) || return 0
  mon=$(date +%b)
  if command -v less >/dev/null 2>&1; then
    { usage_head "$watch" "$mon" "q closes"; usage_body; } | less -R
    return 0
  fi
  usage_head "$watch" "$mon" "any key closes"
  usage_body
  IFS= read -r -t 300 -n 1 ans 2>/dev/null
  return 0
}

usage_head() {  # <watch> <month> <how it closes>
  printf '\033[1musage · %s · %s\033[0m  \033[90m%s\033[0m\n' "$2" "$1" "$3"
}

usage_body() {
  printf '\033[90m  %-10s %10s %7s\033[0m\n' day usd reqs
  usage_rows
  printf '\n'
  usage_line summary
  # ~ is the estimate's own disclaimer, carried through from tusage rather than
  # explained twice: a day with unpriced requests in it is a day the total is
  # low by an unknown amount, and hiding that would make the table look surer
  # than the number under it is.
  printf '\033[90m  ~ that day has requests nothing could be priced from\033[0m\n'
}

usage_window() {  # $ — the modal, or the same body inline where a popup cannot open
  usage_watch >/dev/null || return 0
  prompt_at 80% 85% --ask-usage && return 0
  ask_usage
  return 0
}
