#!/usr/bin/env bash
# Stub-cswap test for hwap-helper.sh. Usage: hwap-test.sh [path-to-helper]
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
HELPER="${1:-${TESTS_DIR}/../ansible/roles/claude_code/files/hwap-helper.sh}"
T="$(mktemp -d)"
trap 'rm -rf "$T" "$ISO"' EXIT
RESET="$(date -u -d '+3 hours' +%FT%TZ)"

mkdir -p "$T/stub" "$T/nojq"
cat > "$T/stub/cswap" <<'EOF'
#!/usr/bin/env bash
[ "$1" = list ] && cat "$STUB_JSON"
EOF
chmod +x "$T/stub/cswap"
for b in bash date python3 cat; do ln -s "$(command -v $b)" "$T/nojq/$b"; done
ln -s "$T/stub/cswap" "$T/nojq/cswap"
for b in tmux screen; do ln -s "$TESTS_DIR/fakes/$b" "$T/nojq/$b"; done
iso_guard "$T/stub:$PATH" "$T/stub"; iso_guard "$T/nojq" "$T/nojq"

acct() { # number active 5h 7d
  printf '{"number":%s,"active":%s,"usageStatus":"ok","disabled":false,"usage":{"fiveHour":{"pct":%s,"resetsAt":"%s"},"sevenDay":{"pct":%s,"resetsAt":"%s"}}}' \
    "$1" "$2" "$3" "$RESET" "$4" "$RESET"
}

fail=0
check() { # label a5 a7 b5 b7 expected-regex
  printf '{"accounts":[%s,%s]}' "$(acct 2 true "$2" "$3")" "$(acct 1 false "$4" "$5")" > "$T/in.json"
  for mode in jq python; do
    if [ $mode = jq ]; then p="$T/stub:$PATH"; else p="$T/nojq"; fi
    out="$(STUB_JSON="$T/in.json" PATH="$p" "$(command -v bash)" "$HELPER")"
    if [[ "$out" =~ ^($6)$ ]]; then echo "PASS [$mode] $1 -> $out"
    else echo "FAIL [$mode] $1 -> '$out' (want /$6/)"; fail=1; fi
  done
}

check "96/98"        96 98 0 0  'ok'
check "97/0"         97 0  0 0  'switch [0-9]+'
check "0/98"         0  98 0 0  'ok'
check "0/99"         0  99 0 0  'switch [0-9]+'
check "98/98"        98 98 0 0  'switch [0-9]+'
check "96/99"        96 99 0 0  'switch [0-9]+'
check "all 97/0"     97 0  97 0 'wait .*'

# ---- hint files (HWAP_HINT_DIR is the helper's test seam for the hint directory) ----
RS="$(date -u -d '+3 hours' +%FT%T).972282+00:00"
ES="$(date -u -d "${RS%.*}Z" +%s)"
HD="$T/hints"
EA="hwaptest-a@example.invalid"; EB="hwaptest-b@example.invalid"
hacct() { # number active email p5 p7 [status] [no5reset]
  local r5=",\"resetsAt\":\"$RS\""; [ -n "${7:-}" ] && r5=""
  printf '{"number":%s,"email":"%s","organizationUuid":"","active":%s,"usageStatus":"%s","disabled":false,"usage":{"fiveHour":{"pct":%s%s},"sevenDay":{"pct":%s,"resetsAt":"%s"}},"usageAgeSeconds":30}' \
    "$1" "$3" "$2" "${6:-ok}" "$4" "$r5" "$5" "$RS"
}
hrun() { # label accounts-json expected-regex [extra-args]
  printf '{"accounts":[%s]}' "$2" > "$T/in.json"
  for mode in jq python; do
    if [ $mode = jq ]; then p="$T/stub:$PATH"; else p="$T/nojq"; fi
    out="$(HWAP_HINT_DIR="$HD" STUB_JSON="$T/in.json" PATH="$p" "$(command -v bash)" "$HELPER" ${4:-})"
    if [[ "$out" =~ ^($3)$ ]]; then echo "PASS [$mode] hint: $1 -> ${out//$'\n'/ | }"
    else echo "FAIL [$mode] hint: $1 -> '$out' (want /$3/)"; fail=1; fi
  done
}
sethint() { mkdir -p "$HD"; printf '%s\n' "$2" > "$HD/usage-$1-personal"; }
ACT="$(hacct 2 true $EA 95 0),$(hacct 1 false $EB 0 0)"

rm -rf "$HD"
hrun "no hint directory at all"          "$ACT" 'ok'
mkdir -p "$HD"
hrun "empty hint directory (unmatched glob)" "$ACT" 'ok'
ln -s "$T/nonexistent" "$HD/usage-$EA-personal"
hrun "dangling hint file is skipped"     "$ACT" 'ok'
rm -f "$HD/usage-$EA-personal"
sethint $EA "98 $ES 0 $ES"
hrun "matching hint raises 95 to 98 -> switch" "$ACT" 'switch 1'
sethint $EA "98 $((ES+3)) 0 $ES"
hrun "hint reset 3 s off still applies"  "$ACT" 'switch 1'
sethint $EA "98 $((ES-3)) 0 $ES"
hrun "hint reset -3 s off still applies" "$ACT" 'switch 1'
sethint $EA "98 $((ES+4)) 0 $ES"
hrun "hint reset 4 s off is ignored"     "$ACT" 'ok'
sethint $EA "50 $ES 0 $ES"
hrun "hint lower than cswap never lowers" "$(hacct 2 true $EA 98 0),$(hacct 1 false $EB 0 0)" 'switch 1'
sethint $EA "98 $ES 0 $((ES+100))"
hrun "5h matches, 7d does not: 5h used"  "$ACT" 'switch 1'
sethint $EA "98 $((ES+100)) 0 $ES"
hrun "5h hint high but 5h reset mismatched" "$ACT" 'ok'
sethint $EA "0 $ES 100 $ES"
hrun "7d matches and high: 7d used"      "$ACT" 'switch 1'
sethint $EA "0 $ES 100 $((ES+100))"
hrun "7d hint high but 7d reset mismatched" "$ACT" 'ok'
sethint $EA "98 0 0 $ES"
hrun "hint reset 0 is ignored"           "$ACT" 'ok'
sethint $EA "98 $ES 0 $ES"
hrun "cswap has no 5h resetsAt: ignored" "$(hacct 2 true $EA 95 0 ok 1),$(hacct 1 false $EB 0 0)" 'ok'
hrun "hint of another account is ignored" "$(hacct 2 true hwaptest-other@example.invalid 95 0),$(hacct 1 false $EB 0 0)" 'ok'
hrun "active not ok: hint changes nothing" "$(hacct 2 true $EA 95 0 token_expired),$(hacct 1 false $EB 0 0)" 'ok'
sethint $EB "98 $ES 0 $ES"
sethint $EA "98 $ES 0 $ES"
hrun "alternate made unusable by its hint is not chosen" "$(hacct 2 true $EA 95 0),$(hacct 1 false $EB 0 0),$(hacct 3 false hwaptest-c@example.invalid 10 0)" 'switch 3'
hrun "hint raises everyone: wait"        "$(hacct 2 true $EA 95 0),$(hacct 1 false $EB 0 0)" 'wait [0-9]+ [0-9]+'
rm -f "$HD/usage-$EB-personal"
for bad in "" "98 $ES 0" "abc $ES 0 $ES" "98" "98 $ES 0 $ES extra" "98 $ES 0 $ES
98 $ES 0 $ES" "-98 $ES 0 $ES"; do
  sethint $EA "$bad"
  hrun "garbage hint '${bad//$'\n'/\\n}'" "$ACT" 'ok'
done
sethint $EA "098 $ES 0 $ES"
hrun "leading zero pct is skipped, not an error" "$ACT" 'ok'
sethint $EA "98 $ES 0 $ES"
hrun "line 2 shows cswap's raw numbers, not the hint" "$ACT" "switch 1.usage 30 95(\.0)? $ES 0(\.0)? $ES $EA-personal 0 0" "--with-usage"
tok="$(HWAP_HINT_DIR="$HD" STUB_JSON="$T/in.json" PATH="$T/stub:$PATH" "$(command -v bash)" "$HELPER")"
len="$(HWAP_HINT_DIR="$HD" STUB_JSON="$T/in.json" PATH="$T/stub:$PATH" "$(command -v bash)" "$HELPER" | wc -c)"
if [ "$tok" != ok ] && [ "$len" -eq "${#tok}" ] && [[ "$tok" != *$'\n'* ]]; then echo "PASS default output with a hint present: one token ($tok), no newline"
else echo "FAIL default output tok='$tok' bytes=$len"; fail=1; fi
exit $fail
