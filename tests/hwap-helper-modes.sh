#!/usr/bin/env bash
# Tests for `hwap-helper.sh current` and `hwap-helper.sh accounts`. Usage: hwap-helper-modes.sh [path-to-helper]
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
HELPER="${1:-$TESTS_DIR/../ansible/roles/claude_code/files/hwap-helper.sh}"
BASH_BIN="$(command -v bash)"
T="$(mktemp -d)"
trap 'rm -rf "$T" "$ISO"' EXIT

# The fake cswap (tests/fakes/cswap) serves $STUB_JSON and fails on $STUB_FAIL.
mkdir -p "$T/nojq"
for b in bash date python3 cat; do ln -s "$(command -v $b)" "$T/nojq/$b"; done
for b in cswap tmux screen; do ln -s "$TESTS_DIR/fakes/$b" "$T/nojq/$b"; done
iso_guard "$PATH"; iso_guard "$T/nojq" "$T/nojq"

iso() { date -u -d "$1" +%FT%T.500000+00:00; }
epoch() { date -u -d "${1%.*}Z" +%s; }
R5="$(iso '+3 hours')"; R7="$(iso '+3 days')"; R5P="$(iso '-1 hour')"
E5="$(epoch "$R5")"; E7="$(epoch "$R7")"; E5P="$(epoch "$R5P")"
EM="modes@example.invalid"; K="$EM-personal"
HD="$T/hints"
TAIL="97 99 120 3"

fail=0
pass() { echo "PASS [$1] $2"; }
bad()  { echo "FAIL [$1] $2 -> $3"; fail=1; }
paths() { if [ "$1" = jq ]; then printf '%s' "$PATH"; else printf '%s' "$T/nojq"; fi; }
sethint() { mkdir -p "$HD"; printf '%s\n' "$2" > "$HD/usage-$1"; }

# Fields 1 and 2 (tag, key) must match exactly, the rest numerically (jq and
# Python print 40.0 and 40 differently).
same_cur() { awk -v a="$1" -v b="$2" 'BEGIN{
  n=split(a,x," "); m=split(b,y," "); if(n!=m) exit 1
  if(x[1]!=y[1] || x[2]!=y[2]) exit 1
  for(i=3;i<=n;i++) if((x[i]+0)!=(y[i]+0)) exit 1
  exit 0 }'; }

# acct <status> <p5> <r5-iso|-> <p7> <r7-iso> [email]: the active account
acct() {
  local r5=""; [ "$3" != - ] && r5=",\"resetsAt\":\"$3\""
  printf '{"number":1,"email":"%s","organizationUuid":"","active":true,"usageStatus":"%s","disabled":false,"usage":{"fiveHour":{"pct":%s%s},"sevenDay":{"pct":%s,"resetsAt":"%s"}},"usageAgeSeconds":30,"lastGoodUsage":{"fiveHour":{"pct":12.0,"resetsAt":"%s"},"sevenDay":{"pct":34.0,"resetsAt":"%s"}},"lastGoodAgeSeconds":412.6}' \
    "${6-$EM}" "$1" "$2" "$r5" "$4" "$5" "$R5" "$R7"
}
other() { printf '{"number":2,"email":"modes-b@example.invalid","organizationUuid":"","active":false,"usageStatus":"ok","disabled":false,"usage":{"fiveHour":{"pct":1.0,"resetsAt":"%s"},"sevenDay":{"pct":2.0,"resetsAt":"%s"}},"usageAgeSeconds":30}' "$R5" "$R7"; }

cur() { # mode label accounts-json expected-line
  local mode="$1" label="$2" out
  printf '{"accounts":[%s]}' "$3" > "$T/in.json"
  out="$(HWAP_HINT_DIR="$HD" STUB_JSON="$T/in.json" PATH="$(paths "$mode")" "$BASH_BIN" "$HELPER" current; echo x)"
  out="${out%x}"
  if [[ "$out" != *$'\n' || "${out%$'\n'}" == *$'\n'* ]]; then bad "$mode" "$label" "not exactly one newline-terminated line: '$out'"
  elif same_cur "$4" "${out%$'\n'}"; then pass "$mode" "$label"
  else bad "$mode" "$label" "got '${out%$'\n'}' want '$4'"; fi
}

for mode in jq python; do
  rm -rf "$HD"
  OK="$(acct ok 40.0 "$R5" 20.0 "$R7"),$(other)"
  cur $mode "active ok, no hint dir" "$OK" "usage $K 40 $E5 20 $E7 $TAIL"
  mkdir -p "$HD"
  cur $mode "active ok, empty hint dir" "$OK" "usage $K 40 $E5 20 $E7 $TAIL"

  sethint $K-nothing "99 $E5 99 $E7"
  cur $mode "hint of another key is ignored" "$OK" "usage $K 40 $E5 20 $E7 $TAIL"
  sethint $K "55 $E5 20 $E7"
  cur $mode "matching hint raises 5h 40 to 55" "$OK" "usage $K 55 $E5 20 $E7 $TAIL"
  sethint $K "55 $((E5+3)) 20 $E7"
  cur $mode "hint reset 3 s off still applies" "$OK" "usage $K 55 $E5 20 $E7 $TAIL"
  sethint $K "30 $E5 20 $E7"
  cur $mode "hint lower than cswap never lowers" "$OK" "usage $K 40 $E5 20 $E7 $TAIL"
  sethint $K "55 $((E5+4)) 20 $E7"
  cur $mode "hint reset 4 s off is ignored" "$OK" "usage $K 40 $E5 20 $E7 $TAIL"
  sethint $K "10 $E5 70 $E7"
  cur $mode "7d hint raises 7d only" "$OK" "usage $K 40 $E5 70 $E7 $TAIL"
  sethint $K "55 $E5 20 $E7"

  cur $mode "5h resetsAt in the past reads 0, reset stays" \
    "$(acct ok 40.0 "$R5P" 20.0 "$R7"),$(other)" "usage $K 0 $E5P 20 $E7 $TAIL"
  sethint $K "99 $E5P 20 $E7"
  cur $mode "past reset is zeroed even when a hint matches it" \
    "$(acct ok 40.0 "$R5P" 20.0 "$R7"),$(other)" "usage $K 0 $E5P 20 $E7 $TAIL"
  sethint $K "55 $E5 20 $E7"
  cur $mode "5h without resetsAt keeps its pct, reset 0" \
    "$(acct ok 40.0 - 20.0 "$R7"),$(other)" "usage $K 40 0 20 $E7 $TAIL"

  cur $mode "token_expired: lastgood numbers, hint not applied" \
    "$(acct token_expired 40.0 "$R5" 20.0 "$R7"),$(other)" "lastgood $K 12 $E5 34 $E7 $TAIL"
  cur $mode "no email: key -" \
    "$(acct ok 40.0 "$R5" 20.0 "$R7" ""),$(other)" "usage - 40 $E5 20 $E7 $TAIL"

  cur $mode "no active account" "$(other)" "none - 0 0 0 0 $TAIL"
  cur $mode "ok account without usage" \
    '{"number":1,"email":"modes@example.invalid","active":true,"usageStatus":"ok","usage":{},"usageAgeSeconds":3}' "none - 0 0 0 0 $TAIL"
  cur $mode "not ok and no lastGoodUsage" \
    '{"number":1,"email":"modes@example.invalid","active":true,"usageStatus":"relogin_required","usage":null}' "none - 0 0 0 0 $TAIL"

  # cswap fails: exactly one line, starting error:
  printf '{"accounts":[%s]}' "$OK" > "$T/in.json"
  out="$(HWAP_HINT_DIR="$HD" STUB_JSON="$T/in.json" STUB_FAIL=1 PATH="$(paths $mode)" "$BASH_BIN" "$HELPER" current)"
  if [[ "$out" == error:?* && "$out" != *$'\n'* ]]; then pass $mode "cswap fails: one error: line ($out)"
  else bad $mode "cswap fails" "out='$out'"; fi
  echo 'not json' > "$T/in.json"
  out="$(HWAP_HINT_DIR="$HD" STUB_JSON="$T/in.json" PATH="$(paths $mode)" "$BASH_BIN" "$HELPER" current)"
  if [[ "$out" == error:?* && "$out" != *$'\n'* ]]; then pass $mode "unparsable cswap output: one error: line ($out)"
  else bad $mode "unparsable cswap output" "out='$out'"; fi

  # default mode and --with-usage are untouched by the new argument
  printf '{"accounts":[%s]}' "$OK" > "$T/in.json"
  d="$(HWAP_HINT_DIR="$HD" STUB_JSON="$T/in.json" PATH="$(paths $mode)" "$BASH_BIN" "$HELPER"; echo x)"
  if [ "$d" = "okx" ]; then pass $mode "default mode: token ok, no newline"; else bad $mode "default mode" "'$d'"; fi
  w="$(HWAP_HINT_DIR="$HD" STUB_JSON="$T/in.json" PATH="$(paths $mode)" "$BASH_BIN" "$HELPER" --with-usage; echo x)"
  if [[ "$w" == "ok"$'\n'"usage 30 40"*" $K 0 0x" ]]; then pass $mode "--with-usage: two lines, no trailing newline"; else bad $mode "--with-usage" "'$w'"; fi
done

# ---- accounts ----
CFG="$T/cfg"
q() { if [ "$1" = null ]; then printf null; else printf '"%s"' "$1"; fi; }
# mkcfg <num> <seat|null> <user|null> <org|null> [suffix]: a fake cswap config
# file carrying only the tier fields (never tokens). The suffix keeps the file
# name unique per call.
mkcfg() {
  mkdir -p "$CFG"
  printf '{"oauthAccount":{"seatTier":%s,"userRateLimitTier":%s,"organizationRateLimitTier":%s}}\n' \
    "$(q "$2")" "$(q "$3")" "$(q "$4")" > "$CFG/.claude-config-$1-${5:-fix}"
}
# ac <num> <email> <active true|false> <status> <disabled true|false> <p5> <r5-iso> <p7> <r7-iso>
ac() {
  printf '{"number":%s,"email":"%s","organizationUuid":"","active":%s,"usageStatus":"%s","disabled":%s,"usage":{"fiveHour":{"pct":%s,"resetsAt":"%s"},"sevenDay":{"pct":%s,"resetsAt":"%s"}},"usageAgeSeconds":30,"lastGoodUsage":{"fiveHour":{"pct":12.0,"resetsAt":"%s"},"sevenDay":{"pct":34.0,"resetsAt":"%s"}},"lastGoodAgeSeconds":412.6}' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "$R5" "$R7"
}
EA="acc-a@example.invalid"; EB="acc-b@example.invalid"; KA="$EA-personal"; KB="$EB-personal"

# Fields 1-4 and 9-10 exactly, the pcts and resets numerically, line by line.
same_acc() { awk -v a="$1" -v b="$2" 'BEGIN{
  n=split(a,L,"\n"); m=split(b,M,"\n"); if(n!=m) exit 1
  for(j=1;j<=n;j++){
    f=split(L[j],x," "); g=split(M[j],y," "); if(f!=10||g!=10) exit 1
    for(i=1;i<=10;i++){
      if(i>=5&&i<=8){ if((x[i]+0)!=(y[i]+0)) exit 1 } else if(x[i]!=y[i]) exit 1 } }
  exit 0 }'; }

# accts <mode> <label> <accounts-json-list> <expected lines, \n-separated>
accts() {
  local mode="$1" label="$2" out
  printf '{"accounts":[%s]}' "$3" > "$T/in.json"
  out="$(HWAP_HINT_DIR="$HD" HWAP_CSWAP_CONFIG_DIR="$CFG" STUB_JSON="$T/in.json" PATH="$(paths "$mode")" "$BASH_BIN" "$HELPER" accounts; echo x)"
  out="${out%x}"
  if [[ "$out" != *$'\n' ]]; then bad "$mode" "$label" "no trailing newline: '$out'"
  elif same_acc "$4" "${out%$'\n'}"; then pass "$mode" "$label"
  else bad "$mode" "$label" "got '${out%$'\n'}' want '$4'"; fi
}

for mode in jq python; do
  rm -rf "$HD" "$CFG"; mkdir -p "$HD"
  mkcfg 1 null null null; mkcfg 2 null null null
  A1="$(ac 1 $EA false ok false 40.0 "$R5" 20.0 "$R7")"
  A2="$(ac 2 $EB true ok false 1.0 "$R5" 2.0 "$R7")"
  accts $mode "two accounts, active #2, unknown plans" "$A1,$A2" \
"1 $KA 0 1 40 $E5 20 $E7 - -
2 $KB 1 1 1 $E5 2 $E7 - -"

  accts $mode "alt over 97 on 5h before reset+buffer: usable 0" \
    "$(ac 1 $EA false ok false 98.0 "$R5" 20.0 "$R7"),$A2" \
"1 $KA 0 0 98 $E5 20 $E7 - -
2 $KB 1 1 1 $E5 2 $E7 - -"
  accts $mode "alt over 99 on 7d before reset+buffer: usable 0" \
    "$(ac 1 $EA false ok false 40.0 "$R5" 99.0 "$R7"),$A2" \
"1 $KA 0 0 40 $E5 99 $E7 - -
2 $KB 1 1 1 $E5 2 $E7 - -"
  accts $mode "alt over 97 but its reset+buffer is past: usable 1, pct 0" \
    "$(ac 1 $EA false ok false 98.0 "$R5P" 20.0 "$R7"),$A2" \
"1 $KA 0 1 0 $E5P 20 $E7 - -
2 $KB 1 1 1 $E5 2 $E7 - -"

  # a hint for key A raises A only and never changes B; usable follows the printed pcts
  sethint $KA "98 $E5 20 $E7"
  accts $mode "hint for A raises A's 5h to 98 and its usable to 0, B untouched" "$A1,$A2" \
"1 $KA 0 0 98 $E5 20 $E7 - -
2 $KB 1 1 1 $E5 2 $E7 - -"
  sethint $KA "30 $E5 20 $E7"
  accts $mode "lower hint for A never lowers" "$A1,$A2" \
"1 $KA 0 1 40 $E5 20 $E7 - -
2 $KB 1 1 1 $E5 2 $E7 - -"
  sethint $KA "10 $E5 50 $E7"
  sethint $KB "10 $E5 60 $E7"
  accts $mode "each hint applies to its own key only" "$A1,$A2" \
"1 $KA 0 1 40 $E5 50 $E7 - -
2 $KB 1 1 10 $E5 60 $E7 - -"
  rm -rf "$HD"; mkdir -p "$HD"

  accts $mode "disabled alt: usable 0" \
    "$(ac 1 $EA false ok true 40.0 "$R5" 20.0 "$R7"),$A2" \
"1 $KA 0 0 40 $E5 20 $E7 - -
2 $KB 1 1 1 $E5 2 $E7 - -"
  accts $mode "token_expired alt: usable 0, its own last numbers" \
    "$(ac 1 $EA false token_expired false 40.0 "$R5" 20.0 "$R7"),$A2" \
"1 $KA 0 0 12 $E5 34 $E7 - -
2 $KB 1 1 1 $E5 2 $E7 - -"
  accts $mode "accounts are sorted by number" "$A2,$A1" \
"1 $KA 0 1 40 $E5 20 $E7 - -
2 $KB 1 1 1 $E5 2 $E7 - -"

  # multipliers, one account each; seat, then user, then organization tier
  mrow() { # label seat user org want5 want7
    mkcfg 1 "$2" "$3" "$4"
    accts $mode "plan: $1" "$(ac 1 $EA true ok false 40.0 "$R5" 20.0 "$R7")" "1 $KA 1 1 40 $E5 20 $E7 $5 $6"
  }
  mrow "seat team_standard" team_standard null null 1.25 -
  mrow "seat team_tier_1" team_tier_1 null null 6.25 -
  mrow "any other seat is unknown" team_premium null null - -
  mrow "other seat stops: user tier is not consulted" team_premium default_claude_max_5x default_claude_ai - -
  mrow "user max_5x" null default_claude_max_5x null 5 5
  mrow "user max_20x" null default_claude_max_20x null 20 20
  mrow "org default_claude_ai" null null default_claude_ai 1 1
  mrow "org max_5x" null null default_claude_max_5x 5 5
  mrow "org max_20x" null null default_claude_max_20x 20 20
  mrow "default_raven alone is unknown" null null default_raven - -
  mrow "nothing set is unknown" null null null - -
  mrow "unknown user tier falls through to org" null something_else default_claude_ai 1 1
  mrow "seat team_standard beats user max_5x" team_standard default_claude_max_5x null 1.25 -
  mrow "user max_5x beats org max_20x" null default_claude_max_5x default_claude_max_20x 5 5

  # config file lookup
  rm -rf "$CFG"; mkdir -p "$CFG"
  accts $mode "no config file: - -" "$(ac 1 $EA true ok false 40.0 "$R5" 20.0 "$R7")" "1 $KA 1 1 40 $E5 20 $E7 - -"
  mkcfg 10 null default_claude_max_20x null
  accts $mode "config of #10 is not #1's" "$(ac 1 $EA true ok false 40.0 "$R5" 20.0 "$R7")" "1 $KA 1 1 40 $E5 20 $E7 - -"
  mkcfg 1 null default_claude_max_5x null a
  mkcfg 1 null default_claude_max_20x null b
  accts $mode "first .claude-config-1-* wins" "$(ac 1 $EA true ok false 40.0 "$R5" 20.0 "$R7")" "1 $KA 1 1 40 $E5 20 $E7 5 5"
  echo 'not json' > "$CFG/.claude-config-1-a"
  accts $mode "unreadable config of #1: - -, others fine" "$(ac 1 $EA true ok false 40.0 "$R5" 20.0 "$R7"),$(ac 10 $EB false ok false 1.0 "$R5" 2.0 "$R7")" \
"1 $KA 1 1 40 $E5 20 $E7 - -
10 $KB 0 1 1 $E5 2 $E7 20 20"

  # cswap fails / unparsable: exactly one error: line
  printf '{"accounts":[%s]}' "$A2" > "$T/in.json"
  out="$(HWAP_HINT_DIR="$HD" HWAP_CSWAP_CONFIG_DIR="$CFG" STUB_JSON="$T/in.json" STUB_FAIL=1 PATH="$(paths $mode)" "$BASH_BIN" "$HELPER" accounts; echo x)"
  if [[ "$out" == error:?*$'\n'x && "${out%x}" != *$'\n'*$'\n' ]]; then pass $mode "accounts: cswap fails -> one error: line"
  else bad $mode "accounts: cswap fails" "out='$out'"; fi
  echo 'not json' > "$T/in.json"
  out="$(HWAP_HINT_DIR="$HD" HWAP_CSWAP_CONFIG_DIR="$CFG" STUB_JSON="$T/in.json" PATH="$(paths $mode)" "$BASH_BIN" "$HELPER" accounts; echo x)"
  if [[ "$out" == error:?*$'\n'x && "${out%x}" != *$'\n'*$'\n' ]]; then pass $mode "accounts: unparsable cswap output -> one error: line"
  else bad $mode "accounts: unparsable cswap output" "out='$out'"; fi
done
exit $fail
