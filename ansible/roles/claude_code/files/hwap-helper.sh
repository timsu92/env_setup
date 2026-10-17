#!/usr/bin/env bash
# Shared by hooks/high-watermark-auto-pause.sh and statusline.sh, so the rule
# "which cswap-managed account can Claude Code use right now" lives in exactly
# one place. Pure function: reads `cswap list --json`, never switches anything.
#
# Prints exactly one line:
#   ok                          the active account is usable (or can't be judged)
#   switch <num>                the active account is exhausted, <num> is the best
#                               enabled account that is usable instead
#   wait <resume> <reset>       nothing is usable. <resume> is the epoch the
#                               earliest account clears (<reset> plus the
#                               buffer), <reset> is that account's raw resetsAt
#   error:<reason>              couldn't decide; callers must surface this
#                               loudly instead of treating it as "clear"
#
# A window is "exhausted" while pct >= RATE_LIMIT_GATE_PCT and the clock is
# before resetsAt + RATE_LIMIT_RESUME_BUFFER_SEC. cswap polls exhausted
# accounts only about every ten minutes, so right after a reset it can still
# report the old pct with a resetsAt already in the past ("reset in 0m"). The
# buffer keeps that stale data from being trusted for a bit longer, and once
# it has run out the window counts as cleared whatever the stale pct says.
set -u

# A rate-limit window at or above this percentage counts as "exhausted".
RATE_LIMIT_GATE_PCT=97

# Extra seconds to treat a window as exhausted after its resetsAt, so we don't
# resume the instant the reset lands (usage data may lag behind the reset).
RATE_LIMIT_RESUME_BUFFER_SEC=120

cswap=""
if command -v cswap >/dev/null 2>&1; then cswap=cswap
elif [ -x "$HOME/.local/bin/cswap" ]; then cswap="$HOME/.local/bin/cswap"
fi
[ -n "$cswap" ] || { printf 'error:cswap_not_found'; exit 0; }
json="$("$cswap" list --json 2>/dev/null)" || { printf 'error:cswap_list_failed'; exit 0; }
now="$(date +%s)"

out=""
if command -v jq >/dev/null 2>&1; then
  out="$(printf '%s' "$json" | jq -r \
    --argjson thr "$RATE_LIMIT_GATE_PCT" --argjson buf "$RATE_LIMIT_RESUME_BUFFER_SEC" --argjson now "$now" '
    def ts: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
    def pct($k): (.usage // {})[$k].pct // 0;
    def rst($k): (.usage // {})[$k].resetsAt | if . == null then null else ts end;
    def exhausted($k): pct($k) >= $thr and (rst($k) == null or rst($k) + $buf > $now);
    def usable: (exhausted("fiveHour") | not) and (exhausted("sevenDay") | not);
    # Epoch this account clears, or null when a window gives no resetsAt.
    def clears_at:
      [ ("fiveHour", "sevenDay") as $k | select(exhausted($k)) | rst($k) ]
      | if length > 0 and all(. != null) then max + $buf else null end;
    (.accounts // []) as $accts
    | ($accts | map(select(.active == true)) | .[0]) as $active
    | ($accts | map(select(.usageStatus == "ok" and .disabled != true))) as $ok
    | if $active != null and $active.usageStatus != "ok" then "ok"
      elif $active != null and ($active | usable) then "ok"
      else
        ($ok | map(select(.active != true and usable))
             | sort_by([ ([pct("fiveHour"), pct("sevenDay")] | max), .number ])) as $alts
        | if ($alts | length) > 0 then
            (if $active == null then "ok" else "switch \($alts[0].number)" end)
          else
            ([ ($ok + ([$active] | map(select(. != null and .usageStatus == "ok"))))
               | unique_by(.number)[] | clears_at | select(. != null) ] ) as $times
            | if ($times | length) > 0 then ($times | min) as $r | "wait \($r) \($r - $buf)"
              else "ok" end
          end
      end
  ' 2>/dev/null)" || out=""
else
  py=""
  if command -v python3 >/dev/null 2>&1; then py=python3
  elif command -v python >/dev/null 2>&1; then py=python
  fi
  [ -n "$py" ] || { printf 'error:no_json_parser'; exit 0; }
  out="$(HWAP_JSON="$json" HWAP_THR="$RATE_LIMIT_GATE_PCT" HWAP_BUF="$RATE_LIMIT_RESUME_BUFFER_SEC" HWAP_NOW="$now" \
    "$py" - <<'PYEOF' 2>/dev/null
import json, os, re
from datetime import datetime

d = json.loads(os.environ['HWAP_JSON'])
thr = float(os.environ['HWAP_THR'])
buf = int(os.environ['HWAP_BUF'])
now = int(os.environ['HWAP_NOW'])

def ts(s):
    return int(datetime.fromisoformat(re.sub(r'\.\d+', '', s).replace('Z', '+00:00')).timestamp())

def win(a, k):
    return (a.get('usage') or {}).get(k) or {}

def pct(a, k):
    return win(a, k).get('pct') or 0

def rst(a, k):
    r = win(a, k).get('resetsAt')
    return ts(r) if r else None

def exhausted(a, k):
    if pct(a, k) < thr:
        return False
    r = rst(a, k)
    return r is None or r + buf > now

def usable(a):
    return not exhausted(a, 'fiveHour') and not exhausted(a, 'sevenDay')

def clears_at(a):
    times = [rst(a, k) for k in ('fiveHour', 'sevenDay') if exhausted(a, k)]
    if not times or any(t is None for t in times):
        return None
    return max(times) + buf

accts = d.get('accounts') or []
active = next((a for a in accts if a.get('active') is True), None)
ok = [a for a in accts if a.get('usageStatus') == 'ok' and a.get('disabled') is not True]

if active is not None and active.get('usageStatus') != 'ok':
    print('ok', end='')
elif active is not None and usable(active):
    print('ok', end='')
else:
    alts = sorted(
        (a for a in ok if a.get('active') is not True and usable(a)),
        key=lambda a: (max(pct(a, 'fiveHour'), pct(a, 'sevenDay')), a.get('number', 0)),
    )
    if alts:
        print('ok' if active is None else 'switch %s' % alts[0].get('number'), end='')
    else:
        pool = list(ok)
        if active is not None and active.get('usageStatus') == 'ok' and active not in pool:
            pool.append(active)
        times = [t for t in (clears_at(a) for a in pool) if t is not None]
        if times:
            r = min(times)
            print('wait %d %d' % (r, r - buf), end='')
        else:
            print('ok', end='')
PYEOF
)" || out=""
fi

if [ -z "$out" ]; then
  printf 'error:cswap_output_unparsable'
  exit 0
fi
printf '%s' "$out"
