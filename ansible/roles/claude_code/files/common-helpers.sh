# Sourced (never executed) by hooks/high-watermark-auto-pause.sh, the other
# checkpoint-compact hooks and statusline.sh, all of which look for it in
# ~/.claude/. No top-level set/trap/exit/stdin read: statusline.sh sources it
# under `set -u`. Everything here is a constant or a function definition.

# ---- constants (the only copy; nothing else defines these) ----
IDEAL_COMPACT_WARN_TASKS=6
IDEAL_COMPACT_ARM_TASKS=3
IDEAL_COMPACT_MARKER='[[STOP_FOR_COMPACT]]'
IDEAL_COMPACT_RATE_SAMPLES=5
IDEAL_COMPACT_HISTORY_PER_ACCOUNT=20
IDEAL_COMPACT_SENT_TTL_SEC=120
IDEAL_COMPACT_COMPACT_TTL_SEC=900
IDEAL_COMPACT_STOPPED_TTL_SEC=900

# ---- copy texts (single-quoted: they contain backticks and CJK) ----
IDEAL_COMPACT_PAUSE_TEXT='目前用量接近上限，系統會在這個 task 結束後壓縮對話並切換帳號。請把當前 task 做完，不要開始下一個 task，如果當前 task 已經完成，就直接停下。如果有需要使用者決定或確認的事項，請先記著並等使用者詢問時提問，不要等待回答。完成後，在最後一則訊息的最後一行單獨寫上 `[[STOP_FOR_COMPACT]]`，然後停止，不要再呼叫工具。系統預期停止時沒有任何的 subagent、shell、timer、monitor、`/loop`執行中，因此如果有需要在 compact 後使用的請先讓他跑完，或是先讓系統 compact 後再重新執行。'
IDEAL_COMPACT_COMPACT_TEXT='使用者目前不在場，不知道上次查看之後發生了什麼事。摘要請保留這幾個 task 過程中發現的事、完成了什麼與結果如何，以及每一個還在等使用者回答的問題，讓使用者回來問的時候答得出來。compact 之後不用先回報，依摘要接著做下一個 task。'
IDEAL_COMPACT_CANCEL_TEXT='用量已經恢復，不需要停下了。請忽略先前的暫停要求，繼續正常工作，不用寫 [[STOP_FOR_COMPACT]]。'
IDEAL_COMPACT_CONTINUE_TEXT='繼續'

# Next to this file (~/.claude/), so a moved ~/.claude keeps working. Callers
# and tests may override it after sourcing.
__IC_HELPER="$(dirname "${BASH_SOURCE[0]}")/hwap-helper.sh"

__cswap_bin() {
  if command -v cswap >/dev/null 2>&1; then printf 'cswap'; return 0; fi
  if [ -x "$HOME/.local/bin/cswap" ]; then printf '%s' "$HOME/.local/bin/cswap"; return 0; fi
  return 1
}

__publish_hold_until() {
  # Display only: tells statusline.sh how long this gate will still wait,
  # which matters in the buffer after a reset, when cswap already reports the
  # account as usable. Always overwritten with the gate's latest estimate (the
  # gate never reads it back), and only written while actually waiting.
  local new="$1" dir file tmp
  dir="${IC_TMP_BASE:-/tmp/claude-$(id -u)}"
  file="$dir/hwap-hold-until"
  mkdir -p "$dir" 2>/dev/null || return 0
  tmp="$(mktemp "$file.XXXXXX" 2>/dev/null)" || return 0
  if printf '%s\n' "$new" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
}

__clear_hold_until() {
  # Called whenever a gate starts or finishes, so a file left behind by an
  # interrupted gate (nothing runs on SIGTERM) disappears the next time any
  # gate runs. Stop never gates and so never calls this.
  rm -f "${IC_TMP_BASE:-/tmp/claude-$(id -u)}/hwap-hold-until" 2>/dev/null
}

__gate() {
  # Usage: __gate [abort_fn]. Returns 0 when the active account is usable, 3
  # when the helper failed (the caller decides what that means; the message is
  # already printed), 4 when abort_fn returned non-zero (it is called once per
  # loop iteration, right before sleeping).
  # Blocks (never denies) until the active account is usable. Re-asks the
  # helper fresh every iteration (capped at 2 minutes between checks) rather
  # than trusting one static estimate, so a disabled/enabled account, a newly
  # added one or an out-of-band reset is noticed promptly.
  # The helper reports "wait <resume> <reset>" while nothing is usable. Both
  # are remembered, overwritten each time (never only moved forward, so the
  # estimate can shrink again): <resume> is reset plus the buffer. Once
  # resetsAt passes the helper may already say "ok" (fresh data, low pct) and
  # the original numbers are gone, so remembering them is what keeps the
  # buffer in effect. "ok" while the clock is still before <reset> means a
  # *different* account cleared (e.g. one enabled or added mid-pause), not
  # that the awaited one reset, so the buffer, which only exists to wait out a
  # reset that already landed, must not apply.
  # Every sleep runs in the background and is waited for, so a SIGTERM trap in
  # the caller fires at once instead of after the sleep finishes.
  local abort_fn="${1:-}" hold_until=0 reset_at=0 switch_tried=0
  __clear_hold_until
  while :; do
    local result now wait_s cswap target
    if [ -x "$__IC_HELPER" ]; then
      result="$("$__IC_HELPER")"
    else
      result="error:hwap_helper_not_found ($__IC_HELPER)"
    fi
    case "$result" in
      error:*)
        echo "high-watermark-auto-pause: cswap check failed (${result#error:}); skipping rate-limit gate for this turn" >&2
        return 3  # The gate hook maps this to exit 1, not 2: Claude Code treats exit 2 as a "deny" and aborts the turn; we want to continue instead.
        ;;
      wait\ *)
        read -r _ hold_until reset_at <<< "$result"
        __publish_hold_until "$hold_until"
        switch_tried=0
        ;;
      switch\ *)
        # The active account is exhausted but an enabled one is usable. The
        # helper only names it, so the switch happens here. The next
        # iteration confirms it took effect (it then reports "ok").
        target="${result#switch }"
        if [ "$switch_tried" -eq 1 ]; then
          echo "high-watermark-auto-pause: switching to account $target did not take effect; retrying in 30s" >&2
          if [ -n "$abort_fn" ] && ! "$abort_fn"; then __clear_hold_until; return 4; fi
          sleep 30 >/dev/null 2>&1 & __IC_SLEEP_PID=$!
          wait "$__IC_SLEEP_PID"
        fi
        if cswap="$(__cswap_bin)"; then
          "$cswap" switch "$target" >/dev/null 2>&1
        fi
        switch_tried=1
        continue
        ;;
      *)
        switch_tried=0
        ;;
    esac
    now=$(date +%s)
    if [ "$result" = "ok" ] && [ "$now" -lt "$reset_at" ]; then
      __clear_hold_until
      return 0
    fi
    wait_s=$(( hold_until - now ))
    if [ "$wait_s" -le 0 ]; then
      __clear_hold_until
      return 0
    fi
    if [ "$wait_s" -gt 120 ]; then wait_s=120; fi
    if [ -n "$abort_fn" ] && ! "$abort_fn"; then __clear_hold_until; return 4; fi
    sleep "$wait_s" >/dev/null 2>&1 & __IC_SLEEP_PID=$!
    wait "$__IC_SLEEP_PID"
  done
}

# ---- paths ----
# Everything the checkpoint-compact flow keeps in /tmp lives under
# ${IC_TMP_BASE:-/tmp/claude-<uid>}, grouped by project: the session
# directory (per-session state) is <base>/<translated path>/<sid>, the
# project directory (state shared by all sessions of a repo) is
# <base>/<repo key>. These functions only print; callers mkdir.

# basename(dirname(transcript_path)): Claude Code's own name for the project
# directory under ~/.claude/projects/. Empty when the input is empty.
__ic_translated_path() {
  local d
  [ -n "${1:-}" ] || return 0
  d="$(basename "$(dirname "$1")")"
  case "$d" in .|/) return 0 ;; esac
  printf '%s' "$d"
}

# <base>/<translated>/<sid>; empty when either part is empty.
__ic_session_dir() {
  local tp
  tp="$(__ic_translated_path "${1:-}")"
  [ -n "$tp" ] && [ -n "${2:-}" ] || return 0
  printf '%s' "${IC_TMP_BASE:-/tmp/claude-$(id -u)}/$tp/$2"
}

# A repo's identity regardless of worktree: the path of the shared git dir
# (main repo's .git, also from a linked worktree) with a trailing /.git cut
# off and every non-alphanumeric character turned into "-". Empty outside git.
__ic_repo_key() {
  local common
  [ -n "${1:-}" ] || return 0
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  [ -n "$common" ] || return 0
  common="${common%/.git}"
  printf '%s' "$common" | sed 's/[^A-Za-z0-9]/-/g'
}

# __ic_project_dir <ledger_dir> <transcript_path>: <base>/<repo key of the
# ledger's directory>, or <base>/<translated path> when that is not in a git
# repo. Empty when neither is known.
__ic_project_dir() {
  local key
  key="$(__ic_repo_key "${1:-}")"
  [ -n "$key" ] || key="$(__ic_translated_path "${2:-}")"
  [ -n "$key" ] || return 0
  printf '%s' "${IC_TMP_BASE:-/tmp/claude-$(id -u)}/$key"
}

# ---- state file, locks and phase timeouts ----
# <session dir>/ideal-compact-state holds key=value lines, read into IC_<key>.
# Writers hold __ic_lock around read -> change -> write; readers (the
# statusline) take no lock because every write is a temp file plus mv.

__IC_STATE_KEYS="phase phase_at skip suppress suppress_key suppress_win suppress_resets dirty ledger armed_key armed_win armed_resets cheap_obs inputbox_fail pending_inject"
__IC_STATE_NUMERIC=" phase_at skip suppress suppress_resets dirty armed_resets inputbox_fail "

# Sets every IC_<key> (defaults for anything missing or malformed). Parsed
# line by line, never sourced: values may hold spaces and are not trusted.
__ic_state_read() {
  local __k __line __v
  IC_phase=standby IC_phase_at=0 IC_skip=0 IC_suppress=0 IC_suppress_key='' IC_suppress_win=''
  IC_suppress_resets=0 IC_dirty=0 IC_ledger='' IC_armed_key='' IC_armed_win='' IC_armed_resets=0
  IC_cheap_obs='' IC_inputbox_fail=0 IC_pending_inject=''
  [ -n "${1:-}" ] && [ -r "$1/ideal-compact-state" ] || return 0
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in *=*) ;; *) continue ;; esac
    __k="${__line%%=*}"
    __v="${__line#*=}"
    case " $__IC_STATE_KEYS " in *" $__k "*) ;; *) continue ;; esac
    case "$__IC_STATE_NUMERIC" in
      *" $__k "*)
        case "$__v" in ''|*[!0-9]*) continue ;; esac
        [ "${#__v}" -le 15 ] || continue
        __v=$((10#$__v)) ;;
    esac
    if [ "$__k" = phase ]; then
      case "$__v" in standby|armed|waiting|to-compact|compacting|continuing|stopped) ;; *) continue ;; esac
    fi
    printf -v "IC_$__k" '%s' "$__v"
  done < "$1/ideal-compact-state" 2>/dev/null
  return 0
}

# Writes every IC_<key> atomically (temp file in the same directory, then mv).
__ic_state_write() {
  local __k __n __v __tmp
  [ -n "${1:-}" ] || return 1
  mkdir -p "$1" 2>/dev/null || return 1
  __tmp="$(mktemp "$1/ideal-compact-state.XXXXXX" 2>/dev/null)" || return 1
  for __k in $__IC_STATE_KEYS; do
    __n="IC_$__k"
    __v="${!__n:-}"
    printf '%s=%s\n' "$__k" "${__v//$'\n'/ }"
  done > "$__tmp" 2>/dev/null && mv -f "$__tmp" "$1/ideal-compact-state" 2>/dev/null || { rm -f "$__tmp" 2>/dev/null; return 1; }
}

# __ic_set_phase <new>: only changes the IC_* variables; the caller writes.
# A caller that queues an injection sets IC_pending_inject after this call.
__ic_set_phase() {
  IC_phase="$1"
  IC_phase_at="$(date +%s)"
  IC_pending_inject=''
  [ "$1" = standby ] && IC_skip=0
  return 0
}

# __ic_lock <file>: a fresh fd per call (bash picks one >= 10), kept in
# __IC_LOCK_FD for __ic_unlock. The lock directory is created when missing.
__IC_LOCK_FD=''
__ic_lock() {
  local __fd
  mkdir -p "$(dirname "$1")" 2>/dev/null || return 1
  { exec {__fd}>>"$1"; } 2>/dev/null || return 1
  if ! flock "$__fd"; then exec {__fd}>&-; return 1; fi
  __IC_LOCK_FD="$__fd"
}

__ic_unlock() {
  local __fd="${__IC_LOCK_FD:-}"
  [ -n "$__fd" ] || return 0
  flock -u "$__fd" 2>/dev/null
  exec {__fd}>&-
  __IC_LOCK_FD=''
  return 0
}

# __ic_ttl_check <now>: works on the IC_* variables the caller just read
# (the caller holds the lock and writes afterwards). A phase that outlived
# its timeout goes back to standby with suppress=1 for the window it was
# armed on; armed_* is copied rather than asking the helper because the
# helper must not run under the lock. Returns 0 when it expired one.
__ic_ttl_check() {
  local ttl
  case "$IC_phase" in
    to-compact|continuing) ttl="$IDEAL_COMPACT_SENT_TTL_SEC" ;;
    compacting) ttl="$IDEAL_COMPACT_COMPACT_TTL_SEC" ;;
    stopped) ttl="$IDEAL_COMPACT_STOPPED_TTL_SEC" ;;
    *) return 1 ;;
  esac
  [ $(( $1 - IC_phase_at )) -gt "$ttl" ] || return 1
  IC_suppress=1
  IC_suppress_key="$IC_armed_key" IC_suppress_win="$IC_armed_win" IC_suppress_resets="$IC_armed_resets"
  __ic_set_phase standby
  return 0
}

# __ic_phase_display <session_dir> <now>: the phase the statusline shows
# (an expired one reads as standby). Reads only, in a subshell so the
# caller's IC_* variables stay untouched.
__ic_phase_display() {
  (
    __ic_state_read "$1"
    __ic_ttl_check "$2" >/dev/null
    printf '%s' "$IC_phase"
  )
}

# ---- ledger counting, history and per-task consumption ----
# A task is complete when "Task N: complete" is a line of the plan's ledger
# (superpowers' progress.md). Every completion appends one line to the
# project's history; see the design's section 4 for the consumption rules.

# __ic_ledger_done <ledger>: the number of distinct N in "Task N: complete"
# lines (task-done does not deduplicate, a rerun adds a line). 0 when the
# ledger is unreadable.
__ic_ledger_done() {
  [ -r "${1:-}" ] || { printf 0; return 0; }
  awk '/^Task [0-9]+: complete/ { split($0, a, /[: ]+/); seen[a[2] + 0] = 1 }
       END { n = 0; for (k in seen) n++; printf "%d", n }' "$1"
}

# __ic_plan_total <plan>: the number of "### Task N:" headings; 0 when the
# plan is unreadable.
__ic_plan_total() {
  [ -r "${1:-}" ] || { printf 0; return 0; }
  awk '/^### Task [0-9]+:/ { n++ } END { printf "%d", n }' "$1"
}

# __ic_ledger_plan <ledger>: the plan's physical absolute path, or empty.
# Candidates come from the plan-path file next to the ledger (written by
# superpowers' sdd-workspace), then from the ledger's first line
# "# SDD ledger — plan: <path>". An absolute path is used as is; a relative
# one is tried against the repo root of the ledger's directory and then
# against the ledger's directory, and the first that exists wins.
__ic_ledger_plan() {
  local __dir __root __cand __rel __base
  [ -n "${1:-}" ] || return 0
  __dir="$(dirname "$1")"
  __root="$(git -C "$__dir" rev-parse --show-toplevel 2>/dev/null)" || __root=''
  for __rel in \
    "$( [ -r "$__dir/plan-path" ] && head -n 1 "$__dir/plan-path" | tr -d '\r' )" \
    "$( [ -r "$1" ] && head -n 1 "$1" | tr -d '\r' | sed -n 's/^# SDD ledger — plan: //p' )"
  do
    [ -n "$__rel" ] || continue
    case "$__rel" in
      /*) __cand="$__rel"; [ -f "$__cand" ] || continue ;;
      *)
        if [ -n "$__root" ] && [ -f "$__root/$__rel" ]; then __cand="$__root/$__rel"
        elif [ -f "$__dir/$__rel" ]; then __cand="$__dir/$__rel"
        else continue
        fi ;;
    esac
    __base="$(basename "$__cand")"
    __dir="$(cd "$(dirname "$__cand")" 2>/dev/null && pwd -P)" || continue
    printf '%s/%s' "$__dir" "$__base"
    return 0
  done
  return 0
}

# __ic_history_latest <hist> <ledger>: the newest history line for that
# ledger (field 2), or empty.
__ic_history_latest() {
  [ -r "${1:-}" ] || return 0
  IC_LEDGER="${2:-}" awk -F'\t' '$2 == ENVIRON["IC_LEDGER"] { l = $0 } END { if (l != "") print l }' "$1"
}

# __ic_history_record <hist> <ledger> <done> <current_line> <dirty>: appends
# one line
#   ts ledger done key p5 r5 p7 r7 dirty c5 c7 b5done b5pct b5r b7done b7pct b7r
# and keeps only the newest IDEAL_COMPACT_HISTORY_PER_ACCOUNT lines of that
# key. <current_line> is the helper's `current` line. Prints `skipped`
# (nothing written) when it is not a usage reading with a known key, else
# `counted` when a window got a per-task consumption, else `baseline`.
# c5/c7 are '-' when the entry yields no number. b* is the window's baseline
# snapshot this entry carries: the entry itself after a rebase, the previous
# entry's snapshot when the delta is 0.
__ic_history_record() {
  local __hist="$1" __ledger="$2" __done="$3" __cur="$4" __dirty="${5:-0}"
  local __tag __key __p5 __r5 __p7 __r7 __thr5 __thr7 __buf __tol __rest
  local __prev __out __status __line __tmp='' __tmp2=''
  read -r __tag __key __p5 __r5 __p7 __r7 __thr5 __thr7 __buf __tol __rest <<< "$__cur"
  if [ "$__tag" != usage ] || [ -z "$__key" ] || [ "$__key" = - ] || [ -z "$__tol" ]; then
    printf skipped
    return 0
  fi
  __ic_lock "$(dirname "$__hist")/ideal-compact-history.lock" || return 1
  __prev="$(__ic_history_latest "$__hist" "$__ledger")"
  __out="$(IC_PREV="$__prev" IC_LEDGER="$__ledger" awk -v ts="$(date +%s)" -v done="$__done" -v key="$__key" \
    -v p5="$__p5" -v r5="$__r5" -v p7="$__p7" -v r7="$__r7" -v dirty="$__dirty" -v tol="$__tol" '
    # Sets OC (consumption or "-") and returns 1 when the window is rebased
    # onto this entry, 0 when the previous baseline is carried.
    function calc(pct, r, bd, bp, br,    d) {
      OC = "-"
      if (all || r - br > tol || br - r > tol) return 1
      d = pct - bp
      if (d < -1e-9 || done - bd <= 0) return 1
      if (d <= 1e-9) return 0
      OC = sprintf("%.4f", d / (done - bd))
      sub(/0+$/, "", OC); sub(/\.$/, "", OC)
      return 1
    }
    BEGIN {
      OFS = "\t"
      n = split(ENVIRON["IC_PREV"], P, "\t")
      all = (n == 0 || done <= P[3] + 0 || key != P[4] || dirty + 0 > 0)
      rb5 = calc(p5, r5, P[12] + 0, P[13] + 0, P[14] + 0); c5 = OC
      rb7 = calc(p7, r7, P[15] + 0, P[16] + 0, P[17] + 0); c7 = OC
      print ((c5 != "-" || c7 != "-") ? "counted" : "baseline")
      print ts, ENVIRON["IC_LEDGER"], done, key, p5, r5, p7, r7, dirty + 0, c5, c7, \
        rb5 ? done : P[12], rb5 ? p5 : P[13], rb5 ? r5 : P[14], \
        rb7 ? done : P[15], rb7 ? p7 : P[16], rb7 ? r7 : P[17]
    }')"
  __status="${__out%%$'\n'*}"
  __line="${__out#*$'\n'}"
  __tmp="$(mktemp "$__hist.XXXXXX" 2>/dev/null)" && __tmp2="$(mktemp "$__hist.XXXXXX" 2>/dev/null)" || {
    rm -f "$__tmp" 2>/dev/null; __ic_unlock; return 1
  }
  { [ -r "$__hist" ] && cat "$__hist"; printf '%s\n' "$__line"; } > "$__tmp" 2>/dev/null
  # Drop this key's lines beyond the newest <keep> (the file is in append order).
  if awk -F'\t' -v k="$__key" -v keep="$IDEAL_COMPACT_HISTORY_PER_ACCOUNT" \
       'NR == FNR { if ($4 == k) total++; next } $4 == k && ++seen <= total - keep { next } { print }' \
       "$__tmp" "$__tmp" > "$__tmp2" 2>/dev/null && mv -f "$__tmp2" "$__hist" 2>/dev/null; then
    rm -f "$__tmp"
  else
    rm -f "$__tmp" "$__tmp2" 2>/dev/null
    __ic_unlock
    return 1
  fi
  __ic_unlock
  printf '%s' "$__status"
}

# __ic_budget <hist> <current_line> <accounts_text>: how many more tasks fit
# before the lower threshold is hit, as "<n> <win>" (win 5h or 7d, the
# smaller window; 5h on a tie) or "unknown -". No trailing newline.
# Read-only: no lock, no write. <current_line> is the helper's `current`
# line (tag key p5 r5 p7 r7 thr5 thr7 buf tol), <accounts_text> its
# `accounts` output (empty or an error: line = no accounts).
# Per window, avg is the mean of the newest IDEAL_COMPACT_RATE_SAMPLES
# positive c of this key. Only when the key has none, positive c of other
# keys count, each c * source multiplier / current multiplier, both taken
# from <accounts_text> (`-`/missing = unknown = skipped), newest N across
# keys. A window without an avg is left out.
__ic_budget() {
  local __hist="$1" __cur="${2:-}" __acc="${3:-}"
  local __tag __key __p5 __r5 __p7 __r7 __thr5 __thr7 __rest
  read -r __tag __key __p5 __r5 __p7 __r7 __thr5 __thr7 __rest <<< "$__cur"
  if [ "$__tag" != usage ] || [ -z "$__key" ] || [ "$__key" = - ]; then
    printf 'unknown -'
    return 0
  fi
  [ -r "$__hist" ] || __hist=/dev/null
  IC_ACC="$__acc" awk -F'\t' -v key="$__key" -v p5="$__p5" -v p7="$__p7" -v t5="$__thr5" -v t7="$__thr7" \
    -v nmax="${IDEAL_COMPACT_RATE_SAMPLES:-5}" '
    function isnum(x) { return x ~ /^[0-9]+([.][0-9]+)?$/ }
    function mean(arr, cnt,    i, from, sum, n) {
      from = cnt - nmax + 1; if (from < 1) from = 1
      for (i = from; i <= cnt; i++) { sum += arr[i]; n++ }
      return sum / n
    }
    function budget(pct, thr, avg,    b) {
      if (!isnum(pct) || !isnum(thr)) return -1
      b = int((thr - pct) / avg + 1e-9)
      return (thr - pct) / avg < 0 ? 0 : b
    }
    BEGIN {
      n = split(ENVIRON["IC_ACC"], L, "\n")
      for (i = 1; i <= n; i++) {
        m = split(L[i], A, /[ \t]+/)
        if (m < 10) continue
        M5[A[2]] = isnum(A[9]) && A[9] + 0 > 0 ? A[9] + 0 : 0
        M7[A[2]] = isnum(A[10]) && A[10] + 0 > 0 ? A[10] + 0 : 0
      }
    }
    NF >= 11 {
      for (w = 5; w <= 7; w += 2) {
        c = $(w == 5 ? 10 : 11)
        if (!isnum(c) || c + 0 <= 0) continue
        if ($4 == key) { o[w, ++on[w]] = c + 0; continue }
        src = (w == 5 ? M5[$4] : M7[$4]); cm = (w == 5 ? M5[key] : M7[key])
        if (src > 0 && cm > 0) { x[w, ++xn[w]] = c * src / cm }
      }
    }
    END {
      for (w = 5; w <= 7; w += 2) {
        cnt = 0
        if (on[w] > 0) { for (i = 1; i <= on[w]; i++) T[++cnt] = o[w, i] }
        else if (xn[w] > 0) { for (i = 1; i <= xn[w]; i++) T[++cnt] = x[w, i] }
        else continue
        b = budget(w == 5 ? p5 : p7, w == 5 ? t5 : t7, mean(T, cnt))
        for (i = 1; i <= cnt; i++) delete T[i]
        if (b < 0) continue
        if (best == "" || b < best) { best = b; win = (w == 5 ? "5h" : "7d") }
      }
      if (best == "") printf "unknown -"; else printf "%d %s", best, win
    }' "$__hist"
}

# __ic_pick_account <hist> <current_line> <accounts_text>: the number of the
# usable, non-active account with the largest known budget, only when it is
# larger than the current account's known budget; empty otherwise. An
# alternate is measured as a `usage` line built from its own accounts row
# plus the thresholds/buf/tol of <current_line>. Read-only.
__ic_pick_account() {
  local __hist="$1" __cur="$2" __acc="${3:-}"
  local __tag __key __p5 __r5 __p7 __r7 __tail __cb __best='' __bestn=-1
  local __num __akey __act __usable __a5 __ar5 __a7 __ar7 __rest __n __out
  read -r __tag __key __p5 __r5 __p7 __r7 __tail <<< "$__cur"
  __cb="$(__ic_budget "$__hist" "$__cur" "$__acc")"
  __cb="${__cb%% *}"
  case "$__cb" in ''|unknown) return 0 ;; esac
  __bestn="$__cb"
  while read -r __num __akey __act __usable __a5 __ar5 __a7 __ar7 __rest; do
    [ "$__act" = 0 ] && [ "$__usable" = 1 ] && [ -n "$__akey" ] && [ "$__akey" != - ] || continue
    __out="$(__ic_budget "$__hist" "usage $__akey $__a5 $__ar5 $__a7 $__ar7 $__tail" "$__acc")"
    __n="${__out%% *}"
    case "$__n" in ''|unknown) continue ;; esac
    if [ "$__n" -gt "$__bestn" ]; then __bestn="$__n"; __best="$__num"; fi
  done <<< "$__acc"
  [ -n "$__best" ] && printf '%s' "$__best"
  return 0
}

# ---- backend detection, input-box check and key sending ----
# The backend is the multiplexer the claude process runs in, as words:
# `tmux <socket> <pane>` or `screen <sty> <window>`. Every tmux call names
# the socket (-S), every screen call the window (-p), so keys and captures
# only ever reach this session's own pane/window. Only builtins are used
# while reading /proc, so a missing binary is noticed before any call.

# __ic_ppid <pid>: the parent pid from /proc/<pid>/stat (field 4). comm can
# hold spaces and parens, so the fields are counted after the last ')'.
__ic_ppid() {
  local __s
  { read -r __s < "/proc/$1/stat"; } 2>/dev/null || return 1
  __s="${__s##*) }"
  read -r _ __s _ <<< "$__s"
  case "$__s" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$__s"
}

# __ic_comm <pid>: /proc/<pid>/comm, or nothing.
__ic_comm() {
  local __c
  { read -r __c < "/proc/$1/comm"; } 2>/dev/null || return 1
  printf '%s' "$__c"
}

# $IC_CLAUDE_PID when set, else the nearest ancestor of $$ named claude, else empty.
__ic_claude_pid() {
  local __p="$$" __i
  if [ -n "${IC_CLAUDE_PID:-}" ]; then printf '%s' "$IC_CLAUDE_PID"; return 0; fi
  for ((__i = 0; __i < 64; __i++)); do
    __p="$(__ic_ppid "$__p")" || return 0
    [ "$__p" -gt 1 ] || return 0
    [ "$(__ic_comm "$__p")" = claude ] && { printf '%s' "$__p"; return 0; }
  done
  return 0
}

# __ic_backend: see the section comment; empty when there is none. TMUX,
# TMUX_PANE, STY and WINDOW come from the hook's own environment when any of
# them is set there, else all four from /proc/<claude pid>/environ. With both
# multiplexers present, the first of claude's ancestors named tmux* or
# screen*/SCREEN* wins (screen when none is found).
__ic_backend() {
  local __pid __kv __t='' __tp='' __sty='' __w='' __has_t=0 __has_s=0 __p __i __c
  __pid="$(__ic_claude_pid)"
  if [ -n "${TMUX:-}${TMUX_PANE:-}${STY:-}${WINDOW:-}" ]; then
    __t="${TMUX:-}" __tp="${TMUX_PANE:-}" __sty="${STY:-}" __w="${WINDOW:-}"
  elif [ -n "$__pid" ] && [ -r "/proc/$__pid/environ" ]; then
    while IFS= read -r -d '' __kv; do
      case "$__kv" in
        TMUX=*) __t="${__kv#TMUX=}" ;;
        TMUX_PANE=*) __tp="${__kv#TMUX_PANE=}" ;;
        STY=*) __sty="${__kv#STY=}" ;;
        WINDOW=*) __w="${__kv#WINDOW=}" ;;
      esac
    done < "/proc/$__pid/environ" 2>/dev/null
  fi
  __t="${__t%%,*}"
  [ -n "$__t" ] && [ -n "$__tp" ] && command -v tmux >/dev/null 2>&1 && __has_t=1
  [ -n "$__sty" ] && [ -n "$__w" ] && command -v screen >/dev/null 2>&1 && __has_s=1
  if [ "$__has_t" = 1 ] && [ "$__has_s" = 1 ]; then
    __has_t=0
    __p="$__pid"
    for ((__i = 0; __i < 64; __i++)); do
      [ -n "$__p" ] || break
      __p="$(__ic_ppid "$__p")" || break
      [ "$__p" -gt 1 ] || break
      __c="$(__ic_comm "$__p")"
      case "$__c" in
        tmux*) __has_t=1; __has_s=0; break ;;
        screen*|SCREEN*) break ;;
      esac
    done
  fi
  if [ "$__has_t" = 1 ]; then printf 'tmux %s %s' "$__t" "$__tp"
  elif [ "$__has_s" = 1 ]; then printf 'screen %s %s' "$__sty" "$__w"
  fi
  return 0
}

# __ic_box_scan <prompt prefix> <rule char> < screen: finds the last line
# starting with the prefix whose line above is a rule and that is followed,
# after any continuation lines, by another rule. A rule starts at column 0
# and is at least 8 rule chars, then only trailing spaces: continuation
# lines are indented two spaces, and under screen's lossy hardcopy a CJK
# character such as 一/丁 has the same low byte as ─, so a short or
# indented run of them is draft text, not a rule. Prints "<box lines>
# <0-based line of the first one> <1 if text>", or nothing when there is
# no such box. Byte-based (LC_ALL=C).
__ic_box_scan() {
  IC_P="$1" IC_R="$2" LC_ALL=C awk '
    function isrule(s,    t, n) { t = s; sub(/ +$/, "", t); n = 0
      while (index(t, R) == 1) { t = substr(t, length(R) + 1); n++ }
      return t == "" && n >= 8 }
    BEGIN { P = ENVIRON["IC_P"]; R = ENVIRON["IC_R"] }
    { L[NR] = $0 }
    END {
      found = 0
      for (i = 1; i <= NR; i++) {
        if (index(L[i], P) != 1 || i < 2 || !isrule(L[i - 1])) continue
        for (j = i + 1; j <= NR && !isrule(L[j]); j++) ;
        if (j > NR) continue
        text = substr(L[i], length(P) + 1)
        for (k = i + 1; k < j; k++) text = text L[k]
        gsub(/ /, "", text)
        n = j - i; row = i - 1; has = (text != ""); found = 1
      }
      if (found) printf "%d %d %d", n, row, has
    }'
}

# __ic_inputbox_state <backend words...>: empty, placeholder, draft or unsure.
# One box line with the cursor right after the prompt (tmux: col 2 of that
# row, 0-based; screen: col 3, 1-based) is empty or, with text, a suggested
# placeholder; anything else in a box is a draft. No box or no cursor is
# unsure. screen's hardcopy keeps only the low byte of each character (the
# prompt reads o+0xa0, a rule NULs) and a CJK character can split a row, so
# screen never compares rows.
__ic_inputbox_state() {
  local __scr __cur __box __n __row __has __x __y='' __f __i __at_prompt=0
  case "${1:-}" in
    tmux)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || { printf unsure; return 0; }
      __scr="$(tmux -S "$2" capture-pane -p -t "$3" 2>/dev/null)" || { printf unsure; return 0; }
      __cur="$(tmux -S "$2" display-message -p -t "$3" '#{cursor_x} #{cursor_y}' 2>/dev/null)" || { printf unsure; return 0; }
      read -r __x __y _ <<< "$__cur"
      case "$__y" in ''|*[!0-9]*) printf unsure; return 0 ;; esac
      __box="$(printf '%s\n' "$__scr" | __ic_box_scan $'\xe2\x9d\xaf\xc2\xa0' $'\xe2\x94\x80')"
      ;;
    screen)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || { printf unsure; return 0; }
      __f="${IC_TMP_BASE:-/tmp/claude-$(id -u)}"
      mkdir -p "$__f" 2>/dev/null && __f="$(mktemp "$__f/ic-hardcopy.XXXXXX" 2>/dev/null)" || { printf unsure; return 0; }
      if ! screen -S "$2" -p "$3" -X hardcopy "$__f" >/dev/null 2>&1; then
        rm -f "$__f"; printf unsure; return 0
      fi
      for __i in 1 2 3 4 5 6 7 8 9 10; do
        [ -s "$__f" ] && break
        sleep 0.1
      done
      __box="$(tr '\000' '\001' < "$__f" 2>/dev/null | __ic_box_scan $'o\xa0' $'\001')"
      rm -f "$__f"
      # The cursor is read after the hardcopy (up to ~1 s later): a keystroke
      # in between moves it off column 3, which reads as draft (abandon).
      __cur="$(screen -S "$2" -p "$3" -Q info 2>/dev/null)" || { printf unsure; return 0; }
      __x="$(printf '%s' "$__cur" | sed -n '1s/^(\([0-9]*\),[0-9]*).*/\1/p')"
      ;;
    *) printf unsure; return 0 ;;
  esac
  case "$__x" in ''|*[!0-9]*) printf unsure; return 0 ;; esac
  [ -n "$__box" ] || { printf unsure; return 0; }
  read -r __n __row __has <<< "$__box"
  if [ "$1" = tmux ]; then
    [ "$__x" = 2 ] && [ "$__y" = "$__row" ] && __at_prompt=1
  else
    [ "$__x" = 3 ] && __at_prompt=1
  fi
  if [ "$__n" = 1 ] && [ "$__at_prompt" = 1 ]; then
    if [ "$__has" = 1 ]; then printf placeholder; else printf empty; fi
  else
    printf draft
  fi
}

# __ic_send <backend words...> <text>: types <text> and then CR as two calls
# (one tmux call turned the CR into a newline). screen's stuff treats '\' as
# an escape, so each one is doubled. Returns the backend's rc.
__ic_send() {
  case "${1:-}" in
    tmux)
      tmux -S "$2" send-keys -l -t "$3" "$4" >/dev/null 2>&1 || return
      tmux -S "$2" send-keys -l -t "$3" $'\r' >/dev/null 2>&1
      ;;
    screen)
      # Only \ is escaped: the copy texts hold no other character stuff
      # interprets ($, ^).
      screen -S "$2" -p "$3" -X stuff "${4//\\/\\\\}" >/dev/null 2>&1 || return
      screen -S "$2" -p "$3" -X stuff $'\r' >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}
