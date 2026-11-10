#!/usr/bin/env bash
# Tests for statusline.sh's usage source selection and stale look.
# Usage: statusline-test.sh [path-to-statusline.sh]
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
STATUSLINE="${1:-${TESTS_DIR}/../ansible/roles/claude_code/files/statusline.sh}"
BASH_BIN="$(command -v bash)"
UID_N="$(id -u)"
T="$(mktemp -d)"
HD="$T/hints"
FAKE_EMAIL="statusline-test@example.invalid"
CACHE="/tmp/claude-$UID_N/ratelimit-$FAKE_EMAIL"
SIDS=()
cleanup() {
  rm -rf "$T" "$ISO" "$CACHE"
  for s in "${SIDS[@]}"; do rm -rf "/tmp/claude-$UID_N/$s"; done
}
trap cleanup EXIT

mkdir -p "$T/stub" "$T/nojqbin" "$T/cfg" "$T/xdg" "$T/cwd" "$T/deploy"
# The repo files lack the exec bit (Ansible sets the mode on deploy), so run a deployed-style copy.
cp "$STATUSLINE" "$T/deploy/statusline.sh"; cp "$(dirname "$STATUSLINE")/hwap-helper.sh" "$T/deploy/hwap-helper.sh"
chmod +x "$T/deploy/statusline.sh" "$T/deploy/hwap-helper.sh"
STATUSLINE="$T/deploy/statusline.sh"
echo "{\"oauthAccount\":{\"emailAddress\":\"$FAKE_EMAIL\"}}" > "$T/cfg/.claude.json"
cat > "$T/stub/cswap" <<'EOF'
#!/usr/bin/env bash
[ "$1" = list ] || exit 0
[ -n "${STUB_COUNT:-}" ] && echo x >> "$STUB_COUNT"
[ -n "${STUB_FAIL:-}" ] && exit 1
cat "$STUB_JSON"
EOF
chmod +x "$T/stub/cswap"
for f in /usr/bin/* /bin/*; do
  b="${f##*/}"; case "$b" in jq|tmux|screen|cswap) continue ;; esac
  [ -e "$T/nojqbin/$b" ] || ln -s "$f" "$T/nojqbin/$b" 2>/dev/null
done
for b in tmux screen; do ln -s "$TESTS_DIR/fakes/$b" "$T/nojqbin/$b"; done
iso_guard "$T/stub:$PATH" "$T/stub"; iso_guard "$T/stub:$T/nojqbin" "$T/stub" "$T/nojqbin"

NOW="$(date +%s)"
iso() { date -u -d "$1" +%FT%T.000000+00:00; }
R5_FUT="$(iso '+2 hours')"; R7_FUT="$(iso '+3 days')"; R5_PAST="$(iso '-1 hour')"

# cswap_json <p5> <p7> <age> [r5iso] [status] -> account 1 active, account 2 inactive
cswap_json() {
  local r5="${4:-$R5_FUT}" st="${5:-ok}"
  cat <<EOF
{"accounts":[
 {"number":1,"active":true,"usageStatus":"$st","disabled":false,"usage":{"fiveHour":{"pct":$1,"resetsAt":"$r5"},"sevenDay":{"pct":$2,"resetsAt":"$R7_FUT"}},"usageAgeSeconds":$3},
 {"number":2,"active":false,"usageStatus":"ok","disabled":false,"usage":{"fiveHour":{"pct":40,"resetsAt":"$R5_FUT"},"sevenDay":{"pct":50,"resetsAt":"$R7_FUT"}},"usageAgeSeconds":$3}
]}
EOF
}

fail=0
n=0
# render <mode> <stdin5> <stdin7> <stamps none|running|idle> <cswap-json-file> [fail]
# sets RAW (with SGR), TXT (stripped), RATE (first NN%/NN%), CALLS (cswap list count)
render() {
  local mode="$1" s5="$2" s7="$3" stamps="$4" jf="$5" failflag="${6:-}"
  n=$((n+1)); local sid="sltest-$$-$n"; SIDS+=("$sid")
  local d="/tmp/claude-$UID_N/$sid"
  mkdir -p "$d"
  [ -n "${KEEP_CACHE:-}" ] || rm -f "$CACHE"
  case "$stamps" in
    running) echo $((NOW-100)) > "$d/turn_start" ;;
    idle) echo $((NOW-100)) > "$d/turn_start"; echo $((NOW-50)) > "$d/turn_stop" ;;
  esac
  local p; if [ "$mode" = jq ]; then p="$T/stub:$PATH"; else p="$T/stub:$T/nojqbin"; fi
  : > "$T/calls"
  local rl; rl="$(printf ',"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}' \
      "$s5" "${S_R5:-$((NOW+7200))}" "$s7" "${S_R7:-$((NOW+259200))}")"
  [ -n "${NO_RL:-}" ] && rl=""
  RAW="$(printf '{"session_id":"%s","model":{"display_name":"M"},"workspace":{"current_dir":"%s"}%s}' \
      "$sid" "$T/cwd" "$rl" |
    env CLAUDE_CONFIG_DIR="$T/cfg" XDG_DATA_HOME="$T/xdg" STATUSLINE_COLS=200 PATH="$p" HWAP_HINT_DIR="${HINT_DIR_OVERRIDE:-$HD}" \
        STUB_JSON="$jf" STUB_COUNT="$T/calls" STUB_FAIL="$failflag" "$BASH_BIN" "$STATUSLINE" 2>/dev/null)"
  TXT="$(printf '%s' "$RAW" | sed 's/\x1b\[[0-9;]*m//g')"
  RATE="$(printf '%s' "$TXT" | sed -n 2p | grep -oE '[0-9]+%/[0-9]+%' | head -1)"
  CALLS="$(wc -l < "$T/calls")"
}
check() { # mode label ok-bool detail
  if [ "$3" = 1 ]; then echo "PASS [$1] $2"; else echo "FAIL [$1] $2 -> $4"; fail=1; fi
}
expect_rate() { # mode label expected
  [ "$RATE" = "$3" ] && check "$1" "$2" 1 || check "$1" "$2" 0 "rate '$RATE' want '$3'"
}

for mode in jq python; do
  cswap_json 10 20 30 > "$T/c-fresh.json"

  rm -f "$CACHE"
  render $mode 41 51 running "$T/c-fresh.json"
  expect_rate $mode "mid-turn ignores cswap" "41%/51%"
  [ ! -e "$CACHE" ] && check $mode "mid-turn writes no ratelimit cache" 1 || check $mode "mid-turn writes no ratelimit cache" 0 "$CACHE exists"
  [ "$CALLS" = 1 ] && check $mode "one cswap call per render" 1 || check $mode "one cswap call per render" 0 "calls=$CALLS"

  render $mode 40 50 idle "$T/c-fresh.json"
  expect_rate $mode "idle uses cswap" "10%/20%"

  # stdin carries the other account's numbers (40/50 are account 2's), cswap's active is account 1
  render $mode 40 50 idle "$T/c-fresh.json"
  expect_rate $mode "switched account: active entry, not stdin's" "10%/20%"

  cswap_json 80 20 30 "$R5_PAST" > "$T/c-past.json"
  render $mode 40 50 idle "$T/c-past.json"
  expect_rate $mode "rolled-over window shows 0%" "0%/20%"

  render $mode 40 50 idle "$T/c-fresh.json" 1
  expect_rate $mode "cswap fails: stdin numbers" "40%/50%"
  case "$TXT" in *"hwap error:cswap_list_failed"*) check $mode "cswap fails: hwap error segment kept" 1 ;; *) check $mode "cswap fails: hwap error segment kept" 0 "segment missing" ;; esac

  echo '{"accounts":[{"number":1,"active":false,"usageStatus":"ok","disabled":false,"usage":{"fiveHour":{"pct":1},"sevenDay":{"pct":1}},"usageAgeSeconds":5}]}' > "$T/c-noactive.json"
  render $mode 40 50 idle "$T/c-noactive.json"
  expect_rate $mode "no active account: stdin numbers" "40%/50%"

  cswap_json 10 20 30 "$R5_FUT" relogin_required > "$T/c-relogin.json"
  render $mode 40 50 idle "$T/c-relogin.json"
  expect_rate $mode "active needs relogin: stdin numbers" "40%/50%"

  render $mode 40 50 none "$T/c-fresh.json"
  expect_rate $mode "no stamps counts as idle" "10%/20%"

  # ---- #20: active account can't be fetched, cswap's lastGoodUsage is its own last numbers ----
  lg_raw() { printf '%s' "$RAW" | sed -n 2p | sed 's/\x1b\[38;2;190;136;116m.*//'; }
  cat > "$T/c-lg.json" <<EOF
{"accounts":[
 {"number":1,"active":true,"usageStatus":"token_expired","disabled":false,"usage":null,"lastGoodUsage":{"fiveHour":{"pct":12,"resetsAt":"$R5_FUT"},"sevenDay":{"pct":34,"resetsAt":"$R7_FUT"}},"lastGoodAgeSeconds":400},
 {"number":2,"active":false,"usageStatus":"ok","disabled":false,"usage":{"fiveHour":{"pct":40,"resetsAt":"$R5_FUT"},"sevenDay":{"pct":50,"resetsAt":"$R7_FUT"}},"usageAgeSeconds":30}
]}
EOF
  render $mode 40 50 idle "$T/c-lg.json"
  expect_rate $mode "lastGoodUsage: its numbers, not stdin's" "12%/34%"
  printf '%s' "$TXT" | sed -n 2p | grep -q '(6m 40s ago)' && check $mode "lastGoodUsage: age shown" 1 || check $mode "lastGoodUsage: age shown" 0 "$(printf '%s' "$TXT" | sed -n 2p)"
  [ "$(lg_raw | grep -oP '\x1b\[2;[0-9;]*m' | wc -l)" -ge 2 ] && check $mode "lastGoodUsage: numbers dim" 1 || check $mode "lastGoodUsage: numbers dim" 0 "$(lg_raw | cat -v)"

  sed 's/"usageAgeSeconds":30/"usageAgeSeconds":30/; s/"lastGoodAgeSeconds":400/"lastGoodAgeSeconds":20/' "$T/c-lg.json" > "$T/c-lg-young.json"
  render $mode 40 50 idle "$T/c-lg-young.json"
  printf '%s' "$TXT" | sed -n 2p | grep -q '(20s ago)' && check $mode "lastGoodUsage: even a young one is dim with its age" 1 || check $mode "lastGoodUsage: even a young one is dim with its age" 0 "$(printf '%s' "$TXT" | sed -n 2p)"

  render $mode 41 51 running "$T/c-lg.json"
  expect_rate $mode "lastGoodUsage: mid-turn still uses stdin" "41%/51%"
  { ! printf '%s' "$TXT" | grep -q ' ago)'; } && check $mode "lastGoodUsage: mid-turn no age" 1 || check $mode "lastGoodUsage: mid-turn no age" 0 "ago present"

  sed "s/\"fiveHour\":{\"pct\":12,\"resetsAt\":\"$R5_FUT\"}/\"fiveHour\":{\"pct\":80,\"resetsAt\":\"$R5_PAST\"}/" "$T/c-lg.json" > "$T/c-lg-past.json"
  render $mode 40 50 idle "$T/c-lg-past.json"
  expect_rate $mode "lastGoodUsage: rolled-over window shows 0%" "0%/34%"

  # no lastGoodUsage at all: the old fallback (dim stdin, no age) stays
  echo '{"accounts":[{"number":1,"active":true,"usageStatus":"token_expired","disabled":false,"usage":null}]}' > "$T/c-lg-none.json"
  render $mode 40 50 idle "$T/c-lg-none.json"
  expect_rate $mode "no lastGoodUsage: stdin numbers" "40%/50%"
  { ! printf '%s' "$TXT" | grep -q ' ago)'; } && check $mode "no lastGoodUsage: no age" 1 || check $mode "no lastGoodUsage: no age" 0 "ago present"

  # a stale cache must not change anything and must stay untouched
  printf '99\n1893000000\n99\n1893000000\n' > "$CACHE"; before="$(cat "$CACHE")"; mt="$(stat -c %Y "$CACHE")"
  KEEP_CACHE=1 render $mode 40 50 idle "$T/c-fresh.json"
  expect_rate $mode "poisoned cache is ignored" "10%/20%"
  KEEP_CACHE=1 render $mode 41 51 running "$T/c-fresh.json"
  [ "$(cat "$CACHE")" = "$before" ] && [ "$(stat -c %Y "$CACHE")" = "$mt" ] && check $mode "poisoned cache left untouched" 1 || check $mode "poisoned cache left untouched" 0 "cache changed"
  rm -f "$CACHE"

  # everything exhausted -> pause segment still shown
  cat > "$T/c-exh.json" <<EOF
{"accounts":[
 {"number":1,"active":true,"usageStatus":"ok","disabled":false,"usage":{"fiveHour":{"pct":97,"resetsAt":"$R5_FUT"},"sevenDay":{"pct":10,"resetsAt":"$R7_FUT"}},"usageAgeSeconds":30},
 {"number":2,"active":false,"usageStatus":"ok","disabled":false,"usage":{"fiveHour":{"pct":98,"resetsAt":"$R5_FUT"},"sevenDay":{"pct":10,"resetsAt":"$R7_FUT"}},"usageAgeSeconds":30}
]}
EOF
  render $mode 40 50 idle "$T/c-exh.json"
  case "$TXT" in *"Paused, resuming in"*) check $mode "pause segment still shown" 1 ;; *) check $mode "pause segment still shown" 0 "missing" ;; esac

  # spinner behaviour is unchanged by the shared stamp loader
  render $mode 40 50 idle "$T/c-fresh.json"
  case "$TXT" in *"🧊"*) check $mode "idle turn still shows the elapsed/idle segment" 1 ;; *) check $mode "idle turn still shows the elapsed/idle segment" 0 "no idle glyph" ;; esac
  render $mode 40 50 running "$T/c-fresh.json"
  case "$TXT" in *"🧊"*) check $mode "running turn shows spinner, not idle segment" 0 "idle glyph present" ;; *) printf '%s' "$TXT" | sed -n 1p | grep -qE '[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]' && check $mode "running turn shows spinner, not idle segment" 1 || check $mode "running turn shows spinner, not idle segment" 0 "no spinner glyph" ;; esac

  # ---- Task 3 rows (age and stale look) ----
  if [ -n "${STAGE3:-}" ]; then
    DIM='\x1b\[[0-9;]*\b2;'
    # the rate segment only: line 2 up to the account label's colour (the token counter after it is always dim)
    rate_raw() { printf '%s' "$RAW" | sed -n 2p | sed 's/\x1b\[38;2;190;136;116m.*//'; }
    stale_cj() { cswap_json "${2:-10}" 20 "$1" > "$T/c-age.json"; }

    stale_cj 180; render $mode 40 50 idle "$T/c-age.json"
    expect_rate $mode "age 180: numbers" "10%/20%"
    { ! printf '%s' "$TXT" | grep -q ' ago)' && ! rate_raw | grep -qP '\x1b\[2;'; } && check $mode "age 180: not stale" 1 || check $mode "age 180: not stale" 0 "ago or dim present"

    stale_cj 181; render $mode 40 50 idle "$T/c-age.json"
    expect_rate $mode "age 181: numbers" "10%/20%"
    printf '%s' "$TXT" | sed -n 2p | grep -q '(3m 1s ago)' && check $mode "age 181: suffix" 1 || check $mode "age 181: suffix" 0 "$(printf '%s' "$TXT" | sed -n 2p)"
    [ "$(rate_raw | grep -oP '\x1b\[2;[0-9;]*m' | wc -l)" -ge 2 ] && check $mode "age 181: both numbers dim" 1 || check $mode "age 181: both numbers dim" 0 "$(rate_raw | cat -v)"

    stale_cj 600; render $mode 40 50 idle "$T/c-age.json"
    printf '%s' "$TXT" | sed -n 2p | grep -q '(10m ago)' && check $mode "age 600: 10m" 1 || check $mode "age 600: 10m" 0 "$(printf '%s' "$TXT" | sed -n 2p)"
    stale_cj 7500; render $mode 40 50 idle "$T/c-age.json"
    printf '%s' "$TXT" | sed -n 2p | grep -q '(2h 5m ago)' && check $mode "age 7500: 2h 5m" 1 || check $mode "age 7500: 2h 5m" 0 "$(printf '%s' "$TXT" | sed -n 2p)"

    stale_cj 181 90; render $mode 40 50 idle "$T/c-age.json"
    rate_raw | grep -qP '\x1b\[2;38;2;224;104;104m90' && check $mode "stale red: dim red, no bold" 1 || check $mode "stale red: dim red, no bold" 0 "$(rate_raw | cat -v)"
    rate_raw | grep -qP '\x1b\[1;38;2;224;104;104mT-' && check $mode "stale red: T- suffix keeps bold" 1 || check $mode "stale red: T- suffix keeps bold" 0 "$(rate_raw | cat -v)"

    render $mode 41 51 running "$T/c-age.json"
    { ! printf '%s' "$TXT" | grep -q ' ago)' && ! rate_raw | grep -qP '\x1b\[2;'; } && check $mode "mid-turn: never dim, no age" 1 || check $mode "mid-turn: never dim, no age" 0 "$(rate_raw | cat -v)"

    render $mode 40 50 idle "$T/c-fresh.json" 1
    { ! printf '%s' "$TXT" | grep -q ' ago)' && [ "$(rate_raw | grep -oP '\x1b\[2;[0-9;]*m' | wc -l)" -ge 2 ]; } && check $mode "fallback: dim, no age" 1 || check $mode "fallback: dim, no age" 0 "$(rate_raw | cat -v)"
  fi

  # ---- #18: the statusline writes a per-account usage hint mid-turn ----
  E5=$((NOW+7200)); E7=$((NOW+259200)); HE="hwaptest-sl@example.invalid"; HF="$HD/usage-$HE-personal"
  hts() { date -u -d "@$1" +%FT%T.500000+00:00; }
  # hjson <p5> <r5> <p7> <r7> [status] [email]: account 1 active, account 2 (usable) other
  hjson() {
    cat <<EOF2
{"accounts":[
 {"number":1,"email":"${6:-$HE}","organizationUuid":"","active":true,"usageStatus":"${5:-ok}","disabled":false,"usage":{"fiveHour":{"pct":$1,"resetsAt":"$(hts $2)"},"sevenDay":{"pct":$3,"resetsAt":"$(hts $4)"}},"usageAgeSeconds":30,"lastGoodUsage":{"fiveHour":{"pct":$1,"resetsAt":"$(hts $2)"},"sevenDay":{"pct":$3,"resetsAt":"$(hts $4)"}},"lastGoodAgeSeconds":30},
 {"number":2,"email":"hwaptest-other@example.invalid","organizationUuid":"","active":false,"usageStatus":"ok","disabled":false,"usage":{"fiveHour":{"pct":0,"resetsAt":"$(hts $2)"},"sevenDay":{"pct":0,"resetsAt":"$(hts $4)"}},"usageAgeSeconds":30}
]}
EOF2
  }
  hhelper() { # json-file -> default helper answer, as the hook asks it
    local p; if [ "$mode" = jq ]; then p="$T/stub:$PATH"; else p="$T/stub:$T/nojqbin"; fi
    HWAP_HINT_DIR="$HD" STUB_JSON="$1" PATH="$p" "$BASH_BIN" "$T/deploy/hwap-helper.sh"
  }
  hcheck() { [ "$2" = 1 ] && check $mode "$1" 1 || check $mode "$1" 0 "$3"; }
  hjson 95 $E5 10 $E7 > "$T/h-ok.json"

  rm -rf "$HD"
  render $mode 41 51 running "$T/h-ok.json"
  hcheck "hint: dir missing is created, both windows written" "$([ "$(cat "$HF" 2>/dev/null)" = "41 $E5 51 $E7" ] && echo 1)" "'$(cat "$HF" 2>&1)'"
  hcheck "hint: one cswap call per render" "$([ "$CALLS" = 1 ] && echo 1)" "calls=$CALLS"
  hcheck "hint: line still renders" "$([ "$RATE" = "41%/51%" ] && echo 1)" "rate '$RATE'"

  mkdir -p "$HD"; printf '9 5 8 %s\n' "$E7" > "$HF"
  S_R7=$((E7+100)) render $mode 41 51 running "$T/h-ok.json"
  hcheck "hint: only 5h matches, 7d pair kept" "$([ "$(cat "$HF")" = "41 $E5 8 $E7" ] && echo 1)" "'$(cat "$HF")'"

  mkdir -p "$HD"; printf '9 5 8 %s\n' "$E7" > "$HF"; touch -d '2020-01-01' "$HF"; b="$(cat "$HF")"
  S_R5=$((E5+100)) S_R7=$((E7+100)) render $mode 41 51 running "$T/h-ok.json"
  hcheck "hint: neither matches, file untouched" "$([ "$(cat "$HF")" = "$b" ] && [ "$(stat -c %Y "$HF")" = "$(date -d 2020-01-01 +%s)" ] && echo 1)" "'$(cat "$HF")' $(stat -c %y "$HF")"

  # temporary observation: how far Claude Code's reset is from cswap's, on screen and in a log
  LOG="$HD/hint-log-$HE-personal"
  rm -rf "$HD"
  render $mode 41 51 running "$T/h-ok.json"
  hcheck "obs: both windows 0s shown" "$(case "$TXT" in *"Δ5h:0s Δ7d:0s"*) echo 1;; esac)" "$(printf '%s' "$TXT" | sed -n 2p)"
  hcheck "obs: log line has raw values and decision" "$(tail -n1 "$LOG" 2>/dev/null | grep -q "stdin5=$E5 cswap5=$E5 diff5=0 m5=1 stdin7=$E7 cswap7=$E7 diff7=0 m7=1" && echo 1)" "'$(tail -n1 "$LOG" 2>&1)'"
  S_R5=$((E5+1)) render $mode 41 51 running "$T/h-ok.json"
  hcheck "obs: +1s shown, still a match" "$(case "$TXT" in *"Δ5h:+1s Δ7d:0s"*) echo 1;; esac)" "$(printf '%s' "$TXT" | sed -n 2p)"
  S_R5=$((E5-2)) S_R7=$((E7+100)) render $mode 41 51 running "$T/h-ok.json"
  hcheck "obs: mismatch flagged" "$(case "$TXT" in *"Δ5h:-2s Δ7d:+100s✗"*) echo 1;; esac)" "$(printf '%s' "$TXT" | sed -n 2p)"
  hcheck "obs: log records the mismatch" "$(tail -n1 "$LOG" | grep -q 'diff7=100 m7=0' && echo 1)" "'$(tail -n1 "$LOG")'"
  for i in $(seq 1 22); do render $mode 41 51 running "$T/h-ok.json"; done
  hcheck "obs: log capped at 20 lines" "$([ "$(wc -l < "$LOG")" = 20 ] && echo 1)" "lines=$(wc -l < "$LOG")"
  rm -rf "$HD"
  render $mode 41 51 idle "$T/h-ok.json"
  hcheck "obs: idle shows nothing and logs nothing" "$(case "$TXT" in *"Δ5h"*) ;; *) [ ! -e "$LOG" ] && echo 1;; esac)" "txt/log present"
  render $mode 41 51 running "$T/h-noemail.json"
  hcheck "obs: account without key shows nothing" "$(case "$TXT" in *"Δ5h"*) ;; *) echo 1;; esac)" "shown"

  # another session of the same account, older reading: same window keeps the higher pct
  mkdir -p "$HD"; printf '98 %s 99 %s\n' "$E5" "$E7" > "$HF"
  render $mode 96 50 running "$T/h-ok.json"
  hcheck "hint: same window, lower stdin does not lower the hint" "$([ "$(cat "$HF")" = "98 $E5 99 $E7" ] && echo 1)" "'$(cat "$HF")'"
  render $mode 99.5 100 running "$T/h-ok.json"
  hcheck "hint: same window, higher stdin raises the hint" "$([ "$(cat "$HF")" = "99.5 $E5 100 $E7" ] && echo 1)" "'$(cat "$HF")'"
  printf '98 %s 99 %s\n' "$((E5-9000))" "$((E7-9000))" > "$HF"
  render $mode 3 4 running "$T/h-ok.json"
  hcheck "hint: new window (different reset) replaces a higher old pct" "$([ "$(cat "$HF")" = "3 $E5 4 $E7" ] && echo 1)" "'$(cat "$HF")'"

  mkdir -p "$HD"; echo garbage > "$HF"
  S_R7=$((E7+100)) render $mode 41 51 running "$T/h-ok.json"
  hcheck "hint: corrupt file counts as 0 0 0 0 when half-matched" "$([ "$(cat "$HF")" = "41 $E5 0 0" ] && echo 1)" "'$(cat "$HF")'"

  rm -rf "$HD"
  render $mode 41 51 idle "$T/h-ok.json"
  hcheck "hint: idle writes nothing" "$([ ! -e "$HF" ] && echo 1)" "written"
  render $mode 41 51 none "$T/h-ok.json"
  hcheck "hint: no stamps writes nothing" "$([ ! -e "$HF" ] && echo 1)" "written"
  hjson 95 $E5 10 $E7 relogin_required > "$T/h-lg.json"
  render $mode 41 51 running "$T/h-lg.json"
  hcheck "hint: lastgood line writes nothing" "$([ ! -e "$HF" ] && echo 1)" "written"
  echo '{"accounts":[{"number":1,"active":true,"usageStatus":"ok","disabled":false,"usage":{"fiveHour":{"pct":5,"resetsAt":"'"$(hts $E5)"'"},"sevenDay":{"pct":5,"resetsAt":"'"$(hts $E7)"'"}},"usageAgeSeconds":3}]}' > "$T/h-noemail.json"
  render $mode 41 51 running "$T/h-noemail.json"
  hcheck "hint: account without email writes nothing" "$([ -z "$(ls "$HD" 2>/dev/null)" ] && echo 1)" "$(ls "$HD" 2>&1)"
  NO_RL=1 render $mode 41 51 running "$T/h-ok.json"
  hcheck "hint: no rate_limits on stdin writes nothing, still renders" "$([ ! -e "$HF" ] && [ -n "$TXT" ] && echo 1)" "txt='$TXT'"

  : > "$T/afile"
  HINT_DIR_OVERRIDE="$T/afile/sub" render $mode 41 51 running "$T/h-ok.json"
  hcheck "hint: unwritable directory, statusline still renders" "$([ "$RATE" = "41%/51%" ] && echo 1)" "rate '$RATE' txt='$TXT'"

  # end to end: what the statusline wrote lifts the hook's answer
  rm -rf "$HD"
  hcheck "e2e: without hint cswap's 95 is ok" "$([ "$(hhelper "$T/h-ok.json")" = ok ] && echo 1)" "$(hhelper "$T/h-ok.json")"
  render $mode 98 10 running "$T/h-ok.json"
  hcheck "e2e: with the written hint the helper says switch 2" "$([ "$(hhelper "$T/h-ok.json")" = "switch 2" ] && echo 1)" "$(hhelper "$T/h-ok.json")"
  # A's stdin (reset E5) while cswap's active is B (reset differs by 100 s): nothing written, B's answer unchanged
  rm -rf "$HD"
  hjson 95 $((E5+100)) 10 $((E7+100)) ok hwaptest-b@example.invalid > "$T/h-b.json"
  render $mode 98 10 running "$T/h-b.json"
  hcheck "e2e: stdin of the previous account is not written for B" "$([ -z "$(ls "$HD" 2>/dev/null | grep '^usage-')" ] && [ "$(hhelper "$T/h-b.json")" = ok ] && echo 1)" "files='$(ls "$HD" 2>&1)'"
done
exit $fail
