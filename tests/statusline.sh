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

# --- Cross-session cache reconciliation (__ratelimit_sync) ---
#
# Cache file is 4 lines: five_pct, five_resets_at, seven_pct, seven_resets_at.
# resets_at is the window's identity (a unix timestamp): fixed within a
# window, only moves forward on a real reset. Reconciliation compares it
# first per field, falling back to pct only when resets_at ties (same
# window) — see __ratelimit_pick_field in statusline.sh for why plain pct
# comparison alone is unsafe across sessions (an idle session's frozen
# reading can tie and drag a more-advanced field backward).

cache_file="/tmp/claude-$(id -u)/ratelimit-$test_email"
rm -f "$cache_file"

# First call: nothing cached yet, this session's own numbers win and get
# written to the shared cache, along with the resets_at that identifies the
# current window for each field.
out1="$(run_statusline 80 60 1000 2000)"
if ! printf '%s' "$out1" | grep -Fq '80%/60%'; then
  printf 'expected 80%%/60%% on first call, got: %s\n' "$out1" >&2
  exit 1
fi
if [ "$(cat "$cache_file" 2>/dev/null)" != "$(printf '80\n1000\n60\n2000')" ]; then
  printf 'expected cache file to contain 80/1000/60/2000, got: %s\n' "$(cat "$cache_file" 2>/dev/null)" >&2
  exit 1
fi

# Second call: a session that hasn't progressed reports the exact same
# frozen pair with the SAME resets_at (same window) but a lower pct than
# what's now cached — this is the idle-session case that used to (with
# plain OR-on-pct comparison) tie and drag the cache backward. Within the
# same window, the larger pct must win and the cache must NOT regress.
out2="$(run_statusline 10 10 1000 2000)"
if ! printf '%s' "$out2" | grep -Fq '80%/60%'; then
  printf 'expected stale-same-window call to still show cached 80%%/60%%, got: %s\n' "$out2" >&2
  exit 1
fi
if [ "$(cat "$cache_file" 2>/dev/null)" != "$(printf '80\n1000\n60\n2000')" ]; then
  printf 'expected cache file to remain 80/1000/60/2000 after a stale same-window call, got: %s\n' "$(cat "$cache_file" 2>/dev/null)" >&2
  exit 1
fi

# Third call: five_hour's window actually rolls over (resets_at advances to
# 1500, pct drops to 5) while seven_day keeps climbing within its still-open
# window (pct 65, same resets_at 2000). Each field is judged on its own
# resets_at: five_hour must adopt the reset (lower pct, newer window)
# without seven_day being affected at all.
out3="$(run_statusline 5 65 1500 2000)"
if ! printf '%s' "$out3" | grep -Fq '5%/65%'; then
  printf 'expected reset call to show 5%%/65%%, got: %s\n' "$out3" >&2
  exit 1
fi
if [ "$(cat "$cache_file" 2>/dev/null)" != "$(printf '5\n1500\n65\n2000')" ]; then
  printf 'expected cache file to update to 5/1500/65/2000 after a reset, got: %s\n' "$(cat "$cache_file" 2>/dev/null)" >&2
  exit 1
fi

# Fourth call: the mirror case — seven_day's window rolls over (resets_at
# advances to 2500, pct drops to 2) while five_hour keeps climbing within
# its still-open window (pct 10, same resets_at 1500).
out4="$(run_statusline 10 2 1500 2500)"
if ! printf '%s' "$out4" | grep -Fq '10%/2%'; then
  printf 'expected 7-day reset call to show 10%%/2%%, got: %s\n' "$out4" >&2
  exit 1
fi
if [ "$(cat "$cache_file" 2>/dev/null)" != "$(printf '10\n1500\n2\n2500')" ]; then
  printf 'expected cache file to update to 10/1500/2/2500 after a 7-day reset, got: %s\n' "$(cat "$cache_file" 2>/dev/null)" >&2
  exit 1
fi

# Decimals must take part in the same-window pct tie-break and be stored
# as-is: 30.5/20.5 is older than a cached 30.9/20.9 even though both
# truncate to 30/20, when both are in the same window (same resets_at).
run_statusline 30.9 20.9 1500 2500 >/dev/null
out5="$(run_statusline 30.5 20.5 1500 2500)"
if ! printf '%s' "$out5" | grep -Fq '30%/20%'; then
  printf 'expected 30%%/20%% for the decimal case, got: %s\n' "$out5" >&2
  exit 1
fi
if [ "$(cat "$cache_file" 2>/dev/null)" != "$(printf '30.9\n1500\n20.9\n2500')" ]; then
  printf 'expected cache file to keep 30.9/1500/20.9/2500, got: %s\n' "$(cat "$cache_file" 2>/dev/null)" >&2
  exit 1
fi

# Missing/null fields (e.g. rate_limits absent) count as pct 0 / resets_at 0:
# resets_at 0 is older than any real cached window, so the cache wins on
# both fields and is left untouched.
out6="$(run_statusline null null null null)"
if ! printf '%s' "$out6" | grep -Fq '30%/20%'; then
  printf 'expected null fields to fall back to cached 30%%/20%%, got: %s\n' "$out6" >&2
  exit 1
fi
if [ "$(cat "$cache_file" 2>/dev/null)" != "$(printf '30.9\n1500\n20.9\n2500')" ]; then
  printf 'expected cache file to stay 30.9/1500/20.9/2500 after null fields, got: %s\n' "$(cat "$cache_file" 2>/dev/null)" >&2
  exit 1
fi

rm -f "$cache_file"

printf 'ALL TESTS PASSED\n'
