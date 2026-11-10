#!/usr/bin/env bash
# Tests for statusline.sh's ideal-compact budget line and the session hold file.
# ---- isolation header: a test must never reach the real session or account ----
unset TMUX TMUX_PANE STY WINDOW CLAUDECODE
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO="$(mktemp -d)"
mkdir -p "$ISO/tmp" "$ISO/home" "$ISO/claude" "$ISO/xdg" "$ISO/cswap" "$ISO/hints"
export IC_TMP_BASE="$ISO/tmp" IC_CLAUDE_PID=$$ HOME="$ISO/home" CLAUDE_CONFIG_DIR="$ISO/claude" \
  XDG_DATA_HOME="$ISO/xdg" HWAP_CSWAP_CONFIG_DIR="$ISO/cswap" HWAP_HINT_DIR="$ISO/hints"
export PATH="$TESTS_DIR/fakes:$PATH"
# iso_guard <PATH> [own stub dir...]: tmux, screen and cswap must resolve into
# tests/fakes (or one of the test's own stub dirs) under <PATH>, else abort.
iso_guard() {
  local c p ok d
  for c in tmux screen cswap; do
    p="$(PATH="$1" command -v "$c")"; ok=0
    [[ "$p" == "$TESTS_DIR"/fakes/* ]] && ok=1
    for d in "${@:2}"; do [[ "$p" == "$d"/* ]] && ok=1; done
    [ "$ok" = 1 ] || { echo "ISOLATION: '$c' resolves to '${p:-nothing}' under that PATH" >&2; exit 2; }
  done
}
iso_guard "$PATH"
# ---- end isolation header ----
FILES="$TESTS_DIR/../ansible/roles/claude_code/files"
BASH_BIN="$(command -v bash)"
T="$ISO/t"
mkdir -p "$T/deploy" "$T/nolib" "$T/ledger" "$T/cfg"
# A process whose environment holds no TMUX/STY: the "claude" that __ic_backend inspects.
env -i sleep 600 & BARE_PID=$!
# The fake tmux reports this shell (BARE_PID's parent) as the pane pid, so a
# tmux backend is seen as hosting claude.
export FAKE_PANE_PID=$$
trap 'kill "$BARE_PID" 2>/dev/null; rm -rf "$ISO"' EXIT

# Deployed-style layouts (repo files lack the exec bit).
for d in deploy nolib; do cp "$FILES/statusline.sh" "$T/$d/statusline.sh"; done
cp "$FILES/common-helpers.sh" "$T/deploy/common-helpers.sh"
# A stub helper: scripted answers per mode, every call logged by mode.
for d in deploy nolib; do
  cat > "$T/$d/hwap-helper.sh" <<'STUB'
#!/usr/bin/env bash
echo "${1:-default}" >> "$STUB_LOG"
case "${1:-}" in
  current)  printf '%s\n' "$STUB_CURRENT" ;;
  accounts) printf '%s\n' "$STUB_ACCOUNTS" ;;
  --with-usage) printf '%s\n%s' "$STUB_DECISION" "$STUB_USAGE" ;;
  *) printf '%s' "$STUB_DECISION" ;;
esac
STUB
  chmod +x "$T/$d/statusline.sh" "$T/$d/hwap-helper.sh"
done
echo '{"oauthAccount":{"emailAddress":"ic-test@example.invalid"}}' > "$T/cfg/.claude.json"
NOW="$(date +%s)"

# Plan with 4 tasks, ledger with 2 done, plan-path next to it.
PLAN="$T/ledger/plan.md"
printf '### Task 1: a\n### Task 2: b\n### Task 3: c\n### Task 4: d\n' > "$PLAN"
LEDGER="$T/ledger/progress.md"
printf 'Task 1: complete\nTask 2: complete\n' > "$LEDGER"
echo "$PLAN" > "$T/ledger/plan-path"
OLD="$T/old"; mkdir -p "$OLD"
printf 'Task 1: complete\nTask 2: complete\n' > "$OLD/progress.md"   # no plan-path, no header: plan unknown

PROJ="$IC_TMP_BASE/-sl-proj"
HIST="$PROJ/ideal-compact-history"
# hist <c5>: one history line for key k1 (fields: ts ledger done key p5 r5 p7 r7 dirty c5 c7 b5done b5pct b5r b7done b7pct b7r)
hist() { mkdir -p "$PROJ"; printf '%s\t%s\t1\tk1\t0\t0\t0\t0\t0\t%s\t-\t-\t-\t-\t-\t-\t-\n' "$NOW" "$LEDGER" "$1" > "$HIST"; }

fail=0; n=0
check() { if [ "$2" = 1 ]; then echo "PASS $1"; else echo "FAIL $1 -> $3"; fail=1; fi; }

SID=''; SDIR=''
new_session() { n=$((n+1)); SID="icsl-$$-$n"; SDIR="$PROJ/$SID"; mkdir -p "$SDIR"; rm -f "$HIST"; : > "$T/log"; }
state() { printf '%s\n' "$@" > "$SDIR/ideal-compact-state"; }
# render [deploy|nolib]: sets RAW, TXT, CALLS (helper modes, one per line)
render() {
  local dir="${1:-deploy}"
  RAW="$(printf '{"session_id":"%s","transcript_path":"%s/%s.jsonl","model":{"display_name":"M"},"workspace":{"current_dir":"%s"}}' \
      "$SID" "$ISO/projects/-sl-proj" "$SID" "$T" |
    env STATUSLINE_COLS=200 CLAUDE_CONFIG_DIR="$T/cfg" IC_CLAUDE_PID="$BARE_PID" ${BACKEND_ENV:-} \
        STUB_LOG="$T/log" STUB_DECISION=ok STUB_USAGE=none \
        STUB_CURRENT="${CURRENT:-usage k1 67 0 20 0 97 99 120 3}" STUB_ACCOUNTS="" \
        "$BASH_BIN" "$T/$dir/statusline.sh" 2>/dev/null)"
  TXT="$(printf '%s' "$RAW" | sed 's/\x1b\[[0-9;]*m//g')"
  SAME="$(printf '%s' "$TXT" | sed '1s/^[^ ]* //')"   # the first glyph is random
  CALLS="$(cat "$T/log")"
  LINE3="$(printf '%s' "$TXT" | sed -n 3p)"
}
WARN_SGR=$'\033[1;38;2;224;175;104m'
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
ok() { check "$1" 1; }
bad() { check "$1" 0 "$2"; }
line3_is() { [ "$LINE3" = "$2" ] && ok "$1" || bad "$1" "line3 '$LINE3' want '$2'"; }
line3_has() { has "$LINE3" "$2" && ok "$1" || bad "$1" "line3 '$LINE3' lacks '$2'"; }
line3_lacks() { has "$LINE3" "$2" && bad "$1" "line3 '$LINE3' has '$2'" || ok "$1"; }

# 1. No state: today's output, two lines, no helper calls beyond the usual one.
new_session; render
[ "$(printf '%s\n' "$TXT" | wc -l)" = 2 ] && ! has "$TXT" '📋' && ok "no state: two lines, no budget line" || bad "no state: two lines" "$TXT"
[ "$(grep -c '^current$\|^accounts$' <<<"$CALLS")" = 0 ] && ok "no state: no current/accounts call" || bad "no state: helper calls" "$CALLS"
BASE_RAW="$RAW"

# 2. State without a ledger: same as no state.
new_session; state phase=armed ledger=
render
[ "$(printf '%s\n' "$TXT" | wc -l)" = 2 ] && ok "no ledger: two lines" || bad "no ledger: two lines" "$TXT"
[ "$(grep -c '^current$\|^accounts$' <<<"$CALLS")" = 0 ] && ok "no ledger: no current/accounts call" || bad "no ledger: helper calls" "$CALLS"

# 3. A ledger path that is not readable: no line.
new_session; state phase=armed "ledger=$T/ledger/missing.md"
render
[ "$(printf '%s\n' "$TXT" | wc -l)" = 2 ] && ok "unreadable ledger: two lines" || bad "unreadable ledger: two lines" "$TXT"

# 4. 2 of 4 done, budget 5 -> warning colour; phase standby is not shown.
new_session; state phase=standby "ledger=$LEDGER"; hist 5.5
BACKEND_ENV="TMUX=$T/sock,1,0 TMUX_PANE=%1" render; BACKEND_ENV=''
line3_is "budget 5: text" '📋 2 left · budget 5'
has "$RAW" "$WARN_SGR" && ok "budget 5: warning colour" || bad "budget 5: warning colour" "no SGR 1;38;2;224;175;104"
[ "$(grep -c '^current$' <<<"$CALLS")" = 1 ] && [ "$(grep -c '^accounts$' <<<"$CALLS")" = 1 ] && ok "ledger: one current and one accounts call" || bad "helper calls" "$CALLS"

# 5. Budget 9: not the warning colour.
new_session; state phase=standby "ledger=$LEDGER"; hist 3.3
render
line3_is "budget 9: text" '📋 2 left · budget 9'
has "$RAW" "$WARN_SGR" && bad "budget 9: no warning colour" "SGR present" || ok "budget 9: no warning colour"

# 6. Old-style ledger: tasks left unknown.
new_session; state phase=standby "ledger=$OLD/progress.md"; hist 5.5
BACKEND_ENV="TMUX=$T/sock,1,0 TMUX_PANE=%1" render; BACKEND_ENV=''
line3_is "old-style ledger: ? left" '📋 ? left · budget 5'

# 7. Empty history: budget unknown, no warning colour.
new_session; state phase=standby "ledger=$LEDGER"
render
line3_is "no history: budget ?" '📋 2 left · budget ?'
has "$RAW" "$WARN_SGR" && bad "budget ?: no warning colour" "SGR present" || ok "budget ?: no warning colour"

# 8. Phase, skip, suppressed.
new_session; state phase=armed "ledger=$LEDGER"; hist 3.3
render; line3_is "armed phase" '📋 2 left · budget 9 [armed]'
new_session; state phase=armed skip=1 "ledger=$LEDGER"; hist 3.3
render; line3_is "skip" '📋 2 left · budget 9 [armed] skip'
new_session; state phase=standby suppress=1 "ledger=$LEDGER"; hist 3.3
render; line3_is "suppressed" '📋 2 left · budget 9 suppressed'

# 9. An expired to-compact shows no phase, and the state file is not touched.
new_session; state phase=to-compact "phase_at=$((NOW-1000))" "ledger=$LEDGER"; hist 3.3
BEFORE="$(cat "$SDIR/ideal-compact-state")"; BEFORE_M="$(stat -c %Y.%y "$SDIR/ideal-compact-state")"
render
line3_is "expired to-compact: no phase" '📋 2 left · budget 9'
[ "$(cat "$SDIR/ideal-compact-state")" = "$BEFORE" ] && [ "$(stat -c %Y.%y "$SDIR/ideal-compact-state")" = "$BEFORE_M" ] \
  && ok "expired to-compact: state file unchanged" || bad "state file unchanged" "changed"
new_session; state phase=to-compact "phase_at=$((NOW-5))" "ledger=$LEDGER"; hist 3.3
render; line3_is "fresh to-compact is shown" '📋 2 left · budget 9 [to-compact]'

# 10. No backend: the text appears with budget <= 6 only.
new_session; state phase=armed "ledger=$LEDGER"; hist 5.5
render; line3_is "budget 5, no backend" '📋 2 left · budget 5 [armed] · no auto-compact: no tmux/screen'
new_session; state phase=armed "ledger=$LEDGER"; hist 3.3
render; line3_lacks "budget 9, no backend: no such text" 'no auto-compact'
new_session; state phase=armed "ledger=$LEDGER"; hist 5.5
BACKEND_ENV="TMUX=$T/sock,1,0 TMUX_PANE=%1" render; BACKEND_ENV=''
line3_lacks "budget 5, tmux: no such text" 'no auto-compact'
new_session; state phase=armed "ledger=$LEDGER"
render; line3_lacks "budget ?, no backend: no such text" 'no auto-compact'

# 11. Input box check failed.
new_session; state phase=armed inputbox_fail=1 "ledger=$LEDGER"; hist 3.3
render; line3_is "inputbox_fail" '📋 2 left · budget 9 [armed] · input box check failed'

# 12. A garbage state file renders and exits 0.
new_session; printf '\377\000garbage\nphase=bogus\nledger\n=\n' > "$SDIR/ideal-compact-state"
RAW="$(printf '{"session_id":"%s","transcript_path":"%s/%s.jsonl","model":{"display_name":"M"}}' "$SID" "$ISO/projects/-sl-proj" "$SID" |
  env STATUSLINE_COLS=200 CLAUDE_CONFIG_DIR="$T/cfg" IC_CLAUDE_PID="$BARE_PID" STUB_LOG="$T/log" STUB_DECISION=ok STUB_USAGE=none \
      STUB_CURRENT="usage k1 67 0 20 0 97 99 120 3" STUB_ACCOUNTS="" "$BASH_BIN" "$T/deploy/statusline.sh" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && has "$RAW" 'M' && ok "garbage state: renders, exit 0" || bad "garbage state" "rc=$rc"
[ "$(printf '%s\n' "$RAW" | wc -l)" = 2 ] && ok "garbage state: no budget line" || bad "garbage state lines" "$RAW"

# 13. Without the library the output is today's, even with a ledger in the state.
new_session; state phase=armed "ledger=$LEDGER"; hist 5.5
render nolib; NOLIB_TXT="$TXT"; NOLIB_SAME="$SAME"
[ "$(printf '%s\n' "$NOLIB_TXT" | wc -l)" = 2 ] && ! has "$NOLIB_TXT" '📋' && ok "no library: two lines, no budget line" || bad "no library" "$NOLIB_TXT"
new_session; render nolib
[ "$SAME" = "$NOLIB_SAME" ] && ok "no library: same output with or without a state" || bad "no library: same output" "differs"
new_session; render
[ "$SAME" = "$NOLIB_SAME" ] && ok "no state: same text as without the library" || bad "no state vs no library" "$TXT vs $NOLIB_TXT"

# 14. The session's checkpoint-hold-until is read when the helper does not say wait.
new_session; echo $((NOW+640)) > "$SDIR/checkpoint-hold-until"
render
has "$TXT" 'Paused, resuming in 10m' && ok "session hold file: Paused, resuming in 10m" || bad "session hold file" "$TXT"
new_session; echo $((NOW-5)) > "$SDIR/checkpoint-hold-until"
render
has "$TXT" 'Paused' && bad "expired session hold file: no pause" "$TXT" || ok "expired session hold file: no pause"
# The global hold file is read from the IC_TMP_BASE seam and wins over the session's.
new_session; echo $((NOW+640)) > "$SDIR/checkpoint-hold-until"; echo $((NOW+3700)) > "$IC_TMP_BASE/hwap-hold-until"
render
has "$TXT" 'Paused, resuming in 1h' && ok "global hold file via IC_TMP_BASE wins" || bad "global hold file" "$TXT"
rm -f "$IC_TMP_BASE/hwap-hold-until"

exit $fail
