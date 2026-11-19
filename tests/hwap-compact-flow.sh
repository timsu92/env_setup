#!/usr/bin/env bash
# Tests for hooks/high-watermark-auto-pause.sh's compact-before-switch flow:
# starting it from each trigger, the stop request, Stop/PreCompact/PostCompact,
# timeouts and where it meets ideal-compact's state. Usage: hwap-compact-flow.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/isolation.sh"
source "$TESTS_DIR/lib/rows.sh"
SRC="$TESTS_DIR/../ansible/roles/claude_code/files"
T="$(mktemp -d)"
# IC_CLAUDE_PID: a process the test owns with an empty environment, so __mux_backend
# never picks up the multiplexer of the shell that started the test from /proc.
env -i sleep 3600 & CLEAN_PID=$!
export IC_CLAUDE_PID=$CLEAN_PID
# The fake tmux reports this shell as the pane pid, the parent of the claude stand-in.
export FAKE_PANE_PID=$$
KILLS=()
trap 'kill "$CLEAN_PID" "${KILLS[@]}" 2>/dev/null; rm -rf "$T" "$ISO"' EXIT
export FAKE_LOG="$T/fake.log"

# Layout mirroring ~/.claude: <T>/common-helpers.sh, <T>/hwap-helper.sh (stub), <T>/hooks/<hook>.sh
mkdir -p "$T/hooks"
cp "$SRC/common-helpers.sh" "$T/common-helpers.sh"
cp "$SRC/hooks/high-watermark-auto-pause.sh" "$T/hooks/hwap.sh"
chmod +x "$T/hooks/hwap.sh"
# The stub helper answers the gate (no argument) with the first line of $STUB_SEQ,
# removing it; "ok" once the file is empty. Every call is logged.
cat > "$T/hwap-helper.sh" <<'STUB'
#!/usr/bin/env bash
printf 'helper %s\n' "$*" >> "$FAKE_LOG"
if [ -z "${1:-}" ] && [ -s "$STUB_SEQ" ]; then
  head -n1 "$STUB_SEQ"; sed -i 1d "$STUB_SEQ"
else
  printf 'ok'
fi
STUB
chmod +x "$T/hwap-helper.sh"
export STUB_SEQ="$T/seq"
seq_set() { printf '%s\n' "$@" > "$STUB_SEQ"; }

TP="$T/projects/-tmp-proj/sess1.jsonl"
SDIR="$IC_TMP_BASE/-tmp-proj/sess1"
NOW=$(date +%s)
L() { bash -c '. "$1"; n="$2"; printf %s "${!n}"' _ "$T/common-helpers.sh" "$1"; }
STOP="$(L HWAP_STOP_TEXT)" COMPACT="$(L HWAP_COMPACT_TEXT)" REASON="$(L HWAP_BLOCK_REASON)"

# hw_state key=value...: a fresh hwap state (phase_at now), these keys win.
# ic_state key=value...: the same for ideal-compact's file.
hw_state() { mkdir -p "$SDIR"; printf '%s\n' phase=idle phase_at="$NOW" "$@" > "$SDIR/hwap-compact-state"; }
ic_state() { mkdir -p "$SDIR"; printf '%s\n' phase=standby phase_at="$NOW" "$@" > "$SDIR/ideal-compact-state"; }
reset() { rm -rf "$SDIR"; mkdir -p "$SDIR"; : > "$FAKE_LOG"; : > "$STUB_SEQ"; }
hw() { sed -n "s/^$1=//p" "$SDIR/hwap-compact-state" 2>/dev/null | tail -n1; }
ic() { sed -n "s/^$1=//p" "$SDIR/ideal-compact-state" 2>/dev/null | tail -n1; }
# send <event> [jq --arg pairs]: runs the hook; RC, stdout in $T/out, stderr in $T/err
send() {
  local ev="$1"; shift
  jq -n --arg ev "$ev" --arg tp "$TP" "$@" \
    '{session_id: "sess1", transcript_path: $tp, cwd: "/tmp", hook_event_name: $ev} + ($ARGS.named | del(.ev, .tp))' \
    | "$T/hooks/hwap.sh" >"$T/out" 2>"$T/err"
  RC=$?
}
ck() { if [ "$2" = "$3" ]; then pass "$1" "$2"; else bad "$1" "$2" "got '$3'"; fi; }
hw_all() {
  local name="$1" exp="$2" got='' kv
  for kv in $exp; do got+="${kv%%=*}=$(hw "${kv%%=*}") "; done
  ck "$name" "$exp " "$got"
}
out() { cat "$T/out"; }
keys() { grep ' send-keys ' "$FAKE_LOG" 2>/dev/null; }
switched() { grep '^cswap switch' "$FAKE_LOG" 2>/dev/null; }
ctx() { printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}' "$1" "$STOP"; }

export TMUX="$T/sock,1,0" TMUX_PANE=%3
SOCK="$T/sock" CR=$'\r'
RULE="$(printf '─%.0s' 1 2 3 4 5 6 7 8 9 10)" NB=$'\xc2\xa0'
printf '%s\n❯%s\n%s\n' "$RULE" "$NB" "$RULE" > "$T/screen-empty"
printf '%s\n❯%sfix the  bug\n  in main.c\n%s\n' "$RULE" "$NB" "$RULE" > "$T/screen-restored"
printf '%s\n❯%ssomething else\n%s\n' "$RULE" "$NB" "$RULE" > "$T/screen-draft"
box() { FAKE_SCREEN="$T/screen-$1" FAKE_CURSOR="$2"; export FAKE_SCREEN FAKE_CURSOR; }
EXP_COMPACT="tmux -S $SOCK send-keys -l -t %3 /compact $COMPACT"$'\n'"tmux -S $SOCK send-keys -l -t %3 $CR"
EXP_CONT="tmux -S $SOCK send-keys -l -t %3 繼續"$'\n'"tmux -S $SOCK send-keys -l -t %3 $CR"
EXP_CR="tmux -S $SOCK send-keys -l -t %3 $CR"

# ---- starting the flow ----
reset; box empty "2 1 0"; seq_set "switch 2"
send PreToolUse --arg tool_name Bash
ck "main-start-out" "$(ctx PreToolUse)" "$(out)"
ck "main-start-keys" "$EXP_COMPACT" "$(keys)"
ck "main-start-no-switch" "" "$(switched)"
hw_all "main-start-state" "phase=queued interrupted=1 stop_pending=0"

# queued: every later tool call passes without asking the helper or typing again
: > "$FAKE_LOG"; seq_set "switch 2"
send PreToolUse --arg tool_name Bash
ck "queued-pass" "rc=0 out= log=" "rc=$RC out=$(out) log=$(cat "$FAKE_LOG")"
send PreToolUse --arg tool_name Bash --arg agent_id a1
ck "queued-sub-pass" "rc=0 out= log=" "rc=$RC out=$(out) log=$(cat "$FAKE_LOG")"

# a subagent's tool call starts it without telling the subagent; the main
# agent's next tool event carries the stop request, once
reset; box empty "2 1 0"; seq_set "switch 2"
send PreToolUse --arg tool_name Bash --arg agent_id a1
ck "sub-start-out" "" "$(out)"
ck "sub-start-keys" "$EXP_COMPACT" "$(keys)"
hw_all "sub-start-state" "phase=queued interrupted=0 stop_pending=1"
send PostToolUse --arg tool_name Bash --arg agent_id a1
ck "sub-posttool-sub-quiet" "" "$(out)"
send PostToolUse --arg tool_name Bash
ck "sub-posttool-main-out" "$(ctx PostToolUse)" "$(out)"
hw_all "sub-posttool-main-state" "phase=queued interrupted=1 stop_pending=0"
send PostToolUse --arg tool_name Bash
ck "sub-posttool-once" "" "$(out)"
reset; box empty "2 1 0"; hw_state phase=queued stop_pending=1
send PreToolUse --arg tool_name Bash
ck "sub-pretool-main-out" "$(ctx PreToolUse)" "$(out)"
hw_all "sub-pretool-main-state" "interrupted=1 stop_pending=0"
reset; hw_state phase=queued stop_pending=1
send UserPromptSubmit --arg prompt '<agent-message from="x">done</agent-message>'
ck "sub-handback-carries-stop" "$(ctx UserPromptSubmit)" "$(out)"
reset; hw_state phase=idle stop_pending=0
send PostToolUse --arg tool_name Bash
ck "posttool-idle-quiet" "rc=0 out= log=" "rc=$RC out=$(out) log=$(cat "$FAKE_LOG")"

# the user's prompt is blocked and kept; no turn starts
reset; box empty "2 1 0"; seq_set "switch 2"
send UserPromptSubmit --arg prompt $'fix the bug\nin main.c'
ck "prompt-block-out" "{\"decision\":\"block\",\"reason\":\"$REASON\"}" "$(out)"
ck "prompt-block-keys" "$EXP_COMPACT" "$(keys)"
ck "prompt-block-kept" $'fix the bug\nin main.c' "$(cat "$SDIR/hwap-compact-prompt")"
hw_all "prompt-block-state" "phase=queued interrupted=0"
[ ! -e "$SDIR/turn_start" ] && pass "prompt-block-no-turn" "no turn_start" || bad "prompt-block-no-turn" "none" "stamped"

# a hand-back is never blocked: its result would be lost
reset; box empty "2 1 0"; seq_set "switch 2"
send UserPromptSubmit --arg prompt '<task-notification>shell done</task-notification>'
ck "handback-out" "$(ctx UserPromptSubmit)" "$(out)"
hw_all "handback-state" "phase=queued interrupted=1"

# ---- falling back to the direct switch ----
# The helper keeps naming account 2 until the switch is made, so the gate's
# second (direct) call sees it again.
fallback() {  # <name>: nothing typed, switched to account 2, no flow
  ck "$1-keys" "" "$(keys)"
  ck "$1-switched" "cswap switch 2" "$(switched)"
  local ph; ph="$(hw phase)"
  ck "$1-state" "idle" "${ph:-idle}"
}
reset; box draft "16 1 0"; seq_set "switch 2" "switch 2"
send PreToolUse --arg tool_name Bash
fallback "draft"
reset; box empty "2 1 0"; seq_set "switch 2" "switch 2"
(unset TMUX TMUX_PANE; send PreToolUse --arg tool_name Bash)
fallback "no-mux"
for ph in to-compact compacting waiting continuing; do
  reset; box empty "2 1 0"; seq_set "switch 2" "switch 2"; ic_state phase=$ph
  send PreToolUse --arg tool_name Bash
  fallback "ic-$ph"
done
# nothing to compact (no assistant message since the last compact boundary):
# /compact would fail without a PostCompact, so the switch is direct
mkdir -p "$(dirname "$TP")"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}' > "$TP"
reset; box empty "2 1 0"; seq_set "switch 2" "switch 2"
send UserPromptSubmit --arg prompt "hello"
fallback "no-history"
ck "no-history-not-blocked" "" "$(out)"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":"x"}}' \
  '{"type":"system","subtype":"compact_boundary"}' '{"type":"user","message":{"role":"user","content":"summary"}}' > "$TP"
reset; box empty "2 1 0"; seq_set "switch 2" "switch 2"
send PreToolUse --arg tool_name Bash
fallback "history-before-boundary"
printf '%s\n' '{"type":"system","subtype":"compact_boundary"}' '{"type":"assistant","message":{"role":"assistant","content":"x"}}' > "$TP"
reset; box empty "2 1 0"; seq_set "switch 2"
send PreToolUse --arg tool_name Bash
ck "history-after-boundary" "queued" "$(hw phase)"
rm -f "$TP"

# a main-agent tool call while compacting: the compact failed, the gate is back
reset; hw_state phase=compacting; seq_set "switch 2" "switch 2"
box draft "16 1 0"
send PreToolUse --arg tool_name Bash
ck "compacting-main-tool" "idle cswap switch 2" "$(hw phase) $(switched)"
reset; hw_state phase=compacting; seq_set "switch 2"
send PreToolUse --arg tool_name Bash --arg agent_id a1
ck "compacting-sub-tool" "compacting " "$(hw phase) $(switched)"

reset; box empty "2 1 0"; seq_set "error:x"
send PreToolUse --arg tool_name Bash
ck "helper-error" "rc=1 keys=" "rc=$RC keys=$(keys)"

# ---- taking ideal-compact over ----
for ph in armed stopped; do
  reset; box empty "2 1 0"; seq_set "switch 2"; ic_state phase=$ph skip=0
  send PreToolUse --arg tool_name Bash
  ck "ic-$ph-takeover" "queued skip=1 phase=$ph" "$(hw phase) skip=$(ic skip) phase=$(ic phase)"
done
reset; box empty "2 1 0"; seq_set "switch 2"; ic_state phase=standby skip=0
send PreToolUse --arg tool_name Bash
ck "ic-standby-untouched" "queued skip=0" "$(hw phase) skip=$(ic skip)"
# /compact cannot be typed: no compact is coming, so ideal-compact gets its
# skip back and the switch is direct
reset; box empty "2 1 0"; seq_set "switch 2" "switch 2"; ic_state phase=armed skip=0
FAKE_FAIL_SEND_KEYS=1 send PreToolUse --arg tool_name Bash
ck "send-fail-skip-restored" "skip=0 phase=armed" "skip=$(ic skip) phase=$(ic phase)"
# (the failed send-keys is still in the fake's log, so no fallback's -keys row)
ck "send-fail-switched" "cswap switch 2 idle" "$(switched) $(hw phase)"
ck "send-fail-quiet" "" "$(out)"
# ideal-compact moves on between hwap's unlocked check and its locked re-read
# (the fake tmux's capture-pane runs inside that window): hwap backs off
reset; box empty "2 1 0"; seq_set "switch 2" "switch 2"; ic_state phase=armed skip=0
FAKE_ON_CAPTURE="sed -i 's/^phase=armed\$/phase=to-compact/' '$SDIR/ideal-compact-state'" \
  send PreToolUse --arg tool_name Bash
ck "ic-moved-on-skip" "skip=0 phase=to-compact" "skip=$(ic skip) phase=$(ic phase)"
fallback "ic-moved-on"

# another hook starts the flow inside the same window: this event passes
# like one arriving while queued (a user prompt is not blocked, starts a turn
# and carries a waiting stop request)
race_hw="printf '%s\\n' phase=queued phase_at=$NOW stop_pending=1 > '$SDIR/hwap-compact-state'"
reset; box empty "2 1 0"; seq_set "switch 2"
FAKE_ON_CAPTURE="$race_hw" send UserPromptSubmit --arg prompt "hello"
ck "race-prompt-out" "$(ctx UserPromptSubmit)" "$(out)"
ck "race-prompt-keys" "" "$(keys)"
hw_all "race-prompt-state" "phase=queued interrupted=1 stop_pending=0"
[ -f "$SDIR/turn_start" ] && pass "race-prompt-stamp" "turn_start" || bad "race-prompt-stamp" "turn_start" "missing"
reset; box empty "2 1 0"; seq_set "switch 2"
FAKE_ON_CAPTURE="$race_hw" send PreToolUse --arg tool_name Bash --arg agent_id a1
ck "race-sub-quiet" "" "$(out)$(keys)$(switched)"
hw_all "race-sub-state" "phase=queued stop_pending=1"

# ---- Stop, PreCompact, timeouts, SessionStart ----
reset; hw_state phase=queued
send Stop
ck "stop-queued" "stopping" "$(hw phase)"
[ -f "$SDIR/turn_stop" ] && pass "stop-stamp" "turn_stop" || bad "stop-stamp" "turn_stop" "missing"
for ph in queued stopping; do
  for trig in manual auto; do
    reset; hw_state phase=$ph stop_pending=1
    send PreCompact --arg trigger $trig
    hw_all "precompact-$ph-$trig" "phase=compacting stop_pending=0"
  done
done
reset; hw_state phase=idle
send PreCompact --arg trigger manual
ck "precompact-idle" "idle" "$(hw phase)"
reset; hw_state phase=stopping phase_at=$((NOW - 200)) interrupted=1
printf 'x' > "$SDIR/hwap-compact-prompt"
send PreToolUse --arg tool_name Bash
hw_all "ttl-stopping" "phase=idle interrupted=0"
[ ! -e "$SDIR/hwap-compact-prompt" ] && pass "ttl-prompt-gone" "removed" || bad "ttl-prompt-gone" "removed" "kept"
reset; hw_state phase=stopping phase_at=$((NOW - 60))
send PreToolUse --arg tool_name Bash
ck "ttl-stopping-fresh" "stopping" "$(hw phase)"
reset; hw_state phase=compacting phase_at=$((NOW - 1000))
send Stop
ck "ttl-compacting" "idle" "$(hw phase)"
reset; sleep 0 & dead=$!; wait "$dead"; hw_state phase=waiting pc_pid=$dead
send Stop
ck "ttl-waiting-dead" "idle" "$(hw phase)"
reset; hw_state phase=waiting pc_pid=$CLEAN_PID
send Stop
ck "ttl-waiting-alive" "waiting" "$(hw phase)"
for src in startup resume clear compact; do
  reset; hw_state phase=queued stop_pending=1 interrupted=1
  send SessionStart --arg source $src
  if [ $src = compact ]; then exp=queued; else exp=idle; fi
  ck "sessionstart-$src" "$exp" "$(hw phase)"
done
# a prompt file left behind with no state file is removed too
reset; printf 'x' > "$SDIR/hwap-compact-prompt"
send SessionStart --arg source startup
ck "sessionstart-orphan-prompt" "gone" "$([ -e "$SDIR/hwap-compact-prompt" ] && echo kept || echo gone)"

# queued: a user prompt passes and starts a turn
reset; hw_state phase=queued; seq_set "switch 2"
send UserPromptSubmit --arg prompt "hello"
ck "queued-prompt" "rc=0 out= log=" "rc=$RC out=$(out) log=$(cat "$FAKE_LOG")"
[ -f "$SDIR/turn_start" ] && pass "queued-prompt-stamp" "turn_start" || bad "queued-prompt-stamp" "turn_start" "missing"

# ---- PostCompact ----
pc() {  # <screen> <cursor> <seq...|-> then state args via PC_STATE
  box "$1" "$2"; shift 2
  reset; [ "$1" = - ] || seq_set "$@"
  hw_state phase=compacting $PC_STATE
  send PostCompact --arg trigger manual
}
PC_STATE="interrupted=1" pc empty "2 1 0" "switch 2"
ck "pc-interrupted-switch" "cswap switch 2" "$(switched)"
ck "pc-interrupted-keys" "$EXP_CONT" "$(keys)"
ck "pc-interrupted-state" "idle rc=0" "$(hw phase) rc=$RC"
PC_STATE="interrupted=0" pc empty "2 1 0" -
ck "pc-waiting-agent-nothing" "" "$(keys)"
ck "pc-waiting-agent-state" "idle" "$(hw phase)"
PC_STATE="interrupted=1" pc draft "16 1 0" -
ck "pc-draft-no-continue" "" "$(keys)"
grep -q '繼續 not sent (input box: draft)' "$T/err" && pass "pc-draft-note" "stderr" || bad "pc-draft-note" "stderr" "$(cat "$T/err")"
# the blocked prompt, put back in the box by Claude Code: CR only when it is still exactly there
box restored "11 2 0"; reset; hw_state phase=compacting
printf '%s' $'fix the bug\nin main.c' > "$SDIR/hwap-compact-prompt"
send PostCompact --arg trigger manual
ck "pc-prompt-restored-cr" "$EXP_CR" "$(keys)"
ck "pc-prompt-restored-state" "idle gone" "$(hw phase) $([ -e "$SDIR/hwap-compact-prompt" ] && echo kept || echo gone)"
box draft "16 1 0"; reset; hw_state phase=compacting
printf '%s' $'fix the bug\nin main.c' > "$SDIR/hwap-compact-prompt"
send PostCompact --arg trigger manual
ck "pc-prompt-other-draft" "" "$(keys)"
grep -q 'blocked prompt was not resubmitted (input box: draft)' "$T/err" && pass "pc-prompt-other-note" "stderr" || bad "pc-prompt-other-note" "stderr" "$(cat "$T/err")"
box empty "2 1 0"; reset; hw_state phase=compacting interrupted=1
printf '%s' 'fix it' > "$SDIR/hwap-compact-prompt"
send PostCompact --arg trigger manual
ck "pc-prompt-empty-typed" "tmux -S $SOCK send-keys -l -t %3 fix it"$'\n'"$EXP_CR" "$(keys)"
box empty "2 1 0"; reset; hw_state phase=compacting
printf '%s' $'two\nlines' > "$SDIR/hwap-compact-prompt"
send PostCompact --arg trigger manual
ck "pc-prompt-multiline-empty" "" "$(keys)"
for ph in idle queued stopping waiting; do
  box empty "2 1 0"; reset; hw_state phase=$ph interrupted=1 pc_pid=$CLEAN_PID
  send PostCompact --arg trigger manual
  ck "pc-in-$ph" "$ph||" "$(hw phase)|$(keys)|$(out)"
done

# a kill while waiting for an account: back to idle, nothing typed, exit 1
box empty "2 1 0"; reset; hw_state phase=compacting interrupted=1
seq_set "wait $((NOW + 600)) $((NOW + 500))"
jq -n --arg tp "$TP" '{session_id: "sess1", transcript_path: $tp, hook_event_name: "PostCompact", trigger: "manual"}' \
  | "$T/hooks/hwap.sh" >"$T/out" 2>"$T/err" & PC=$!
KILLS+=("$PC")
for _ in $(seq 50); do [ "$(hw phase)" = waiting ] && break; sleep 0.1; done
ck "pc-kill-waiting" "waiting $PC" "$(hw phase) $(hw pc_pid)"
sleep 0.3; kill -TERM "$PC"; wait "$PC"; RC=$?
ck "pc-kill" "rc=1 idle keys=" "rc=$RC $(hw phase) keys=$(keys)"

unset TMUX TMUX_PANE FAKE_SCREEN FAKE_CURSOR
exit $fail
