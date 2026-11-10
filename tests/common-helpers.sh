#!/usr/bin/env bash
# Tests for common-helpers.sh (the shared library) and the gate hook that sources it.
# Usage: common-helpers.sh
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

# Layout mirroring ~/.claude: <T>/common-helpers.sh, <T>/hwap-helper.sh (stub), <T>/hooks/<hook>.sh
mkdir -p "$T/hooks"
cp "$SRC/common-helpers.sh" "$T/common-helpers.sh"
cp "$SRC/hooks/high-watermark-auto-pause.sh" "$T/hooks/high-watermark-auto-pause.sh"
chmod +x "$T/hooks/high-watermark-auto-pause.sh"
# The stub helper prints the first line of $STUB_SEQ and removes it, one answer per call; "ok" once the file is empty.
cat > "$T/hwap-helper.sh" <<'STUB'
#!/usr/bin/env bash
if [ -s "$STUB_SEQ" ]; then
  head -n1 "$STUB_SEQ"
  sed -i 1d "$STUB_SEQ"
else
  printf 'ok'
fi
STUB
chmod +x "$T/hwap-helper.sh"
export STUB_SEQ="$T/seq"

fail=0
pass() { echo "PASS [$1] $2"; }
bad()  { echo "FAIL [$1] $2 -> $3"; fail=1; }
seq_set() { printf '%s\n' "$@" > "$STUB_SEQ"; }
# run_gate [abort_fn]: runs __gate in a fresh bash, prints "rc=<n> secs=<n>" and keeps stderr in $T/err
run_gate() {
  local s e rc
  s=$(date +%s.%N)
  bash -c '. "$1"; __IC_HELPER="$2"; __gate "${3:-}"; echo "rc=$?"' _ "$T/common-helpers.sh" "$T/hwap-helper.sh" "${1:-}" 2>"$T/err" >"$T/out"
  e=$(date +%s.%N)
  rc="$(grep -o 'rc=[0-9]*' "$T/out")"
  printf '%s secs=%s' "$rc" "$(awk -v a="$s" -v b="$e" 'BEGIN{printf "%.1f", b-a}')"
}
secs_between() { awk -v v="${1##*secs=}" -v lo="$2" -v hi="$3" 'BEGIN{exit !(v>=lo && v<=hi)}'; }

# ---- sourcing the library ----
out="$(bash -c 'set -u; . "$1"; declare -F __field >/dev/null && echo has_field; echo "${IDEAL_COMPACT_WARN_TASKS}/${IDEAL_COMPACT_ARM_TASKS}/${IDEAL_COMPACT_MARKER}/${IDEAL_COMPACT_RATE_SAMPLES}/${IDEAL_COMPACT_HISTORY_PER_ACCOUNT}/${IDEAL_COMPACT_SENT_TTL_SEC}/${IDEAL_COMPACT_COMPACT_TTL_SEC}/${IDEAL_COMPACT_STOPPED_TTL_SEC}/${IDEAL_COMPACT_CONTINUE_TEXT}"' _ "$T/common-helpers.sh" 2>&1)"
[ "$out" = '6/3/[[STOP_FOR_COMPACT]]/5/20/120/900/900/繼續' ] && pass source "set -u: no __field, constants defined, no output" || bad source "constants" "$out"
src_out="$(bash -c 'set -u; . "$1"' _ "$T/common-helpers.sh" 2>&1 </dev/null)"
[ -z "$src_out" ] && pass source-quiet "sourcing prints nothing" || bad source-quiet "output" "$src_out"
for v in PAUSE COMPACT CANCEL; do
  txt="$(bash -c '. "$1"; n=IDEAL_COMPACT_'$v'_TEXT; printf %s "${!n}"' _ "$T/common-helpers.sh")"
  [ -n "$txt" ] && pass "text-$v" "defined ($(printf %s "$txt" | wc -c) bytes)" || bad "text-$v" "empty" ""
done
pause="$(bash -c '. "$1"; printf %s "$IDEAL_COMPACT_PAUSE_TEXT"' _ "$T/common-helpers.sh")"
case "$pause" in *'`[[STOP_FOR_COMPACT]]`'*'`/loop`執行中'*) pass text-pause-ticks "backticks kept verbatim" ;; *) bad text-pause-ticks "ticks" "$pause" ;; esac
[ "$(bash -c '. "$1"; printf %s "$__IC_HELPER"' _ "$T/common-helpers.sh")" = "$T/hwap-helper.sh" ] \
  && pass helper-path "default __IC_HELPER sits next to the library" || bad helper-path "default" ""

# ---- __gate ----
NOW=$(date +%s)
: > "$FAKE_LOG"
seq_set ok
r="$(run_gate)"; [ "$r" = "rc=0 secs=${r##*secs=}" ] && secs_between "$r" 0 0.9 && pass gate-ok "ok -> rc 0 without sleeping" || bad gate-ok "ok" "$r"

seq_set "wait $((NOW + 2)) $((NOW + 1))" ok
r="$(run_gate)"; case "$r" in rc=0*) secs_between "$r" 1.0 3.5 && pass gate-wait "wait then ok -> rc 0 after ~2 s ($r)" || bad gate-wait "timing" "$r" ;; *) bad gate-wait "rc" "$r" ;; esac
[ -e "$IC_TMP_BASE/hwap-hold-until" ] && bad gate-hold-cleared "hold file left behind" "" || pass gate-hold-cleared "hold file removed when the gate finishes"

: > "$FAKE_LOG"
seq_set "switch 3" ok
r="$(run_gate)"; case "$r" in rc=0*) grep -qx 'cswap switch 3' "$FAKE_LOG" && pass gate-switch "switch 3 -> cswap switch 3, then rc 0" || bad gate-switch "no switch logged" "$(cat "$FAKE_LOG")" ;; *) bad gate-switch "rc" "$r" ;; esac

seq_set "error:x"
r="$(run_gate)"; case "$r" in rc=3*) grep -q 'cswap check failed (x)' "$T/err" && pass gate-error "error:x -> rc 3 + stderr message" || bad gate-error "stderr" "$(cat "$T/err")" ;; *) bad gate-error "rc" "$r" ;; esac

NOW=$(date +%s)
abort_once() { return 1; }
export -f abort_once
seq_set "wait $((NOW + 300)) $((NOW + 299))"
r="$(run_gate abort_once)"; case "$r" in rc=4*) secs_between "$r" 0 1.0 && pass gate-abort "abort fn failing -> rc 4 within 1 s" || bad gate-abort "timing" "$r" ;; *) bad gate-abort "rc" "$r" ;; esac
[ -e "$IC_TMP_BASE/hwap-hold-until" ] && bad gate-abort-hold "hold file left behind" "" || pass gate-abort-hold "hold file removed on abort"

# abort fn that keeps saying yes does not stop a normal wait
abort_never() { return 0; }
export -f abort_never
NOW=$(date +%s); seq_set "wait $((NOW + 1)) $((NOW))" ok
r="$(run_gate abort_never)"; case "$r" in rc=0*) pass gate-abort-ok "abort fn returning 0 lets the gate finish" ;; *) bad gate-abort-ok "rc" "$r" ;; esac

# SIGTERM during a long wait ends a subshell with a TERM trap at once
NOW=$(date +%s); seq_set "wait $((NOW + 300)) $((NOW + 299))"
( . "$T/common-helpers.sh"; __IC_HELPER="$T/hwap-helper.sh"; trap 'exit 0' TERM; __gate; exit 9 ) >/dev/null 2>&1 &
pid=$!
sleep 0.7
spid="$(pgrep -P "$pid" sleep)"  # the orphaned sleep, cleaned up below
s=$(date +%s.%N); kill -TERM "$pid"; wait "$pid"; rc=$?; e=$(date +%s.%N)
d="$(awk -v a="$s" -v b="$e" 'BEGIN{printf "%.1f", b-a}')"
[ "$rc" = 0 ] && awk -v d="$d" 'BEGIN{exit !(d<=1.0)}' && pass gate-sigterm "TERM during a 300 s wait ended it in ${d}s" || bad gate-sigterm "rc=$rc after ${d}s" ""
[ -n "$spid" ] && kill "$spid" 2>/dev/null

# ---- the real gate hook, sourcing the library ----
PRE='{"hook_event_name":"PreToolUse","session_id":"s1"}'
seq_set "error:x"
hout="$("$T/hooks/high-watermark-auto-pause.sh" <<<"$PRE" 2>"$T/herr")"; hrc=$?
[ "$hrc" = 1 ] && [ -z "$hout" ] && grep -q 'high-watermark-auto-pause: cswap check failed (x); skipping rate-limit gate for this turn' "$T/herr" \
  && pass hook-error "helper error -> exit 1, same stderr message" || bad hook-error "rc=$hrc" "$(cat "$T/herr")"
seq_set ok
hout="$("$T/hooks/high-watermark-auto-pause.sh" <<<"$PRE" 2>"$T/herr")"; hrc=$?
[ "$hrc" = 0 ] && [ -z "$hout" ] && [ ! -s "$T/herr" ] && pass hook-ok "ok -> exit 0, silent" || bad hook-ok "rc=$hrc" "$(cat "$T/herr")"
mv "$T/common-helpers.sh" "$T/common-helpers.sh.off"
hout="$("$T/hooks/high-watermark-auto-pause.sh" <<<"$PRE" 2>"$T/herr")"; hrc=$?
mv "$T/common-helpers.sh.off" "$T/common-helpers.sh"
[ "$hrc" = 1 ] && grep -qx 'high-watermark-auto-pause: common-helpers.sh not found' "$T/herr" \
  && pass hook-no-lib "missing library -> exit 1 + message" || bad hook-no-lib "rc=$hrc" "$(cat "$T/herr")"

# ---- path helpers ----
ic() { bash -c 'set -u; . "$1"; shift; "$@"' _ "$T/common-helpers.sh" "$@"; }
tp="$(ic __ic_translated_path "$HOME/.claude/projects/-home-tim-projects-env-setup/abc.jsonl")"
[ "$tp" = "-home-tim-projects-env-setup" ] && pass translated "transcript path -> project dir name" || bad translated "got" "$tp"
[ -z "$(ic __ic_translated_path '')" ] && pass translated-empty "empty input -> empty" || bad translated-empty "not empty" ""
[ "$(ic __ic_session_dir "/h/projects/-p/abc.jsonl" sid1)" = "$IC_TMP_BASE/-p/sid1" ] \
  && pass session-dir "<base>/<translated>/<sid>" || bad session-dir "got" "$(ic __ic_session_dir "/h/projects/-p/abc.jsonl" sid1)"
[ -z "$(ic __ic_session_dir '' sid1)" ] && [ -z "$(ic __ic_session_dir "/h/projects/-p/abc.jsonl" '')" ] \
  && pass session-dir-empty "empty transcript or sid -> empty" || bad session-dir-empty "not empty" ""
[ ! -e "$IC_TMP_BASE/-p" ] && pass session-dir-nomkdir "prints only, creates nothing" || bad session-dir-nomkdir "created" "$IC_TMP_BASE/-p"

REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
want="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir | sed 's#/\.git$##; s/[^A-Za-z0-9]/-/g')"
[ -n "$want" ] || { echo "cannot compute expected repo key"; exit 2; }
[ "$(ic __ic_repo_key "$REPO_ROOT")" = "$want" ] && pass repo-key-root "this checkout -> $want" || bad repo-key-root "got" "$(ic __ic_repo_key "$REPO_ROOT")"
[ "$(ic __ic_repo_key "$REPO_ROOT/ansible/roles")" = "$want" ] && pass repo-key-subdir "subdirectory -> same key" || bad repo-key-subdir "got" "$(ic __ic_repo_key "$REPO_ROOT/ansible/roles")"

# a throwaway repo with a linked worktree: both give the main repo's key (never touches the real repo)
GR="$T/gitrepo"; GW="$T/gitwt"
git init -q "$GR" && git -C "$GR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
  && git -C "$GR" worktree add -q "$GW" -b wt >/dev/null 2>&1
want_tmp="$(printf '%s' "$GR" | sed 's/[^A-Za-z0-9]/-/g')"
[ "$(ic __ic_repo_key "$GR")" = "$want_tmp" ] && pass repo-key-tmp "temp repo -> its path" || bad repo-key-tmp "got" "$(ic __ic_repo_key "$GR")"
[ "$(ic __ic_repo_key "$GW")" = "$want_tmp" ] && pass repo-key-worktree "linked worktree -> main repo's key" || bad repo-key-worktree "got" "$(ic __ic_repo_key "$GW")"

NG="$T/nogit"; mkdir -p "$NG"
[ -z "$(ic __ic_repo_key "$NG")" ] && pass repo-key-nogit "outside git -> empty" || bad repo-key-nogit "not empty" "$(ic __ic_repo_key "$NG")"
[ -z "$(ic __ic_repo_key '')" ] && pass repo-key-empty "empty dir -> empty" || bad repo-key-empty "not empty" ""
[ "$(ic __ic_project_dir "$GW" "/h/projects/-p/abc.jsonl")" = "$IC_TMP_BASE/$want_tmp" ] \
  && pass project-dir-git "git: <base>/<repo key>" || bad project-dir-git "got" "$(ic __ic_project_dir "$GW" "/h/projects/-p/abc.jsonl")"
[ "$(ic __ic_project_dir "$NG" "/h/projects/-p/abc.jsonl")" = "$IC_TMP_BASE/-p" ] \
  && pass project-dir-nogit "no git: falls back to the translated path" || bad project-dir-nogit "got" "$(ic __ic_project_dir "$NG" "/h/projects/-p/abc.jsonl")"

# ---- the hook's turn stamps ----
sdir="$IC_TMP_BASE/-proj-a/s9"
UPS='{"hook_event_name":"UserPromptSubmit","session_id":"s9","transcript_path":"/h/.claude/projects/-proj-a/s9.jsonl","prompt":"hi"}'
seq_set ok
"$T/hooks/high-watermark-auto-pause.sh" <<<"$UPS" >/dev/null 2>&1
[ -f "$sdir/turn_start" ] && [ ! -e "$IC_TMP_BASE/s9" ] \
  && pass stamp-start "turn_start under <base>/<translated>/<sid>/, not <base>/<sid>/" || bad stamp-start "layout" "$(find "$IC_TMP_BASE" -name 'turn_*' 2>&1)"
"$T/hooks/high-watermark-auto-pause.sh" <<<"${UPS/UserPromptSubmit/Stop}" >/dev/null 2>&1
[ -f "$sdir/turn_stop" ] && pass stamp-stop "turn_stop beside it" || bad stamp-stop "missing" "$(ls "$sdir")"
rm -rf "$IC_TMP_BASE/-proj-a" "$IC_TMP_BASE/s8"
NOTP='{"hook_event_name":"UserPromptSubmit","session_id":"s8","prompt":"hi"}'
seq_set ok
"$T/hooks/high-watermark-auto-pause.sh" <<<"$NOTP" >/dev/null 2>&1
[ -z "$(find "$IC_TMP_BASE" -name 'turn_*')" ] && [ ! -e "$IC_TMP_BASE/s8" ] \
  && pass stamp-no-transcript "no transcript_path -> nothing written" || bad stamp-no-transcript "wrote" "$(find "$IC_TMP_BASE" -name 'turn_*')"

# ---- state file ----
KEYS="phase phase_at skip suppress suppress_key suppress_win suppress_resets dirty ledger ledger_done armed_key armed_win armed_resets cheap_obs inputbox_fail pending_inject"
DUMP='for k in '"$KEYS"'; do n=IC_$k; printf "%s=%s\n" "$k" "${!n}"; done'
DEFAULTS="$(printf '%s\n' phase=standby phase_at=0 skip=0 suppress=0 suppress_key= suppress_win= suppress_resets=0 dirty=0 ledger= ledger_done=0 armed_key= armed_win= armed_resets=0 cheap_obs= inputbox_fail=0 pending_inject=)"
# sc '<script>': the script runs in a fresh bash with the library sourced under set -u
sc() { bash -c 'set -u; . "$1"; shift; eval "$1"' _ "$T/common-helpers.sh" "$1"; }

SD="$T/sess/s1"
out="$(sc "IC_phase=armed IC_dirty=7 IC_cheap_obs=old; __ic_state_read '$T/sess/missing'; $DUMP" 2>&1)"
[ "$out" = "$DEFAULTS" ] && pass state-missing "missing file -> every IC_<key> at its default (and stale values reset)" || bad state-missing "got" "$out"
out="$(sc "__ic_state_read ''; $DUMP" 2>&1)"
[ "$out" = "$DEFAULTS" ] && pass state-no-dir "empty session dir -> defaults" || bad state-no-dir "got" "$out"

sc "IC_phase=to-compact IC_phase_at=1700000000 IC_skip=1 IC_suppress=1 IC_suppress_key=sk IC_suppress_win=5h IC_suppress_resets=1700000500 IC_dirty=3 IC_ledger=/a/b/ledger.md IC_ledger_done=4 IC_armed_key=ak IC_armed_win=7d IC_armed_resets=1700009999 IC_cheap_obs='3 4  5=x' IC_inputbox_fail=2 IC_pending_inject='繼續 now'; __ic_state_write '$SD'"
[ -f "$SD/ideal-compact-state" ] && [ "$(ls -A "$SD" | wc -l)" = 1 ] && pass state-write "mkdir -p, one file, no temp left behind" || bad state-write "dir" "$(ls -A "$SD" 2>&1)"
want="$(printf '%s\n' phase=to-compact phase_at=1700000000 skip=1 suppress=1 suppress_key=sk suppress_win=5h suppress_resets=1700000500 dirty=3 ledger=/a/b/ledger.md ledger_done=4 armed_key=ak armed_win=7d armed_resets=1700009999 'cheap_obs=3 4  5=x' inputbox_fail=2 'pending_inject=繼續 now')"
[ "$(sc "__ic_state_read '$SD'; $DUMP")" = "$want" ] && pass state-roundtrip "every key survives write -> read (spaces, '=' and CJK in values)" || bad state-roundtrip "got" "$(sc "__ic_state_read '$SD'; $DUMP")"
[ "$(cat "$SD/ideal-compact-state")" = "$want" ] && pass state-format "plain key=value lines" || bad state-format "file" "$(cat "$SD/ideal-compact-state")"

mkdir -p "$T/g"
printf 'phase=bogus\n\nphase_at\n=x\nskip=1\ndirty=abc\nsuppress_key=kk\nunknown=zz\nsuppress_resets=-5\nlinewithout\nledger_done=x1\narmed_win=7d\ncheap_obs=a=b c\narme' > "$T/g/ideal-compact-state"
out="$(sc "__ic_state_read '$T/g'; $DUMP" 2>&1)"
want="$(printf '%s\n' phase=standby phase_at=0 skip=1 suppress=0 suppress_key=kk suppress_win= suppress_resets=0 dirty=0 ledger= ledger_done=0 armed_key= armed_win=7d armed_resets=0 'cheap_obs=a=b c' inputbox_fail=0 pending_inject=)"
[ "$out" = "$want" ] && pass state-garbage "bogus phase, '=x', no-'=', non-numbers, unknown key, truncated tail -> defaults, rest kept, no output" || bad state-garbage "got" "$out"
: > "$T/g/ideal-compact-state"
[ "$(sc "__ic_state_read '$T/g'; $DUMP" 2>&1)" = "$DEFAULTS" ] && pass state-empty "empty file -> defaults" || bad state-empty "got" "$(sc "__ic_state_read '$T/g'; $DUMP" 2>&1)"
for ph in standby armed waiting to-compact compacting continuing stopped; do
  printf 'phase=%s\n' "$ph" > "$T/g/ideal-compact-state"
  [ "$(sc "__ic_state_read '$T/g'; echo \$IC_phase")" = "$ph" ] && pass "state-phase-$ph" "read as is" || bad "state-phase-$ph" "got" "$(sc "__ic_state_read '$T/g'; echo \$IC_phase")"
done

# __ic_set_phase
out="$(sc "IC_phase=armed IC_skip=1 IC_pending_inject=x IC_phase_at=5; b=\$(date +%s); __ic_set_phase standby; a=\$(date +%s); echo \"\$IC_phase \$IC_skip [\$IC_pending_inject] \$((IC_phase_at>=b && IC_phase_at<=a))\"")"
[ "$out" = "standby 0 [] 1" ] && pass setphase-standby "standby clears skip and pending_inject, stamps phase_at" || bad setphase-standby "got" "$out"
out="$(sc "IC_phase=armed IC_skip=1 IC_pending_inject=x; __ic_set_phase to-compact; echo \"\$IC_phase \$IC_skip [\$IC_pending_inject]\"")"
[ "$out" = "to-compact 1 []" ] && pass setphase-other "other phase keeps skip, clears pending_inject" || bad setphase-other "got" "$out"

# __ic_ttl_check: rows are "phase ttl"
suppress_kw='armed_key=AK
armed_win=5h
armed_resets=1700004000'
ttl_run() {  # ttl_run <phase> <age> -> "rc phase suppress key/win/resets skip"
  local d="$T/ttl"; rm -rf "$d"; mkdir -p "$d"
  printf 'phase=%s\nphase_at=1700000000\nskip=1\ndirty=2\n%s\n' "$1" "$suppress_kw" > "$d/ideal-compact-state"
  sc "__ic_state_read '$d'; __ic_ttl_check $((1700000000 + $2)); r=\$?; echo \"\$r \$IC_phase \$IC_suppress \$IC_suppress_key/\$IC_suppress_win/\$IC_suppress_resets \$IC_skip \$IC_dirty\""
}
for row in "to-compact 120" "continuing 120" "compacting 900" "stopped 900"; do
  set -- $row
  [ "$(ttl_run "$1" "$2")" = "1 $1 0 //0 1 2" ] && pass "ttl-$1-edge" "$2 s -> unchanged" || bad "ttl-$1-edge" "got" "$(ttl_run "$1" "$2")"
  [ "$(ttl_run "$1" "$(($2 + 1))")" = "0 standby 1 AK/5h/1700004000 0 2" ] && pass "ttl-$1-expired" "$(($2 + 1)) s -> standby, suppress=1, armed_* copied, skip cleared" || bad "ttl-$1-expired" "got" "$(ttl_run "$1" "$(($2 + 1))")"
done
for ph in armed waiting standby; do
  [ "$(ttl_run "$ph" 864000)" = "1 $ph 0 //0 1 2" ] && pass "ttl-$ph-never" "10 days -> unchanged" || bad "ttl-$ph-never" "got" "$(ttl_run "$ph" 864000)"
done
[ "$(ttl_run to-compact 119)" = "1 to-compact 0 //0 1 2" ] && pass ttl-young "well under the TTL -> unchanged" || bad ttl-young "got" "$(ttl_run to-compact 119)"

# __ic_phase_display
d="$T/disp"; mkdir -p "$d"
printf 'phase=to-compact\nphase_at=%s\nskip=1\narmed_key=AK\n' "$(( $(date +%s) - 500 ))" > "$d/ideal-compact-state"
before="$(cksum < "$d/ideal-compact-state")"
out="$(sc "IC_phase=armed IC_armed_key=mine IC_dirty=9; p=\$(__ic_phase_display '$d' \$(date +%s)); echo \"\$p \$IC_phase \$IC_armed_key \$IC_dirty\"")"
[ "$out" = "standby armed mine 9" ] && pass display-expired "expired to-compact shows standby, caller's IC_* untouched" || bad display-expired "got" "$out"
[ "$before" = "$(cksum < "$d/ideal-compact-state")" ] && pass display-readonly "file byte-identical afterwards" || bad display-readonly "file changed" ""
printf 'phase=compacting\nphase_at=%s\n' "$(( $(date +%s) - 500 ))" > "$d/ideal-compact-state"
[ "$(sc "__ic_phase_display '$d' \$(date +%s)")" = "compacting" ] && pass display-live "unexpired phase shown as is" || bad display-live "got" "$(sc "__ic_phase_display '$d' \$(date +%s)")"
[ "$(sc "__ic_phase_display '$T/nodir' \$(date +%s)")" = "standby" ] && pass display-missing "no state file -> standby" || bad display-missing "got" "$(sc "__ic_phase_display '$T/nodir' \$(date +%s)")"

# locks
out="$(sc "__ic_lock '$T/lk/new/x.lock'; r1=\$?; f1=\$__IC_LOCK_FD; __ic_lock '$T/lk/new/y.lock'; f2=\$__IC_LOCK_FD; echo \"\$r1 \$((f1>=10)) \$((f1!=f2)) \$([ -e /proc/self/fd/\$f1 ] && echo open)\"; __ic_unlock; echo \"\$([ -e /proc/self/fd/\$f2 ] && echo open || echo closed) \$([ -e /proc/self/fd/\$f1 ] && echo open || echo closed)\"")"
[ "$out" = "0 1 1 open
closed open" ] && pass lock-fd "missing dir created, each call its own fd, unlock closes the current one" || bad lock-fd "got" "$out"
sc "__ic_lock '$T/lk/h.lock'; sleep 1; __ic_unlock" &
hp=$!; sleep 0.3
s=$(date +%s.%N)
sc "__ic_lock '$T/lk/h.lock'; __ic_unlock"
e=$(date +%s.%N); wait "$hp"
awk -v a="$s" -v b="$e" 'BEGIN{exit !(b-a>=0.5)}' && pass lock-blocks "a second locker waits for the holder ($(awk -v a="$s" -v b="$e" 'BEGIN{printf "%.1f", b-a}') s)" || bad lock-blocks "did not wait" ""
sc "__ic_lock '$T/lk/h.lock'; __ic_unlock; __ic_unlock; echo done" >/dev/null 2>&1 && pass unlock-twice "unlock without a lock is harmless" || bad unlock-twice "failed" ""
s=$(date +%s.%N)
sc "__ic_lock '$T/lk/h.lock'; __ic_unlock"
e=$(date +%s.%N)
awk -v a="$s" -v b="$e" 'BEGIN{exit !(b-a<0.5)}' && pass lock-released "free again after unlock" || bad lock-released "still held" ""

# __ic_lock must not leave a stderr redirect behind in the caller's shell
out="$(sc "__ic_lock '$T/lk/err.lock'; echo e >&2; __ic_unlock; echo e2 >&2" 2>&1)"
[ "$out" = "e
e2" ] && pass lock-stderr "stderr still reaches the caller after __ic_lock" || bad lock-stderr "got" "$out"
# leading zeros read as decimal numbers
printf 'dirty=08\nphase_at=0009\nskip=00\n' > "$T/g/ideal-compact-state"
out="$(sc "__ic_state_read '$T/g'; echo \"\$((IC_dirty+1)) \$((IC_phase_at+1)) \$((IC_skip+1))\"" 2>&1)"
[ "$out" = "9 10 1" ] && pass state-leading-zero "08/0009/00 -> 8/9/0, safe in \$(( ))" || bad state-leading-zero "got" "$out"

# two writers, 50 read-modify-write rounds each under the lock -> dirty ends at 100
CD="$T/conc"; mkdir -p "$CD"
rmw='for i in $(seq 50); do __ic_lock "$2/ideal-compact-state.lock"; __ic_state_read "$2"; IC_dirty=$((IC_dirty+1)); __ic_state_write "$2"; __ic_unlock; done'
bash -c '. "$1"; '"$rmw" _ "$T/common-helpers.sh" "$CD" & w1=$!
bash -c '. "$1"; '"$rmw" _ "$T/common-helpers.sh" "$CD" & w2=$!
wait "$w1" "$w2"
[ "$(sc "__ic_state_read '$CD'; echo \$IC_dirty")" = 100 ] && pass lock-concurrent "2 writers x 50 rounds -> dirty=100" || bad lock-concurrent "got" "$(sc "__ic_state_read '$CD'; echo \$IC_dirty")"


# ---- ledger counting, plan lookup ----
LD="$T/led"; mkdir -p "$LD"
printf '# Plan 6 progress ledger\nTask 1: complete (a)\nTask 2: complete\nTask 2: complete (rerun)\nTask 3: pending\n  Task 4: complete\n' > "$LD/l1.md"
[ "$(sc "__ic_ledger_done '$LD/l1.md'")" = 2 ] && pass ledger-done "distinct N among 'Task N: complete' lines (rerun counted once)" || bad ledger-done "got" "$(sc "__ic_ledger_done '$LD/l1.md'")"
[ "$(sc "__ic_ledger_done '$LD/none.md'")" = 0 ] && pass ledger-done-missing "no ledger -> 0" || bad ledger-done-missing "got" "$(sc "__ic_ledger_done '$LD/none.md'")"

RP="$T/repo"; mkdir -p "$RP/docs" "$RP/.superpowers/sdd/w"
git -C "$RP" init -q
printf '# Plan\n### Task 1: a\ntext\n### Task 2: b\n#### Task 3: not a heading\n### Task 10: c\n' > "$RP/docs/p.md"
RPP="$(cd "$RP" && pwd -P)"
WL="$RP/.superpowers/sdd/w/progress.md"
printf '# Plan 6 progress ledger\nTask 1: complete\n' > "$WL"
[ "$(sc "__ic_plan_total '$RP/docs/p.md'")" = 3 ] && pass plan-total "counts '### Task N:' headings only" || bad plan-total "got" "$(sc "__ic_plan_total '$RP/docs/p.md'")"
[ "$(sc "__ic_plan_total '$RP/docs/none.md'")" = 0 ] && pass plan-total-missing "no plan -> 0" || bad plan-total-missing "got" ""
[ -z "$(sc "__ic_ledger_plan '$WL'")" ] && pass plan-none "no plan-path and no plan line -> empty (done still counted: $(sc "__ic_ledger_done '$WL'"))" || bad plan-none "got" "$(sc "__ic_ledger_plan '$WL'")"
printf 'docs/p.md\n' > "$RP/.superpowers/sdd/w/plan-path"
out="$(sc "__ic_ledger_plan '$WL'")"
[ "$out" = "$RPP/docs/p.md" ] && pass plan-path-rel "plan-path file, repo-relative" || bad plan-path-rel "got" "$out"
mkdir -p "$T/outside"; printf '### Task 1: x\n' > "$T/outside/q.md"
printf '%s\n' "$T/outside/q.md" > "$RP/.superpowers/sdd/w/plan-path"
out="$(sc "__ic_ledger_plan '$WL'")"
[ "$out" = "$(cd "$T/outside" && pwd -P)/q.md" ] && pass plan-path-abs "plan-path file, absolute outside the repo" || bad plan-path-abs "got" "$out"
printf 'docs/gone.md\n' > "$RP/.superpowers/sdd/w/plan-path"
[ -z "$(sc "__ic_ledger_plan '$WL'")" ] && pass plan-path-missing "plan-path names a missing file -> empty" || bad plan-path-missing "got" "$(sc "__ic_ledger_plan '$WL'")"
rm "$RP/.superpowers/sdd/w/plan-path"
printf '# SDD ledger — plan: docs/p.md\nTask 1: complete\n' > "$WL"
out="$(sc "__ic_ledger_plan '$WL'")"
[ "$out" = "$RPP/docs/p.md" ] && pass plan-line-rel "first line, relative to the repo root" || bad plan-line-rel "got" "$out"
printf '# SDD ledger — plan: %s\n' "$T/outside/q.md" > "$WL"
out="$(sc "__ic_ledger_plan '$WL'")"
[ "$out" = "$(cd "$T/outside" && pwd -P)/q.md" ] && pass plan-line-abs "first line, absolute" || bad plan-line-abs "got" "$out"
# outside git: relative path tried against the ledger's directory
mkdir -p "$T/nogit"; printf '### Task 1: x\n' > "$T/nogit/np.md"; printf '# SDD ledger — plan: np.md\n' > "$T/nogit/progress.md"
out="$(sc "__ic_ledger_plan '$T/nogit/progress.md'")"
[ "$out" = "$(cd "$T/nogit" && pwd -P)/np.md" ] && pass plan-line-ledger-dir "not in git: falls back to the ledger's directory" || bad plan-line-ledger-dir "got" "$out"
# the repo-root candidate wins over the ledger directory when both exist
printf 'other\n' > "$RP/.superpowers/sdd/w/docs-p.txt"; mkdir -p "$RP/.superpowers/sdd/w/docs"; printf '### Task 1: z\n' > "$RP/.superpowers/sdd/w/docs/p.md"
printf '# SDD ledger — plan: docs/p.md\n' > "$WL"
out="$(sc "__ic_ledger_plan '$WL'")"
[ "$out" = "$RPP/docs/p.md" ] && pass plan-root-first "repo root tried before the ledger directory" || bad plan-root-first "got" "$out"
rm -rf "$RP/.superpowers/sdd/w/docs" "$RP/.superpowers/sdd/w/docs-p.txt"

# ---- history ----
HD="$T/hist"; H="$HD/ideal-compact-history"
R5=1800000000 R7=1900000000
# rec <ledger> <done> <p5> <r5> <p7> <r7> [key=k1] [dirty=0] [tag=usage]; prints the function's answer
rec() { sc "__ic_history_record '$H' '$1' '$2' '${9:-usage} ${7:-k1} $3 $4 $5 $6 97 99 120 3' '${8:-0}'"; }
# fld <ledger> <n>: field n of the newest line for that ledger
fld() { sc "__ic_history_latest '$H' '$1'" | cut -f"$2"; }
# num_eq <a> <b>: numeric equality
num_eq() { awk -v a="$1" -v b="$2" 'BEGIN{d=a-b; exit !(d<1e-9 && d>-1e-9)}'; }
chk() { # chk <id> <desc> <ledger> <field> <expected>
  local g; g="$(fld "$3" "$4")"
  if [ "$g" = "$5" ] || { [[ "$g" =~ ^[0-9.]+$ && "$5" =~ ^[0-9.]+$ ]] && num_eq "$g" "$5"; }; then pass "$1" "$2"; else bad "$1" "$2" "field $4 = '$g', expected '$5'"; fi
}

[ -z "$(sc "__ic_history_latest '$H' '/l/a'")" ] && pass hist-latest-missing "no file -> empty" || bad hist-latest-missing "got" ""
A=/l/a
out="$(rec $A 2 10 $R5 20 $R7)"
[ "$out" = baseline ] && pass hist-first "first record of a ledger -> baseline" || bad hist-first "got" "$out"
chk hist-first-c "first record has no numbers" $A 10 -
chk hist-first-c7 "first record has no 7d number" $A 11 -
chk hist-first-base "baseline snapshot = this entry" $A 12 2
[ "$(fld $A 13)" = 10 ] && [ "$(fld $A 14)" = $R5 ] && [ "$(fld $A 15)" = 2 ] && [ "$(fld $A 16)" = 20 ] && [ "$(fld $A 17)" = $R7 ] && pass hist-first-snap "all six baseline fields" || bad hist-first-snap "fields" "$(sc "__ic_history_latest '$H' '$A'")"
[ "$(fld $A 2)" = "$A" ] && [ "$(fld $A 3)" = 2 ] && [ "$(fld $A 4)" = k1 ] && [ "$(fld $A 5)" = 10 ] && [ "$(fld $A 6)" = $R5 ] && [ "$(fld $A 9)" = 0 ] && pass hist-layout "ledger/done/key/pct/reset/dirty columns" || bad hist-layout "fields" "$(sc "__ic_history_latest '$H' '$A'")"
[[ "$(fld $A 1)" =~ ^[0-9]{10}$ ]] && pass hist-ts "epoch timestamp" || bad hist-ts "got" "$(fld $A 1)"

out="$(rec $A 3 10 $R5 22 $R7)"
[ "$out" = counted ] && pass hist-delta-7d "7d moved, 5h did not -> counted" || bad hist-delta-7d "got" "$out"
chk hist-zero-c5 "delta 0 -> c5 '-'" $A 10 -
chk hist-zero-b5done "delta 0 -> 5h baseline carried (done stays 2)" $A 12 2
chk hist-zero-b5pct "5h baseline pct carried" $A 13 10
chk hist-c7 "7d: 2 over 1 task" $A 11 2
chk hist-b7done "7d baseline moved to 3" $A 15 3
chk hist-b7pct "7d baseline pct moved to 22" $A 16 22
out="$(rec $A 4 12 $R5 22 $R7)"
chk hist-c5 "5h: 2 over (4-2) tasks = 1" $A 10 1
chk hist-c5-b "5h baseline moved to 4" $A 12 4
chk hist-c5-bpct "5h baseline pct 12" $A 13 12
chk hist-c7-zero "7d delta 0 -> '-'" $A 11 -
chk hist-b7-carry "7d baseline carried (3/22)" $A 15 3
[ "$out" = counted ] && pass hist-counted "counted" || bad hist-counted "got" "$out"
out="$(rec $A 5 12 $R5 22 $R7)"
[ "$out" = baseline ] && pass hist-both-zero "both deltas 0 -> baseline (no number)" || bad hist-both-zero "got" "$out"
chk hist-both-zero-b "baselines both carried" $A 12 4

# reset tolerance
B=/l/b
rec $B 1 10 $R5 10 $R7 >/dev/null
out="$(rec $B 2 11 $((R5+4)) 11 $R7)"
chk reset-4s-c5 "5h reset moved 4 s -> no number" $B 10 -
chk reset-4s-rebase "5h window rebased to this entry" $B 12 2
chk reset-4s-c7 "7d window still yields its number" $B 11 1
[ "$out" = counted ] && pass reset-4s-out "counted" || bad reset-4s-out "got" "$out"
C=/l/c
rec $C 1 10 $R5 10 $R7 >/dev/null
rec $C 2 11 $((R5+3)) 11 $((R7-3)) >/dev/null
chk reset-3s-c5 "5h reset moved 3 s -> same window" $C 10 1
chk reset-3s-c7 "7d reset moved 3 s earlier -> same window" $C 11 1

# negative delta
D=/l/d
rec $D 1 10 $R5 10 $R7 >/dev/null
out="$(rec $D 2 9 $R5 12 $R7)"
chk neg-c5 "5h delta -1 -> no number" $D 10 -
chk neg-b5 "5h rebased (done 2)" $D 12 2
chk neg-b5pct "5h rebased (pct 9)" $D 13 9
chk neg-c7 "7d still counted" $D 11 2

# key change, dirty, done regression
E=/l/e
rec $E 1 10 $R5 10 $R7 >/dev/null
out="$(rec $E 2 12 $R5 12 $R7 k2)"
[ "$out" = baseline ] && pass key-change "key changed -> baseline" || bad key-change "got" "$out"
[ "$(fld $E 10)" = - ] && [ "$(fld $E 11)" = - ] && [ "$(fld $E 12)" = 2 ] && [ "$(fld $E 15)" = 2 ] && [ "$(fld $E 4)" = k2 ] && pass key-change-b "no numbers, both rebased to the new key" || bad key-change-b "line" "$(sc "__ic_history_latest '$H' '$E'")"
out="$(rec $E 3 14 $R5 14 $R7 k2 1)"
[ "$out" = baseline ] && pass dirty "dirty=1 -> baseline" || bad dirty "got" "$out"
[ "$(fld $E 10)" = - ] && [ "$(fld $E 11)" = - ] && [ "$(fld $E 12)" = 3 ] && [ "$(fld $E 9)" = 1 ] && pass dirty-b "no numbers, rebased, dirty stored" || bad dirty-b "line" "$(sc "__ic_history_latest '$H' '$E'")"
out="$(rec $E 4 16 $R5 16 $R7 k2 3)"
[ "$out" = baseline ] && [ "$(fld $E 9)" = 3 ] && pass dirty-counter "dirty counter 3 -> baseline" || bad dirty-counter "got" "$out"
out="$(rec $E 5 18 $R5 18 $R7 k2 0)"
[ "$out" = counted ] && [ "$(fld $E 10)" = 2 ] && pass dirty-zero "dirty=0 counts" || bad dirty-zero "got" "$out"
out="$(rec $E 1 20 $R5 20 $R7 k2)"
[ "$out" = baseline ] && [ "$(fld $E 12)" = 1 ] && [ "$(fld $E 10)" = - ] && pass done-regress "done 1 after 5 -> baseline, rebased" || bad done-regress "got" "$out"
out="$(rec $E 1 21 $R5 21 $R7 k2)"
[ "$out" = baseline ] && pass done-equal "done equal to the previous -> baseline" || bad done-equal "got" "$out"

# arithmetic: floats, 4 decimals
F=/l/f
rec $F 1 40.0 $R5 10.0 $R7 >/dev/null
rec $F 4 41.5 $R5 11.0 $R7 >/dev/null
chk float-c5 "40.0 -> 41.5 over 3 tasks = 0.5" $F 10 0.5
chk float-c7 "10.0 -> 11.0 over 3 tasks = 0.3333" $F 11 0.3333
chk float-pct-kept "raw pct stored as given" $F 5 41.5

# skipped
before="$(cksum < "$H")"
out="$(rec $A 9 50 $R5 50 $R7 k1 0 lastgood)"
[ "$out" = skipped ] && [ "$before" = "$(cksum < "$H")" ] && pass skip-tag "tag lastgood -> skipped, file unchanged" || bad skip-tag "got" "$out"
out="$(rec $A 9 50 $R5 50 $R7 - 0)"
[ "$out" = skipped ] && [ "$before" = "$(cksum < "$H")" ] && pass skip-key "key '-' -> skipped, file unchanged" || bad skip-key "got" "$out"
out="$(rec $A 9 50 $R5 50 $R7 k1 0 none)"
[ "$out" = skipped ] && [ "$before" = "$(cksum < "$H")" ] && pass skip-none "tag none -> skipped" || bad skip-none "got" "$out"
[ "$(sc "__ic_history_latest '$H' '$A'" | cut -f3)" = 5 ] && pass skip-latest "skipped record is not the latest" || bad skip-latest "got" ""

# pruning per account
P=/l/p; H0="$H"; H="$HD/prune/ideal-compact-history"
for i in $(seq 25); do rec $P $i 10 $R5 10 $R7 >/dev/null; done
rec /l/q 1 10 $R5 10 $R7 k2 >/dev/null
n1="$(awk -F'\t' '$4=="k1"' "$H" | wc -l)"; n2="$(awk -F'\t' '$4=="k2"' "$H" | wc -l)"
[ "$n1" = 20 ] && [ "$n2" = 1 ] && pass prune "25 k1 + 1 k2 -> 20 k1 lines and the k2 line" || bad prune "counts" "k1=$n1 k2=$n2"
[ "$(awk -F'\t' '$4=="k1"{print $3}' "$H" | head -1)" = 6 ] && [ "$(awk -F'\t' '$4=="k1"{print $3}' "$H" | tail -1)" = 25 ] && pass prune-newest "the newest 20 are kept (done 6..25)" || bad prune-newest "range" "$(awk -F'\t' '$4=="k1"{print $3}' "$H" | tr '\n' ' ')"
[ -z "$(ls "$HD/prune" | grep -v '^ideal-compact-history')" ] && [ "$(ls "$HD/prune" | wc -l)" = 2 ] && pass prune-clean "history file and lock only, no temp left" || bad prune-clean "dir" "$(ls "$HD/prune")"

# two ledgers interleaving
H="$HD/inter/ideal-compact-history"
rec /l/x 1 10 $R5 10 $R7 >/dev/null
rec /l/y 1 50 $R5 50 $R7 >/dev/null
rec /l/x 2 12 $R5 12 $R7 >/dev/null
rec /l/y 2 55 $R5 56 $R7 >/dev/null
[ "$(fld /l/x 10)" = 2 ] && [ "$(fld /l/y 10)" = 5 ] && [ "$(fld /l/y 11)" = 6 ] && pass interleave "each ledger pairs with its own previous line" || bad interleave "got" "x=$(fld /l/x 10) y=$(fld /l/y 10)"
rec /l/y 3 58 $R5 56 $R7 >/dev/null
[ "$(fld /l/y 10)" = 3 ] && pass interleave-2 "y: 55 -> 58 over one task" || bad interleave-2 "got" "$(fld /l/y 10)"
[ "$(sc "__ic_history_latest '$H' /l/x" | cut -f3)" = 2 ] && [ -z "$(sc "__ic_history_latest '$H' /l/z")" ] && pass hist-latest-ledger "latest per ledger; unknown ledger -> empty" || bad hist-latest-ledger "got" ""

# concurrent writers keep every line
H="$HD/conc/ideal-compact-history"
wr='for i in $(seq 20); do __ic_history_record "$2" "$3" "$i" "usage k$4 $i 1800000000 $i 1900000000 97 99 120 3" 0 >/dev/null; done'
bash -c '. "$1"; '"$wr" _ "$T/common-helpers.sh" "$H" /l/m 1 & w1=$!
bash -c '. "$1"; '"$wr" _ "$T/common-helpers.sh" "$H" /l/n 2 & w2=$!
wait "$w1" "$w2"
[ "$(wc -l < "$H")" = 40 ] && [ "$(awk -F'\t' 'NF==17' "$H" | wc -l)" = 40 ] && pass hist-concurrent "2 writers x 20 records -> 40 whole lines" || bad hist-concurrent "lines" "$(wc -l < "$H")"

# ---- budget and account picking ----
BD="$T/budget"; mkdir -p "$BD"; BH="$BD/ideal-compact-history"
# hl <key> <c5> <c7>: one history line (17 fields), appended to $BH
hl() { printf '1\t/l/x\t1\t%s\t0\t0\t0\t0\t0\t%s\t%s\t0\t0\t0\t0\t0\t0\n' "$1" "$2" "$3" >> "$BH"; }
# bud <current_line> [accounts_text]: __ic_budget on $BH
bud() { sc "__ic_budget '$BH' '$1' '$2'"; }
TH='97 99 120 3'
: > "$BH"
for c in 1 1 1 1 1 3; do hl k1 "$c" -; done
out="$(bud "usage k1 90 $R5 10 $R7 $TH")"
[ "$out" = "5 5h" ] && pass bud-5h "newest 5 of 1 1 1 1 1 3 -> avg 1.4, (97-90)/1.4 = 5" || bad bud-5h "got" "$out"
: > "$BH"; for c in 1 1 1 1 1 3; do hl k1 "$c" 0.5; done
out="$(bud "usage k1 90 $R5 98 $R7 $TH")"
[ "$out" = "2 7d" ] && pass bud-7d "7d avg 0.5, (99-98)/0.5 = 2 beats 5h 5 -> 2 7d" || bad bud-7d "got" "$out"
out="$(bud "usage k1 97 $R5 10 $R7 $TH")"
[ "$out" = "0 5h" ] && pass bud-zero "p5 at 97 -> 0 5h" || bad bud-zero "got" "$out"
out="$(bud "usage k1 99 $R5 10 $R7 $TH")"
[ "$out" = "0 5h" ] && pass bud-floor0 "p5 above the threshold never goes below 0" || bad bud-floor0 "got" "$out"
out="$(bud "usage k1 90 $R5 10 $R7 $TH")"
[ "$out" = "5 5h" ] && pass bud-5h-smaller "5h 5, 7d 178 -> the smaller window" || bad bud-5h-smaller "got" "$out"
out="$(sc "__ic_budget '$BH' 'usage k1 90 $R5 98 $R7 $TH' ''" | wc -c)"
[ "$out" = 4 ] && pass bud-no-newline "'2 7d' without a trailing newline" || bad bud-no-newline "bytes" "$out"

# conversion from other keys
: > "$BH"; hl k2 2 -
ACC="1 k1 1 1 90 $R5 10 $R7 1 1
2 k2 0 1 5 $R5 5 $R7 5 5"
out="$(bud "usage k1 90 $R5 10 $R7 $TH" "$ACC")"
[ "$out" = "0 5h" ] && pass bud-convert "no own 5h samples: k2 c5 2 x 5/1 = 10 -> (97-90)/10 = 0.7 -> 0" || bad bud-convert "got" "$out"
ACC="1 k1 1 1 50 $R5 10 $R7 1 1
2 k2 0 1 5 $R5 5 $R7 5 5"
out="$(bud "usage k1 50 $R5 10 $R7 $TH" "$ACC")"
[ "$out" = "4 5h" ] && pass bud-convert-n "(97-50)/10 = 4" || bad bud-convert-n "got" "$out"
ACC="1 k1 1 1 50 $R5 10 $R7 - 1
2 k2 0 1 5 $R5 5 $R7 5 5"
out="$(bud "usage k1 50 $R5 10 $R7 $TH" "$ACC")"
[ "$out" = "unknown -" ] && pass bud-cur-unknown-mult "current mult5 '-' -> window left out" || bad bud-cur-unknown-mult "got" "$out"
out="$(bud "usage k1 50 $R5 10 $R7 $TH" "")"
[ "$out" = "unknown -" ] && pass bud-no-accounts "no accounts text -> no conversion" || bad bud-no-accounts "got" "$out"
out="$(bud "usage k1 50 $R5 10 $R7 $TH" "error:cswap failed")"
[ "$out" = "unknown -" ] && pass bud-error-accounts "error line -> no accounts" || bad bud-error-accounts "got" "$out"
ACC="1 k3 1 1 50 $R5 10 $R7 1 1
2 k2 0 1 5 $R5 5 $R7 5 5"
out="$(bud "usage k1 50 $R5 10 $R7 $TH" "$ACC")"
[ "$out" = "unknown -" ] && pass bud-cur-not-listed "current key not in accounts -> no conversion" || bad bud-cur-not-listed "got" "$out"
: > "$BH"; hl k2 - 2
ACC="1 k1 1 1 50 $R5 10 $R7 1 -
2 k2 0 1 5 $R5 5 $R7 5 5"
out="$(bud "usage k1 50 $R5 10 $R7 $TH" "$ACC")"
[ "$out" = "unknown -" ] && pass bud-7d-team-cur "7d conversion, current is a Team seat -> left out" || bad bud-7d-team-cur "got" "$out"
ACC="1 k1 1 1 50 $R5 10 $R7 1 1
2 k2 0 1 5 $R5 5 $R7 5 -"
out="$(bud "usage k1 50 $R5 10 $R7 $TH" "$ACC")"
[ "$out" = "unknown -" ] && pass bud-7d-team-src "7d conversion, source is a Team seat -> left out" || bad bud-7d-team-src "got" "$out"
ACC="1 k1 1 1 50 $R5 10 $R7 1 1
2 k2 0 1 5 $R5 5 $R7 5 5"
out="$(bud "usage k1 50 $R5 10 $R7 $TH" "$ACC")"
[ "$out" = "8 7d" ] && pass bud-7d-convert "7d: 2 x 5 = 10 -> (99-10)/10 = 8.9 -> 8, 5h has no source" || bad bud-7d-convert "got" "$out"
# newest 5 across other keys, each with its own multiplier
: > "$BH"; hl k2 1 -; hl k3 4 -; for i in 1 2 3 4; do hl k2 1 -; done
ACC="1 k1 1 1 50 $R5 10 $R7 2 1
2 k2 0 1 5 $R5 5 $R7 2 5
3 k3 0 1 5 $R5 5 $R7 6 5"
out="$(bud "usage k1 50 $R5 10 $R7 $TH" "$ACC")"
[ "$out" = "14 5h" ] && pass bud-convert-newest5 "newest 5 of the others: k3 4x6/2 = 12 and four k2 1x2/2 = 1 -> avg 3.2, 47/3.2 = 14" || bad bud-convert-newest5 "got" "$out"
: > "$BH"; hl k3 4 -; hl k2 1 -; hl k2 1 -
out="$(bud "usage k1 50 $R5 10 $R7 $TH" "$ACC")"
# k3: 4 x 6/2 = 12 ; k2: 1 x 2/2 = 1, 1 -> mean 14/3 = 4.667 -> 47/4.667 = 10.07
[ "$out" = "10 5h" ] && pass bud-convert-mixed "per-key multipliers applied, mean over the sources" || bad bud-convert-mixed "got" "$out"
# own samples win over conversion
: > "$BH"; hl k2 2 -; hl k1 2 -
out="$(bud "usage k1 50 $R5 10 $R7 $TH" "$ACC")"
[ "$out" = "23 5h" ] && pass bud-own-first "own sample present -> no conversion (47/2 = 23)" || bad bud-own-first "got" "$out"
# only positive samples count
: > "$BH"; hl k1 2 -; hl k1 0 -; hl k1 - -
out="$(bud "usage k1 50 $R5 10 $R7 $TH" "")"
[ "$out" = "23 5h" ] && pass bud-positive-only "0 and '-' are not samples" || bad bud-positive-only "got" "$out"
# tags
out="$(bud "lastgood k1 50 $R5 10 $R7 $TH" "")"
[ "$out" = "unknown -" ] && pass bud-lastgood "tag lastgood -> unknown -" || bad bud-lastgood "got" "$out"
out="$(bud "none - - - - - $TH" "")"
[ "$out" = "unknown -" ] && pass bud-none "tag none -> unknown -" || bad bud-none "got" "$out"
BH_SAVE="$BH"; BH="$BD/missing"
out="$(bud "usage k1 50 $R5 10 $R7 $TH" "")"
[ "$out" = "unknown -" ] && pass bud-no-file "no history file -> unknown -" || bad bud-no-file "got" "$out"
BH="$BH_SAVE"

# pick
pk() { sc "__ic_pick_account '$BH' '$1' '$2'"; }
: > "$BH"; hl k1 2 -; hl k2 1 -; hl k3 5 -
CUR="usage k1 95 $R5 10 $R7 $TH"
ACC="1 k1 1 1 95 $R5 10 $R7 1 1
2 k2 0 0 0 $R5 0 $R7 1 1
3 k3 0 1 82 $R5 0 $R7 1 1
4 k4 0 1 96 $R5 0 $R7 - -"
# current: (97-95)/2 = 1 ; k2 not usable ; k3: (97-82)/5 = 3 ; k4 unknown
out="$(pk "$CUR" "$ACC")"
[ "$out" = 3 ] && pass pick-best "alt #3 budget 3 > current 1 -> 3" || bad pick-best "got" "$out"
ACC="1 k1 1 1 95 $R5 10 $R7 1 1
2 k2 0 1 0 $R5 0 $R7 1 1
3 k3 0 1 82 $R5 0 $R7 1 1"
out="$(pk "$CUR" "$ACC")"
[ "$out" = 2 ] && pass pick-largest "k2 budget 97 beats k3 3" || bad pick-largest "got" "$out"
ACC="1 k1 1 1 95 $R5 10 $R7 1 1
3 k3 0 1 92 $R5 0 $R7 1 1"
out="$(pk "$CUR" "$ACC")"
[ -z "$out" ] && pass pick-not-larger "alt budget 1 = current 1 -> empty" || bad pick-not-larger "got" "$out"
ACC="1 k1 1 1 95 $R5 10 $R7 1 1
4 k4 0 1 5 $R5 0 $R7 - -"
out="$(pk "$CUR" "$ACC")"
[ -z "$out" ] && pass pick-alt-unknown "usable alt with no budget -> empty" || bad pick-alt-unknown "got" "$out"
ACC="1 k1 1 1 95 $R5 10 $R7 1 1
2 k2 0 0 0 $R5 0 $R7 1 1"
out="$(pk "$CUR" "$ACC")"
[ -z "$out" ] && pass pick-not-usable "alt not usable -> empty" || bad pick-not-usable "got" "$out"
: > "$BH"; hl k3 5 -
ACC="1 k1 1 1 95 $R5 10 $R7 - -
3 k3 0 1 0 $R5 0 $R7 1 1"
out="$(pk "$CUR" "$ACC")"
[ -z "$out" ] && pass pick-cur-unknown "current budget unknown -> empty" || bad pick-cur-unknown "got" "$out"
out="$(pk "$CUR" "")"
[ -z "$out" ] && pass pick-no-accounts "no accounts text -> empty" || bad pick-no-accounts "got" "$out"
out="$(pk "$CUR" "error:cswap failed")"
[ -z "$out" ] && pass pick-error "error line -> empty" || bad pick-error "got" "$out"
# the alternate is measured with its own row, thresholds from the current line
: > "$BH"; hl k1 2 -; hl k3 1 -
CUR="usage k1 95 $R5 10 $R7 97 99 120 3"
ACC="1 k1 1 1 95 $R5 10 $R7 1 1
3 k3 0 1 90 $R5 0 $R7 1 1"
out="$(pk "$CUR" "$ACC")"
[ "$out" = 3 ] && pass pick-alt-row "alt p5 90 from its own row: 7/1 = 7 > 1" || bad pick-alt-row "got" "$out"
# read-only: no writes
before="$(cksum < "$BH")"; pk "$CUR" "$ACC" >/dev/null; bud "$CUR" "$ACC" >/dev/null
[ "$before" = "$(cksum < "$BH")" ] && [ "$(ls "$BD" | wc -l)" = 1 ] && pass bud-read-only "history untouched, no lock or temp file created" || bad bud-read-only "dir" "$(ls "$BD")"

# ---- backend detection ----
# Wrapper scripts whose comm is their file name (the shebang names bash
# directly: through env the comm would be bash): each runs its arguments in
# the background and waits, so a chain of them is a chain of ancestors.
PR_D="$T/procs"; mkdir -p "$PR_D"
for n in claude tmux screen SCREEN 'a) b'; do printf '#!%s\n"$@" &\nwait\n' "$BASH" > "$PR_D/$n"; chmod +x "$PR_D/$n"; done
SLEEP_BIN="$(command -v sleep)"
# chain <wrapper...>: starts wrapper1 -> wrapper2 -> ... -> bash -> sleep and
# prints the sleep pid (the "claude" pid of a row)
chain() {
  local pf="$T/procs/pid.$RANDOM" i
  "${@/#/$PR_D/}" bash -c 'sleep 30 & echo $! > "$1"; wait' _ "$pf" >/dev/null 2>&1 &
  for i in $(seq 50); do [ -s "$pf" ] && break; sleep 0.1; done
  cat "$pf"
}
# The fake tmux answers #{pane_pid} with $FAKE_PANE_PID: the test shell, an
# ancestor of IC_CLAUDE_PID=$$ (itself) and of every sleeper it starts.
export FAKE_PANE_PID=$$
pp() { sc "__ic_ppid $1"; }
: > "$FAKE_LOG"
out="$(TMUX=/tmp/s,1,0 TMUX_PANE=%3 sc __ic_backend)"
[ "$out" = "tmux /tmp/s %3" ] && pass backend-tmux "own TMUX + TMUX_PANE, pane pid an ancestor of claude -> tmux <socket> <pane>" || bad backend-tmux "got" "$out"
grep -qxF 'tmux -S /tmp/s display-message -p -t %3 #{pane_pid}' "$FAKE_LOG" \
  && pass backend-tmux-query "pane pid asked of -S <socket> -t <pane>" || bad backend-tmux-query "log" "$(cat "$FAKE_LOG")"
env -i "$SLEEP_BIN" 30 & up=$!
out="$(FAKE_PANE_PID=$up TMUX=/tmp/s,1,0 TMUX_PANE=%3 sc __ic_backend)"
[ -z "$out" ] && pass backend-tmux-foreign "pane pid not claude or an ancestor -> no backend" || bad backend-tmux-foreign "got" "$out"
out="$(FAKE_FAIL_PANE_PID=1 TMUX=/tmp/s,1,0 TMUX_PANE=%3 sc __ic_backend)"
[ -z "$out" ] && pass backend-tmux-query-fails "pane pid query fails -> no backend" || bad backend-tmux-query-fails "got" "$out"
out="$(FAKE_PANE_PID='' TMUX=/tmp/s,1,0 TMUX_PANE=%3 sc __ic_backend)"
[ -z "$out" ] && pass backend-tmux-query-blank "pane pid query prints nothing -> no backend" || bad backend-tmux-query-blank "got" "$out"
out="$(STY=$$.x WINDOW=2 sc __ic_backend)"
[ "$out" = "screen $$.x 2" ] && pass backend-screen "own STY (<ancestor pid>.x) + WINDOW -> screen <sty> <window>" || bad backend-screen "got" "$out"
out="$(STY=1.x WINDOW=2 sc __ic_backend)"
[ -z "$out" ] && pass backend-screen-foreign "STY pid not an ancestor of claude -> no backend" || bad backend-screen-foreign "got" "$out"
out="$(STY=x WINDOW=2 sc __ic_backend)"
[ -z "$out" ] && pass backend-screen-no-pid "STY without a pid prefix -> no backend" || bad backend-screen-no-pid "got" "$out"
out="$(TMUX=/tmp/s,1,0 sc __ic_backend)"
[ -z "$out" ] && pass backend-no-pane "TMUX without TMUX_PANE -> no backend" || bad backend-no-pane "got" "$out"
out="$(TMUX_PANE=%3 STY=$$.x sc __ic_backend)"
[ -z "$out" ] && pass backend-halves "TMUX_PANE alone and STY without WINDOW -> no backend" || bad backend-halves "got" "$out"
cp1="$(chain tmux screen)"; cp2="$(chain SCREEN tmux)"; cp3="$(chain claude)"
a1="$(pp "$cp1")"; a3="$(pp "$cp3")"
out="$(IC_CLAUDE_PID="$cp1" TMUX=/tmp/s,1,0 TMUX_PANE=%3 STY=$a1.x WINDOW=2 sc __ic_backend)"
[ "$out" = "screen $a1.x 2" ] && pass backend-both-screen "both set, nearest multiplexer ancestor screen (inside tmux) -> screen" || bad backend-both-screen "got" "$out"
out="$(FAKE_PANE_PID=$cp2 IC_CLAUDE_PID="$cp2" TMUX=/tmp/s,1,0 TMUX_PANE=%3 STY=123.x WINDOW=2 sc __ic_backend)"
[ "$out" = "tmux /tmp/s %3" ] && pass backend-both-tmux "both set, nearest multiplexer ancestor tmux (inside SCREEN) -> tmux" || bad backend-both-tmux "got" "$out"
out="$(IC_CLAUDE_PID="$cp3" TMUX=/tmp/s,1,0 TMUX_PANE=%3 STY=$a3.x WINDOW=2 sc __ic_backend)"
[ "$out" = "screen $a3.x 2" ] && pass backend-both-undecided "both set, no multiplexer ancestor -> screen" || bad backend-both-undecided "got" "$out"
env TMUX=/tmp/t,1,0 TMUX_PANE=%9 "$SLEEP_BIN" 30 & ep1=$!
env -i "$SLEEP_BIN" 30 & ep2=$!
env STY=$$.y WINDOW=4 TMUX=/tmp/u,1,0 "$SLEEP_BIN" 30 & ep3=$!
sleep 0.2
out="$(IC_CLAUDE_PID="$ep1" sc __ic_backend)"
[ "$out" = "tmux /tmp/t %9" ] && pass backend-environ "nothing in the hook env -> /proc/<claude>/environ" || bad backend-environ "got" "$out"
out="$(IC_CLAUDE_PID="$ep3" sc __ic_backend)"
[ "$out" = "screen $$.y 4" ] && pass backend-environ-screen "environ STY + WINDOW (TMUX without pane ignored) -> screen" || bad backend-environ-screen "got" "$out"
out="$(IC_CLAUDE_PID="$ep3" TMUX_PANE=%1 sc __ic_backend)"
[ -z "$out" ] && pass backend-one-source "any var in the hook env -> environ not mixed in" || bad backend-one-source "got" "$out"
out="$(IC_CLAUDE_PID="$ep2" sc __ic_backend)"
[ -z "$out" ] && pass backend-none "nothing anywhere -> empty" || bad backend-none "got" "$out"
# Headless claude (-p / --print) has no input box to type into. The trailing
# `; :` keeps bash from exec'ing sleep, so the cmdline stays as written.
bash -c 'sleep 30; :' claude -p 'fix it' & hp1=$!
bash -c 'sleep 30; :' claude --print & hp2=$!
bash -c 'sleep 30; :' claude 'explain -p' --model x & hp3=$!
sleep 0.2
out="$(IC_CLAUDE_PID="$hp1" TMUX=/tmp/s,1,0 TMUX_PANE=%3 sc __ic_backend)"
[ -z "$out" ] && pass backend-headless-p "claude started with -p -> no backend" || bad backend-headless-p "got" "$out"
out="$(IC_CLAUDE_PID="$hp2" STY=$$.x WINDOW=2 sc __ic_backend)"
[ -z "$out" ] && pass backend-headless-print "claude started with --print -> no backend" || bad backend-headless-print "got" "$out"
out="$(IC_CLAUDE_PID="$hp3" TMUX=/tmp/s,1,0 TMUX_PANE=%3 sc __ic_backend)"
[ "$out" = "tmux /tmp/s %3" ] && pass backend-interactive-args "-p only inside another argument -> backend kept" || bad backend-interactive-args "got" "$out"
kill "$hp1" "$hp2" "$hp3" 2>/dev/null
mkdir -p "$T/onlyscreen"; ln -s "$TESTS_DIR/fakes/screen" "$T/onlyscreen/screen"; ln -s "$(command -v dirname)" "$T/onlyscreen/dirname"
if [ -z "$(PATH="$T/onlyscreen" command -v tmux)" ]; then
  out="$(TMUX=/tmp/s,1,0 TMUX_PANE=%3 STY=$$.x WINDOW=2 PATH="$T/onlyscreen" "$BASH" -c '. "$1"; __ic_backend' _ "$T/common-helpers.sh")"
  [ "$out" = "screen $$.x 2" ] && pass backend-no-binary "no tmux binary -> tmux skipped" || bad backend-no-binary "got" "$out"
  out="$(TMUX=/tmp/s,1,0 TMUX_PANE=%3 PATH="$T/onlyscreen" "$BASH" -c '. "$1"; __ic_backend' _ "$T/common-helpers.sh")"
  [ -z "$out" ] && pass backend-no-binary-empty "only tmux vars, no tmux binary -> empty" || bad backend-no-binary-empty "got" "$out"
else
  bad backend-no-binary "isolation" "tmux found under the stub PATH"
fi
out="$(grep -v ' display-message -p -t [^ ]* #{pane_pid}$' "$FAKE_LOG")"
[ -z "$out" ] && pass backend-no-calls "detection only asks tmux for the pane pid, never screen" || bad backend-no-calls "log" "$out"
unset FAKE_PANE_PID
# __ic_claude_pid walks /proc: claude -> 'a) b' -> bash; comm with ') ' does not confuse the stat parse
"$PR_D/claude" "$PR_D/a) b" bash -c 'unset IC_CLAUDE_PID; . "$1"; __ic_claude_pid > "$2"' _ "$T/common-helpers.sh" "$T/cpid" & wp=$!
wait "$wp"
[ "$(cat "$T/cpid")" = "$wp" ] && pass claude-pid-walk "nearest ancestor named claude, through a comm holding ') '" || bad claude-pid-walk "got" "$(cat "$T/cpid") want $wp"
out="$(IC_CLAUDE_PID=4242 sc __ic_claude_pid)"
[ "$out" = 4242 ] && pass claude-pid-env "IC_CLAUDE_PID wins" || bad claude-pid-env "got" "$out"
# Orphaned (double fork), so the claude session running these tests is no longer an ancestor.
( bash -c 'sleep 0.3; unset IC_CLAUDE_PID; . "$1"; __ic_claude_pid > "$2.tmp"; mv "$2.tmp" "$2"' _ "$T/common-helpers.sh" "$T/cpid-none" & )
for i in $(seq 50); do [ -e "$T/cpid-none" ] && break; sleep 0.1; done
out="$(cat "$T/cpid-none" 2>/dev/null || echo missing)"
[ -z "$out" ] && pass claude-pid-none "no claude ancestor -> empty" || bad claude-pid-none "got" "$out"
kill "$cp1" "$cp2" "$cp3" "$ep1" "$ep2" "$ep3" "$up" 2>/dev/null
wait 2>/dev/null

# ---- input box ----
NB=$'\xc2\xa0'; RULE='────────────────────'
export FAKE_SCREEN="$T/screen.txt"
tfix() { printf '%s\n' "$@" > "$FAKE_SCREEN"; }
ibs() { FAKE_CURSOR="$1" sc "__ic_inputbox_state $2"; }
HIST=('● old output' '❯ an earlier prompt' '')
tfix "${HIST[@]}" "$RULE" "❯$NB" "$RULE" '  ? for shortcuts'
: > "$FAKE_LOG"
out="$(ibs '2 4 0' 'tmux /tmp/s %3')"
[ "$out" = empty ] && pass box-tmux-empty "empty box, cursor col 2 of the box row -> empty" || bad box-tmux-empty "got" "$out"
grep -qxF 'tmux -S /tmp/s capture-pane -p -t %3' "$FAKE_LOG" && grep -qxF 'tmux -S /tmp/s display-message -p -t %3 #{cursor_x} #{cursor_y} #{pane_in_mode}' "$FAKE_LOG" \
  && pass box-tmux-target "capture-pane and display-message aimed at -S <socket> -t <pane>" || bad box-tmux-target "log" "$(cat "$FAKE_LOG")"
out="$(ibs '2 1 0' 'tmux /tmp/s %3')"
[ "$out" = draft ] && pass box-tmux-wrong-row "cursor col 2 but not on the box row -> draft" || bad box-tmux-wrong-row "got" "$out"
tfix "${HIST[@]}" "$RULE" "❯${NB}Try \"fix lint errors\"" "$RULE" '  ? for shortcuts'
out="$(ibs '2 4 0' 'tmux /tmp/s %3')"
[ "$out" = placeholder ] && pass box-tmux-placeholder "text, cursor right after the prompt -> placeholder" || bad box-tmux-placeholder "got" "$out"
out="$(ibs '24 4 0' 'tmux /tmp/s %3')"
[ "$out" = draft ] && pass box-tmux-draft1 "text, cursor after it -> draft" || bad box-tmux-draft1 "got" "$out"
tfix "${HIST[@]:0:2}" '                              ctrl+g to edit in Vim' "$RULE" "❯${NB}123" '  456' "$RULE" '  ? for shortcuts'
out="$(ibs '5 5 0' 'tmux /tmp/s %3')"
[ "$out" = draft ] && pass box-tmux-draft2 "two-line draft 123/456, cursor col 5 of the second row -> draft" || bad box-tmux-draft2 "got" "$out"
out="$(ibs '2 3 0' 'tmux /tmp/s %3')"
[ "$out" = draft ] && pass box-tmux-draft2-home "two box lines, cursor at the prompt -> still draft" || bad box-tmux-draft2-home "got" "$out"
tfix "${HIST[@]}" "$RULE" "❯${NB}hello" '  ─' '' "$RULE" '  ? for shortcuts'
out="$(ibs '2 4 0' 'tmux /tmp/s %3')"
[ "$out" = draft ] && pass box-tmux-indented-rule "a draft line of ─ indented two spaces is not the bottom rule -> draft" || bad box-tmux-indented-rule "got" "$out"
tfix "${HIST[@]}" "$RULE" "❯${NB}hello" '───' "$RULE" '  ? for shortcuts'
out="$(ibs '2 4 0' 'tmux /tmp/s %3')"
[ "$out" = draft ] && pass box-tmux-short-rule "an unindented line of 3 ─ is not a rule -> draft" || bad box-tmux-short-rule "got" "$out"
tfix "${HIST[@]}" "❯$NB" '  ? for shortcuts'
out="$(ibs '2 3 0' 'tmux /tmp/s %3')"
[ "$out" = unsure ] && pass box-tmux-no-rules "no rows of ─ -> unsure" || bad box-tmux-no-rules "got" "$out"
tfix "${HIST[@]}" "$RULE" '❯ an earlier prompt' "$RULE"
out="$(ibs '2 4 0' 'tmux /tmp/s %3')"
[ "$out" = unsure ] && pass box-tmux-history "❯ + ASCII space (history) is not the box -> unsure" || bad box-tmux-history "got" "$out"
tfix "${HIST[@]}" "$RULE" "❯$NB" "$RULE"
out="$(FAKE_FAIL_CURSOR=1 ibs '2 4' 'tmux /tmp/s %3')"
[ "$out" = unsure ] && pass box-tmux-no-cursor "cursor query fails -> unsure" || bad box-tmux-no-cursor "got" "$out"
out="$(ibs '' 'tmux /tmp/s %3')"
[ "$out" = unsure ] && pass box-tmux-blank-cursor "cursor query prints nothing -> unsure" || bad box-tmux-blank-cursor "got" "$out"
out="$(ibs '2 4 1' 'tmux /tmp/s %3')"
[ "$out" = unsure ] && pass box-tmux-copy-mode "empty box but the pane is in copy mode -> unsure" || bad box-tmux-copy-mode "got" "$out"
out="$(ibs '2 4 0' 'tmux /tmp/s %3')"
[ "$out" = empty ] && pass box-tmux-not-in-mode "empty box, pane_in_mode 0 -> empty" || bad box-tmux-not-in-mode "got" "$out"
out="$(ibs '2 4' 'tmux /tmp/s %3')"
[ "$out" = unsure ] && pass box-tmux-no-mode-field "answer without pane_in_mode -> unsure" || bad box-tmux-no-mode-field "got" "$out"

# screen hardcopy keeps only each character's low byte: ❯ -> o, U+00A0 -> \xa0,
# ─ -> \x00; 上 (U+4E0A) -> \x0a splits its row, so lines are not screen rows.
SR='\0\0\0\0\0\0\0\0\0\0\0\0'
SH='\x25\x0f old output\no an earlier prompt\nab\nc\n'
sfix() { printf "$1" > "$FAKE_SCREEN"; }
sfix "$SH$SR\no\xa0\n$SR\n  ? for shortcuts\n"
: > "$FAKE_LOG"
out="$(ibs '(3,20)/(80,24)+1024 +flow UTF-8 0(claude)' 'screen 123.x 2')"
[ "$out" = empty ] && pass box-screen-empty "hardcopy bytes o\\xa0 between NUL rules, cursor col 3 -> empty" || bad box-screen-empty "got" "$out"
grep -qE '^screen -S 123\.x -p 2 -X hardcopy /' "$FAKE_LOG" && grep -qxF 'screen -S 123.x -p 2 -Q info' "$FAKE_LOG" \
  && pass box-screen-target "hardcopy (absolute file) and -Q info aimed at -S <sty> -p <window>" || bad box-screen-target "log" "$(cat "$FAKE_LOG")"
hc="$(sed -n 's/^screen .* -X hardcopy //p' "$FAKE_LOG")"
[[ "$hc" == "$IC_TMP_BASE"/* ]] && [ ! -e "$hc" ] && pass box-screen-tmpfile "hardcopy file under IC_TMP_BASE, removed afterwards" || bad box-screen-tmpfile "file" "$hc"
sfix "$SH$SR\no\xa0Try \"fix lint errors\"\n$SR\n"
out="$(ibs '(3,20)/(80,24)+1024' 'screen 123.x 2')"
[ "$out" = placeholder ] && pass box-screen-placeholder "text, cursor col 3 -> placeholder" || bad box-screen-placeholder "got" "$out"
out="$(ibs '(25,20)/(80,24)+1024' 'screen 123.x 2')"
[ "$out" = draft ] && pass box-screen-draft1 "text, cursor after it -> draft" || bad box-screen-draft1 "got" "$out"
sfix "$SH$SR\no\xa0123\n  456\n$SR\n"
out="$(ibs '(6,21)/(80,24)+1024' 'screen 123.x 2')"
[ "$out" = draft ] && pass box-screen-draft2 "two-line draft, cursor (6,21) -> draft" || bad box-screen-draft2 "got" "$out"
out="$(ibs '(3,20)/(80,24)+1024' 'screen 123.x 2')"
[ "$out" = draft ] && pass box-screen-draft2-home "two box lines, cursor col 3 -> still draft" || bad box-screen-draft2-home "got" "$out"
# 一 (U+4E00) and 丁 (U+4E01) keep the low bytes 0x00/0x01, the same as a rule.
sfix "$SH$SR\no\xa0hello\n  \x01\n\n$SR\n"
out="$(ibs '(3,22)/(80,24)+1024' 'screen 123.x 2')"
[ "$out" = draft ] && pass box-screen-cjk-01 "continuation line of 0x01 bytes (丁) is not the bottom rule -> draft" || bad box-screen-cjk-01 "got" "$out"
sfix "$SH$SR\no\xa0hello\n  \0\0\n\n$SR\n"
out="$(ibs '(3,22)/(80,24)+1024' 'screen 123.x 2')"
[ "$out" = draft ] && pass box-screen-cjk-00 "continuation line of 0x00 bytes (一一) is not the bottom rule -> draft" || bad box-screen-cjk-00 "got" "$out"
sfix "${SH}o\xa0\n  ? for shortcuts\n"
out="$(ibs '(3,20)/(80,24)+1024' 'screen 123.x 2')"
[ "$out" = unsure ] && pass box-screen-no-rules "no NUL rules -> unsure" || bad box-screen-no-rules "got" "$out"
sfix "$SH$SR\no\xa0\n$SR\n"
out="$(FAKE_FAIL_CURSOR=1 ibs '(3,20)' 'screen 123.x 2')"
[ "$out" = unsure ] && pass box-screen-no-cursor "-Q info fails -> unsure" || bad box-screen-no-cursor "got" "$out"
out="$(FAKE_SCREEN="$T/none" ibs '(3,20)' 'screen 123.x 2')"
[ "$out" = unsure ] && pass box-screen-no-hardcopy "hardcopy never written -> unsure (after polling)" || bad box-screen-no-hardcopy "got" "$out"
out="$(ibs '2 4' '')"
[ "$out" = unsure ] && pass box-no-backend "no backend words -> unsure" || bad box-no-backend "got" "$out"

# ---- sending ----
: > "$FAKE_LOG"
sc '__ic_send tmux /tmp/s %3 "/compact $IDEAL_COMPACT_COMPACT_TEXT"'; rc=$?
ctext="$(bash -c '. "$1"; printf %s "$IDEAL_COMPACT_COMPACT_TEXT"' _ "$T/common-helpers.sh")"
want="$(printf 'tmux -S /tmp/s send-keys -l -t %%3 /compact %s\ntmux -S /tmp/s send-keys -l -t %%3 \r' "$ctext")"
[ "$rc" = 0 ] && [ "$(cat "$FAKE_LOG")" = "$want" ] && pass send-tmux "text, then CR, as two send-keys -l calls on -S <socket> -t <pane>" || bad send-tmux "rc=$rc log" "$(cat -A "$FAKE_LOG")"
: > "$FAKE_LOG"
sc '__ic_send screen 123.x 2 "a\\b 繼續"'; rc=$?
want="$(printf 'screen -S 123.x -p 2 -X stuff a\\\\b 繼續\nscreen -S 123.x -p 2 -X stuff \r')"
[ "$rc" = 0 ] && [ "$(cat "$FAKE_LOG")" = "$want" ] && pass send-screen "stuff text (backslash doubled), then CR, both with -p <window>" || bad send-screen "rc=$rc log" "$(cat -A "$FAKE_LOG")"
: > "$FAKE_LOG"
sc '__ic_send "" "" "" x'; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FAKE_LOG" ] && pass send-no-backend "no backend -> non-zero, nothing sent" || bad send-no-backend "rc=$rc" "$(cat "$FAKE_LOG")"

exit $fail
