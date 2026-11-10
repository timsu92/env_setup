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
