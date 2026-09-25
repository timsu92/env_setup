#!/usr/bin/env bash
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
statusline="$script_dir/ansible/roles/claude_code/files/statusline.sh"

# Isolated fake account identity so __ratelimit_sync/__account_segment never
# touch the real developer's ~/.claude.json or real /tmp/claude-<uid>/ratelimit-*
# cache file. XDG_DATA_HOME is also isolated so no real cswap sequence.json
# leaks an alias into the output.
fixture_home="$(mktemp -d)"
trap 'rm -rf "$fixture_home"; rm -f "/tmp/claude-$(id -u)/ratelimit-$test_email"' EXIT
test_email="statusline-test@example.invalid"
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$test_email" > "$fixture_home/.claude.json"
rm -f "/tmp/claude-$(id -u)/ratelimit-$test_email"

run_statusline() {
  # $1: five_hour used_percentage, $2: seven_day used_percentage
  local fixture
  fixture="$(printf '{"model":{"display_name":"test"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":%s},"seven_day":{"used_percentage":%s}},"context_window":{"total_input_tokens":1000,"context_window_size":10000,"used_percentage":10}}' "$1" "$2")"
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

# --- Cross-session cache reconciliation (__ratelimit_sync) ---

cache_file="/tmp/claude-$(id -u)/ratelimit-$test_email"
rm -f "$cache_file"

# First call: nothing cached yet, this session's own numbers win and get
# written to the shared cache.
out1="$(run_statusline 80 60)"
if ! printf '%s' "$out1" | grep -Fq '80%/60%'; then
  printf 'expected 80%%/60%% on first call, got: %s\n' "$out1" >&2
  exit 1
fi
if [ "$(cat "$cache_file" 2>/dev/null)" != "$(printf '80\n60')" ]; then
  printf 'expected cache file to contain 80/60, got: %s\n' "$(cat "$cache_file" 2>/dev/null)" >&2
  exit 1
fi

# Second call: a "stale" session reports lower numbers on both fields (e.g.
# hasn't talked to Anthropic since before another session progressed
# further) — the cached (larger) values must win on display, and the cache
# file must NOT regress.
out2="$(run_statusline 10 10)"
if ! printf '%s' "$out2" | grep -Fq '80%/60%'; then
  printf 'expected stale call to still show cached 80%%/60%%, got: %s\n' "$out2" >&2
  exit 1
fi
if [ "$(cat "$cache_file" 2>/dev/null)" != "$(printf '80\n60')" ]; then
  printf 'expected cache file to remain 80/60 after a stale call, got: %s\n' "$(cat "$cache_file" 2>/dev/null)" >&2
  exit 1
fi

# Third call: five_hour resets (drops to 5, lower than cached 80) while
# seven_day keeps climbing (65, higher than cached 60) — the OR-rule must
# treat the whole new pair as fresher and adopt the reset five_hour value
# too, not keep the stale pre-reset 80%.
out3="$(run_statusline 5 65)"
if ! printf '%s' "$out3" | grep -Fq '5%/65%'; then
  printf 'expected reset call to show 5%%/65%%, got: %s\n' "$out3" >&2
  exit 1
fi
if [ "$(cat "$cache_file" 2>/dev/null)" != "$(printf '5\n65')" ]; then
  printf 'expected cache file to update to 5/65 after a reset, got: %s\n' "$(cat "$cache_file" 2>/dev/null)" >&2
  exit 1
fi

# Fourth call: the mirror case — seven_day resets (drops to 2, lower than
# cached 65) while five_hour keeps climbing (10, higher than cached 5).
out4="$(run_statusline 10 2)"
if ! printf '%s' "$out4" | grep -Fq '10%/2%'; then
  printf 'expected 7-day reset call to show 10%%/2%%, got: %s\n' "$out4" >&2
  exit 1
fi
if [ "$(cat "$cache_file" 2>/dev/null)" != "$(printf '10\n2')" ]; then
  printf 'expected cache file to update to 10/2 after a 7-day reset, got: %s\n' "$(cat "$cache_file" 2>/dev/null)" >&2
  exit 1
fi

# Decimals must take part in the comparison and be stored as-is: 30.5/20.5
# is older than a cached 30.9/20.9 even though both truncate to 30/20.
run_statusline 30.9 20.9 >/dev/null
out5="$(run_statusline 30.5 20.5)"
if ! printf '%s' "$out5" | grep -Fq '30%/20%'; then
  printf 'expected 30%%/20%% for the decimal case, got: %s\n' "$out5" >&2
  exit 1
fi
if [ "$(cat "$cache_file" 2>/dev/null)" != "$(printf '30.9\n20.9')" ]; then
  printf 'expected cache file to keep 30.9/20.9, got: %s\n' "$(cat "$cache_file" 2>/dev/null)" >&2
  exit 1
fi

# Missing/null fields (e.g. rate_limits absent) count as 0: the cache wins
# and is left untouched.
out6="$(run_statusline null null)"
if ! printf '%s' "$out6" | grep -Fq '30%/20%'; then
  printf 'expected null fields to fall back to cached 30%%/20%%, got: %s\n' "$out6" >&2
  exit 1
fi
if [ "$(cat "$cache_file" 2>/dev/null)" != "$(printf '30.9\n20.9')" ]; then
  printf 'expected cache file to stay 30.9/20.9 after null fields, got: %s\n' "$(cat "$cache_file" 2>/dev/null)" >&2
  exit 1
fi

rm -f "$cache_file"
