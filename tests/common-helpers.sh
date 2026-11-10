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
KEYS="phase phase_at skip suppress suppress_key suppress_win suppress_resets dirty ledger armed_key armed_win armed_resets cheap_obs inputbox_fail pending_inject"
DUMP='for k in '"$KEYS"'; do n=IC_$k; printf "%s=%s\n" "$k" "${!n}"; done'
DEFAULTS="$(printf '%s\n' phase=standby phase_at=0 skip=0 suppress=0 suppress_key= suppress_win= suppress_resets=0 dirty=0 ledger= armed_key= armed_win= armed_resets=0 cheap_obs= inputbox_fail=0 pending_inject=)"
# sc '<script>': the script runs in a fresh bash with the library sourced under set -u
sc() { bash -c 'set -u; . "$1"; shift; eval "$1"' _ "$T/common-helpers.sh" "$1"; }

SD="$T/sess/s1"
out="$(sc "IC_phase=armed IC_dirty=7 IC_cheap_obs=old; __ic_state_read '$T/sess/missing'; $DUMP" 2>&1)"
[ "$out" = "$DEFAULTS" ] && pass state-missing "missing file -> every IC_<key> at its default (and stale values reset)" || bad state-missing "got" "$out"
out="$(sc "__ic_state_read ''; $DUMP" 2>&1)"
[ "$out" = "$DEFAULTS" ] && pass state-no-dir "empty session dir -> defaults" || bad state-no-dir "got" "$out"

sc "IC_phase=to-compact IC_phase_at=1700000000 IC_skip=1 IC_suppress=1 IC_suppress_key=sk IC_suppress_win=5h IC_suppress_resets=1700000500 IC_dirty=3 IC_ledger=/a/b/ledger.md IC_armed_key=ak IC_armed_win=7d IC_armed_resets=1700009999 IC_cheap_obs='3 4  5=x' IC_inputbox_fail=2 IC_pending_inject='繼續 now'; __ic_state_write '$SD'"
[ -f "$SD/ideal-compact-state" ] && [ "$(ls -A "$SD" | wc -l)" = 1 ] && pass state-write "mkdir -p, one file, no temp left behind" || bad state-write "dir" "$(ls -A "$SD" 2>&1)"
want="$(printf '%s\n' phase=to-compact phase_at=1700000000 skip=1 suppress=1 suppress_key=sk suppress_win=5h suppress_resets=1700000500 dirty=3 ledger=/a/b/ledger.md armed_key=ak armed_win=7d armed_resets=1700009999 'cheap_obs=3 4  5=x' inputbox_fail=2 'pending_inject=繼續 now')"
[ "$(sc "__ic_state_read '$SD'; $DUMP")" = "$want" ] && pass state-roundtrip "every key survives write -> read (spaces, '=' and CJK in values)" || bad state-roundtrip "got" "$(sc "__ic_state_read '$SD'; $DUMP")"
[ "$(cat "$SD/ideal-compact-state")" = "$want" ] && pass state-format "plain key=value lines" || bad state-format "file" "$(cat "$SD/ideal-compact-state")"

mkdir -p "$T/g"
printf 'phase=bogus\n\nphase_at\n=x\nskip=1\ndirty=abc\nsuppress_key=kk\nunknown=zz\nsuppress_resets=-5\nlinewithout\narmed_win=7d\ncheap_obs=a=b c\narme' > "$T/g/ideal-compact-state"
out="$(sc "__ic_state_read '$T/g'; $DUMP" 2>&1)"
want="$(printf '%s\n' phase=standby phase_at=0 skip=1 suppress=0 suppress_key=kk suppress_win= suppress_resets=0 dirty=0 ledger= armed_key= armed_win=7d armed_resets=0 'cheap_obs=a=b c' inputbox_fail=0 pending_inject=)"
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

# two writers, 50 read-modify-write rounds each under the lock -> dirty ends at 100
CD="$T/conc"; mkdir -p "$CD"
rmw='for i in $(seq 50); do __ic_lock "$2/ideal-compact-state.lock"; __ic_state_read "$2"; IC_dirty=$((IC_dirty+1)); __ic_state_write "$2"; __ic_unlock; done'
bash -c '. "$1"; '"$rmw" _ "$T/common-helpers.sh" "$CD" & w1=$!
bash -c '. "$1"; '"$rmw" _ "$T/common-helpers.sh" "$CD" & w2=$!
wait "$w1" "$w2"
[ "$(sc "__ic_state_read '$CD'; echo \$IC_dirty")" = 100 ] && pass lock-concurrent "2 writers x 50 rounds -> dirty=100" || bad lock-concurrent "got" "$(sc "__ic_state_read '$CD'; echo \$IC_dirty")"

exit $fail
