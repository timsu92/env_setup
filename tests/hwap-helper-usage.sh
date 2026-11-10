#!/usr/bin/env bash
# Tests for `hwap-helper.sh --with-usage`. Usage: hwap-usage-test.sh [path-to-helper]
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
BASH_BIN="$(command -v bash)"
T="$(mktemp -d)"
trap 'rm -rf "$T" "$ISO"' EXIT

mkdir -p "$T/stub" "$T/nojq"
cat > "$T/stub/cswap" <<'EOF'
#!/usr/bin/env bash
[ "$1" = list ] || exit 0
[ -n "${STUB_FAIL:-}" ] && exit 1
cat "$STUB_JSON"
EOF
chmod +x "$T/stub/cswap"
for b in bash date python3 cat; do ln -s "$(command -v $b)" "$T/nojq/$b"; done
ln -s "$T/stub/cswap" "$T/nojq/cswap"
for b in tmux screen; do ln -s "$TESTS_DIR/fakes/$b" "$T/nojq/$b"; done
iso_guard "$T/stub:$PATH" "$T/stub"; iso_guard "$T/nojq" "$T/nojq"

R5="2026-11-06T15:29:59.972282+00:00"
R7="2026-11-09T15:59:59.972299+00:00"
E5="$(date -u -d '2026-11-06T15:29:59Z' +%s)"
E7="$(date -u -d '2026-11-09T15:59:59Z' +%s)"
K="hwaptest@example.invalid-personal"

fail=0
paths() { # mode -> PATH
  if [ "$1" = jq ]; then printf '%s' "$T/stub:$PATH"; else printf '%s' "$T/nojq"; fi
}
pass() { echo "PASS [$1] $2"; }
bad()  { echo "FAIL [$1] $2 -> $3"; fail=1; }

# numeric-aware comparison of two whitespace-separated lines
same_nums() { awk -v a="$1" -v b="$2" 'BEGIN{
  n=split(a,x," "); m=split(b,y," "); if(n!=m) exit 1
  if(x[1]!=y[1]) exit 1
  if(x[1]=="usage" && n>=7 && x[7]!=y[7]) exit 1
  for(i=2;i<=n;i++) if((x[i]+0)!=(y[i]+0)) exit 1
  exit 0 }'; }

run_case() { # label json-file mode args expected-line1-regex expected-line2 [fail]
  local label="$1" jf="$2" mode="$3" args="$4" re1="$5" exp2="$6" failflag="${7:-}"
  local out l1 l2
  out="$(STUB_JSON="$jf" STUB_FAIL="$failflag" PATH="$(paths "$mode")" "$BASH_BIN" "$HELPER" $args)"
  l1="${out%%$'\n'*}"
  if [[ "$out" == *$'\n'* ]]; then l2="${out#*$'\n'}"; else l2="<none>"; fi
  if ! [[ "$l1" =~ ^($re1)$ ]]; then bad "$mode" "$label" "line1 '$l1'"; return; fi
  if [ "$exp2" = "<none>" ]; then
    [ "$l2" = "<none>" ] && pass "$mode" "$label" || bad "$mode" "$label" "unexpected line2 '$l2'"
  elif [[ "$exp2" == "usage none" ]]; then
    [ "$l2" = "usage none" ] && pass "$mode" "$label" || bad "$mode" "$label" "line2 '$l2'"
  else
    if same_nums "$exp2" "$l2"; then pass "$mode" "$label"; else bad "$mode" "$label" "line2 '$l2' want '$exp2'"; fi
  fi
}

active_ok() { # age
  cat <<EOF
{"accounts":[
 {"number":1,"email":"hwaptest@example.invalid","organizationUuid":"","active":true,"usageStatus":"ok","disabled":false,"usage":{"fiveHour":{"pct":6.0,"resetsAt":"$R5"},"sevenDay":{"pct":77.0,"resetsAt":"$R7"}},"usageFetchedAt":"2026-11-06T14:05:45Z","usageAgeSeconds":$1},
 {"number":2,"active":false,"usageStatus":"ok","disabled":false,"usage":{"fiveHour":{"pct":0.0},"sevenDay":{"pct":10.0,"resetsAt":"$R7"}},"usageFetchedAt":"2026-11-06T14:05:45Z","usageAgeSeconds":$1}
]}
EOF
}

for mode in jq python; do
  active_ok 31.2 > "$T/ok.json"

  # default mode: byte-identical token, no trailing newline
  out="$(STUB_JSON="$T/ok.json" PATH="$(paths $mode)" "$BASH_BIN" "$HELPER")"
  len="$(STUB_JSON="$T/ok.json" PATH="$(paths $mode)" "$BASH_BIN" "$HELPER" | wc -c)"
  if [ "$out" = ok ] && [ "$len" -eq "${#out}" ]; then pass $mode "default mode unchanged (token, no newline)"
  else bad $mode "default mode unchanged" "out='$out' bytes=$len"; fi

  run_case "with-usage active ok" "$T/ok.json" $mode --with-usage 'ok' "usage 31 6.0 $E5 77.0 $E7 $K 0 0"

  # 5h window has no resetsAt
  cat > "$T/noreset.json" <<EOF
{"accounts":[{"number":1,"email":"hwaptest@example.invalid","organizationUuid":"","active":true,"usageStatus":"ok","disabled":false,"usage":{"fiveHour":{"pct":0.0},"sevenDay":{"pct":77.0,"resetsAt":"$R7"}},"usageAgeSeconds":5.9}]}
EOF
  run_case "5h without resetsAt" "$T/noreset.json" $mode --with-usage 'ok' "usage 5 0.0 0 77.0 $E7 $K 0 0"

  # active needs relogin
  cat > "$T/relogin.json" <<'EOF'
{"accounts":[{"number":1,"active":true,"usageStatus":"relogin_required","usage":null}]}
EOF
  run_case "active relogin_required" "$T/relogin.json" $mode --with-usage 'ok' "usage none"

  # active account with an empty usage object: both paths must agree
  cat > "$T/emptyusage.json" <<EOF
{"accounts":[{"number":1,"active":true,"usageStatus":"ok","disabled":false,"usage":{},"usageAgeSeconds":5}]}
EOF
  run_case "empty usage object" "$T/emptyusage.json" $mode --with-usage 'ok' "usage none"

  # no active account
  cat > "$T/noactive.json" <<EOF
{"accounts":[{"number":1,"active":false,"usageStatus":"ok","disabled":false,"usage":{"fiveHour":{"pct":6.0,"resetsAt":"$R5"},"sevenDay":{"pct":7.0,"resetsAt":"$R7"}},"usageAgeSeconds":10}]}
EOF
  run_case "no active account" "$T/noactive.json" $mode --with-usage 'ok' "usage none"

  # usageAgeSeconds absent
  cat > "$T/noage.json" <<EOF
{"accounts":[{"number":1,"active":true,"usageStatus":"ok","disabled":false,"usage":{"fiveHour":{"pct":6.0,"resetsAt":"$R5"},"sevenDay":{"pct":7.0,"resetsAt":"$R7"}}}]}
EOF
  run_case "usageAgeSeconds absent" "$T/noage.json" $mode --with-usage 'ok' "usage none"

  # active token_expired: cswap has no usage but gives the account's own last good one
  cat > "$T/lg.json" <<EOF
{"accounts":[
 {"number":1,"active":true,"usageStatus":"token_expired","disabled":false,"usage":null,"lastGoodUsage":{"fiveHour":{"pct":12.0,"resetsAt":"$R5"},"sevenDay":{"pct":34.0,"resetsAt":"$R7"}},"lastGoodFetchedAt":"2026-11-06T14:00:00Z","lastGoodAgeSeconds":412.6},
 {"number":2,"active":false,"usageStatus":"ok","disabled":false,"usage":{"fiveHour":{"pct":0.0},"sevenDay":{"pct":10.0,"resetsAt":"$R7"}},"usageAgeSeconds":5}
]}
EOF
  run_case "token_expired with lastGoodUsage" "$T/lg.json" $mode --with-usage 'ok' "lastgood 412 12.0 $E5 34.0 $E7"
  # the default mode must not change
  out="$(STUB_JSON="$T/lg.json" PATH="$(paths $mode)" "$BASH_BIN" "$HELPER")"
  [ "$out" = ok ] && pass $mode "lastGoodUsage: default mode still one token" || bad $mode "lastGoodUsage: default mode" "out='$out'"

  # foreign_credential and unavailable take the same path
  sed 's/token_expired/foreign_credential/' "$T/lg.json" > "$T/lg-foreign.json"
  run_case "foreign_credential with lastGoodUsage" "$T/lg-foreign.json" $mode --with-usage 'ok' "lastgood 412 12.0 $E5 34.0 $E7"
  sed 's/token_expired/unavailable/' "$T/lg.json" > "$T/lg-unavail.json"
  run_case "unavailable with lastGoodUsage" "$T/lg-unavail.json" $mode --with-usage 'ok' "lastgood 412 12.0 $E5 34.0 $E7"

  # a window without resetsAt gives 0
  cat > "$T/lg-noreset.json" <<EOF
{"accounts":[{"number":1,"active":true,"usageStatus":"token_expired","usage":null,"lastGoodUsage":{"fiveHour":{"pct":0.0},"sevenDay":{"pct":34.0,"resetsAt":"$R7"}},"lastGoodAgeSeconds":9}]}
EOF
  run_case "lastGoodUsage window without resetsAt" "$T/lg-noreset.json" $mode --with-usage 'ok' "lastgood 9 0.0 0 34.0 $E7"

  # nothing usable to show
  echo '{"accounts":[{"number":1,"active":true,"usageStatus":"token_expired","usage":null}]}' > "$T/lg-none.json"
  run_case "token_expired without lastGoodUsage" "$T/lg-none.json" $mode --with-usage 'ok' "usage none"
  echo '{"accounts":[{"number":1,"active":true,"usageStatus":"token_expired","usage":null,"lastGoodUsage":{},"lastGoodAgeSeconds":9}]}' > "$T/lg-empty.json"
  run_case "token_expired with empty lastGoodUsage" "$T/lg-empty.json" $mode --with-usage 'ok' "usage none"
  echo '{"accounts":[{"number":1,"active":true,"usageStatus":"token_expired","usage":null,"lastGoodUsage":{"fiveHour":{"pct":1.0},"sevenDay":{"pct":2.0}}}]}' > "$T/lg-noage.json"
  run_case "lastGoodUsage without lastGoodAgeSeconds" "$T/lg-noage.json" $mode --with-usage 'ok' "usage none"

  # only the active account's lastGoodUsage counts
  cat > "$T/lg-other.json" <<EOF
{"accounts":[
 {"number":1,"active":true,"usageStatus":"token_expired","usage":null},
 {"number":2,"active":false,"usageStatus":"token_expired","usage":null,"lastGoodUsage":{"fiveHour":{"pct":50.0},"sevenDay":{"pct":60.0}},"lastGoodAgeSeconds":9}
]}
EOF
  run_case "another account's lastGoodUsage is ignored" "$T/lg-other.json" $mode --with-usage 'ok' "usage none"

  # --stdin-resets: per-window match flags (tolerance 3 s) and the account key
  run_case "stdin resets equal" "$T/ok.json" $mode "--with-usage --stdin-resets $E5 $E7" 'ok' "usage 31 6.0 $E5 77.0 $E7 $K 1 1"
  run_case "5h off by 3 s matches" "$T/ok.json" $mode "--with-usage --stdin-resets $((E5+3)) $E7" 'ok' "usage 31 6.0 $E5 77.0 $E7 $K 1 1"
  run_case "5h off by -3 s matches" "$T/ok.json" $mode "--with-usage --stdin-resets $((E5-3)) $E7" 'ok' "usage 31 6.0 $E5 77.0 $E7 $K 1 1"
  run_case "5h off by 4 s does not" "$T/ok.json" $mode "--with-usage --stdin-resets $((E5+4)) $E7" 'ok' "usage 31 6.0 $E5 77.0 $E7 $K 0 1"
  run_case "7d judged separately" "$T/ok.json" $mode "--with-usage --stdin-resets $E5 $((E7+4))" 'ok' "usage 31 6.0 $E5 77.0 $E7 $K 1 0"
  run_case "stdin resets 0 0" "$T/ok.json" $mode "--with-usage --stdin-resets 0 0" 'ok' "usage 31 6.0 $E5 77.0 $E7 $K 0 0"
  run_case "garbage stdin reset treated as 0" "$T/ok.json" $mode "--with-usage --stdin-resets abc $E7" 'ok' "usage 31 6.0 $E5 77.0 $E7 $K 0 1"
  run_case "no cswap resetsAt: 0 vs 0 is no match" "$T/noreset.json" $mode "--with-usage --stdin-resets 0 $E7" 'ok' "usage 5 0.0 0 77.0 $E7 $K 0 1"
  run_case "lastgood unchanged with flag" "$T/lg.json" $mode "--with-usage --stdin-resets $E5 $E7" 'ok' "lastgood 412 12.0 $E5 34.0 $E7"
  run_case "usage none unchanged with flag" "$T/relogin.json" $mode "--with-usage --stdin-resets $E5 $E7" 'ok' "usage none"

  # key: organisation appended, odd characters become _, no email gives -
  cat > "$T/org.json" <<EOF2
{"accounts":[{"number":1,"email":"a b/c@x.io","organizationUuid":"abc-123","active":true,"usageStatus":"ok","disabled":false,"usage":{"fiveHour":{"pct":1.0,"resetsAt":"$R5"},"sevenDay":{"pct":2.0,"resetsAt":"$R7"}},"usageAgeSeconds":4}]}
EOF2
  run_case "org key and sanitised email" "$T/org.json" $mode "--with-usage" 'ok' "usage 4 1.0 $E5 2.0 $E7 a_b_c@x.io-abc-123 0 0"
  cat > "$T/noemail.json" <<EOF2
{"accounts":[{"number":1,"active":true,"usageStatus":"ok","disabled":false,"usage":{"fiveHour":{"pct":1.0,"resetsAt":"$R5"},"sevenDay":{"pct":2.0,"resetsAt":"$R7"}},"usageAgeSeconds":4}]}
EOF2
  run_case "no email gives key -" "$T/noemail.json" $mode "--with-usage --stdin-resets $E5 $E7" 'ok' "usage 4 1.0 $E5 2.0 $E7 - 1 1"

  # cswap fails
  run_case "cswap exits 1" "$T/ok.json" $mode --with-usage 'error:cswap_list_failed' "usage none" 1

  # unparsable output
  echo 'not json' > "$T/bad.json"
  run_case "cswap prints not json" "$T/bad.json" $mode --with-usage 'error:cswap_output_unparsable' "usage none"
done
exit $fail
