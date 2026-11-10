#!/usr/bin/env bash
# Tests for hooks/ideal-compact.sh: SessionStart, UserPromptSubmit, PreCompact,
# PostToolUse, Stop, Notification, phase timeouts and __ic_takeover. Usage: ideal-compact-hook.sh
# ---- isolation header: a test must never reach the real session or account ----
unset TMUX TMUX_PANE STY WINDOW CLAUDECODE
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO="$(mktemp -d)"
mkdir -p "$ISO/tmp" "$ISO/home" "$ISO/claude" "$ISO/xdg" "$ISO/cswap" "$ISO/hints"
export IC_TMP_BASE="$ISO/tmp" HOME="$ISO/home" CLAUDE_CONFIG_DIR="$ISO/claude" \
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
# IC_CLAUDE_PID: a process the test owns with an empty environment, so __ic_backend
# never picks up the multiplexer of the shell that started the test from /proc.
env -i sleep 3600 & CLEAN_PID=$!
export IC_CLAUDE_PID=$CLEAN_PID
# KILLS: every background process a row starts (hooks, claude stand-ins), killed on exit
KILLS=()
trap 'kill "$CLEAN_PID" "${KILLS[@]}" 2>/dev/null; rm -rf "$T" "$ISO"' EXIT
export FAKE_LOG="$T/fake.log"

# Layout mirroring ~/.claude: <T>/common-helpers.sh, <T>/hwap-helper.sh (stub), <T>/hooks/ideal-compact.sh
mkdir -p "$T/hooks" "$T/cwd"
cp "$SRC/common-helpers.sh" "$T/common-helpers.sh"
cp "$SRC/hooks/ideal-compact.sh" "$T/hooks/ideal-compact.sh"
# The stub helper prints the scripted `current` / `accounts` text.
cat > "$T/hwap-helper.sh" <<'STUB'
#!/usr/bin/env bash
[ -n "${FAKE_LOG:-}" ] && printf 'helper %s\n' "$*" >> "$FAKE_LOG"
[ -n "${STUB_SIDE:-}" ] && eval "$STUB_SIDE"
case "${1:-}" in
  current) cat "$STUB_CURRENT" 2>/dev/null ;;
  accounts) cat "$STUB_ACCOUNTS" 2>/dev/null ;;
  # the gate's call (no argument): $STUB_GATE is a snippet printing its answer,
  # nothing (= ok) when unset
  '') [ -n "${STUB_GATE:-}" ] && eval "$STUB_GATE" ;;
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
# send <json fields as jq --arg pairs>: runs the hook; sets RC; stdout/stderr in $T/out, $T/err.
# cwd is $SEND_CWD when set, else $T/cwd.
send() {
  local ev="$1"; shift
  jq -n --arg ev "$ev" --arg tp "$TP" --arg cwd "${SEND_CWD:-$T/cwd}" "$@" \
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
set_state phase=standby pending_inject=cancel ledger_done=3
send SessionStart --arg source resume
st_all "ss-pending-cleared" "phase=standby pending_inject= ledger_done=0"
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
    __IC_IN_CS=0 __IC_SIGNALED=0
    eval "$(sed -n "/^__cs_lock() {/,/^}/p; /^__cs_unlock() {/p; /^__cs_leave() {/,/^}/p; /^__hist_path() {/,/^}/p; /^__ic_takeover() {/,/^}/p" "$1/hooks/ideal-compact.sh")"
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
  # PostToolUse in armed may legitimately print (see below); waiting only records
  if [ "$ev" = PostToolUse ]; then set_state phase=waiting; else set_state phase=armed; fi
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


# ---- PostToolUse ----
# A git repo with a 4-task plan and a 7.0.0-style ledger; the cwd of these rows is the repo.
R="$T/repo"; mkdir -p "$R/docs" "$R/.superpowers/sdd/ws"
git -C "$R" init -q
printf '### Task 1: a\n### Task 2: b\n### Task 3: c\n### Task 4: d\n' > "$R/docs/plan.md"
RP="$(cd "$R" && pwd -P)"
LED="$R/.superpowers/sdd/ws/progress.md"; LEDP="$RP/.superpowers/sdd/ws/progress.md"
RHIST="$IC_TMP_BASE/$(printf '%s' "$RP" | sed 's/[^A-Za-z0-9]/-/g')/ideal-compact-history"
R5=$((NOW + 9000)) R7=$((NOW + 90000))
printf 'usage KEY1 50 %s 20 %s 97 99 120 3\n' $R5 $R7 > "$T/current"
PAUSE="$(bash -c '. "$1"; printf %s "$IDEAL_COMPACT_PAUSE_TEXT"' _ "$T/common-helpers.sh")"
CANCEL="$(bash -c '. "$1"; printf %s "$IDEAL_COMPACT_CANCEL_TEXT"' _ "$T/common-helpers.sh")"
# ledger <N...>: the ledger with these tasks complete
ledger() { { printf '# SDD ledger — plan: docs/plan.md\n'; for n in "$@"; do printf 'Task %s: complete (ok)\n' "$n"; done; } > "$LED"; }
# seed <c5> [<done>]: history with one other-ledger line of KEY1 carrying c5 (budget
# (97-50)/c5 on 5h; '-' = unknown) and, with <done>, a line of our ledger at that count
seed() {
  mkdir -p "$(dirname "$RHIST")"
  printf '1\tL\t1\tKEY1\t10\t%s\t10\t%s\t0\t%s\t-\t1\t10\t%s\t1\t10\t%s\n' $R5 $R7 "$1" $R5 $R7 > "$RHIST"
  [ -z "${2:-}" ] || printf '2\t%s\t%s\tKEY1\t50\t%s\t20\t%s\t0\t-\t-\t%s\t50\t%s\t%s\t20\t%s\n' \
    "$LEDP" "$2" $R5 $R7 "$2" $R5 "$2" $R7 >> "$RHIST"
}
# hl <ledger>: history lines of that ledger; hlast <ledger> <field>: a field of its newest
hl() { awk -F'\t' -v l="$1" '$2 == l' "$RHIST" 2>/dev/null | wc -l | tr -d ' '; }
hlast() { awk -F'\t' -v l="$1" -v f="$2" '$2 == l { v = $f } END { print v }' "$RHIST" 2>/dev/null; }
# cfg <email>: the account the statusline reads, plus its usage hint (r5 r7 = $R5 $R7)
cfg() {
  printf '{"oauthAccount":{"emailAddress":"%s","organizationUuid":"org1"}}\n' "$1" > "$CLAUDE_CONFIG_DIR/.claude.json"
  printf '50 %s 20 %s\n' $R5 $R7 > "$HWAP_HINT_DIR/usage-$1-org1"
}
OBS_A="a@x.com-org1 $R5 $R7"
cfg a@x.com
# ptu <tool> <tool_input json> [jq args]: a PostToolUse from the repo
ptu() { local tool="$1" ti="$2"; shift 2; SEND_CWD="$R" send PostToolUse --arg tool_name "$tool" --argjson tool_input "$ti" "$@"; }
edit_led() { ptu Edit "$(jq -cn --arg f "${1:-$LED}" '{file_path: $f, old_string: "x", new_string: "Task 2: complete (ok)"}')" "${@:2}"; }
read_any() { ptu Read '{"file_path":"/etc/hostname"}' "$@"; }
ctx() { jq -r '.hookSpecificOutput.additionalContext // empty' "$T/out" 2>/dev/null; }
export TMUX="$T/sock,1,0" TMUX_PANE=%3

# fast path: idle standby, nothing about a ledger -> no lock, no helper
set_state phase=standby; : > "$FAKE_LOG"
read_any
ck "ptu-fast-no-calls" "" "$(cat "$FAKE_LOG")"
ck "ptu-fast-no-lock" "absent" "$([ -e "$SDIR/ideal-compact-state.lock" ] && echo present || echo absent)"
no_stdout "ptu-fast-quiet"

# stopped + any tool call -> armed (also from a subagent)
set_state phase=stopped
read_any
st_all "ptu-stopped-armed" "phase=armed"
no_stdout "ptu-stopped-quiet"
set_state phase=stopped
read_any --arg agent_id ag1
st_all "ptu-stopped-armed-subagent" "phase=armed"

# an empty ledger counts nothing; the first completion is a baseline
rm -f "$RHIST"; ledger
set_state phase=standby
ptu Write "$(jq -cn --arg f "$LED" '{file_path: $f, content: "# SDD ledger"}')"
ck "ptu-empty-ledger-no-history" "absent" "$([ -e "$RHIST" ] && echo present || echo absent)"
ck "ptu-empty-ledger-stored" "$LEDP" "$(st ledger)"
ledger 1
edit_led
ck "ptu-first-baseline" "1 1 - -" "$(hl "$LEDP") $(hlast "$LEDP" 3) $(hlast "$LEDP" 10) $(hlast "$LEDP" 11)"
no_stdout "ptu-first-baseline-quiet"

# task-done completion with budget 2 -> armed + pause text
seed 20 1; ledger 1 2
set_state phase=standby
ptu Bash '{"command":"task-done docs/plan.md 2 abc -- true"}'
st_all "ptu-arm" "phase=armed armed_key=KEY1 armed_win=5h armed_resets=$R5 suppress=0 ledger=$LEDP"
ck "ptu-arm-text" "$PAUSE" "$(ctx)"
ck "ptu-arm-json" "$(jq -cn --arg t "$PAUSE" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $t}}')" "$(cat "$T/out")"
ck "ptu-arm-obs" "$OBS_A" "$(st cheap_obs)"
ck "ptu-arm-recorded" "2" "$(hlast "$LEDP" 3)"
# the same without a backend -> stays standby
seed 20 1; ledger 1 2
set_state phase=standby
TMUX_PANE='' ptu Bash '{"command":"task-done docs/plan.md 2 abc -- true"}'
st_all "ptu-no-backend" "phase=standby"
no_stdout "ptu-no-backend-quiet"
ck "ptu-no-backend-recorded" "2" "$(hlast "$LEDP" 3)"

# armed: a key change re-evaluates on any tool call (the ledger is at its recorded count, so no completion)
ledger 1 2
seed 6 2; set_state phase=armed ledger="$LEDP" armed_key=KEY1 armed_win=5h armed_resets=$R5 cheap_obs="$OBS_A"
cfg b@x.com
read_any
st_all "ptu-armed-cancel" "phase=standby suppress=0"
ck "ptu-armed-cancel-text" "$CANCEL" "$(ctx)"
ck "ptu-armed-cancel-rc" "0" "$RC"
seed 9 2; set_state phase=armed ledger="$LEDP" armed_key=KEY1 armed_win=5h armed_resets=$R5 cheap_obs="$OBS_A"
read_any
st_all "ptu-armed-mid" "phase=armed"
ck "ptu-armed-mid-obs" "b@x.com-org1 $R5 $R7" "$(st cheap_obs)"
no_stdout "ptu-armed-mid-quiet"
printf 'error:cswap_failed\n' > "$T/current"
seed 6 2; set_state phase=armed ledger="$LEDP" armed_key=KEY1 armed_win=5h armed_resets=$R5 cheap_obs="$OBS_A"
read_any
st_all "ptu-armed-helper-error" "phase=armed"
no_stdout "ptu-armed-helper-error-quiet"
printf 'usage KEY1 50 %s 20 %s 97 99 120 3\n' $R5 $R7 > "$T/current"
# unchanged observation: no evaluation even with a high budget
seed 6 2; set_state phase=armed ledger="$LEDP" cheap_obs="b@x.com-org1 $R5 $R7"; : > "$FAKE_LOG"
read_any
st_all "ptu-armed-unchanged" "phase=armed"
no_stdout "ptu-armed-unchanged-quiet"
ck "ptu-armed-unchanged-no-helper" "" "$(cat "$FAKE_LOG")"
cfg a@x.com
# missing config: falls back to the helper's key and resets
mv "$CLAUDE_CONFIG_DIR/.claude.json" "$T/cfg.bak"
seed 9 2; set_state phase=armed ledger="$LEDP" cheap_obs="$OBS_A"
read_any
ck "ptu-obs-fallback" "KEY1 $R5 $R7" "$(st cheap_obs)"
mv "$T/cfg.bak" "$CLAUDE_CONFIG_DIR/.claude.json"

# armed + completion with budget 2 -> pause again
seed 20 1; ledger 1 2
set_state phase=armed ledger="$LEDP" armed_key=KEY1 armed_win=5h armed_resets=$R5 cheap_obs="$OBS_A"
edit_led
st_all "ptu-rearm" "phase=armed"
ck "ptu-rearm-text" "$PAUSE" "$(ctx)"

# standby + suppress
seed 20 1; ledger 1 2
set_state phase=standby suppress=1 suppress_key=KEY1 suppress_win=5h suppress_resets=$R5
edit_led
st_all "ptu-suppress-kept" "phase=standby suppress=1"
no_stdout "ptu-suppress-kept-quiet"
seed 20 1; ledger 1 2
set_state phase=standby suppress=1 suppress_key=KEY1 suppress_win=5h suppress_resets=$((R5 - 2))
edit_led
st_all "ptu-suppress-tolerance" "phase=standby suppress=1"
seed 20 1; ledger 1 2
set_state phase=standby suppress=1 suppress_key=KEY1 suppress_win=5h suppress_resets=$((R5 - 4))
edit_led
st_all "ptu-suppress-reset-moved" "phase=armed suppress=0"
ck "ptu-suppress-reset-moved-text" "$PAUSE" "$(ctx)"
seed 20 1; ledger 1 2
set_state phase=standby suppress=1 suppress_key=OTHER suppress_win=5h suppress_resets=$R5
edit_led
st_all "ptu-suppress-key-changed" "phase=armed suppress=0"
seed 20 1; ledger 1 2
set_state phase=standby suppress=1 armed_key=KEY1 armed_win=5h armed_resets=$R5
edit_led
st_all "ptu-suppress-armed-fallback" "phase=standby suppress=1"
seed 20 1; ledger 1 2
set_state phase=standby suppress=1 armed_key=KEY1 armed_win=7d armed_resets=$((R7 + 10))
edit_led
st_all "ptu-suppress-armed-fallback-moved" "phase=armed suppress=0"
seed 20 1; ledger 1 2
set_state phase=standby suppress=1
edit_led
st_all "ptu-suppress-nothing-stored" "phase=standby suppress=1"
# standby with budget 5: suppress cleared, not armed
seed 9 1; ledger 1 2
set_state phase=standby suppress=1 suppress_key=OTHER suppress_win=5h suppress_resets=$R5
edit_led
st_all "ptu-suppress-cleared-no-arm" "phase=standby suppress=0 suppress_key="
no_stdout "ptu-suppress-cleared-no-arm-quiet"

# Review Focus 1: an old-style ledger found through an Edit's file_path
OLD="$R/.superpowers/sdd/progress.md"; OLDP="$RP/.superpowers/sdd/progress.md"
printf '# Plan 6 progress ledger\nTask 1: complete\n' > "$OLD"
seed -; set_state phase=standby
edit_led "$OLD"
printf 'Task 2: complete\n' >> "$OLD"
edit_led "$OLD"
ck "ptu-old-ledger" "2 2" "$(hl "$OLDP") $(hlast "$OLDP" 3)"
ck "ptu-old-ledger-stored" "$OLDP" "$(st ledger)"

# Review Focus 2: one completion seen twice is recorded once; a recreated ledger is a baseline
seed - 1; ledger 1 2; set_state phase=standby
edit_led
ptu Bash '{"command":"task-done docs/plan.md 2 abc -- true"}'
ck "ptu-seen-twice" "1" "$(awk -F'\t' -v l="$LEDP" '$2 == l && $3 == 2' "$RHIST" | wc -l | tr -d ' ')"
seed 20 2; ledger 1; set_state phase=standby
edit_led
ck "ptu-recreated-baseline" "1 - -" "$(hlast "$LEDP" 3) $(hlast "$LEDP" 10) $(hlast "$LEDP" 11)"
st_all "ptu-recreated-no-arm" "phase=standby"
no_stdout "ptu-recreated-quiet"

# dirty: the record carries it (a baseline) and the state's dirty drops by it
for d in 0 1; do
  mkdir -p "$(dirname "$RHIST")"
  printf '2\t%s\t1\tKEY1\t40\t%s\t20\t%s\t0\t-\t-\t1\t40\t%s\t1\t20\t%s\n' "$LEDP" $R5 $R7 $R5 $R7 > "$RHIST"
  ledger 1 2; set_state phase=standby dirty=$d
  edit_led
  ck "ptu-dirty-$d" "$d $([ "$d" = 0 ] && echo 10 || echo -) 0" "$(hlast "$LEDP" 9) $(hlast "$LEDP" 10) $(st dirty)"
done

# TTL-expired stopped (suppress copied from armed_*), then a completion with budget 2
seed 20 1; ledger 1 2
set_state phase=stopped phase_at=$((NOW - 901)) armed_key=KEY1 armed_win=5h armed_resets=$R5
edit_led
st_all "ptu-ttl-stopped-suppressed" "phase=standby suppress=1 suppress_key=KEY1"
no_stdout "ptu-ttl-stopped-quiet"

# armed, observation changed, backend gone -> standby + cancel
ledger 1 2; seed 20 2; set_state phase=armed ledger="$LEDP" armed_key=KEY1 armed_win=5h armed_resets=$R5 cheap_obs=old
TMUX_PANE='' read_any
st_all "ptu-backend-gone" "phase=standby suppress=0"
ck "ptu-backend-gone-text" "$CANCEL" "$(ctx)"

# subagent calls: completions count, nothing printed, injection queued for the main agent
seed 20 1; ledger 1 2; set_state phase=standby ledger="$LEDP"
edit_led "$LED" --arg agent_id ag1
no_stdout "ptu-sub-quiet"
st_all "ptu-sub-armed" "phase=armed pending_inject=pause cheap_obs="
ck "ptu-sub-recorded" "2" "$(hlast "$LEDP" 3)"
read_any
ck "ptu-sub-delivered" "$PAUSE" "$(ctx)"
st_all "ptu-sub-delivered-cleared" "phase=armed pending_inject="
seed 6 1; ledger 1 2; set_state phase=armed ledger="$LEDP" cheap_obs="$OBS_A"
edit_led "$LED" --arg agent_id ag1
no_stdout "ptu-sub-cancel-quiet"
st_all "ptu-sub-cancel-queued" "phase=standby pending_inject=cancel"
read_any
ck "ptu-sub-cancel-delivered" "$CANCEL" "$(ctx)"
st_all "ptu-sub-cancel-cleared" "phase=standby pending_inject="
# a subagent never runs the observation re-evaluation
ledger 1 2; seed 6 2; set_state phase=armed ledger="$LEDP" cheap_obs=old
read_any --arg agent_id ag1
st_all "ptu-sub-no-obs-eval" "phase=armed cheap_obs=old"
no_stdout "ptu-sub-no-obs-eval-quiet"
# a queued injection that no longer fits the phase is dropped
set_state phase=standby pending_inject=pause
read_any
no_stdout "ptu-pending-dropped"
st_all "ptu-pending-dropped-cleared" "phase=standby pending_inject="
# no jq: the account key comes from the Python fallback
ledger 1 2; seed 9 2; set_state phase=armed ledger="$LEDP" cheap_obs=old
printf '%s' "{\"session_id\":\"sess1\",\"transcript_path\":\"$TP\",\"cwd\":\"$R\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/etc/hostname\"}}" \
  | PATH="$T/nojq" "$T/nojq/bash" "$T/hooks/ideal-compact.sh" >"$T/out" 2>"$T/err"
ck "ptu-nojq-obs" "$OBS_A" "$(st cheap_obs)"
# an unrecorded completion (current not `usage`) is evaluated once, not on every call
for cl in "lastgood 0 50 $R5 20 $R7" "error:cswap_failed"; do
  printf '%s\n' "$cl" > "$T/current"
  ledger 1 2; seed - 1
  set_state phase=armed ledger="$LEDP" cheap_obs="$OBS_A"
  edit_led
  ck "ptu-skipped-once-done [${cl%% *}]" "1 2" "$(hl "$LEDP") $(st ledger_done)"
  : > "$FAKE_LOG"
  read_any
  ck "ptu-skipped-once-no-helper [${cl%% *}]" "" "$(cat "$FAKE_LOG")"
done
printf 'usage KEY1 50 %s 20 %s 97 99 120 3\n' $R5 $R7 > "$T/current"
# a new ledger path starts its remembered count over
ledger 1 2; seed - 1
set_state phase=standby ledger=/elsewhere/progress.md ledger_done=5
edit_led
ck "ptu-ledger-change-resets-done" "2 2" "$(hlast "$LEDP" 3) $(st ledger_done)"
# standby without a completion never builds the observation (no helper fallback)
mv "$CLAUDE_CONFIG_DIR/.claude.json" "$T/cfg.bak"
ledger 1 2; seed - 2; set_state phase=standby ledger="$LEDP" ledger_done=2; : > "$FAKE_LOG"
edit_led
ck "ptu-standby-no-obs" "" "$(cat "$FAKE_LOG")"
mv "$T/cfg.bak" "$CLAUDE_CONFIG_DIR/.claude.json"

# ---- Stop: marker + quiet ----
MARK='[[STOP_FOR_COMPACT]]'
# stop <message> [jq args]: a Stop with both quiet lists present and empty
stop() { local m="$1"; shift; send Stop --arg last_assistant_message "$m" --argjson background_tasks '[]' --argjson session_crons '[]' "$@"; }
set_state phase=armed
stop $'OK\n'"$MARK"
st_all "stop-armed-marker" "phase=stopped"
no_stdout "stop-quiet"
set_state phase=armed
stop $'OK\n'"$MARK"$'   \n\n \n'
st_all "stop-marker-trailing-blank" "phase=stopped"
set_state phase=armed
stop "$MARK"
st_all "stop-marker-only" "phase=stopped"
set_state phase=armed
stop $'OK\n  '"$MARK"$'\t\r\n'
st_all "stop-marker-trim" "phase=stopped"
set_state phase=armed
stop $'OK\n'"$MARK"$'\nand then some'
st_all "stop-marker-then-text" "phase=armed"
set_state phase=armed
stop "see $MARK"
st_all "stop-marker-inline" "phase=armed"
set_state phase=armed
stop "done"
st_all "stop-no-marker" "phase=armed"
set_state phase=armed
send Stop --arg last_assistant_message "$MARK" --argjson session_crons '[]'
st_all "stop-bg-missing" "phase=armed"
set_state phase=armed
send Stop --arg last_assistant_message "$MARK" --argjson background_tasks '[]'
st_all "stop-crons-missing" "phase=armed"
set_state phase=armed
send Stop --arg last_assistant_message "$MARK" --argjson background_tasks '[]' --argjson session_crons '[{"id":"c1"}]'
st_all "stop-crons-nonempty" "phase=armed"
set_state phase=armed
send Stop --arg last_assistant_message "$MARK" --argjson background_tasks '[{"id":"a1","type":"subagent","status":"running"}]' --argjson session_crons '[]'
st_all "stop-bg-running" "phase=armed"
set_state phase=armed
send Stop --arg last_assistant_message "$MARK" --argjson background_tasks null --argjson session_crons '[]'
st_all "stop-bg-null" "phase=armed"
set_state phase=armed
send Stop --argjson background_tasks '[]' --argjson session_crons '[]'
st_all "stop-no-message" "phase=armed"
# stopped + marker again: still stopped, phase_at refreshed; otherwise back to armed
set_state phase=stopped phase_at=$((NOW - 100))
stop "$MARK"
ck "stop-stopped-marker" "stopped" "$(st phase)"
[ "$(st phase_at)" -gt $((NOW - 100)) ] && pass "stop-stopped-phase-at" ok || bad "stop-stopped-phase-at" "refreshed" "$(st phase_at)"
set_state phase=stopped
stop "carry on"
st_all "stop-stopped-no-marker" "phase=armed"
set_state phase=stopped
send Stop --arg last_assistant_message "$MARK" --argjson background_tasks '[{"id":"a1"}]' --argjson session_crons '[]'
st_all "stop-stopped-not-quiet" "phase=armed"
for ph in standby waiting to-compact compacting continuing; do
  set_state phase=$ph
  stop "$MARK"
  st_all "stop-$ph-unchanged" "phase=$ph"
done
set_state phase=armed
printf '%s' "{\"session_id\":\"sess1\",\"transcript_path\":\"$TP\",\"cwd\":\"$T/cwd\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"OK\\n$MARK\",\"background_tasks\":[],\"session_crons\":[]}" \
  | PATH="$T/nojq" "$T/nojq/bash" "$T/hooks/ideal-compact.sh" >"$T/out" 2>"$T/err"
st_all "stop-nojq" "phase=stopped"

# ---- Notification ----
export TMUX="$T/sock,1,0" TMUX_PANE=%3
SOCK="$T/sock"
RULE="$(printf '─%.0s' 1 2 3 4 5 6 7 8 9 10)"
NB=$'\xc2\xa0'
printf '%s\n❯%s\n%s\n' "$RULE" "$NB" "$RULE" > "$T/screen-empty"
printf '%s\n❯%sTry "fix lint errors"\n%s\n' "$RULE" "$NB" "$RULE" > "$T/screen-placeholder"
printf '%s\n❯%sdraft text\n%s\n' "$RULE" "$NB" "$RULE" > "$T/screen-draft"
: > "$T/screen-none"
COMPACT="$(bash -c '. "$1"; printf %s "$IDEAL_COMPACT_COMPACT_TEXT"' _ "$T/common-helpers.sh")"
CR=$'\r'
sent() { grep ' send-keys ' "$FAKE_LOG" 2>/dev/null; }
# idle <screen> <cursor> [phase state...]: an idle_prompt in `stopped` from the repo
idle() {
  FAKE_SCREEN="$T/screen-$1" FAKE_CURSOR="$2"; export FAKE_SCREEN FAKE_CURSOR
  shift 2
  set_state phase=stopped "$@"; : > "$FAKE_LOG"
  SEND_CWD="$R" send Notification --arg notification_type idle_prompt
}
EXP_COMPACT="tmux -S $SOCK send-keys -l -t %3 /compact $COMPACT"$'\n'"tmux -S $SOCK send-keys -l -t %3 $CR"
EXP_CONT="tmux -S $SOCK send-keys -l -t %3 繼續"$'\n'"tmux -S $SOCK send-keys -l -t %3 $CR"

seed 20
for kind in empty placeholder; do
  idle $kind "2 1" inputbox_fail=1
  ck "idle-$kind-compact-sent" "$EXP_COMPACT" "$(sent)"
  st_all "idle-$kind-compact-state" "phase=to-compact inputbox_fail=0 suppress=0"
  no_stdout "idle-$kind-quiet"
done
[ "$(st phase_at)" -ge "$NOW" ] && pass "idle-compact-phase-at" ok || bad "idle-compact-phase-at" ">= now" "$(st phase_at)"
seed 6
idle empty "2 1" inputbox_fail=1
ck "idle-continue-sent" "$EXP_CONT" "$(sent)"
st_all "idle-continue-state" "phase=continuing inputbox_fail=0 suppress=0"
seed 5
idle placeholder "2 1"
ck "idle-budget-9-continues" "$EXP_CONT" "$(sent)"
seed 7   # (97-50)/7 = 6: not above the warn count
idle empty "2 1"
ck "idle-budget-6-compact" "$EXP_COMPACT" "$(sent)"
st_all "idle-budget-6-compact-state" "phase=to-compact"
rm -f "$RHIST"
idle empty "2 1"
ck "idle-budget-unknown-compact-sent" "$EXP_COMPACT" "$(sent)"
seed 20
# nothing is sent on skip, and nothing is touched at all
idle empty "2 1" skip=1
ck "idle-skip-log-empty" "" "$(cat "$FAKE_LOG")"
st_all "idle-skip-state" "phase=stopped skip=1 suppress=0"
# a draft: takeover without inputbox_fail
idle draft "7 1" inputbox_fail=0
ck "idle-draft-nothing-sent" "" "$(sent)"
st_all "idle-draft-takeover" "phase=standby suppress=1 inputbox_fail=0"
# unsure (cursor query fails / no box): takeover with inputbox_fail=1
export FAKE_FAIL_CURSOR=1
idle empty "2 1"
ck "idle-unsure-cursor-nothing-sent" "" "$(sent)"
st_all "idle-unsure-cursor-takeover" "phase=standby suppress=1 inputbox_fail=1"
unset FAKE_FAIL_CURSOR
idle none "2 1"
ck "idle-unsure-nobox-nothing-sent" "" "$(sent)"
st_all "idle-unsure-nobox-takeover" "phase=standby suppress=1 inputbox_fail=1"
# no backend: takeover, nothing sent, no capture
TMUX_PANE='' idle empty "2 1"
ck "idle-nobackend-log" "" "$(cat "$FAKE_LOG" | grep -v '^helper ')"
st_all "idle-nobackend-takeover" "phase=standby suppress=1 inputbox_fail=0"
# the takeover is tied to the stopped phase and to the budget's window
idle draft "7 1" armed_key=ARMK
st_all "idle-takeover-suppress-key" "suppress_key=KEY1 suppress_win=5h suppress_resets=$R5"
# other notification types and other phases do nothing
set_state phase=stopped; : > "$FAKE_LOG"
SEND_CWD="$R" send Notification --arg notification_type permission_prompt
ck "idle-other-type" "stopped|" "$(st phase)|$(cat "$FAKE_LOG")"
no_stdout "idle-other-type-quiet"
SEND_CWD="$R" send Notification
ck "idle-no-type" "stopped|" "$(st phase)|$(cat "$FAKE_LOG")"
for ph in standby armed waiting to-compact compacting continuing; do
  set_state phase=$ph; : > "$FAKE_LOG"
  FAKE_SCREEN="$T/screen-empty" FAKE_CURSOR="2 1" SEND_CWD="$R" send Notification --arg notification_type idle_prompt
  ck "idle-in-$ph" "$ph|" "$(st phase)|$(cat "$FAKE_LOG")"
done
# the user starts typing while the helper runs: the input box is checked after it
printf '%s\n❯%sdraft\n  more\n%s\n' "$RULE" "$NB" "$RULE" > "$T/screen-typing"
export STUB_SIDE="cp \"$T/screen-typing\" \"\$FAKE_SCREEN\""
cp "$T/screen-empty" "$T/screen-live"
FAKE_SCREEN="$T/screen-live" FAKE_CURSOR="2 1"; export FAKE_SCREEN FAKE_CURSOR
set_state phase=stopped; : > "$FAKE_LOG"
SEND_CWD="$R" send Notification --arg notification_type idle_prompt
ck "idle-typing-during-helper-nothing-sent" "" "$(sent)"
st_all "idle-typing-during-helper-takeover" "phase=standby suppress=1 inputbox_fail=0"
unset STUB_SIDE
# the box check comes after the helper in the log
set_state phase=stopped; : > "$FAKE_LOG"
cp "$T/screen-empty" "$T/screen-live"
SEND_CWD="$R" send Notification --arg notification_type idle_prompt
ck "idle-box-after-helper" "helper current" "$(sed -n '1p' "$FAKE_LOG")"
ck "idle-box-after-helper-capture" "yes" "$(awk '/^helper accounts/ { h = NR } /capture-pane/ { c = NR } END { print (h && c > h) ? "yes" : "no" }' "$FAKE_LOG")"
# races: the state changes after the input box check, before the lock
mkdir -p "$T/racebin"
cat > "$T/racebin/tmux" <<'RACE'
#!/usr/bin/env bash
"$TESTS_DIR/fakes/tmux" "$@"; rc=$?
case " $* " in *" display-message "*) [ -n "${RACE_LINE:-}" ] && printf '%s\n' "$RACE_LINE" >> "$RACE_SDIR/ideal-compact-state" ;; esac
exit $rc
RACE
chmod +x "$T/racebin/tmux"
iso_guard "$T/racebin:$PATH" "$T/racebin"
export TESTS_DIR RACE_SDIR="$SDIR"
for line in skip=1 phase=armed phase=standby; do
  RACE_LINE="$line"; export RACE_LINE
  OLDPATH="$PATH"; PATH="$T/racebin:$PATH"
  idle empty "2 1" inputbox_fail=1
  PATH="$OLDPATH"
  ck "idle-race-$line-nothing-sent" "" "$(sent)"
  ck "idle-race-$line-state" "${line#*=}" "$(st "${line%%=*}")"
  ck "idle-race-$line-inputbox-fail-reset" "0" "$(st inputbox_fail)"
done
unset RACE_LINE
unset FAKE_SCREEN FAKE_CURSOR

# ---- PostCompact: switch, wait, continue ----
# The hook runs in the background (it may wait); pc_wait collects it.
export IC_MIN_WAIT_SEC=1
FAKE_SCREEN="$T/screen-empty" FAKE_CURSOR="2 1"; export FAKE_SCREEN FAKE_CURSOR
PCH="$SDIR/checkpoint-hold-until"; GH="$IC_TMP_BASE/hwap-hold-until"
# pchist <c5 of KEY1> [<c5 of KEY2>]: history of the cwd's project (5h only)
pchist() {
  mkdir -p "$(dirname "$HIST")"
  printf '1\tL\t1\tKEY1\t10\t1\t10\t1\t0\t%s\t-\t0\t0\t0\t0\t0\t0\n' "$1" > "$HIST"
  [ -z "${2:-}" ] || printf '1\tL\t1\tKEY2\t10\t1\t10\t1\t0\t%s\t-\t0\t0\t0\t0\t0\t0\n' "$2" >> "$HIST"
}
# new_claude: a fresh claude stand-in in IC_CLAUDE_PID (CLAUDE_PID), so a row can kill it
new_claude() { env -i sleep 3600 & CLAUDE_PID=$!; KILLS+=("$CLAUDE_PID"); export IC_CLAUDE_PID=$CLAUDE_PID; }
# pc_bg [state...]: phase compacting (plus these keys), then the hook in the background (HPID)
pc_bg() {
  set_state phase=compacting "$@"; : > "$FAKE_LOG"; rm -f "$PCH" "$GH"
  jq -n --arg tp "$TP" --arg cwd "$T/cwd" \
    '{session_id: "sess1", transcript_path: $tp, cwd: $cwd, hook_event_name: "PostCompact", trigger: "manual"}' > "$T/pc.json"
  "$T/hooks/ideal-compact.sh" < "$T/pc.json" > "$T/out" 2> "$T/err" & HPID=$!
  KILLS+=("$HPID")
}
# pc_wait <seconds>: RC = the hook's exit status, or `timeout` (the hook is then killed)
pc_wait() {
  local i
  for ((i = 0; i < $1 * 10; i++)); do kill -0 "$HPID" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$HPID" 2>/dev/null; then
    pkill -P "$HPID" 2>/dev/null; kill -9 "$HPID" 2>/dev/null; wait "$HPID" 2>/dev/null; RC=timeout
  else
    wait "$HPID"; RC=$?
  fi
}
absent() { [ -e "$1" ] && echo present || echo absent; }
# until_ok <seconds> <command...>: polls the command every 0.1 s until it succeeds
# (then waits 0.2 s more, so a just-started sleep is being waited for); 1 on timeout
until_ok() {
  local n=$(( $1 * 10 )) i; shift
  for ((i = 0; i < n; i++)); do "$@" && { sleep 0.2; return 0; }; sleep 0.1; done
  return 1
}
# in_sleep: the background hook is inside one of its sleeps
in_sleep() { pgrep -P "$HPID" -x sleep >/dev/null; }
switched() { grep '^cswap switch' "$FAKE_LOG" 2>/dev/null; }
pc_cur() { printf 'usage KEY1 50 %s 20 %s 97 99 %s 3\n' "$1" $R7 "${2:-120}" > "$T/current"; }

# budget 2, an alternate with budget 8 -> switch, then 繼續
pchist 20 10; pc_cur $R5
printf 'usage KEY2 10 %s 20 %s 97 99 120 3\n' $R5 $R7 > "$T/current-alt"
printf '1 KEY1 1 1 50 %s 20 %s 1 1\n2 KEY2 0 1 10 %s 20 %s 1 1\n' $R5 $R7 $R5 $R7 > "$T/accounts"
export STUB_SIDE="grep -q '^cswap switch 2' \"\$FAKE_LOG\" && cp \"$T/current-alt\" \"\$STUB_CURRENT\""
pc_bg; pc_wait 10
unset STUB_SIDE
ck "pc-switch-rc" "0" "$RC"
ck "pc-switch-switched" "cswap switch 2" "$(switched)"
ck "pc-switch-sent" "$EXP_CONT" "$(sent)"
st_all "pc-switch-state" "phase=continuing suppress=0"
no_stdout "pc-switch-quiet"
: > "$T/accounts"

# no better alternate, budget 5 -> no switch, 繼續
pchist 9; pc_cur $R5
pc_bg; pc_wait 10
ck "pc-no-alt-switched" "" "$(switched)"
ck "pc-no-alt-sent" "$EXP_CONT" "$(sent)"
st_all "pc-no-alt-state" "phase=continuing"

# the helper fails during the gate -> 繼續 at once (budget 2 would otherwise wait)
pchist 20; pc_cur $R5
export STUB_GATE='printf error:boom'
pc_bg; pc_wait 3
unset STUB_GATE
ck "pc-gate-error-rc" "0" "$RC"
ck "pc-gate-error-sent" "$EXP_CONT" "$(sent)"
ck "pc-gate-error-no-hold" "absent" "$(absent "$PCH")"

# budget 2, 5h reset 3 s ahead, buffer 1 s -> hold written, 繼續 after reset + buffer
pchist 20; R5S=$(( $(date +%s) + 3 )); pc_cur $R5S 1
export STUB_SIDE="[ \$(date +%s) -ge $R5S ] && printf 'usage KEY1 0 $R5S 20 $R7 97 99 1 3\n' > \"\$STUB_CURRENT\""
pc_bg; until_ok 5 test -s "$PCH"
ck "pc-hold-written" "$((R5S + 1))" "$(cat "$PCH" 2>/dev/null)"
ck "pc-hold-phase" "waiting" "$(st phase)"
ck "pc-hold-not-yet" "" "$(sent)"
pc_wait 12
unset STUB_SIDE
ck "pc-hold-rc" "0" "$RC"
ck "pc-hold-sent" "$EXP_CONT" "$(sent)"
ck "pc-hold-removed" "absent" "$(absent "$PCH")"
ck "pc-hold-message-once" "1" "$(grep -c "^ideal-compact: waiting for budget; cancel with kill $HPID\$" "$T/err")"
[ "$(date +%s)" -ge $((R5S + 1)) ] && pass "pc-hold-after-buffer" ok || bad "pc-hold-after-buffer" "sent after reset + buffer" "early"

# SIGTERM during the gate's wait, and during the budget wait -> exit 1 at once, standby+suppress
export STUB_GATE='printf "wait %s %s" $(( $(date +%s) + 100 )) $(( $(date +%s) + 90 ))'
pchist 20; pc_cur $R5
pc_bg armed_key=ARMK armed_win=5h armed_resets=77; until_ok 5 in_sleep
ck "pc-term-gate-hold-published" "present" "$(absent "$GH")"
kill -TERM "$HPID"; pc_wait 1
unset STUB_GATE
ck "pc-term-gate-rc" "1" "$RC"
st_all "pc-term-gate-state" "phase=standby suppress=1 suppress_key=ARMK suppress_win=5h suppress_resets=77"
ck "pc-term-gate-holds-gone" "absent absent" "$(absent "$GH") $(absent "$PCH")"
ck "pc-term-gate-nothing-sent" "" "$(sent)"
pc_bg; until_ok 5 in_sleep
ck "pc-term-budget-hold-written" "present" "$(absent "$PCH")"
kill -TERM "$HPID"; pc_wait 1
ck "pc-term-budget-rc" "1" "$RC"
st_all "pc-term-budget-state" "phase=standby suppress=1"
ck "pc-term-budget-holds-gone" "absent absent" "$(absent "$GH") $(absent "$PCH")"
ck "pc-term-budget-nothing-sent" "" "$(sent)"

# the claude process ends during the gate's wait, and during the budget wait -> ends, nothing sent
export STUB_GATE='printf "wait %s %s" $(( $(date +%s) + 1 )) $(( $(date +%s) + 1 ))'
new_claude; pc_bg; until_ok 5 test -e "$GH"
kill "$CLAUDE_PID"; pc_wait 5
unset STUB_GATE
ck "pc-claude-gone-gate-rc" "0" "$RC"
ck "pc-claude-gone-gate-nothing-sent" "" "$(sent)"
ck "pc-claude-gone-gate-no-hold" "absent absent" "$(absent "$PCH") $(absent "$GH")"
pchist 20; R5S=$(( $(date +%s) + 3 )); pc_cur $R5S 1
new_claude; pc_bg; until_ok 5 test -s "$PCH"
ck "pc-claude-gone-budget-waiting" "present" "$(absent "$PCH")"
kill "$CLAUDE_PID"; pc_wait 8
ck "pc-claude-gone-budget-rc" "0" "$RC"
ck "pc-claude-gone-budget-nothing-sent" "" "$(sent)"
ck "pc-claude-gone-budget-hold-gone" "absent" "$(absent "$PCH")"
export IC_CLAUDE_PID=$CLEAN_PID

# another hook sets standby during the gate's wait, and during the budget wait -> ends, nothing sent
export STUB_GATE='printf "wait %s %s" $(( $(date +%s) + 1 )) $(( $(date +%s) + 1 ))'
pc_bg; until_ok 5 test -e "$GH"
printf 'phase=standby\n' >> "$SDIR/ideal-compact-state"; pc_wait 5
unset STUB_GATE
ck "pc-standby-gate-rc" "0" "$RC"
ck "pc-standby-gate-nothing-sent" "" "$(sent)"
ck "pc-standby-gate-phase" "standby" "$(st phase)"
ck "pc-standby-gate-no-hold" "absent absent" "$(absent "$PCH") $(absent "$GH")"
pchist 20; R5S=$(( $(date +%s) + 3 )); pc_cur $R5S 1
pc_bg; until_ok 5 test -s "$PCH"
ck "pc-standby-budget-waiting" "present" "$(absent "$PCH")"
printf 'phase=standby\n' >> "$SDIR/ideal-compact-state"; pc_wait 8
ck "pc-standby-budget-rc" "0" "$RC"
ck "pc-standby-budget-nothing-sent" "" "$(sent)"
ck "pc-standby-budget-hold-gone" "absent" "$(absent "$PCH")"
pc_cur $R5

# an alternate gains budget while the hook waits for a far reset -> switch and 繼續
# before the hold expires (budget and pick are re-evaluated every round)
pchist 20 10; pc_cur $R5
printf '1 KEY1 1 1 50 %s 20 %s 1 1\n2 KEY2 0 0 10 %s 20 %s 1 1\n' $R5 $R7 $R5 $R7 > "$T/accounts"
printf '1 KEY1 1 1 50 %s 20 %s 1 1\n2 KEY2 0 1 10 %s 20 %s 1 1\n' $R5 $R7 $R5 $R7 > "$T/accounts-alt"
export STUB_SIDE="[ -s \"$PCH\" ] && cp \"$T/accounts-alt\" \"\$STUB_ACCOUNTS\"; grep -q '^cswap switch 2' \"\$FAKE_LOG\" && cp \"$T/current-alt\" \"\$STUB_CURRENT\""
export IC_MAX_WAIT_SEC=1
pc_bg; pc_wait 10
unset STUB_SIDE IC_MAX_WAIT_SEC
ck "pc-alt-mid-wait-rc" "0" "$RC"
ck "pc-alt-mid-wait-switched" "cswap switch 2" "$(switched)"
ck "pc-alt-mid-wait-sent" "$EXP_CONT" "$(sent)"
ck "pc-alt-mid-wait-hold-gone" "absent" "$(absent "$PCH")"
: > "$T/accounts"; pc_cur $R5

# the limiting window's reset is unknown (0) with budget 2 -> 繼續 at once, no hold
pchist 20; pc_cur 0
pc_bg; pc_wait 3
ck "pc-reset-0-sent" "$EXP_CONT" "$(sent)"
ck "pc-reset-0-no-wait-message" "" "$(grep 'waiting for budget' "$T/err")"
pc_cur $R5

# SIGTERM while the main path holds the state lock -> no deadlock, exit 1
pchist 9
export IC_TEST_CS_SLEEP=1.5
pc_bg; until_ok 5 in_sleep
kill -TERM "$HPID"; pc_wait 2
unset IC_TEST_CS_SLEEP
ck "pc-term-in-lock-rc" "1" "$RC"
st_all "pc-term-in-lock-state" "phase=standby suppress=1"
ck "pc-term-in-lock-nothing-sent" "" "$(sent)"

# SIGTERM between the text and the CR of 繼續 -> both keys still go out, then exit 1
mkdir -p "$T/termbin"
cat > "$T/termbin/tmux" <<'TERMT'
#!/usr/bin/env bash
"$TESTS_DIR/fakes/tmux" "$@"; rc=$?
case " $* " in *" send-keys "*繼續*) kill -TERM "$PPID" ;; esac
exit $rc
TERMT
chmod +x "$T/termbin/tmux"
iso_guard "$T/termbin:$PATH" "$T/termbin"
pchist 9
OLDPATH="$PATH"; PATH="$T/termbin:$PATH"
pc_bg; pc_wait 5
PATH="$OLDPATH"
ck "pc-term-in-send-rc" "1" "$RC"
ck "pc-term-in-send-both-keys" "$EXP_CONT" "$(sent)"
ck "pc-term-in-send-state" "continuing" "$(st phase)"

# a draft in the input box at send time -> takeover, nothing sent; unsure -> inputbox_fail
pchist 9
FAKE_SCREEN="$T/screen-draft" FAKE_CURSOR="7 1"
pc_bg; pc_wait 5
ck "pc-draft-nothing-sent" "" "$(sent)"
st_all "pc-draft-state" "phase=standby suppress=1 inputbox_fail=0"
FAKE_SCREEN="$T/screen-none" FAKE_CURSOR="2 1"
pc_bg; pc_wait 5
ck "pc-unsure-nothing-sent" "" "$(sent)"
st_all "pc-unsure-state" "phase=standby suppress=1 inputbox_fail=1"
FAKE_SCREEN="$T/screen-empty"
pc_bg inputbox_fail=1; pc_wait 5
st_all "pc-empty-resets-inputbox-fail" "phase=continuing inputbox_fail=0"

# PostCompact outside compacting does nothing
for ph in standby armed waiting continuing; do
  set_state phase=$ph; : > "$FAKE_LOG"
  send PostCompact --arg trigger manual
  ck "pc-in-$ph" "$ph|" "$(st phase)|$(cat "$FAKE_LOG")"
  no_stdout "pc-in-$ph-quiet"
done
unset FAKE_SCREEN FAKE_CURSOR IC_MIN_WAIT_SEC

unset TMUX TMUX_PANE

exit $fail
