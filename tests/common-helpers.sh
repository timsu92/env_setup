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

exit $fail
