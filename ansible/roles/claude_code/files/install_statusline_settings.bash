#!/usr/bin/env bash
# Claude statusline renderer installer.
# Modify the fields after the "Edit fields below" line.
#
# Exit codes: 0 = settings.json changed, 10 = already correct (no change
# needed, no backup written), anything else = failure.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SL="${CLAUDE_STATUSLINE_PATH:-${CLAUDE_DIR}/statusline.sh}"

__banner() {
  local color="$1"
  local msg="$2"
  printf '\n\033[%sm' "$color"
  cat <<'BANNER_EOF'
      _        _             _ _                  _
  ___| |_ __ _| |_ _   _ ___| (_)_ __   ___   ___| |__
 / __| __/ _` | __| | | / __| | | '_ \ / _ \ / __| '_ \
 \__ \ || (_| | |_| |_| \__ \ | | | | |  __/_\__ \ | | |
 |___/\__\__,_|\__|\__,_|___/_|_|_| |_|\___(_)___/_| |_|
BANNER_EOF
  printf '\033[0m\n\033[%sm  %s\033[0m\n\n' "$color" "$msg"
}

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

__offer_self_heal() {
  local err_msg="$1"
  if [ "${STATUSLINE_SELFHEAL:-0}" = "1" ] && command -v claude >/dev/null 2>&1; then
    echo "STATUSLINE_SELFHEAL=1 — invoking 'claude' to repair settings.json" >&2
    local snippet prompt
    snippet="$(head -c 4096 "$SETTINGS" 2>/dev/null || printf '')"
    prompt="$(cat <<PROMPT_EOF
Fix my settings.json at $SETTINGS so it has a top-level statusLine={type:'command',command:'$SL'} while preserving every other key. Current contents:
\`\`\`
$snippet
\`\`\`
Error: $err_msg
PROMPT_EOF
)"
    claude -p "$prompt" || true
    return 0
  fi
  echo "" >&2
  echo "Could not merge settings.json automatically." >&2
  echo "Install 'jq' (brew install jq / apt-get install jq) or python3 and re-run." >&2
  echo "Or set STATUSLINE_SELFHEAL=1 and ensure 'claude' is on PATH to auto-repair." >&2
  echo "Your previous settings.json is backed up at $SETTINGS.bak.*" >&2
  return 1
}

__merge_with_jq() {
  local tmp
  tmp="$(mktemp)"
  # Called from an `&&` list, where set -e is off, so a failure must be
  # checked by hand or an empty $tmp would replace settings.json.
  jq --arg cmd "$SL" '. + { statusLine: { type:"command", command:$cmd, refreshInterval:1 } }' "$SETTINGS" > "$tmp" ||
    { rm -f "$tmp"; return 1; }
  __commit_if_changed "$tmp"
}

__merge_with_python() {
  local py="$1" tmp
  tmp="$(mktemp)"
  STATUSLINE_PATH="$SL" SETTINGS_PATH="$SETTINGS" MERGED_PATH="$tmp" "$py" - <<'PYEOF' || { rm -f "$tmp"; return 1; }
import json, os, sys
p = os.environ['SETTINGS_PATH']
sl = os.environ['STATUSLINE_PATH']
try:
    with open(p, 'r', encoding='utf-8') as f:
        d = json.load(f)
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
d['statusLine'] = {'type': 'command', 'command': sl, 'refreshInterval': 1}
with open(os.environ['MERGED_PATH'], 'w', encoding='utf-8') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
PYEOF
  __commit_if_changed "$tmp"
}

# A backend's exit status is 0 (changed) or 10 (already correct) when it
# worked, so the next backend is only tried after a real failure.
__merge_ok=0
__merge_rc=1
if [ "$__merge_ok" = "0" ] && command -v jq >/dev/null 2>&1; then
  __merge_with_jq 2>/dev/null && __merge_rc=0 || __merge_rc=$?
  case "$__merge_rc" in 0|10) __merge_ok=1 ;; esac
fi
if [ "$__merge_ok" = "0" ] && command -v python3 >/dev/null 2>&1; then
  __merge_with_python python3 2>/dev/null && __merge_rc=0 || __merge_rc=$?
  case "$__merge_rc" in 0|10) __merge_ok=1 ;; esac
fi
if [ "$__merge_ok" = "0" ] && command -v python >/dev/null 2>&1; then
  __merge_with_python python 2>/dev/null && __merge_rc=0 || __merge_rc=$?
  case "$__merge_rc" in 0|10) __merge_ok=1 ;; esac
fi
if [ "$__merge_ok" = "0" ]; then
  if __offer_self_heal "all JSON merge backends failed (need jq or python)"; then
    __banner 33 "installed with errors — restart Claude Code to verify"
    exit 0
  fi
  __banner 31 "error: install failed"
  exit 1
fi

if [ "$__merge_rc" -eq 10 ]; then
  __banner 32 "statusLine already configured, nothing to change"
  exit 10
fi
__banner 32 "installed successfully — restart Claude Code to see it"
exit 0
