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
# With --with-usage (used by statusline.sh) a second line follows, from the same
# single `cswap list --json` call, about the active account:
#   usage <age_s> <pct5> <resets5> <pct7> <resets7> <key> <m5> <m7>
#                               age_s is usageAgeSeconds truncated, the pcts are
#                               as cswap gives them, the resets are epochs (0
#                               when cswap gives no resetsAt). <key> names the
#                               active account in a hint file name:
#                               <email>-<organizationUuid or "personal">, each
#                               part with [^A-Za-z0-9._@+-] turned into _, or -
#                               when the account has no email. <m5>/<m7> are 1
#                               when the --stdin-resets value for that window
#                               and cswap's reset are both non-zero and within
#                               RATE_LIMIT_HINT_TOLERANCE_SEC, else 0.
#   lastgood <age_s> <pct5> <resets5> <pct7> <resets7>
#                               same fields, but from cswap's lastGoodUsage: the
#                               active account's usageStatus isn't ok (say
#                               token_expired) so cswap has no usage for it, yet
#                               it still holds that account's own last numbers
#   usage none                  no active account, or nothing to show: usageStatus
#                               ok without usage/usageAgeSeconds, not ok without
#                               a usable lastGoodUsage + lastGoodAgeSeconds, or
#                               cswap failed (any error:*)
# Without the flag only the first line is printed, exactly as before.
#
# --with-usage may be followed by --stdin-resets <r5> <r7>: Claude Code's own
# resets_at (epoch seconds) for the 5-hour and 7-day windows. Anything that is
# not all digits counts as 0. Without it <m5> and <m7> are 0.
#
# A window is "exhausted" while pct >= its own threshold (the 5-hour and 7-day
# windows have separate ones below) and the clock is
# before resetsAt + RATE_LIMIT_RESUME_BUFFER_SEC. cswap polls exhausted
# accounts only about every ten minutes, so right after a reset it can still
# report the old pct with a resetsAt already in the past ("reset in 0m"). The
# buffer keeps that stale data from being trusted for a bit longer, and once
# it has run out the window counts as cleared whatever the stale pct says.
set -u

with_usage=0
stdin_r5=0
stdin_r7=0
if [ "${1:-}" = "--with-usage" ]; then
  with_usage=1
  if [ "${2:-}" = "--stdin-resets" ]; then
    # digits only (at most 15, so jq numbers stay exact), else 0; 10# drops leading zeros
    [[ "${3:-}" =~ ^[0-9]{1,15}$ ]] && stdin_r5=$((10#$3))
    [[ "${4:-}" =~ ^[0-9]{1,15}$ ]] && stdin_r7=$((10#$4))
  fi
fi

# Prints the answer ($1), plus the usage line ($2, default "usage none") in
# --with-usage mode. Every exit goes through here so no path forgets line 2.
emit() {
  printf '%s' "$1"
  if [ "$with_usage" = 1 ]; then printf '\n%s' "${2:-usage none}"; fi
}

# A rate-limit window at or above its percentage counts as "exhausted".
RATE_LIMIT_GATE_PCT_5H=97
RATE_LIMIT_GATE_PCT_7D=99

# Extra seconds to treat a window as exhausted after its resetsAt, so we don't
# resume the instant the reset lands (usage data may lag behind the reset).
RATE_LIMIT_RESUME_BUFFER_SEC=120

# Claude Code's resets_at and cswap's resetsAt count as the same window when
# they differ by at most this many seconds (cswap's carries fractions, and it
# is unknown whether Claude Code rounds or truncates).
RATE_LIMIT_HINT_TOLERANCE_SEC=3

cswap=""
if command -v cswap >/dev/null 2>&1; then cswap=cswap
elif [ -x "$HOME/.local/bin/cswap" ]; then cswap="$HOME/.local/bin/cswap"
fi
[ -n "$cswap" ] || { emit 'error:cswap_not_found'; exit 0; }
json="$("$cswap" list --json 2>/dev/null)" || { emit 'error:cswap_list_failed'; exit 0; }
now="$(date +%s)"

# Hint files: statusline.sh writes Claude Code's own numbers for the account in
# use to <hint dir>/usage-<key> (see "usage" above for <key>) while a session is
# mid-turn, as "<pct5> <resets5> <pct7> <resets7>". They are collected into
# {"<key>": [pct5, resets5, pct7, resets7], ...}; a file that is missing,
# unreadable, vanishes meanwhile or isn't exactly that shape is skipped, which
# means "no hint". HWAP_HINT_DIR is only a test seam.
hint_dir="${HWAP_HINT_DIR:-/tmp/claude-$UID}"
hints_json='{}'
if [ -d "$hint_dir" ]; then
  hint_sep=""
  hints_body=""
  for hint_file in "$hint_dir"/usage-*; do
    [ -f "$hint_file" ] || continue
    hint_key="${hint_file##*/usage-}"
    [[ "$hint_key" =~ ^[A-Za-z0-9._@+-]+$ ]] || continue
    hint_content="$(cat "$hint_file" 2>/dev/null)" || continue
    [[ "$hint_content" =~ ^(0|[1-9][0-9]*)(\.[0-9]+)?\ [0-9]{1,15}\ (0|[1-9][0-9]*)(\.[0-9]+)?\ [0-9]{1,15}$ ]] || continue
    read -r hint_p5 hint_r5 hint_p7 hint_r7 <<< "$hint_content"
    hints_body="$hints_body$hint_sep\"$hint_key\":[$hint_p5,$((10#$hint_r5)),$hint_p7,$((10#$hint_r7))]"
    hint_sep=","
  done
  hints_json="{$hints_body}"
fi

# jq: the hint file key of an account (same rule as the Python key() below).
JQ_KEY_DEFS='
  def clean: gsub("[^A-Za-z0-9._@+-]"; "_");
  def key($a):
    if ($a.email // "") == "" then "-"
    else "\($a.email | clean)-\(if ($a.organizationUuid // "") == "" then "personal" else ($a.organizationUuid | clean) end)" end;
'

out=""
if command -v jq >/dev/null 2>&1; then
  out="$(printf '%s' "$json" | jq -r \
    --argjson hints "$hints_json" --argjson tol "$RATE_LIMIT_HINT_TOLERANCE_SEC" \
    --argjson thr5 "$RATE_LIMIT_GATE_PCT_5H" --argjson thr7 "$RATE_LIMIT_GATE_PCT_7D" --argjson buf "$RATE_LIMIT_RESUME_BUFFER_SEC" --argjson now "$now" '
    def ts: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
    def rst($k): (.usage // {})[$k].resetsAt | if . == null then null else ts end;
    '"$JQ_KEY_DEFS"'
    # The cswap pct, raised to the hint file pct when the account is ok and the
    # hint reset time is the same window (within the tolerance). Never lowers.
    def pct($k):
      ((.usage // {})[$k].pct // 0) as $c
      | if .usageStatus == "ok" and ($hints[key(.)] != null) then
          $hints[key(.)] as $h
          | (if $k == "fiveHour" then [$h[0], $h[1]] else [$h[2], $h[3]] end) as [$hp, $hr]
          | rst($k) as $cr
          | if $hr != 0 and $cr != null and $cr != 0 and (($hr - $cr) | fabs) <= $tol then ([$c, $hp] | max) else $c end
        else $c end;
    def thr($k): if $k == "fiveHour" then $thr5 else $thr7 end;
    def exhausted($k): pct($k) >= thr($k) and (rst($k) == null or rst($k) + $buf > $now);
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
  [ -n "$py" ] || { emit 'error:no_json_parser'; exit 0; }
  out="$(HWAP_JSON="$json" HWAP_HINTS="$hints_json" HWAP_TOL="$RATE_LIMIT_HINT_TOLERANCE_SEC" HWAP_THR_5H="$RATE_LIMIT_GATE_PCT_5H" HWAP_THR_7D="$RATE_LIMIT_GATE_PCT_7D" HWAP_BUF="$RATE_LIMIT_RESUME_BUFFER_SEC" HWAP_NOW="$now" \
    "$py" - <<'PYEOF' 2>/dev/null
import json, os, re
from datetime import datetime

d = json.loads(os.environ['HWAP_JSON'])
thr = {'fiveHour': float(os.environ['HWAP_THR_5H']), 'sevenDay': float(os.environ['HWAP_THR_7D'])}
buf = int(os.environ['HWAP_BUF'])
now = int(os.environ['HWAP_NOW'])
tol = int(os.environ['HWAP_TOL'])
hints = json.loads(os.environ['HWAP_HINTS'])

def clean(x):
    return re.sub(r'[^A-Za-z0-9._@+-]', '_', x)

# Same rule as the jq key() and the key() of the usage line below: keep in sync.
def key(a):
    if not a.get('email'):
        return '-'
    return '%s-%s' % (clean(a['email']), clean(a['organizationUuid']) if a.get('organizationUuid') else 'personal')

def ts(s):
    return int(datetime.fromisoformat(re.sub(r'\.\d+', '', s).replace('Z', '+00:00')).timestamp())

def win(a, k):
    return (a.get('usage') or {}).get(k) or {}

def rst(a, k):
    r = win(a, k).get('resetsAt')
    return ts(r) if r else None

# cswap's pct, raised to the hint file's pct when the account is ok and the
# hint's reset time is the same window's (within the tolerance). Never lowers.
def pct(a, k):
    c = win(a, k).get('pct') or 0
    h = hints.get(key(a)) if a.get('usageStatus') == 'ok' else None
    if h is None:
        return c
    hp, hr = (h[0], h[1]) if k == 'fiveHour' else (h[2], h[3])
    cr = rst(a, k)
    if hr != 0 and cr and abs(hr - cr) <= tol:
        return max(c, hp)
    return c

def exhausted(a, k):
    if pct(a, k) < thr[k]:
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
  emit 'error:cswap_output_unparsable'
  exit 0
fi

usage_line="usage none"
if [ "$with_usage" = 1 ]; then
  if command -v jq >/dev/null 2>&1; then
    usage_line="$(printf '%s' "$json" | jq -r \
      --argjson tol "$RATE_LIMIT_HINT_TOLERANCE_SEC" --argjson sr5 "$stdin_r5" --argjson sr7 "$stdin_r7" '
      def ts: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
      def rst($u; $k): ($u[$k] // {}).resetsAt | if . == null then 0 else ts end;
      def line($tag; $u; $age):
        "\($tag) \($age | floor) \($u.fiveHour.pct // 0) \(rst($u; "fiveHour")) \($u.sevenDay.pct // 0) \(rst($u; "sevenDay"))";
      '"$JQ_KEY_DEFS"'
      def flag($s; $c): if $s != 0 and $c != 0 and (($s - $c) | fabs) <= $tol then 1 else 0 end;
      ((.accounts // []) | map(select(.active == true)) | .[0]) as $a
      | if $a == null then "usage none"
        elif $a.usageStatus == "ok" then
          if $a.usage == null or $a.usage == {} or $a.usageAgeSeconds == null then "usage none"
          else line("usage"; $a.usage; $a.usageAgeSeconds)
               + " \(key($a)) \(flag($sr5; rst($a.usage; "fiveHour"))) \(flag($sr7; rst($a.usage; "sevenDay")))" end
        elif ($a.lastGoodUsage | type) == "object" and $a.lastGoodUsage != {} and $a.lastGoodAgeSeconds != null
        then line("lastgood"; $a.lastGoodUsage; $a.lastGoodAgeSeconds)
        else "usage none" end
    ' 2>/dev/null)" || usage_line="usage none"
  else
    usage_line="$(HWAP_JSON="$json" HWAP_TOL="$RATE_LIMIT_HINT_TOLERANCE_SEC" HWAP_SR5="$stdin_r5" HWAP_SR7="$stdin_r7" "$py" - <<'PYEOF' 2>/dev/null
import json, os, re
from datetime import datetime

def ts(s):
    return int(datetime.fromisoformat(re.sub(r'\.\d+', '', s).replace('Z', '+00:00')).timestamp())

def line(tag, u, age):
    def win(k):
        return u.get(k) or {}
    def rst(k):
        r = win(k).get('resetsAt')
        return ts(r) if r else 0
    return '%s %d %s %d %s %d' % (tag, int(age), win('fiveHour').get('pct') or 0, rst('fiveHour'), win('sevenDay').get('pct') or 0, rst('sevenDay'))

def clean(x):
    return re.sub(r'[^A-Za-z0-9._@+-]', '_', x)

def key(a):
    if not a.get('email'):
        return '-'
    return '%s-%s' % (clean(a['email']), clean(a['organizationUuid']) if a.get('organizationUuid') else 'personal')

def flag(s, c):
    return 1 if s != 0 and c != 0 and abs(s - c) <= tol else 0

tol = int(os.environ['HWAP_TOL'])
sr5 = int(os.environ['HWAP_SR5'])
sr7 = int(os.environ['HWAP_SR7'])
d = json.loads(os.environ['HWAP_JSON'])
a = next((x for x in (d.get('accounts') or []) if x.get('active') is True), None)
if a is None:
    print('usage none', end='')
elif a.get('usageStatus') == 'ok':
    if not a.get('usage') or a.get('usageAgeSeconds') is None:
        print('usage none', end='')
    else:
        u = a['usage']
        def r(k):
            x = (u.get(k) or {}).get('resetsAt')
            return ts(x) if x else 0
        print('%s %s %d %d' % (line('usage', u, a['usageAgeSeconds']), key(a), flag(sr5, r('fiveHour')), flag(sr7, r('sevenDay'))), end='')
elif isinstance(a.get('lastGoodUsage'), dict) and a['lastGoodUsage'] and a.get('lastGoodAgeSeconds') is not None:
    print(line('lastgood', a['lastGoodUsage'], a['lastGoodAgeSeconds']), end='')
else:
    print('usage none', end='')
PYEOF
)" || usage_line="usage none"
  fi
fi
emit "$out" "$usage_line"
