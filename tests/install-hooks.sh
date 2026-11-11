#!/usr/bin/env bash
# install_hooks.bash must be idempotent: re-registering the same hooks reports
# "no change" (exit 10) and leaves settings.json alone, even when another
# script registered hooks on the same events (#16). Run against both merge
# backends: jq, and python3 on a PATH without jq.
source "$(dirname "${BASH_SOURCE[0]}")/lib/isolation.sh"
source "$TESTS_DIR/lib/rows.sh"
trap 'rm -rf "$ISO"' EXIT

INSTALL="$TESTS_DIR/../ansible/roles/claude_code/files/install_hooks.bash"
SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"

# A PATH with python3 but no jq, so install_hooks.bash falls back to python.
NOJQ="$ISO/nojq-bin"
mkdir -p "$NOJQ"
for c in bash cat cp mv rm mkdir mktemp date python3 env dirname; do
  ln -s "$(command -v "$c")" "$NOJQ/$c"
done
iso_guard "$TESTS_DIR/fakes:$NOJQ" "$NOJQ"

# reg <backend> <script> <event-spec>...: register, print the exit code.
reg() {
  local backend="$1"; shift
  if [ "$backend" = python ]; then
    PATH="$TESTS_DIR/fakes:$NOJQ" bash "$INSTALL" "$@" >/dev/null 2>&1
  else
    bash "$INSTALL" "$@" >/dev/null 2>&1
  fi
  echo $?
}
hwap() { reg "$1" /h/hwap.sh PreToolUse:691200 UserPromptSubmit:691200 Stop; }
ic()   { reg "$1" /h/ic.sh PostToolUse Stop PostCompact:691200 UserPromptSubmit; }
commands() { jq -c "[.hooks.$1[].hooks[0].command]" "$SETTINGS"; }

for b in jq python; do
  rm -rf "${CLAUDE_CONFIG_DIR:?}"/*

  rc="$(hwap $b)"; [ "$rc" = 0 ] && pass "$b" "first registration changes settings.json" || bad "$b" "first registration" "rc=$rc"
  [ "$(cat "$SETTINGS.bak" 2>/dev/null)" = '{}' ] && pass "$b" "rewrite backs up the old file to settings.json.bak" || bad "$b" "first backup" "$(cat "$SETTINGS.bak" 2>&1)"
  rc="$(hwap $b)"; [ "$rc" = 10 ] && pass "$b" "same registration again is a no-op" || bad "$b" "same registration again" "rc=$rc"

  # Two scripts sharing Stop and UserPromptSubmit must both settle.
  ic "$b" >/dev/null
  before="$(cat "$SETTINGS")"; bak="$(cat "$SETTINGS.bak")"
  rc1="$(hwap $b)"; rc2="$(ic $b)"
  [ "$rc1/$rc2" = "10/10" ] && pass "$b" "scripts sharing events both settle" || bad "$b" "scripts sharing events" "hwap rc=$rc1 ic rc=$rc2"
  [ "$(cat "$SETTINGS")" = "$before" ] && pass "$b" "settled run leaves the file byte-identical" || bad "$b" "settled run" "file rewritten"
  [ "$(cat "$SETTINGS.bak")" = "$bak" ] && pass "$b" "settled run leaves the backup alone" || bad "$b" "settled run backup" "rewritten"

  # An entry someone else appended after ours (RTK does this on PreToolUse).
  jq '.hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}]' \
    "$SETTINGS" > "$ISO/s" && mv "$ISO/s" "$SETTINGS"
  rc="$(hwap $b)"
  [ "$rc" = 10 ] && pass "$b" "foreign entry after ours is not a change" || bad "$b" "foreign entry after ours" "rc=$rc"
  [ "$(commands PreToolUse)" = '["/h/hwap.sh","rtk hook claude"]' ] \
    && pass "$b" "foreign entry keeps its place" || bad "$b" "foreign entry order" "$(commands PreToolUse)"

  # Same content, different formatting (another writer re-serialized it).
  jq -c . "$SETTINGS" > "$ISO/s" && mv "$ISO/s" "$SETTINGS"
  compact="$(cat "$SETTINGS")"
  rc="$(hwap $b)"
  [ "$rc" = 10 ] && pass "$b" "formatting-only difference is not a change" || bad "$b" "formatting-only difference" "rc=$rc"
  [ "$(cat "$SETTINGS")" = "$compact" ] && pass "$b" "formatting-only difference leaves the file alone" || bad "$b" "formatting-only file" "rewritten"

  # A real change updates our entry where it stands.
  rc="$(reg $b /h/hwap.sh PreToolUse:60 UserPromptSubmit:691200 Stop)"
  [ "$rc" = 0 ] && pass "$b" "changed timeout is a change" || bad "$b" "changed timeout" "rc=$rc"
  [ "$(jq -c '[.hooks.PreToolUse[].hooks[0] | [.command, .timeout]]' "$SETTINGS")" = '[["/h/hwap.sh",60],["rtk hook claude",null]]' ] \
    && pass "$b" "changed entry is updated in place" || bad "$b" "changed entry" "$(jq -c '.hooks.PreToolUse' "$SETTINGS")"
  [ "$(commands Stop)" = '["/h/hwap.sh","/h/ic.sh"]' ] \
    && pass "$b" "other events keep their order" || bad "$b" "other events order" "$(commands Stop)"

  # Duplicated entries of our own collapse into one, at the first one's place.
  jq '.hooks.Stop += [{"hooks":[{"type":"command","command":"/h/hwap.sh"}]}]' \
    "$SETTINGS" > "$ISO/s" && mv "$ISO/s" "$SETTINGS"
  before="$(cat "$SETTINGS")"
  rc="$(reg $b /h/hwap.sh PreToolUse:60 UserPromptSubmit:691200 Stop)"
  [ "$rc" = 0 ] && [ "$(commands Stop)" = '["/h/hwap.sh","/h/ic.sh"]' ] \
    && pass "$b" "duplicate own entries collapse in place" || bad "$b" "duplicate own entries" "rc=$rc $(commands Stop)"
  [ "$(cat "$SETTINGS.bak")" = "$before" ] && pass "$b" "backup holds the file as it was before the latest rewrite" || bad "$b" "latest backup" "stale"

  # Every rewrite reuses the one backup file.
  n="$(find "$CLAUDE_CONFIG_DIR" -name 'settings.json.bak*' | wc -l)"
  [ "$n" = 1 ] && pass "$b" "only settings.json.bak is kept" || bad "$b" "backup files" "$n"
done

exit $fail
