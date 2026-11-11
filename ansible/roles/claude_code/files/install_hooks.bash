#!/usr/bin/env bash
# Registers a hook script in settings.json's "hooks" key.
#
# Usage: install_hooks.bash <hook-script> <Event>[:<timeout-seconds>]...
#   e.g. install_hooks.bash ~/.claude/hooks/foo.sh PreToolUse:600 Stop
#
# Each <Event> gets one entry running <hook-script>. An entry already running
# the same <hook-script> is replaced where it stands (extra copies of it are
# dropped); otherwise the entry is appended. Updating in place, instead of
# moving our entry to the end, is what keeps re-runs idempotent when several
# hook scripts (or RTK) register on the same event: none of them reorders the
# others. Several hook scripts can be registered by separate invocations
# without touching each other's (or anyone else's) entries.
#
# settings.json is rewritten only when its parsed content changes, so another
# writer's formatting or key order is never reported as a change. A rewrite
# first copies the old file to settings.json.bak, overwriting the previous
# backup (RTK's `rtk init` uses the same name), so only the latest one is kept.
#
# Exit codes: 0 = settings.json changed, 10 = already correct (no change
# needed), anything else = failure.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <hook-script> <Event>[:<timeout-seconds>]..." >&2
  exit 2
fi
HOOK_SCRIPT="$1"
shift
EVENT_SPECS=("$@")

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p "$CLAUDE_DIR"
SETTINGS="$CLAUDE_DIR/settings.json"
[ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"

# Replaces $SETTINGS with the merged file $1, keeping the old one as the
# single backup $SETTINGS.bak.
__commit() {
  cp "$SETTINGS" "$SETTINGS.bak"
  mv "$1" "$SETTINGS"
}

__merge_with_jq() {
  local tmp
  tmp="$(mktemp)"
  jq --arg script "$HOOK_SCRIPT" '
    def upsert_hook(event; extra):
      { "hooks": [ ( { "type": "command", "command": $script } + extra ) ] } as $new
      | (.hooks[event] // []) as $list
      | ([ $list | to_entries[] | select(.value.hooks[0].command == $script) | .key ] | first) as $at
      | .hooks[event] = (
          if $at == null then $list + [ $new ]
          else [ $list | to_entries[]
                 | if .key == $at then $new
                   elif .value.hooks[0].command == $script then empty
                   else .value end ]
          end
        );
    reduce $ARGS.positional[] as $spec (.;
      ($spec | split(":")) as $p
      | upsert_hook($p[0]; if $p[1] then {"timeout": ($p[1] | tonumber)} else {} end)
    )
  ' "$SETTINGS" --args "${EVENT_SPECS[@]}" > "$tmp"
  # `==` on parsed values ignores formatting and object key order.
  if jq -e -n --slurpfile a "$SETTINGS" --slurpfile b "$tmp" '$a == $b' >/dev/null; then
    rm -f "$tmp"
    return 10
  fi
  __commit "$tmp"
}

# The python script exits 10 without writing OUT_PATH when nothing changed.
__merge_with_python() {
  local py="$1" tmp rc=0
  tmp="$(mktemp)"
  HOOK_SCRIPT="$HOOK_SCRIPT" SETTINGS_PATH="$SETTINGS" OUT_PATH="$tmp" "$py" - "${EVENT_SPECS[@]}" <<'PYEOF' || rc=$?
import copy, json, os, sys

settings_path = os.environ['SETTINGS_PATH']
script = os.environ['HOOK_SCRIPT']

try:
    with open(settings_path, 'r', encoding='utf-8') as f:
        d = json.load(f)
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
before = copy.deepcopy(d)

hooks = d.setdefault('hooks', {})


def runs_script(h):
    inner = h.get('hooks') if isinstance(h, dict) else None
    return bool(inner) and isinstance(inner[0], dict) and inner[0].get('command') == script


def upsert_hook(event, extra):
    entry = {'type': 'command', 'command': script}
    entry.update(extra)
    new = {'hooks': [entry]}
    result, placed = [], False
    for h in hooks.get(event, []):
        if not runs_script(h):
            result.append(h)
        elif not placed:
            result.append(new)
            placed = True
    if not placed:
        result.append(new)
    hooks[event] = result


for spec in sys.argv[1:]:
    event, _, timeout = spec.partition(':')
    upsert_hook(event, {'timeout': int(timeout)} if timeout else {})

# dict/list equality ignores formatting and object key order.
if d == before:
    sys.exit(10)
with open(os.environ['OUT_PATH'], 'w', encoding='utf-8') as f:
    json.dump(d, f, indent=2)
PYEOF
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    return "$rc"
  fi
  __commit "$tmp"
}

if command -v jq >/dev/null 2>&1; then
  __merge_with_jq
  exit $?
fi
if command -v python3 >/dev/null 2>&1; then
  __merge_with_python python3
  exit $?
fi
if command -v python >/dev/null 2>&1; then
  __merge_with_python python
  exit $?
fi

echo "Could not merge settings.json: need jq or python3/python on PATH." >&2
exit 1
