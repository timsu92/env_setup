#!/usr/bin/env bash
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
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
statusline="$script_dir/ansible/roles/claude_code/files/statusline.sh"

# Isolated fake account identity so __account_segment never touches the real
# developer's ~/.claude.json. XDG_DATA_HOME is also isolated so no real cswap
# sequence.json leaks an alias into the output.
fixture_home="$(mktemp -d)"
trap 'rm -rf "$fixture_home" "$ISO"' EXIT
test_email="statusline-test@example.invalid"
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$test_email" > "$fixture_home/.claude.json"

run_statusline() {
  # $1: five_hour used_percentage, $2: seven_day used_percentage
  # $3: five_hour resets_at (unix ts, default: a fixed "current window"),
  # $4: seven_day resets_at (unix ts, default: a fixed "current window")
  local five_pct="$1" seven_pct="$2" five_resets="${3:-1000000000}" seven_resets="${4:-2000000000}"
  local fixture
  fixture="$(printf '{"model":{"display_name":"test"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}},"context_window":{"total_input_tokens":1000,"context_window_size":10000,"used_percentage":10}}' \
    "$five_pct" "$five_resets" "$seven_pct" "$seven_resets")"
  CLAUDE_CONFIG_DIR="$fixture_home" XDG_DATA_HOME="$fixture_home" STATUSLINE_COLS=80 \
    bash "$statusline" <<< "$fixture" | sed 's/\x1b\[[0-9;]*m//g'
}

plain_output="$(run_statusline 12.9 34.8)"

if ! printf '%s' "$plain_output" | grep -Fq '12%/34%'; then
  printf 'expected truncated pct output, got: %s\n' "$plain_output" >&2
  exit 1
fi

case "$plain_output" in
  *'12.9%'*|*'34.8%'*) printf 'pct output still contains decimals: %s\n' "$plain_output" >&2; exit 1 ;;
esac
