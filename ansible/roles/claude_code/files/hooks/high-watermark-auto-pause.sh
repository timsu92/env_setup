#!/usr/bin/env bash
# Claude Code hook: registered on PreToolUse, UserPromptSubmit, and Stop.
# PreToolUse/UserPromptSubmit gate (sleep, never deny) until the active
# cswap-managed account is under the rate-limit threshold, switching to
# another enabled account first when one is usable. What "usable" means is
# decided by ../hwap-helper.sh, which statusline.sh shares.
# UserPromptSubmit/Stop also stamp turn_start/turn_stop for the
# statusline's turn-duration display — always AFTER the gate clears, so
# time spent waiting never counts as part of the turn's duration.
set -u

# Relative to this script (~/.claude/hooks/), so a moved ~/.claude keeps working.
HELPER="$(dirname "${BASH_SOURCE[0]}")/../hwap-helper.sh"

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
  dir="/tmp/claude-$(id -u)"
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
  rm -f "/tmp/claude-$(id -u)/hwap-hold-until" 2>/dev/null
}

__gate() {
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
  local hold_until=0 reset_at=0 switch_tried=0
  __clear_hold_until
  while :; do
    local result now wait cswap target
    if [ -x "$HELPER" ]; then
      result="$("$HELPER")"
    else
      result="error:hwap_helper_not_found ($HELPER)"
    fi
    case "$result" in
      error:*)
        echo "high-watermark-auto-pause: cswap check failed (${result#error:}); skipping rate-limit gate for this turn" >&2
        exit 1  # Don't exit with code 2 since Claude Code treats that as a "deny" and aborts the turn; we want to continue instead.
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
          sleep 30
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
    wait=$(( hold_until - now ))
    if [ "$wait" -le 0 ]; then
      __clear_hold_until
      return 0
    fi
    if [ "$wait" -gt 120 ]; then wait=120; fi
    sleep "$wait"
  done
}

__stamp_turn() {
  local which="$1" sid
  sid="$(__field 'session_id')"
  [ -n "$sid" ] || return 0
  local tdir
  tdir="/tmp/claude-$(id -u)/$sid"
  mkdir -p "$tdir"
  date +%s > "$tdir/$which"
}

case "$(__field 'hook_event_name')" in
  PreToolUse)
    __gate
    ;;
  UserPromptSubmit)
    __gate
    __stamp_turn turn_start
    ;;
  Stop)
    __stamp_turn turn_stop
    ;;
esac

exit 0
