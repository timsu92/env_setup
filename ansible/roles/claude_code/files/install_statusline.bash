#!/usr/bin/env bash
# Claude statusline renderer installer.
# Modify the fields after the "Edit fields below" line.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p "$CLAUDE_DIR"
SL="$CLAUDE_DIR/statusline.sh"

__banner() {
  local color="$1"
  local msg="$2"
  printf '\n\033[%sm' "$color"
  cat <<'BANNER_EOF'
      _        _             _ _                  _
  ___| |_ __ _| |_ _   _ ___| (_)_ __   ___   ___| |__
 / __| __/ _` | __| | | / __| | | '_ \ / _ \ / __| '_ \
 \__ \ || (_| | |_| |_| \__ \ | | | | |  __/_\__ \ | | |
 |___/\__\__,_|\__|\__,_|___/_|_|_| |_|\___(_)___/_| |_|
BANNER_EOF
  printf '\033[0m\n\033[%sm  %s\033[0m\n\n' "$color" "$msg"
}

cat > "$SL" <<'STATUSLINE_EOF'
#!/usr/bin/env bash
set -u
INPUT="$(cat)"
export INPUT_JSON="$INPUT"

# Terminal width for flex-spacer math. Honors STATUSLINE_COLS env override
# (used by parity tests); otherwise tries tput, finally falls back to 80.
STATUSLINE_COLS=${STATUSLINE_COLS:-$(tput cols 2>/dev/null || echo 80)}

# Visible-character length: strip CSI SGR sequences then count chars.
# Wide glyphs (emoji, CJK) count as 1 column — same simplification as the
# interpret backend uses.
__visible_len() {
  printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g' | awk '{ printf "%s", length($0) }'
}

__repeat_char() {
  local ch="$1" n="$2" out=""
  if [ "$n" -le 0 ]; then printf ''; return; fi
  local i=0
  while [ "$i" -lt "$n" ]; do out+="$ch"; i=$((i+1)); done
  printf '%s' "$out"
}

__sgr() { printf '\033[%sm' "$1"; }
__reset() { printf '\033[0m'; }

if command -v jq >/dev/null 2>&1; then
  __field() {
    printf '%s' "$INPUT_JSON" | jq -r --arg p "$1" '
      ($p | split(".")) as $parts
      | reduce $parts[] as $k (.; if type == "object" and has($k) then .[$k] else null end)
      | if . == null then "" else (if type == "string" then . else tostring end) end
    ' 2>/dev/null
  }
else
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys' >/dev/null 2>&1; then
    __PY=python3
  elif command -v python >/dev/null 2>&1; then
    __PY=python
  else
    __PY=""
  fi
  __field() {
    if [ -z "$__PY" ]; then printf ''; return; fi
    PATH_ARG="$1" "$__PY" - <<'PYEOF' 2>/dev/null
import json, os
d = json.loads(os.environ.get('INPUT_JSON','{}') or '{}')
p = os.environ.get('PATH_ARG','')
cur = d
for part in p.split('.'):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        cur = None
        break
if cur is None:
    print('', end='')
elif isinstance(cur, bool):
    print('true' if cur else 'false', end='')
else:
    print(cur, end='')
PYEOF
  }
fi

__basename() { local s="$1"; printf '%s' "${s##*/}"; }
__compact() {
  local s="$1"
  if [ -z "$s" ]; then printf ''; return; fi
  # Use awk so we don't depend on bash arrays. Split on '/', take the first
  # char of every segment except the last; preserve a leading slash by
  # emitting an empty initial element when the path starts with '/'.
  printf '%s' "$s" | awk 'BEGIN{FS="/"} {
    out=""
    for (i=1; i<=NF; i++) {
      if (i==NF) { piece = $i }
      else if ($i == "") { piece = "" }
      else { piece = substr($i, 1, 1) }
      if (i==1) { out = piece } else { out = out "/" piece }
    }
    printf "%s", out
  }'
}
__tildify() {
  local s="$1"
  local home="${HOME%/}"
  if [ -n "$home" ] && [[ "$s" == "$home"* ]]; then
    printf '~%s' "${s#$home}"
    return
  fi
  if [[ "$s" =~ ^/(Users|home)/[^/]+(.*)$ ]]; then
    printf '~%s' "${BASH_REMATCH[2]}"
    return
  fi
  printf '%s' "$s"
}
__truncate() {
  local s="$1" n="$2"
  if [ "$n" -le 0 ] || [ "${#s}" -le "$n" ]; then printf '%s' "$s"; return; fi
  if [ "$n" -le 1 ]; then printf '%s' "${s:0:$n}"; return; fi
  printf '%s…' "${s:0:$((n-1))}"
}
__cost_fmt() { printf '$%.*f' "$2" "$1"; }
__dur_hms() {
  local ms="$1" total h m s
  total=$((ms/1000)); h=$((total/3600)); m=$(((total%3600)/60)); s=$((total%60))
  if [ "$h" -gt 0 ]; then printf '%d:%02d:%02d' "$h" "$m" "$s"
  else printf '%d:%02d' "$m" "$s"; fi
}
__dur_human() {
  local ms="$1" total m s h mm
  total=$((ms/1000))
  if [ "$total" -lt 60 ]; then printf '%ds' "$total"; return; fi
  m=$((total/60)); s=$((total%60))
  if [ "$m" -lt 60 ]; then
    if [ "$s" -gt 0 ]; then printf '%dm %ds' "$m" "$s"; else printf '%dm' "$m"; fi
    return
  fi
  h=$((m/60)); mm=$((m%60))
  if [ "$mm" -gt 0 ]; then printf '%dh %dm' "$h" "$mm"; else printf '%dh' "$h"; fi
}
__bar() {
  local pct="$1" width="$2" filled="$3" empty="$4"
  local p i n=0 e=0
  p=${pct%.*}
  [ -z "$p" ] && p=0
  if [ "$p" -lt 0 ]; then p=0; fi
  if [ "$p" -gt 100 ]; then p=100; fi
  n=$(( (p * width + 50) / 100 ))
  e=$((width - n))
  local out=""
  for ((i=0; i<n; i++)); do out+="$filled"; done
  for ((i=0; i<e; i++)); do out+="$empty"; done
  printf '%s' "$out"
}
__git_branch() {
  local cwd dir
  cwd="$(__field workspace.current_dir)"
  if [ -z "$cwd" ]; then cwd="$(__field cwd)"; fi
  if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
    git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null
  else
    __field workspace.git_worktree
  fi
}
__git_dirty() {
  local cwd
  cwd="$(__field workspace.current_dir)"
  if [ -z "$cwd" ]; then cwd="$(__field cwd)"; fi
  if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
    if [ -n "$(git -C "$cwd" status --porcelain 2>/dev/null)" ]; then printf '1'; else printf '0'; fi
  else
    printf '0'
  fi
}
__git_toplevel() {
  local cwd="$1"
  command -v git >/dev/null 2>&1 || return 1
  git -C "$cwd" rev-parse --show-toplevel 2>/dev/null
}
__git_common_root() {
  # Main repository's root (the directory containing the real .git folder),
  # no matter $1 sits in the main worktree or a linked worktree.
  local cwd="$1" gcd
  command -v git >/dev/null 2>&1 || return 1
  gcd="$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$gcd" in
    /*) : ;;
    *) gcd="$cwd/$gcd" ;;
  esac
  gcd="$(cd "$gcd" 2>/dev/null && pwd -P)" || return 1
  printf '%s' "${gcd%/*}"
}
__repo_path_segment() {
  # "…/<repo>[/<subpath>]" when not in a linked worktree; just "…/<repo>"
  # when it is one (the worktree's own name/subpath goes in the segment
  # __worktree_segment emits instead).
  local cwd="$1" toplevel common_root
  toplevel="$(__git_toplevel "$cwd")" || return 1
  common_root="$(__git_common_root "$cwd")" || return 1
  if [ "$common_root" = "$toplevel" ]; then
    printf '…/%s%s' "$(__basename "$common_root")" "${cwd#"$toplevel"}"
  else
    printf '…/%s' "$(__basename "$common_root")"
  fi
}
__worktree_segment() {
  local cwd="$1" toplevel common_root
  toplevel="$(__git_toplevel "$cwd")" || { printf ''; return; }
  common_root="$(__git_common_root "$cwd")" || { printf ''; return; }
  if [ "$common_root" = "$toplevel" ]; then
    printf ''
    return
  fi
  printf '%s%s' "$(__basename "$toplevel")" "${cwd#"$toplevel"}"
}
__emit() {
  local style="$1" text="$2"
  if [ -n "$style" ]; then __sgr "$style"; fi
  printf '%s' "$text"
  if [ -n "$style" ]; then __reset; fi
}
__norm_int() {
  # Coerce a possibly-decimal/empty/garbage field value to a non-negative
  # integer string. Used by token-display helpers.
  local v="$1"
  v="${v%%.*}"
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}
__fmt_token_compact() {
  local n
  n="$(__norm_int "$1")"
  if [ "$n" -lt 1000 ]; then printf '%s' "$n"; return; fi
  if [ "$n" -lt 1000000 ]; then
    local whole=$((n / 1000))
    local rem=$((n - whole * 1000))
    local dec=$((rem / 100))
    if [ "$dec" -eq 0 ]; then printf '%dk' "$whole"; else printf '%d.%dk' "$whole" "$dec"; fi
    return
  fi
  local whole=$((n / 1000000))
  local rem=$((n - whole * 1000000))
  local dec=$((rem / 100000))
  if [ "$dec" -eq 0 ]; then printf '%dM' "$whole"; else printf '%d.%dM' "$whole" "$dec"; fi
}
__fmt_token_full() {
  local n
  n="$(__norm_int "$1")"
  printf '%s' "$n" | awk '{
    s=$0; out=""; n=length(s)
    while (n > 3) { out=","substr(s,n-2,3) out; n -= 3 }
    out=substr(s,1,n) out
    printf "%s", out
  }'
}
__tokens_used() { __field 'context_window.total_input_tokens'; }
__tokens_total() { __field 'context_window.context_window_size'; }
__tokens_remaining() {
  local u t
  u="$(__norm_int "$(__tokens_used)")"
  t="$(__norm_int "$(__tokens_total)")"
  local r=$((t - u))
  if [ "$r" -lt 0 ]; then r=0; fi
  printf '%d' "$r"
}
__tokens_pct_int() {
  local p="$(__field 'context_window.used_percentage')"
  __norm_int "$p"
}
__tick() {
  if [ -n "${STATUSLINE_CLOCK_OVERRIDE:-}" ]; then
    printf '%s' "$STATUSLINE_CLOCK_OVERRIDE"
  else
    date +%s
  fi
}
__rel_time() {
  local target="$1"
  if [ -z "$target" ]; then printf ''; return; fi
  case "$target" in
    ''|*[!0-9.-]*) printf ''; return ;;
  esac
  local t_int="${target%.*}"
  if [ -z "$t_int" ] || [ "$t_int" = "-" ]; then printf ''; return; fi
  local now diff h m s rem
  now=$(__tick)
  diff=$((t_int - now))
  if [ "$diff" -le 0 ]; then printf ''; return; fi
  if [ "$diff" -lt 60 ]; then printf 'T-%ds' "$diff"; return; fi
  if [ "$diff" -lt 3600 ]; then
    m=$((diff/60)); s=$((diff%60))
    printf 'T-%dm%02ds' "$m" "$s"; return
  fi
  h=$((diff/3600)); rem=$(((diff%3600)/60))
  printf 'T-%dh%02dm' "$h" "$rem"
}

# Edit fields below
if [ "$(__field 'fast_mode')" = 'true' ]; then
  __emit '' '⚡'
else
  __items=('😺' '😽' '😸' '😻' '🙀' '😼' '🐈' '😹' '😾' '🐱' '🐈‍⬛')
  __idx=$(( RANDOM % 11 ))
  __emit '' "${__items[$__idx]}"
fi
__repeat_char ' ' 1
__v="$(__field 'model.display_name')"
__emit '38;2;187;154;247' "$__v"
__repeat_char ' ' 1
if [ "$(__field 'thinking.enabled')" = 'true' ]; then
  __v="$(__field 'effort.level')"
  __emit '' "$__v"
fi
__repeat_char ' ' 1
__cwd="$(__field 'workspace.current_dir')"
__repo_seg="$(__repo_path_segment "$__cwd")"
if [ -n "$__repo_seg" ]; then
  __emit '38;2;97;214;214' '󰊢 '
  __emit '38;2;97;214;214' "$__repo_seg"
  __wt_seg="$(__worktree_segment "$__cwd")"
  if [ -n "$__wt_seg" ]; then
    __repeat_char ' ' 1
    __emit '38;2;97;214;214' ' '
    __emit '38;2;97;214;214' "$__wt_seg"
  fi
else
  __emit '38;2;97;214;214' '  '
  __v="$(__tildify "$__cwd")"
  __emit '38;2;97;214;214' "$__v"
fi
__repeat_char ' ' 1
__emit '38;2;172;43;153' ' '
__out="$(__git_branch)"
__emit '38;2;172;43;153' "$__out"
__repeat_char ' ' 1
if awk -v v="$(__field 'cost.total_duration_ms')" 'BEGIN{exit !(v+0 > 5000)}'; then
  __emit '' '  '
  __v="$(__field 'cost.total_duration_ms')"
  __out="$(__dur_human "${__v:-0}")"
  __emit '' "$__out"
fi
__reset
printf '\n'
__reset
five_hour_pct="$(__field 'rate_limits.five_hour.used_percentage')"
seven_day_pct="$(__field 'rate_limits.seven_day.used_percentage')"
if awk -v a="$five_hour_pct" -v b="$seven_day_pct" 'BEGIN{exit !(a+0 > 90 || b+0 > 90)}'; then
    __emit '38;2;224;104;104' ''
elif awk -v a="$five_hour_pct" -v b="$seven_day_pct" 'BEGIN{exit !(a+0 > 30 || b+0 > 30)}'; then
    __emit '38;2;224;175;104' ''
else
    __emit '38;2;158;206;106' ''
fi
__repeat_char ' ' 1
if awk -v v="$five_hour_pct" 'BEGIN{exit !(v+0 < 75)}'; then
  __emit '38;2;158;206;106' "$five_hour_pct"
  __emit '38;2;158;206;106' '%'
elif awk -v v="$five_hour_pct" 'BEGIN{exit !(v+0 < 85)}'; then
  __emit '4;38;2;224;175;104' "$five_hour_pct"
  __emit '4;38;2;224;175;104' '%'
else
  __emit '1;38;2;224;104;104' "$five_hour_pct"
  __emit '1;38;2;224;104;104' '%'
  __v="$(__field 'rate_limits.five_hour.resets_at')"
  __out="$(__rel_time "$__v")"
  __emit '1;38;2;224;104;104' "$__out"
fi
__emit '' '/'
if awk -v v="$seven_day_pct" 'BEGIN{exit !(v+0 < 75)}'; then
  __emit '38;2;158;206;106' "$seven_day_pct"
  __emit '38;2;158;206;106' '%'
elif awk -v v="$seven_day_pct" 'BEGIN{exit !(v+0 < 85)}'; then
  __emit '4;38;2;224;175;104' "$seven_day_pct"
  __emit '4;38;2;224;175;104' '%'
else
  __emit '1;38;2;224;104;104' "$seven_day_pct"
  __emit '1;38;2;224;104;104' '%'
  __v="$(__field 'rate_limits.seven_day.resets_at')"
  __out="$(__rel_time "$__v")"
  __emit '1;38;2;224;104;104' "$__out"
fi
__repeat_char ' ' 1
if awk -v v="$(__field 'cost.total_cost_usd')" 'BEGIN{exit !(v+0 > 0)}'; then
  __emit '1;3;38;2;51;51;47;48;2;231;231;42' ' '
  __v="$(__field 'cost.total_cost_usd')"
  __out="$(__cost_fmt "${__v:-0}" 2)"
  __emit '1;3;38;2;51;51;47;48;2;231;231;42' "$__out"
fi
__repeat_char ' ' 1
__emit '2;38;2;211;134;155' '  '
__u="$(__tokens_used)"
__t="$(__tokens_total)"
__p="$(__tokens_pct_int)"
__uf="$(__fmt_token_compact "$__u")"
__tf="$(__fmt_token_compact "$__t")"
__emit '2;38;2;211;134;155' "$__uf/$__tf ($__p%)"

exit 0

STATUSLINE_EOF
chmod +x "$SL"

SETTINGS="$CLAUDE_DIR/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"

__offer_self_heal() {
  local err_msg="$1"
  if [ "${STATUSLINE_SELFHEAL:-0}" = "1" ] && command -v claude >/dev/null 2>&1; then
    echo "STATUSLINE_SELFHEAL=1 — invoking 'claude' to repair settings.json" >&2
    local snippet prompt
    snippet="$(head -c 4096 "$SETTINGS" 2>/dev/null || printf '')"
    prompt="$(cat <<PROMPT_EOF
Fix my settings.json at $SETTINGS so it has a top-level statusLine={type:'command',command:'$SL'} while preserving every other key. Current contents:
\`\`\`
$snippet
\`\`\`
Error: $err_msg
PROMPT_EOF
)"
    claude -p "$prompt" || true
    return 0
  fi
  echo "" >&2
  echo "Could not merge settings.json automatically." >&2
  echo "Install 'jq' (brew install jq / apt-get install jq) or python3 and re-run." >&2
  echo "Or set STATUSLINE_SELFHEAL=1 and ensure 'claude' is on PATH to auto-repair." >&2
  echo "Your previous settings.json is backed up at $SETTINGS.bak.*" >&2
  return 1
}

__merge_with_jq() {
  local tmp
  tmp="$(mktemp)"
  jq --arg cmd "$SL" '. + { statusLine: { type:"command", command:$cmd } }' "$SETTINGS" > "$tmp"
  mv "$tmp" "$SETTINGS"
}

__merge_with_python() {
  local py="$1"
  STATUSLINE_PATH="$SL" SETTINGS_PATH="$SETTINGS" "$py" - <<'PYEOF'
import json, os, sys
p = os.environ['SETTINGS_PATH']
sl = os.environ['STATUSLINE_PATH']
try:
    with open(p, 'r', encoding='utf-8') as f:
        d = json.load(f)
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
d['statusLine'] = {'type': 'command', 'command': sl}
with open(p, 'w', encoding='utf-8') as f:
    json.dump(d, f, indent=2)
PYEOF
}

__merge_ok=0
if [ "$__merge_ok" = "0" ] && command -v jq >/dev/null 2>&1; then
  if __merge_with_jq 2>/dev/null; then __merge_ok=1; fi
fi
if [ "$__merge_ok" = "0" ] && command -v python3 >/dev/null 2>&1; then
  if __merge_with_python python3 2>/dev/null; then __merge_ok=1; fi
fi
if [ "$__merge_ok" = "0" ] && command -v python >/dev/null 2>&1; then
  if __merge_with_python python 2>/dev/null; then __merge_ok=1; fi
fi
if [ "$__merge_ok" = "0" ]; then
  if __offer_self_heal "all JSON merge backends failed (need jq or python)"; then
    __banner 33 "installed with errors — restart Claude Code to verify"
    exit 0
  fi
  __banner 31 "error: install failed"
  exit 1
fi

__banner 32 "installed successfully — restart Claude Code to see it"
exit 0
