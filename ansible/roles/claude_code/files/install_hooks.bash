#!/usr/bin/env bash
# Registers a hook script in settings.json's "hooks" key.
#
# Usage: install_hooks.bash <hook-script> <Event>[:<timeout-seconds>]...
#   e.g. install_hooks.bash ~/.claude/hooks/foo.sh PreToolUse:600 Stop
#
# Each <Event> gets one entry running <hook-script>. Entries already running
# the same <hook-script> are replaced, so re-running is idempotent and several
# hook scripts can be registered by separate invocations without touching
# each other's (or anyone else's) entries.
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
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

# Replaces $SETTINGS with the merged file $1, keeping a timestamped backup of
# the old one. Does nothing (and returns 10) when the content is identical.
__commit_if_changed() {
  local merged="$1" before after
  before="$(cat "$SETTINGS")"
  after="$(cat "$merged")"
  if [ "$before" = "$after" ]; then
    rm -f "$merged"
    return 10
  fi
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
  mv "$merged" "$SETTINGS"
  return 0
}

__merge_with_jq() {
  local tmp
  tmp="$(mktemp)"
  jq --arg script "$HOOK_SCRIPT" '
    def upsert_hook(event; extra):
      .hooks[event] = (
        ((.hooks[event] // []) | map(select(.hooks[0].command != $script)))
        + [ { "hooks": [ ( { "type": "command", "command": $script } + extra ) ] } ]
      );
    reduce $ARGS.positional[] as $spec (.;
      ($spec | split(":")) as $p
      | upsert_hook($p[0]; if $p[1] then {"timeout": ($p[1] | tonumber)} else {} end)
    )
  ' "$SETTINGS" --args "${EVENT_SPECS[@]}" > "$tmp"
  __commit_if_changed "$tmp"
}

__merge_with_python() {
  local py="$1" tmp
  tmp="$(mktemp)"
  HOOK_SCRIPT="$HOOK_SCRIPT" SETTINGS_PATH="$SETTINGS" OUT_PATH="$tmp" "$py" - "${EVENT_SPECS[@]}" <<'PYEOF'
import json, os, sys

settings_path = os.environ['SETTINGS_PATH']
script = os.environ['HOOK_SCRIPT']

try:
    with open(settings_path, 'r', encoding='utf-8') as f:
        d = json.load(f)
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}

hooks = d.setdefault('hooks', {})


def upsert_hook(event, extra):
    existing = [h for h in hooks.get(event, []) if h.get('hooks', [{}])[0].get('command') != script]
    entry = {'type': 'command', 'command': script}
    entry.update(extra)
    existing.append({'hooks': [entry]})
    hooks[event] = existing


for spec in sys.argv[1:]:
    event, _, timeout = spec.partition(':')
    upsert_hook(event, {'timeout': int(timeout)} if timeout else {})

with open(os.environ['OUT_PATH'], 'w', encoding='utf-8') as f:
    json.dump(d, f, indent=2)
PYEOF
  __commit_if_changed "$tmp"
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
