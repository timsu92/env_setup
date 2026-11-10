#!/usr/bin/env bash
# Claude Code hook for the checkpoint-compact flow: pause at a task boundary,
# /compact through the terminal multiplexer, switch account, send 繼續.
# Registered on PostToolUse, Stop, Notification, PreCompact, PostCompact,
# SessionStart and UserPromptSubmit. This file handles SessionStart,
# UserPromptSubmit and PreCompact; the other events are stubs for now.
# It never blocks Claude Code: exit 0 on every path (never 2), and nothing on
# stdout except PostToolUse's additionalContext JSON.
set -u

# Relative to this script (~/.claude/hooks/), so a moved ~/.claude keeps working.
LIB="$(dirname "${BASH_SOURCE[0]}")/../common-helpers.sh"
# shellcheck source=../common-helpers.sh
if [ -r "$LIB" ] && . "$LIB"; then
  :
else
  echo "ideal-compact: common-helpers.sh not found" >&2
  exit 0
fi

INPUT="$(cat)"

# __field <key>: a top-level field of the hook input as text. A nested value
# (tool_input) comes back as compact JSON.
__field() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r --arg k "$1" '(.[$k] // empty) | if type == "string" then . else tojson end' 2>/dev/null
  else
    local py=""
    if command -v python3 >/dev/null 2>&1; then py=python3
    elif command -v python >/dev/null 2>&1; then py=python
    fi
    [ -z "$py" ] && { printf ''; return; }
    IC_INPUT="$INPUT" IC_KEY="$1" "$py" - <<'PYEOF' 2>/dev/null
import json, os
d = json.loads(os.environ.get('IC_INPUT', '{}') or '{}')
v = d.get(os.environ.get('IC_KEY', ''), '')
print(v if isinstance(v, str) else json.dumps(v, separators=(',', ':'), ensure_ascii=False), end='')
PYEOF
  fi
}

EVENT="$(__field hook_event_name)"
TPATH="$(__field transcript_path)"
CWD="$(__field cwd)"
SDIR="$(__ic_session_dir "$TPATH" "$(__field session_id)")"
[ -n "$SDIR" ] || exit 0
LOCK="$SDIR/ideal-compact-state.lock"

# __ic_takeover <expected> [inputbox_fail]: the user (or something else) took
# the session over while the flow was running, or a step failed. Sets phase
# standby with suppress=1 for the window the budget is currently counted on,
# so the flow does not re-arm until that window resets. <expected> is a phase
# name or `nonstandby`; the takeover happens only when the phase still is that
# (checked again under the lock) and returns 1 changing nothing otherwise. Any
# second argument also sets inputbox_fail=1 in the same write.
# The helper and the budget run BEFORE the lock (the lock never spans them);
# when the helper fails or the budget is unknown, armed_* is used instead.
__ic_takeover() {
  local expected="$1" fail="${2:-}" cur='' acc='' ledger pdir hist budget bwin='' key r5 r7
  local s_key='' s_win='' s_resets=0
  if [ -x "$__IC_HELPER" ]; then
    cur="$("$__IC_HELPER" current 2>/dev/null)"
    acc="$("$__IC_HELPER" accounts 2>/dev/null)"
  fi
  case "$cur" in error:*) cur='' ;; esac
  __ic_state_read "$SDIR"
  ledger="$IC_ledger"
  if [ -n "$ledger" ]; then
    pdir="$(__ic_project_dir "$(dirname "$ledger")" "$TPATH")"
  else
    pdir="$(__ic_project_dir "$CWD" "$TPATH")"
  fi
  hist=/dev/null
  [ -n "$pdir" ] && hist="$pdir/ideal-compact-history"
  if [ -n "$cur" ]; then
    budget="$(__ic_budget "$hist" "$cur" "$acc")"
    bwin="${budget#* }"
    # `current` is: tag key p5 r5 p7 r7 ...
    read -r _ key _ r5 _ r7 _ <<< "$cur"
    case "$bwin" in
      5h) s_key="$key" s_win=5h s_resets="$r5" ;;
      7d) s_key="$key" s_win=7d s_resets="$r7" ;;
      *) bwin='' ;;
    esac
  fi
  __ic_lock "$LOCK" || return 1
  __ic_state_read "$SDIR"
  if [ "$expected" = nonstandby ]; then
    [ "$IC_phase" != standby ] || { __ic_unlock; return 1; }
  else
    [ "$IC_phase" = "$expected" ] || { __ic_unlock; return 1; }
  fi
  if [ -z "$bwin" ]; then
    s_key="$IC_armed_key" s_win="$IC_armed_win" s_resets="$IC_armed_resets"
  fi
  __ic_set_phase standby
  IC_suppress=1 IC_suppress_key="$s_key" IC_suppress_win="$s_win" IC_suppress_resets="${s_resets:-0}"
  [ -n "$fail" ] && IC_inputbox_fail=1
  __ic_state_write "$SDIR"
  __ic_unlock
  return 0
}

# Every event first lets an overdue phase go back to standby (with suppress),
# so the handlers below never see an expired one.
__ttl_step() {
  __ic_lock "$LOCK" || exit 0
  __ic_state_read "$SDIR"
  if __ic_ttl_check "$(date +%s)"; then __ic_state_write "$SDIR"; fi
  __ic_unlock
}

# New session (not the one /compact restarts): nothing of an old flow applies.
# dirty stays, it counts activity that already happened.
__on_session_start() {
  case "$(__field source)" in startup|resume|clear) ;; *) return 0 ;; esac
  __ic_lock "$LOCK" || return 0
  __ic_state_read "$SDIR"
  if [ "$IC_phase" != standby ] || [ "$IC_skip" != 0 ] || [ "$IC_suppress" != 0 ] || [ -n "$IC_ledger" ]; then
    __ic_set_phase standby
    IC_suppress=0 IC_suppress_key='' IC_suppress_win='' IC_suppress_resets=0 IC_ledger=''
    __ic_state_write "$SDIR"
  fi
  __ic_unlock
}

__on_prompt() {
  local prompt first kind=other seen
  prompt="$(__field prompt)"
  # A background agent's hand-back is not the user speaking (Task 1 ruling).
  case "$prompt" in '<agent-message '*) return 0 ;; esac
  read -r first _ <<< "$prompt"
  if [ "$first" = /ideal-compact-skip ] || [[ "$prompt" == *'<!-- ideal-compact:skip -->'* ]]; then
    kind=skip
  elif [ "$first" = /ideal-compact-standby ] || [[ "$prompt" == *'<!-- ideal-compact:standby -->'* ]]; then
    kind=standby
  elif [ "$prompt" = "$IDEAL_COMPACT_CONTINUE_TEXT" ]; then
    kind=continue
  fi
  __ic_lock "$LOCK" || return 0
  __ic_state_read "$SDIR"
  IC_dirty=$(( IC_dirty + 1 ))
  case "$kind" in
    skip)
      IC_skip=1 ;;
    standby)
      case "$IC_phase" in armed|stopped) __ic_set_phase standby ;; esac
      IC_skip=0 IC_suppress=0 IC_suppress_key='' IC_suppress_win='' IC_suppress_resets=0 ;;
    continue)
      # Our own keyed 繼續 ends the flow. The same word typed in any other
      # phase is an ordinary prompt.
      if [ "$IC_phase" = continuing ]; then
        __ic_set_phase standby
        IC_suppress=0 IC_suppress_key='' IC_suppress_win='' IC_suppress_resets=0
      else
        kind=other
      fi ;;
  esac
  seen="$IC_phase"
  __ic_state_write "$SDIR"
  __ic_unlock
  if [ "$kind" = other ] && [ "$seen" != standby ]; then
    __ic_takeover nonstandby || true
  fi
}

__on_precompact() {
  local seen moved=0
  __ic_lock "$LOCK" || return 0
  __ic_state_read "$SDIR"
  IC_dirty=$(( IC_dirty + 1 ))
  if [ "$IC_phase" = to-compact ] && [ "$(__field trigger)" = manual ]; then
    # Our own /compact reached the CLI.
    __ic_set_phase compacting
    moved=1
  fi
  seen="$IC_phase"
  __ic_state_write "$SDIR"
  __ic_unlock
  # Any other compaction while the flow is active is not ours.
  if [ "$moved" = 0 ] && [ "$seen" != standby ]; then
    __ic_takeover nonstandby || true
  fi
}

__ttl_step
case "$EVENT" in
  SessionStart) __on_session_start ;;
  UserPromptSubmit) __on_prompt ;;
  PreCompact) __on_precompact ;;
  PostToolUse) : ;;   # Task 11 (its fast path for an idle standby goes first)
  Stop) : ;;          # Task 12
  Notification) : ;;  # Task 12
  PostCompact) : ;;   # Task 13
esac
exit 0
