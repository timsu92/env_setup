#!/usr/bin/env bash
# Claude Code hook: registered on PreToolUse, UserPromptSubmit, PostToolUse,
# Stop, PreCompact, PostCompact and SessionStart.
# PreToolUse/UserPromptSubmit gate (sleep, never deny) until the active
# cswap-managed account is under the rate-limit threshold. What "usable"
# means is decided by ../hwap-helper.sh, which statusline.sh shares.
# When the helper names another account to switch to and the session runs in
# tmux or screen, the switch waits for a compact instead (compact-before-switch
# flow): /compact is typed into the input box, the agent is asked to stop, and
# PostCompact switches and resumes. Without a multiplexer the switch happens
# at once, as before. The flow and where it meets ideal-compact.sh's own flow
# are described in docs/superpowers/specs/
# 2026-11-19-hwap-compact-before-switch-design.md.
# UserPromptSubmit/Stop also stamp turn_start/turn_stop for the
# statusline's turn-duration display — always AFTER the gate clears, so
# time spent waiting never counts as part of the turn's duration.
set -u

# Relative to this script (~/.claude/hooks/), so a moved ~/.claude keeps working.
# The library holds the gate and finds hwap-helper.sh next to itself.
LIB="$(dirname "${BASH_SOURCE[0]}")/../common-helpers.sh"
# shellcheck source=../common-helpers.sh
if [ -r "$LIB" ]; then
  . "$LIB"
else
  echo "high-watermark-auto-pause: common-helpers.sh not found" >&2
  exit 1
fi

INPUT="$(cat)"

__field() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
  else
    local py=""
    if command -v python3 >/dev/null 2>&1; then py=python3
    elif command -v python >/dev/null 2>&1; then py=python
    fi
    [ -z "$py" ] && { printf ''; return; }
    HWAP_INPUT="$INPUT" HWAP_KEY="$1" "$py" - <<'PYEOF' 2>/dev/null
import json, os
d = json.loads(os.environ.get('HWAP_INPUT', '{}') or '{}')
print(d.get(os.environ.get('HWAP_KEY', ''), ''), end='')
PYEOF
  fi
}

EVENT="$(__field hook_event_name)"
SDIR="$(__session_dir "$(__field transcript_path)" "$(__field session_id)")"
HW_STATE="$SDIR/hwap-compact-state"
HW_LOCK="$SDIR/hwap-compact-state.lock"
HW_PROMPT="$SDIR/hwap-compact-prompt"

__stamp_turn() {
  [ -n "$SDIR" ] || return 0
  mkdir -p "$SDIR"
  date +%s > "$SDIR/$1"
}

# ---- state: <session dir>/hwap-compact-state, key=value lines ----
# Same rules as ideal-compact's file: parsed, never sourced; writers hold
# HW_LOCK around read -> change -> write; every write is a temp file plus mv.
__HW_KEYS="phase phase_at stop_pending interrupted pc_pid"

__hw_read() {
  local k line v
  HW_phase=idle HW_phase_at=0 HW_stop_pending=0 HW_interrupted=0 HW_pc_pid=''
  [ -n "$SDIR" ] && [ -r "$HW_STATE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *=*) ;; *) continue ;; esac
    k="${line%%=*}" v="${line#*=}"
    case "$k" in
      phase) case "$v" in idle|queued|stopping|compacting|waiting) ;; *) continue ;; esac ;;
      phase_at|stop_pending|interrupted|pc_pid)
        case "$v" in ''|*[!0-9]*) continue ;; esac
        [ "${#v}" -le 15 ] || continue ;;
      *) continue ;;
    esac
    printf -v "HW_$k" '%s' "$v"
  done < "$HW_STATE" 2>/dev/null
  return 0
}

__hw_write() {
  local k n tmp
  [ -n "$SDIR" ] || return 1
  mkdir -p "$SDIR" 2>/dev/null || return 1
  tmp="$(mktemp "$HW_STATE.XXXXXX" 2>/dev/null)" || return 1
  for k in $__HW_KEYS; do
    n="HW_$k"
    printf '%s=%s\n' "$k" "${!n:-}"
  done > "$tmp" 2>/dev/null && mv -f "$tmp" "$HW_STATE" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# __hw_phase <new>: changes the HW_* variables only (the caller writes).
# Back to idle forgets everything the flow carried, the blocked prompt too.
__hw_phase() {
  HW_phase="$1"
  HW_phase_at="$(date +%s)"
  if [ "$1" = idle ]; then
    HW_stop_pending=0 HW_interrupted=0 HW_pc_pid=''
    rm -f "$HW_PROMPT" 2>/dev/null
  fi
  return 0
}

# __hw_expired: on the HW_* the caller just read under the lock. true when
# the phase outlived its timeout: stopping (the queued /compact never ran),
# compacting (PostCompact never came) or waiting whose PostCompact process
# is gone (SIGKILL runs no trap). queued has none: a long tool call or a
# subagent may keep the turn going for any length of time.
__hw_expired() {
  local now
  now="$(date +%s)"
  case "$HW_phase" in
    stopping) [ $(( now - HW_phase_at )) -gt "$HWAP_STOPPING_TTL_SEC" ] ;;
    compacting) [ $(( now - HW_phase_at )) -gt "$IDEAL_COMPACT_COMPACT_TTL_SEC" ] ;;
    waiting) [ -z "$HW_pc_pid" ] || ! kill -0 "$HW_pc_pid" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# __hw_step: every event (but PostToolUse's fast path) first reads the state
# and lets an expired phase go back to idle. Leaves the state in HW_*.
__hw_step() {
  HW_phase=idle HW_stop_pending=0 HW_interrupted=0
  [ -n "$SDIR" ] && [ -e "$HW_STATE" ] || return 0
  __lock "$HW_LOCK" || { __hw_read; return 0; }
  __hw_read
  if __hw_expired; then __hw_phase idle; __hw_write; fi
  __unlock
}

# ---- output ----
__json_str() { local t="${1//\\/\\\\}"; printf '%s' "${t//\"/\\\"}"; }
__emit_context() {
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$1" "$(__json_str "$2")"
}
__emit_block() {
  printf '{"decision":"block","reason":"%s"}\n' "$(__json_str "$HWAP_BLOCK_REASON")"
}

# __hw_deliver_stop <event>: a subagent started the flow while the main agent
# may be busy; the main agent's next tool event (or prompt) carries the stop
# request. Delivering it means the main agent was interrupted: interrupted=1,
# so PostCompact sends 繼續.
__hw_deliver_stop() {
  [ "$HW_stop_pending" = 1 ] && [ -z "$(__field agent_id)" ] || return 0
  __lock "$HW_LOCK" || return 0
  __hw_read
  if [ "$HW_stop_pending" != 1 ]; then __unlock; return 0; fi
  HW_stop_pending=0 HW_interrupted=1
  __hw_write
  __unlock
  __emit_context "$1" "$HWAP_STOP_TEXT"
}

# __hw_has_history: true when the transcript has an assistant message after
# its last compact boundary. Without one, /compact answers "Not enough
# messages to compact": PreCompact fires but PostCompact never does. Such a
# short context is cheap to carry over, so the switch happens directly. An
# unreadable transcript counts as having history.
__hw_has_history() {
  local tp
  tp="$(__field transcript_path)"
  [ -r "$tp" ] || return 0
  awk '/"subtype":"compact_boundary"/ { n = 0 } /"role":"assistant"/ { n = 1 } END { exit !n }' "$tp" 2>/dev/null
}

# __hw_back_to_idle: undoes this hook's own idle -> queued.
__hw_back_to_idle() {
  __lock "$HW_LOCK" || return 0
  __hw_read
  [ "$HW_phase" = queued ] && { __hw_phase idle; __hw_write; }
  __unlock
}

# __hw_start <main|sub|prompt|handback>: starts the compact-before-switch
# flow (idle -> queued). 0 when it started here, 2 when another hook started
# it a moment ago (the caller treats the event as one arriving while queued),
# 1 when it cannot start and the caller switches directly. Conditions, all of
# them: a transcript with something to compact, a multiplexer, ideal-compact
# in standby, armed or stopped (any later phase means its own compact is under
# way or just done, and its PostCompact chooses the account), an input box
# with nothing typed.
__hw_start() {
  local kind="$1" backend box ic_lock="$SDIR/ideal-compact-state.lock" took=0 old_skip
  local -a bw
  [ -n "$SDIR" ] || return 1
  __hw_has_history || return 1
  backend="$(__mux_backend)"
  [ -n "$backend" ] || return 1
  # Meeting point with ideal-compact.sh (1): its phase decides. This unlocked
  # read only filters early; the decision is the locked re-read below.
  __state_read "$SDIR"
  case "$IC_phase" in standby|armed|stopped) ;; *) return 1 ;; esac
  read -r -a bw <<< "$backend"
  box="$(__mux_inputbox_state "${bw[@]}")"
  case "$box" in empty|placeholder) ;; *) return 1 ;; esac

  __lock "$HW_LOCK" || return 1
  __hw_read
  if [ "$HW_phase" != idle ]; then __unlock; return 2; fi
  __hw_phase queued
  case "$kind" in
    main|handback) HW_interrupted=1 ;;
    sub) HW_stop_pending=1 ;;
    prompt)
      local tmp
      tmp="$(mktemp "$HW_PROMPT.XXXXXX" 2>/dev/null)" \
        && { printf '%s' "$(__field prompt)" > "$tmp" && mv -f "$tmp" "$HW_PROMPT" || rm -f "$tmp"; } 2>/dev/null ;;
  esac
  __hw_write
  __unlock

  # Meeting point with ideal-compact.sh (1): re-read its phase under its lock.
  # If it moved past stopped meanwhile, its own compact is on the way: back
  # off. From armed or stopped, take its flow over the way /ideal-compact-skip
  # does (skip=1, so its idle_prompt sends neither /compact nor 繼續). Its
  # PreCompact then treats this compact as a takeover: standby with suppress.
  if ! __lock "$ic_lock"; then __hw_back_to_idle; return 1; fi
  __state_read "$SDIR"
  case "$IC_phase" in
    standby) ;;
    armed|stopped) old_skip="$IC_skip" took=1; IC_skip=1; __state_write "$SDIR" ;;
    *) __unlock; __hw_back_to_idle; return 1 ;;
  esac
  __unlock

  if ! __mux_send "${bw[@]}" "/compact $HWAP_COMPACT_TEXT"; then
    # No compact is coming: give ideal-compact its skip back.
    if [ "$took" = 1 ] && __lock "$ic_lock"; then
      __state_read "$SDIR"
      case "$IC_phase" in armed|stopped) IC_skip="$old_skip"; __state_write "$SDIR" ;; esac
      __unlock
    fi
    __hw_back_to_idle
    return 1
  fi
  case "$kind" in
    main) __emit_context PreToolUse "$HWAP_STOP_TEXT" ;;
    handback) __emit_context UserPromptSubmit "$HWAP_STOP_TEXT" ;;
    prompt) __emit_block ;;
  esac
  return 0
}

# __hw_gate <kind> <event>: the gate, compacting before a switch when it can.
# Sets HW_STARTED=1 when the flow started here. When another hook started it
# a moment ago, the event passes like one arriving while queued (a waiting
# stop request goes out with it). Exits 1 (non-blocking error) when the
# helper failed: Claude Code treats exit 2 as a "deny" and aborts the turn.
HW_STARTED=0
__hw_gate() {
  local rc
  if [ "$HW_phase" = idle ]; then
    __gate '' 1; rc=$?
    case "$rc" in
      0) return 0 ;;
      5)
        __hw_start "$1"; rc=$?
        case "$rc" in
          0) HW_STARTED=1; return 0 ;;
          2) __hw_read; __hw_deliver_stop "$2"; return 0 ;;
        esac ;;
      *) exit 1 ;;
    esac
  fi
  __gate || exit 1
}

# ---- events ----

__on_pre_tool_use() {
  __hw_step
  # The main agent runs no tool while a compaction is in progress: one that
  # does means the compact failed (no PostCompact will come). Back to idle,
  # so the gate below applies again.
  if [ "$HW_phase" = compacting ] && [ -z "$(__field agent_id)" ] && __lock "$HW_LOCK"; then
    __hw_read
    [ "$HW_phase" = compacting ] && { __hw_phase idle; __hw_write; }
    __unlock
  fi
  case "$HW_phase" in
    # The compact is queued: let everything through, no gate, no second /compact.
    queued|stopping|compacting) __hw_deliver_stop PreToolUse; return 0 ;;
  esac
  if [ -n "$(__field agent_id)" ]; then __hw_gate sub PreToolUse; else __hw_gate main PreToolUse; fi
}

__on_prompt() {
  local kind=prompt
  __hw_step
  case "$HW_phase" in
    queued|stopping|compacting)
      __hw_deliver_stop UserPromptSubmit
      __stamp_turn turn_start
      return 0 ;;
  esac
  # Meeting point with ideal-compact.sh (5): both flows use __is_handback, so
  # they agree on which prompts are the user speaking.
  __is_handback "$(__field prompt)" && kind=handback
  __hw_gate "$kind" UserPromptSubmit
  # A blocked prompt starts no turn.
  [ "$HW_STARTED" = 1 ] && [ "$kind" = prompt ] && return 0
  __stamp_turn turn_start
}

__on_post_tool_use() {
  # Fast path: runs on every tool call, so nothing but one file read unless a
  # stop request is waiting for the main agent.
  [ -n "$SDIR" ] && [ -r "$HW_STATE" ] || return 0
  [ -z "$(__field agent_id)" ] || return 0
  __hw_read
  [ "$HW_stop_pending" = 1 ] || return 0
  case "$HW_phase" in queued|stopping) __hw_deliver_stop PostToolUse ;; esac
}

__on_stop() {
  __stamp_turn turn_stop
  __hw_step
  [ "$HW_phase" = queued ] || return 0
  __lock "$HW_LOCK" || return 0
  __hw_read
  [ "$HW_phase" = queued ] && { __hw_phase stopping; __hw_write; }
  __unlock
}

# Any compaction while queued or stopping counts as ours: a manual one is
# the /compact this flow typed, an auto one compacts just the same.
# Meeting point with ideal-compact.sh (2): its __on_precompact sees the same
# event. This flow only starts with ideal-compact in standby, armed or
# stopped, and there ideal-compact ends up in standby (only dirty, or its
# takeover), so its PostCompact does nothing and only this flow's PostCompact
# switches and resumes. Its own compact never runs while this flow is queued
# or stopping, so this hook ignores that one.
__on_precompact() {
  __hw_step
  case "$HW_phase" in queued|stopping) ;; *) return 0 ;; esac
  __lock "$HW_LOCK" || return 0
  __hw_read
  case "$HW_phase" in
    queued|stopping) __hw_phase compacting; HW_stop_pending=0; __hw_write ;;
  esac
  __unlock
}

__on_session_start() {
  case "$(__field source)" in startup|resume|clear) ;; *) return 0 ;; esac
  [ -n "$SDIR" ] || return 0
  rm -f "$HW_PROMPT" 2>/dev/null
  [ -e "$HW_STATE" ] || return 0
  __lock "$HW_LOCK" || return 0
  __hw_read
  __hw_phase idle
  __hw_write
  __unlock
}

# ---- PostCompact: switch, wait for a usable account, resume ----
# Registered with the gate's ~8 day timeout. A signal (the user's kill) ends
# the wait and sends nothing; one that lands while the state lock is held is
# remembered and acted on once it is released (the handler takes the lock).
__HW_IN_CS=0 __HW_SIGNALED=0 __SLEEP_PID=
__hw_on_signal() {
  if [ "$__HW_IN_CS" = 1 ]; then __HW_SIGNALED=1; return 0; fi
  __HW_IN_CS=1
  [ -n "${__SLEEP_PID:-}" ] && kill "$__SLEEP_PID" 2>/dev/null
  if __lock "$HW_LOCK"; then
    __hw_read
    [ "$HW_phase" = waiting ] && { __hw_phase idle; __hw_write; }
    __unlock
  fi
  __clear_hold_until
  exit 1
}
__hw_cs_lock() { __HW_IN_CS=1; __lock "$HW_LOCK" && return 0; __hw_cs_leave; return 1; }
__hw_cs_leave() { __HW_IN_CS=0; [ "$__HW_SIGNALED" = 1 ] && __hw_on_signal; return 0; }

# The gate's abort_fn: stop waiting once someone else moved the phase on or
# claude is gone. Reads without the lock (every write is atomic).
__hw_wait_ok() {
  __hw_read
  [ "$HW_phase" = waiting ] && __proc_claude_alive
}

# __hw_resume <backend words...>: what goes into the input box after the
# compact. The prompt this flow blocked was put back in the box by Claude
# Code: a CR submits it, but only while the box still holds exactly it. Else
# 繼續, only when the main agent was interrupted (a main agent that was only
# waiting for background work is woken by their hand-back). Nothing is typed
# over a draft.
# Meeting point with ideal-compact.sh (3): the 繼續 and the resubmitted prompt
# reach its UserPromptSubmit while it is in standby, where both are an
# ordinary prompt that only bumps dirty. It treats 繼續 as its own only in
# continuing, which it cannot be in after this flow's compact.
__hw_resume() {
  local box want got
  box="$(__mux_inputbox_state "$@")"
  if [ "$HW_had_prompt" = 1 ]; then
    want="$(printf '%s' "$HW_prompt" | LC_ALL=C tr -d ' \t\r\n')"
    case "$box" in
      draft)
        if [ "$1" = tmux ] && got="$(__mux_box_text "$2" "$3")" && [ "$got" = "$want" ]; then
          __mux_cr "$@" || true
          return 0
        fi ;;
      empty|placeholder)
        if [[ "$HW_prompt" != *$'\n'* ]] && [ -n "$HW_prompt" ]; then
          __mux_send "$@" "$HW_prompt" || true
          return 0
        fi ;;
    esac
    echo "high-watermark-auto-pause: account switched after compact; the blocked prompt was not resubmitted (input box: $box)" >&2
    return 0
  fi
  [ "$HW_was_interrupted" = 1 ] || return 0
  case "$box" in
    empty|placeholder) __mux_send "$@" "$IDEAL_COMPACT_CONTINUE_TEXT" || true ;;
    *) echo "high-watermark-auto-pause: account switched after compact; 繼續 not sent (input box: $box)" >&2 ;;
  esac
}

__on_post_compact() {
  local rc backend
  local -a bw
  __hw_step
  [ "$HW_phase" = compacting ] || return 0
  trap __hw_on_signal TERM HUP
  __hw_cs_lock || return 0
  __hw_read
  if [ "$HW_phase" != compacting ]; then __unlock; __hw_cs_leave; return 0; fi
  __hw_phase waiting
  HW_pc_pid=$$
  __hw_write
  __unlock
  __hw_cs_leave

  # Switches to the account the helper names, or waits until one is usable.
  # A helper error (rc 3) resumes anyway, like ideal-compact's PostCompact.
  __gate __hw_wait_ok; rc=$?
  __SLEEP_PID=
  [ "$rc" = 4 ] && return 0
  __hw_wait_ok || return 0

  HW_had_prompt=0 HW_prompt=''
  if [ -r "$HW_PROMPT" ]; then HW_had_prompt=1; HW_prompt="$(cat "$HW_PROMPT" 2>/dev/null)"; fi
  backend="$(__mux_backend)"
  __hw_cs_lock || return 0
  __hw_read
  if [ "$HW_phase" != waiting ]; then __unlock; __hw_cs_leave; return 0; fi
  # Idle first: the text sent below must find no flow running. Going idle
  # clears interrupted, so __hw_resume reads the copy.
  HW_was_interrupted="$HW_interrupted"
  __hw_phase idle
  __hw_write
  __unlock
  # Signals stay deferred through the send, so text and CR go out as a unit.
  if [ -n "$backend" ]; then
    read -r -a bw <<< "$backend"
    __hw_resume "${bw[@]}"
  fi
  __hw_cs_leave
}

case "$EVENT" in
  PreToolUse) __on_pre_tool_use ;;
  UserPromptSubmit) __on_prompt ;;
  PostToolUse) __on_post_tool_use ;;
  Stop) __on_stop ;;
  PreCompact) __on_precompact ;;
  PostCompact) __on_post_compact ;;
  SessionStart) __on_session_start ;;
esac

exit 0
