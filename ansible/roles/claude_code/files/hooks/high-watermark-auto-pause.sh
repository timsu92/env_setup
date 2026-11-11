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

__stamp_turn() {
  local which="$1" tdir
  tdir="$(__session_dir "$(__field 'transcript_path')" "$(__field 'session_id')")"
  [ -n "$tdir" ] || return 0
  mkdir -p "$tdir"
  date +%s > "$tdir/$which"
}

case "$(__field 'hook_event_name')" in
  PreToolUse)
    __gate || exit 1  # rc 3 = helper error, already reported on stderr
    ;;
  UserPromptSubmit)
    __gate || exit 1
    __stamp_turn turn_start
    ;;
  Stop)
    __stamp_turn turn_stop
    ;;
esac

exit 0
