#!/usr/bin/env bash
# Registers high-watermark-auto-pause.sh in settings.json's "hooks" key.
#
# Exit codes: 0 = settings.json changed, 10 = already correct (no change
# needed), anything else = failure.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p "$CLAUDE_DIR"
HOOK_SCRIPT="$CLAUDE_DIR/hooks/high-watermark-auto-pause.sh"
SETTINGS="$CLAUDE_DIR/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"

# ~8 days: safely past the 7-day weekly-limit worst case plus the gate's
# own resume-time buffer.
HOOK_TIMEOUT=691200

__merge_with_jq() {
  local tmp before after
  before="$(cat "$SETTINGS")"
  tmp="$(mktemp)"
  jq --arg script "$HOOK_SCRIPT" --argjson timeout "$HOOK_TIMEOUT" '
    def upsert_hook(event; extra):
      .hooks[event] = (
        ((.hooks[event] // []) | map(select(.hooks[0].command != $script)))
        + [ { "hooks": [ ( { "type": "command", "command": $script } + extra ) ] } ]
      );
    upsert_hook("PreToolUse"; {"timeout": $timeout})
    | upsert_hook("UserPromptSubmit"; {"timeout": $timeout})
    | upsert_hook("Stop"; {})
  ' "$SETTINGS" > "$tmp"
  after="$(cat "$tmp")"
  mv "$tmp" "$SETTINGS"
  [ "$before" = "$after" ] && return 10
  return 0
}

__merge_with_python() {
  local py="$1" before after
  before="$(cat "$SETTINGS")"
  HOOK_SCRIPT="$HOOK_SCRIPT" HOOK_TIMEOUT="$HOOK_TIMEOUT" SETTINGS_PATH="$SETTINGS" "$py" - <<'PYEOF'
import json, os

settings_path = os.environ['SETTINGS_PATH']
script = os.environ['HOOK_SCRIPT']
timeout = int(os.environ['HOOK_TIMEOUT'])

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


upsert_hook('PreToolUse', {'timeout': timeout})
upsert_hook('UserPromptSubmit', {'timeout': timeout})
upsert_hook('Stop', {})

with open(settings_path, 'w', encoding='utf-8') as f:
    json.dump(d, f, indent=2)
PYEOF
  after="$(cat "$SETTINGS")"
  [ "$before" = "$after" ] && return 10
  return 0
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
echo "Your previous settings.json is backed up at $SETTINGS.bak.*" >&2
exit 1
