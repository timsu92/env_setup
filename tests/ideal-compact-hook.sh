#!/usr/bin/env bash
# Tests for hooks/ideal-compact.sh: SessionStart, UserPromptSubmit, PreCompact,
# phase timeouts and __ic_takeover. Usage: ideal-compact-hook.sh
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
SRC="$TESTS_DIR/../ansible/roles/claude_code/files"
T="$(mktemp -d)"
trap 'rm -rf "$T" "$ISO"' EXIT
export FAKE_LOG="$T/fake.log"

# Layout mirroring ~/.claude: <T>/common-helpers.sh, <T>/hwap-helper.sh (stub), <T>/hooks/ideal-compact.sh
mkdir -p "$T/hooks" "$T/cwd"
cp "$SRC/common-helpers.sh" "$T/common-helpers.sh"
cp "$SRC/hooks/ideal-compact.sh" "$T/hooks/ideal-compact.sh"
# The stub helper prints the scripted `current` / `accounts` text.
cat > "$T/hwap-helper.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  current) cat "$STUB_CURRENT" 2>/dev/null ;;
  accounts) cat "$STUB_ACCOUNTS" 2>/dev/null ;;
esac
exit 0
STUB
chmod +x "$T/hwap-helper.sh" "$T/hooks/ideal-compact.sh"
export STUB_CURRENT="$T/current" STUB_ACCOUNTS="$T/accounts"

fail=0
pass() { echo "PASS [$1] $2"; }
bad()  { echo "FAIL [$1] $2 -> $3"; fail=1; }

TP="$T/projects/-tmp-proj/sess1.jsonl"   # transcript_path: translated path -tmp-proj
SDIR="$IC_TMP_BASE/-tmp-proj/sess1"
HIST="$IC_TMP_BASE/-tmp-proj/ideal-compact-history"   # cwd is not in git: translated path
NOW=$(date +%s)

# set_state key=value...: a fresh state file: neutral defaults (phase_at is now, so no
# phase is overdue), then these keys (a later line wins when the file is read)
set_state() {
  rm -rf "$SDIR"; mkdir -p "$SDIR"
  printf '%s\n' phase=standby phase_at="$NOW" dirty=0 skip=0 suppress=0 "$@" > "$SDIR/ideal-compact-state"
}
# st <key>: value of a state key ('' when absent), the last line wins like in the reader
st() { sed -n "s/^$1=//p" "$SDIR/ideal-compact-state" 2>/dev/null | tail -n1; }
# send <json fields as jq --arg pairs>: runs the hook; sets RC; stdout/stderr in $T/out, $T/err
send() {
  local ev="$1"; shift
  jq -n --arg ev "$ev" --arg tp "$TP" --arg cwd "$T/cwd" "$@" \
    '{session_id: "sess1", transcript_path: $tp, cwd: $cwd, hook_event_name: $ev} + ($ARGS.named | del(.ev, .tp, .cwd))' \
    | "$T/hooks/ideal-compact.sh" >"$T/out" 2>"$T/err"
  RC=$?
}
# ck <name> <expected> <actual>
ck() { if [ "$2" = "$3" ]; then pass "$1" "$2"; else bad "$1" "$2" "got '$3'"; fi; }
# st_all <name> <expected "k=v k=v"> : compares the listed keys
st_all() {
  local name="$1" exp="$2" got='' kv
  for kv in $exp; do got+="${kv%%=*}=$(st "${kv%%=*}") "; done
  ck "$name" "$exp " "$got"
}
no_stdout() { ck "$1" "rc=0 out=" "rc=$RC out=$(cat "$T/out")"; }

printf 'usage KEY1 50 %s 20 %s 97 99 120 3\n' $((NOW + 9000)) $((NOW + 90000)) > "$T/current"
: > "$T/accounts"

# ---- SessionStart ----
for src in startup resume clear; do
  set_state phase=armed suppress=1 skip=1 ledger=x dirty=1 armed_key=K
  send SessionStart --arg source "$src"
  st_all "ss-$src" "phase=standby suppress=0 skip=0 ledger= dirty=1"
  no_stdout "ss-$src-quiet"
done
set_state phase=armed suppress=1 skip=1 ledger=x dirty=1
send SessionStart --arg source compact
st_all "ss-compact-unchanged" "phase=armed suppress=1 skip=1 ledger=x dirty=1"
set_state phase=standby
send SessionStart --arg source startup
[ -e "$SDIR/ideal-compact-state" ] && st_all "ss-clean-standby" "phase=standby dirty=0" || pass "ss-clean-standby" "no state"

# ---- UserPromptSubmit: dirty ----
for ph in standby armed waiting to-compact compacting continuing stopped; do
  set_state phase=$ph dirty=4
  send UserPromptSubmit --arg prompt "hello"
  ck "dirty-$ph" "5" "$(st dirty)"
done
set_state phase=standby
send UserPromptSubmit --arg prompt "hello"
ck "dirty-from-empty" "1" "$(st dirty)"

# ---- keyed 繼續 ----
set_state phase=continuing suppress=1 suppress_key=K dirty=0
send UserPromptSubmit --arg prompt "繼續"
st_all "continue-keyed" "phase=standby suppress=0"
ck "continue-keyed-nothing-out" "rc=0 out=" "rc=$RC out=$(cat "$T/out")"
set_state phase=armed dirty=0 armed_key=K armed_win=5h armed_resets=123
send UserPromptSubmit --arg prompt "繼續"
st_all "continue-typed-while-armed" "phase=standby suppress=1"

# ---- other prompt takeover ----
for ph in armed waiting to-compact compacting continuing stopped; do
  set_state phase=$ph skip=1 pending_inject=x
  send UserPromptSubmit --arg prompt "do something else"
  st_all "takeover-$ph" "phase=standby suppress=1 skip=0 pending_inject="
  no_stdout "takeover-$ph-quiet"
done
set_state phase=standby skip=1 suppress=0 dirty=2
send UserPromptSubmit --arg prompt "do something else"
st_all "standby-other" "phase=standby suppress=0 skip=1 dirty=3"

# ---- takeover fills suppress_* from current + budget, else armed_* ----
rm -f "$HIST"; mkdir -p "$(dirname "$HIST")"
printf '1\tL\t1\tKEY1\t10\t1\t10\t1\t0\t10\t-\t0\t0\t0\t0\t0\t0\n' > "$HIST"   # c5=10: budget (97-50)/10=4 on 5h
set_state phase=armed armed_key=ARMK armed_win=7d armed_resets=777
send UserPromptSubmit --arg prompt "x"
st_all "takeover-budget" "suppress=1 suppress_key=KEY1 suppress_win=5h suppress_resets=$((NOW + 9000))"
printf '1\tL\t1\tKEY1\t10\t1\t10\t1\t0\t-\t1\t0\t0\t0\t0\t0\t0\n' > "$HIST"   # c7=1: budget (99-20)/1=79 on 7d
set_state phase=armed armed_key=ARMK armed_win=5h armed_resets=777
send UserPromptSubmit --arg prompt "x"
st_all "takeover-budget-7d" "suppress_key=KEY1 suppress_win=7d suppress_resets=$((NOW + 90000))"
rm -f "$HIST"
set_state phase=armed armed_key=ARMK armed_win=7d armed_resets=777
send UserPromptSubmit --arg prompt "x"
st_all "takeover-unknown-budget" "suppress=1 suppress_key=ARMK suppress_win=7d suppress_resets=777"
printf 'error:cswap_failed\n' > "$T/current"
set_state phase=armed armed_key=ARMK armed_win=7d armed_resets=777
send UserPromptSubmit --arg prompt "x"
st_all "takeover-helper-error" "suppress_key=ARMK suppress_win=7d suppress_resets=777"
printf 'usage KEY1 50 %s 20 %s 97 99 120 3\n' $((NOW + 9000)) $((NOW + 90000)) > "$T/current"

# ---- __ic_takeover with a stale expected phase changes nothing ----
tk() {  # tk <expected> [arg]: runs the hook's __ic_takeover on the current state, prints its rc
  bash -c '
    . "$1/common-helpers.sh"; __IC_HELPER="$1/hwap-helper.sh"
    SDIR="$2" TPATH="$3" CWD="$4" LOCK="$2/ideal-compact-state.lock"
    eval "$(sed -n "/^__ic_takeover() {/,/^}/p" "$1/hooks/ideal-compact.sh")"
    __ic_takeover "${@:5}"; echo "rc=$?"' _ "$T" "$SDIR" "$TP" "$T/cwd" "$@"
}
set_state phase=armed dirty=2 armed_key=ARMK
ck "takeover-stale" "rc=1" "$(tk to-compact)"
st_all "takeover-stale-unchanged" "phase=armed suppress=0 dirty=2"
ck "takeover-nonstandby-in-standby" "rc=1" "$(set_state phase=standby; tk nonstandby)"
st_all "takeover-standby-unchanged" "phase=standby suppress=0"
set_state phase=waiting
ck "takeover-expected-ok" "rc=0" "$(tk waiting)"
st_all "takeover-expected-state" "phase=standby suppress=1 inputbox_fail=0"
set_state phase=to-compact
ck "takeover-inputbox-fail" "rc=0" "$(tk to-compact 1)"
st_all "takeover-inputbox-fail-state" "phase=standby suppress=1 inputbox_fail=1"

# ---- commands ----
for body in '/ideal-compact-skip' '/ideal-compact-skip now' 'text <!-- ideal-compact:skip --> more'; do
  set_state phase=stopped dirty=0
  send UserPromptSubmit --arg prompt "$body"
  st_all "skip-stopped [$body]" "phase=stopped skip=1 suppress=0 dirty=1"
done
set_state phase=standby skip=0
send UserPromptSubmit --arg prompt "/ideal-compact-skip"
st_all "skip-standby" "phase=standby skip=1"
set_state phase=armed
send UserPromptSubmit --arg prompt "/ideal-compact-skip"
st_all "skip-armed" "phase=armed skip=1"
for ph in armed stopped; do
  for body in '/ideal-compact-standby' 'x <!-- ideal-compact:standby -->'; do
    set_state phase=$ph skip=1 suppress=1 suppress_key=K suppress_win=5h suppress_resets=5
    send UserPromptSubmit --arg prompt "$body"
    st_all "standby-cmd-$ph [$body]" "phase=standby skip=0 suppress=0 suppress_key= suppress_win= suppress_resets=0"
  done
done
set_state phase=waiting skip=1 suppress=1
send UserPromptSubmit --arg prompt "/ideal-compact-standby"
st_all "standby-cmd-waiting" "phase=waiting skip=0 suppress=0"
set_state phase=standby skip=1 suppress=1
send UserPromptSubmit --arg prompt "/ideal-compact-standby"
st_all "standby-cmd-standby" "phase=standby skip=0 suppress=0"
set_state phase=armed
send UserPromptSubmit --arg prompt "/ideal-compact-standby"
no_stdout "standby-cmd-quiet"

# ---- background-agent hand-back ----
set_state phase=armed dirty=3 skip=1
send UserPromptSubmit --arg prompt $'<agent-message from="abc">\n[Subagent hand-back] done'
st_all "agent-message" "phase=armed dirty=3 skip=1 suppress=0"
no_stdout "agent-message-quiet"

# ---- PreCompact ----
set_state phase=to-compact dirty=0
send PreCompact --arg trigger manual
st_all "precompact-manual-to-compact" "phase=compacting dirty=1 suppress=0"
no_stdout "precompact-quiet"
set_state phase=to-compact dirty=0 armed_key=ARMK armed_win=5h armed_resets=9
rm -f "$HIST"; printf 'error:x\n' > "$T/current"
send PreCompact --arg trigger auto
st_all "precompact-auto-to-compact" "phase=standby suppress=1 dirty=1"
set_state phase=armed dirty=0
send PreCompact --arg trigger manual
st_all "precompact-manual-armed" "phase=standby suppress=1 dirty=1"
for ph in waiting continuing stopped compacting; do
  set_state phase=$ph dirty=0
  send PreCompact --arg trigger manual
  st_all "precompact-$ph" "phase=standby suppress=1 dirty=1"
done
set_state phase=standby dirty=5 suppress=0 skip=1
send PreCompact --arg trigger manual
st_all "precompact-standby" "phase=standby dirty=6 suppress=0 skip=1"
send PreCompact --arg trigger auto
ck "precompact-standby-auto" "7" "$(st dirty)"
printf 'usage KEY1 50 %s 20 %s 97 99 120 3\n' $((NOW + 9000)) $((NOW + 90000)) > "$T/current"

# ---- TTL before handling ----
for ev in SessionStart UserPromptSubmit PreCompact Stop PostToolUse Notification PostCompact; do
  set_state phase=to-compact phase_at=$((NOW - 121)) armed_key=ARMK armed_win=5h armed_resets=55
  case "$ev" in
    SessionStart) send "$ev" --arg source compact ;;
    UserPromptSubmit) send "$ev" --arg prompt "/ideal-compact-skip" ;;
    PreCompact) send "$ev" --arg trigger manual ;;
    *) send "$ev" ;;
  esac
  st_all "ttl-$ev" "phase=standby suppress=1 suppress_key=ARMK suppress_win=5h suppress_resets=55"
  no_stdout "ttl-$ev-quiet"
done
set_state phase=to-compact phase_at=$((NOW - 100)) armed_key=ARMK
send Stop
ck "ttl-not-yet" "to-compact" "$(st phase)"
set_state phase=standby phase_at=$((NOW - 100000))
send Stop
st_all "ttl-standby-none" "phase=standby suppress=0"

# ---- robustness ----
for ev in Stop PostToolUse Notification PostCompact SessionStart UserPromptSubmit PreCompact Bogus; do
  set_state phase=armed
  send "$ev"
  ck "never-exit-2-$ev" "rc=0 out=" "rc=$RC out=$(cat "$T/out")"
done
printf '{}' | "$T/hooks/ideal-compact.sh" >"$T/out" 2>"$T/err"; ck "empty-input" "0" "$?"
rm -f "$T/common-helpers.sh.bak"; mv "$T/common-helpers.sh" "$T/common-helpers.sh.bak"
printf '{}' | "$T/hooks/ideal-compact.sh" >"$T/out" 2>"$T/err"; rc=$?
mv "$T/common-helpers.sh.bak" "$T/common-helpers.sh"
ck "no-library-exit" "0" "$rc"
grep -q 'common-helpers.sh not found' "$T/err" && pass "no-library-message" ok || bad "no-library-message" "stderr names the library" "$(cat "$T/err")"
# no jq: the Python fallback reads the same fields
mkdir -p "$T/nojq"
for b in bash dirname basename cat date mktemp mv rm mkdir flock sed awk head id python3 tr git cp sleep; do
  p="$(command -v "$b")" && ln -sf "$p" "$T/nojq/$b"
done
ln -sf "$TESTS_DIR/fakes/tmux" "$T/nojq/tmux"; ln -sf "$TESTS_DIR/fakes/screen" "$T/nojq/screen"; ln -sf "$TESTS_DIR/fakes/cswap" "$T/nojq/cswap"
iso_guard "$T/nojq" "$T/nojq"
set_state phase=armed dirty=0 armed_key=ARMK armed_win=5h armed_resets=9
printf '%s' "{\"session_id\":\"sess1\",\"transcript_path\":\"$TP\",\"cwd\":\"$T/cwd\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hi\"}" \
  | PATH="$T/nojq" "$T/nojq/bash" "$T/hooks/ideal-compact.sh" >"$T/out" 2>"$T/err"
st_all "nojq-python" "phase=standby suppress=1 dirty=1"

exit $fail
