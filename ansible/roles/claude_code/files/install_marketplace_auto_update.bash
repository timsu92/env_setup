#!/usr/bin/env bash
# Turns on background auto-update for plugin marketplaces in settings.json.
#
# Usage: install_marketplace_auto_update.bash <marketplace>...
#
# Sets "autoUpdate": true on each named extraKnownMarketplaces entry that
# already exists. `claude plugin marketplace add` writes the entry, and has no
# flag for this. A name with no entry (the marketplace was never added) is
# left alone, because an entry with no "source" would break Claude Code.
#
# settings.json is rewritten only when its parsed content changes, so another
# writer's formatting or key order is never reported as a change. A rewrite
# first copies the old file to settings.json.bak, overwriting the previous
# backup (install_hooks.bash and RTK use the same name). A settings.json that
# isn't valid JSON is an error, never replaced. The file's content is never
# printed, because it can hold credentials.
#
# Exit codes: 0 = settings.json changed, 10 = already correct (no change
# needed, no marketplace named, or no settings.json yet), anything else =
# failure.
set -euo pipefail

# Nothing to turn on.
[ "$#" -gt 0 ] || exit 10

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
# Nothing has added a marketplace yet, so there is no entry to update.
[ -s "$SETTINGS" ] || exit 10

# Replaces $SETTINGS with the merged file $1, keeping the old one as the
# single backup $SETTINGS.bak with the same mode, because both can hold
# credentials. The new content is renamed over the file a symlinked
# settings.json points to, so the write is atomic and the symlink stays.
__commit() {
  local target staged
  target="$(readlink -f "$SETTINGS")"
  staged="$(mktemp "$target.XXXXXX")"
  cat "$1" > "$staged"
  rm -f "$1"
  chmod --reference="$target" "$staged"
  cp -p "$SETTINGS" "$SETTINGS.bak"
  mv "$staged" "$target"
}

__merge_with_jq() {
  local tmp
  tmp="$(mktemp)"
  jq '
    reduce $ARGS.positional[] as $name (.;
      if (.extraKnownMarketplaces[$name] | type) == "object"
      then .extraKnownMarketplaces[$name].autoUpdate = true
      else . end)
  ' "$SETTINGS" --args "$@" > "$tmp" || { rm -f "$tmp"; return 1; }
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
  shift
  tmp="$(mktemp)"
  SETTINGS_PATH="$SETTINGS" OUT_PATH="$tmp" "$py" - "$@" <<'PYEOF' || rc=$?
import copy, json, os, sys

with open(os.environ['SETTINGS_PATH'], 'r', encoding='utf-8') as f:
    d = json.load(f)
before = copy.deepcopy(d)

markets = d.get('extraKnownMarketplaces') if isinstance(d, dict) else None
for name in sys.argv[1:]:
    entry = markets.get(name) if isinstance(markets, dict) else None
    if isinstance(entry, dict):
        entry['autoUpdate'] = True

# dict/list equality ignores formatting and object key order.
if d == before:
    sys.exit(10)
with open(os.environ['OUT_PATH'], 'w', encoding='utf-8') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write('\n')
PYEOF
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    return "$rc"
  fi
  __commit "$tmp"
}

if command -v jq >/dev/null 2>&1; then
  __merge_with_jq "$@"
  exit $?
fi
if command -v python3 >/dev/null 2>&1; then
  __merge_with_python python3 "$@"
  exit $?
fi
if command -v python >/dev/null 2>&1; then
  __merge_with_python python "$@"
  exit $?
fi

echo "Could not update settings.json: need jq or python3/python on PATH." >&2
exit 1
