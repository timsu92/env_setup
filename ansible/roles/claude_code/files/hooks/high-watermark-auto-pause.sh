#!/usr/bin/env bash
# Claude Code hook: registered on PreToolUse, UserPromptSubmit, and Stop.
# PreToolUse/UserPromptSubmit gate (sleep, never deny) until some
# cswap-managed account clears both rate-limit windows under 97%.
# UserPromptSubmit/Stop also stamp turn_start/turn_stop for the
# statusline's turn-duration display — always AFTER the gate clears, so
# time spent waiting never counts as part of the turn's duration.
set -u

# A rate-limit window at or above this percentage counts as "exhausted"
# when deciding whether a cswap-managed account is usable.
RATE_LIMIT_GATE_PCT=97

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

__cswap_check() {
  # Prints "available" if some cswap-managed account currently has both
  # fiveHour and sevenDay usage under 97%; prints the (ISO-8601) resetsAt of
  # the earliest point any exhausted account clears if none are available;
  # prints "error:<reason>" if we can't determine either of those (missing
  # cswap binary, "list --json" failing, no jq/python to parse it, or
  # unparsable output). Callers must surface the error case loudly instead
  # of quietly treating "we couldn't check" the same as "confirmed clear" —
  # otherwise a broken cswap install silently disables the whole gate.
  local cswap json resume_str
  cswap="$(__cswap_bin)" || { printf 'error:cswap_not_found'; return; }
  json="$("$cswap" list --json 2>/dev/null)" || { printf 'error:cswap_list_failed'; return; }
  if command -v jq >/dev/null 2>&1; then
    resume_str="$(printf '%s' "$json" | jq -r --argjson threshold "$RATE_LIMIT_GATE_PCT" '
      [.accounts[] | select(.usageStatus == "ok")] as $ok
      | ($ok | any(((.usage.fiveHour.pct // 0) < $threshold) and ((.usage.sevenDay.pct // 0) < $threshold))) as $has_available
      | if $has_available then "available"
        else
          [ $ok[] |
            ([ (if (.usage.fiveHour.pct // 0) >= $threshold then (.usage.fiveHour.resetsAt // empty) else empty end),
               (if (.usage.sevenDay.pct // 0) >= $threshold then (.usage.sevenDay.resetsAt // empty) else empty end)
             ] | map(select(. != null))) as $times
            | if ($times | length) > 0 then ($times | max) else empty end
          ] | if length > 0 then min else "available" end
        end
    ' 2>/dev/null)" || resume_str=""
  else
    local py=""
    if command -v python3 >/dev/null 2>&1; then py=python3
    elif command -v python >/dev/null 2>&1; then py=python
    fi
    if [ -n "$py" ]; then
      resume_str="$(HWAP_CSWAP_JSON="$json" HWAP_GATE_PCT="$RATE_LIMIT_GATE_PCT" "$py" - <<'PYEOF' 2>/dev/null
import json, os
d = json.loads(os.environ.get('HWAP_CSWAP_JSON', '{}') or '{}')
threshold = float(os.environ.get('HWAP_GATE_PCT'))
ok = [a for a in d.get('accounts', []) if a.get('usageStatus') == 'ok']
def pct(a, k):
    return ((a.get('usage') or {}).get(k) or {}).get('pct') or 0
def resets(a, k):
    return ((a.get('usage') or {}).get(k) or {}).get('resetsAt')
if any(pct(a, 'fiveHour') < threshold and pct(a, 'sevenDay') < threshold for a in ok):
    print('available', end='')
else:
    candidates = []
    for a in ok:
        times = [t for t in (
            resets(a, 'fiveHour') if pct(a, 'fiveHour') >= threshold else None,
            resets(a, 'sevenDay') if pct(a, 'sevenDay') >= threshold else None,
        ) if t]
        if times:
            candidates.append(max(times))
    print(min(candidates) if candidates else 'available', end='')
PYEOF
)" || resume_str=""
    else
      printf 'error:no_json_parser'
      return
    fi
  fi
  if [ -z "$resume_str" ]; then
    printf 'error:cswap_output_unparsable'
    return
  fi
  printf '%s' "$resume_str"
}

__gate() {
  # Blocks (never denies) until some account clears. Re-checks cswap fresh
  # every iteration (capped at 2 minutes between checks) rather than
  # trusting one static estimate, so an out-of-band reset or a newly
  # cleared account is noticed promptly instead of only at the original
  # worst-case estimate.
  while :; do
    local result epoch now wait
    result="$(__cswap_check)"
    case "$result" in
      error:*)
        echo "high-watermark-auto-pause: cswap check failed (${result#error:}); skipping rate-limit gate for this turn" >&2
        exit 1  # Don't exit with code 2 since Claude Code treats that as a "deny" and aborts the turn; we want to continue instead.
        ;;
    esac
    if [ "$result" = "available" ]; then
      return 0
    fi
    epoch="$(date -d "$result" +%s 2>/dev/null)" || return 0
    now=$(date +%s)
    wait=$(( epoch - now ))
    if [ "$wait" -le 0 ]; then
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
