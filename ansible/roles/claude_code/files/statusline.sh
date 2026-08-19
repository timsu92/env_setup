#!/usr/bin/env bash
set -u

# A rate-limit window at or above this percentage counts as "exhausted"
# when deciding whether a cswap-managed account is usable.
RATE_LIMIT_GATE_PCT=97

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
    printf '~%s' "${s#"$home"}"
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
  local cwd
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
  # "…/<repo>/<subpath>" where <subpath> is cwd relative to whichever
  # worktree (main or linked) cwd actually sits in — this always reflects
  # your real position in the working tree, regardless of which worktree
  # that is. Which worktree it is gets its own tag from __worktree_segment.
  local cwd="$1" toplevel common_root
  toplevel="$(__git_toplevel "$cwd")" || return 1
  common_root="$(__git_common_root "$cwd")" || return 1
  printf '…/%s%s' "$(__basename "$common_root")" "${cwd#"$toplevel"}"
}
__worktree_segment() {
  # Just a name tag for which linked worktree cwd is in (empty when cwd is
  # in the main worktree) — no subpath here, __repo_path_segment already
  # carries that. Whether to show this tag at all is decided by our own
  # common_root/toplevel check (ground truth from git) — Claude Code's
  # "workspace.git_worktree" field isn't reliable for that decision (it can
  # be non-empty even when cwd is in the main worktree, not a linked one).
  # Once we've confirmed we ARE in a linked worktree, prefer that field for
  # the display NAME, falling back to our own basename computation.
  local cwd="$1" native toplevel common_root
  toplevel="$(__git_toplevel "$cwd")" || { printf ''; return; }
  common_root="$(__git_common_root "$cwd")" || { printf ''; return; }
  if [ "$common_root" = "$toplevel" ]; then
    printf ''
    return
  fi
  native="$(__field 'workspace.git_worktree')"
  if [ -n "$native" ]; then
    printf '%s' "$native"
    return
  fi
  printf '%s' "$(__basename "$toplevel")"
}
__emit() {
  local style="$1" text="$2"
  if [ -n "$style" ]; then __sgr "$style"; fi
  printf '%s' "$text"
  if [ -n "$style" ]; then __reset; fi
}
__norm_int() {
  # Coerce a possibly-decimal/empty/garbage field value to a non-negative
  # integer string.
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
  local p
  p="$(__field 'context_window.used_percentage')"
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
__cswap_bin() {
  if command -v cswap >/dev/null 2>&1; then printf 'cswap'; return 0; fi
  if [ -x "$HOME/.local/bin/cswap" ]; then printf '%s' "$HOME/.local/bin/cswap"; return 0; fi
  return 1
}
__cswap_resume_at() {
  # Prints the epoch time some cswap-managed account next clears both
  # fiveHour and sevenDay usage under 97%, or empty if one already does,
  # cswap is unavailable, or the JSON can't be parsed. resetsAt strings are
  # all same-width ISO-8601 UTC (+00:00), so lexicographic max/min sorts
  # the same as chronological order — no date parsing needed inside jq.
  local cswap json resume_str
  cswap="$(__cswap_bin)" || { printf ''; return; }
  json="$("$cswap" list --json 2>/dev/null)" || { printf ''; return; }
  if command -v jq >/dev/null 2>&1; then
    resume_str="$(printf '%s' "$json" | jq -r --argjson threshold "$RATE_LIMIT_GATE_PCT" '
      [.accounts[] | select(.usageStatus == "ok")] as $ok
      | ($ok | any(((.usage.fiveHour.pct // 0) < $threshold) and ((.usage.sevenDay.pct // 0) < $threshold))) as $has_available
      | if $has_available then empty
        else
          [ $ok[] |
            ([ (if (.usage.fiveHour.pct // 0) >= $threshold then (.usage.fiveHour.resetsAt // empty) else empty end),
               (if (.usage.sevenDay.pct // 0) >= $threshold then (.usage.sevenDay.resetsAt // empty) else empty end)
             ] | map(select(. != null))) as $times
            | if ($times | length) > 0 then ($times | max) else empty end
          ] | if length > 0 then min else empty end
        end
    ' 2>/dev/null)"
  else
    local py=""
    if command -v python3 >/dev/null 2>&1; then py=python3
    elif command -v python >/dev/null 2>&1; then py=python
    fi
    if [ -n "$py" ]; then
      resume_str="$(CSWAP_JSON="$json" CSWAP_GATE_PCT="$RATE_LIMIT_GATE_PCT" "$py" - <<'PYEOF' 2>/dev/null
import json, os
d = json.loads(os.environ.get('CSWAP_JSON', '{}') or '{}')
threshold = float(os.environ.get('CSWAP_GATE_PCT'))
ok = [a for a in d.get('accounts', []) if a.get('usageStatus') == 'ok']
def pct(a, k):
    return ((a.get('usage') or {}).get(k) or {}).get('pct') or 0
def resets(a, k):
    return ((a.get('usage') or {}).get(k) or {}).get('resetsAt')
has_available = any(pct(a, 'fiveHour') < threshold and pct(a, 'sevenDay') < threshold for a in ok)
if has_available:
    print('', end='')
else:
    candidates = []
    for a in ok:
        times = [t for t in (
            resets(a, 'fiveHour') if pct(a, 'fiveHour') >= threshold else None,
            resets(a, 'sevenDay') if pct(a, 'sevenDay') >= threshold else None,
        ) if t]
        if times:
            candidates.append(max(times))
    print(min(candidates) if candidates else '', end='')
PYEOF
)"
    fi
  fi
  if [ -z "${resume_str:-}" ] || [ "$resume_str" = "null" ]; then
    printf ''
    return
  fi
  date -d "$resume_str" +%s 2>/dev/null || printf ''
}
__account_segment() {
  # Prints the active account's alias if set, else its email, or empty if no
  # account is logged in. Reads Claude Code's and cswap's own local state
  # files directly instead of shelling out to `cswap status --json` — that
  # command also fetches live rate-limit usage over the network even though
  # we only need identity here, so it would pay for a round-trip this field
  # doesn't need.
  local claude_home claude_cfg
  claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  if [ -f "$claude_home/.config.json" ]; then
    claude_cfg="$claude_home/.config.json"
  else
    claude_cfg="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
  fi
  [ -f "$claude_cfg" ] || { printf ''; return; }
  local xdg_data seq_json
  if [ -n "${XDG_DATA_HOME:-}" ] && [[ "$XDG_DATA_HOME" = /* ]]; then
    xdg_data="$XDG_DATA_HOME"
  else
    xdg_data="$HOME/.local/share"
  fi
  seq_json="$xdg_data/claude-swap/sequence.json"
  if command -v jq >/dev/null 2>&1; then
    local email
    email="$(jq -r '.oauthAccount.emailAddress // empty' "$claude_cfg" 2>/dev/null)"
    [ -n "$email" ] || { printf ''; return; }
    local acct_alias=""
    if [ -f "$seq_json" ]; then
      acct_alias="$(jq -r --arg e "$email" '(.accounts // {}) | to_entries[] | select(.value.email == $e) | .value.alias // empty' "$seq_json" 2>/dev/null | head -n1)"
    fi
    if [ -n "$acct_alias" ]; then printf '%s' "$acct_alias"; else printf '%s' "$email"; fi
  else
    local py=""
    if command -v python3 >/dev/null 2>&1; then py=python3
    elif command -v python >/dev/null 2>&1; then py=python
    fi
    if [ -n "$py" ]; then
      CSWAP_CLAUDE_CFG="$claude_cfg" CSWAP_SEQ_JSON="$seq_json" "$py" - <<'PYEOF' 2>/dev/null
import json, os
email = ''
try:
    with open(os.environ['CSWAP_CLAUDE_CFG'], encoding='utf-8') as f:
        d = json.load(f)
    email = (d.get('oauthAccount') or {}).get('emailAddress') or ''
except Exception:
    pass
if not email:
    print('', end='')
else:
    alias = ''
    try:
        with open(os.environ['CSWAP_SEQ_JSON'], encoding='utf-8') as f:
            seq = json.load(f)
        for acct in (seq.get('accounts') or {}).values():
            if acct.get('email') == email:
                alias = acct.get('alias') or ''
                break
    except Exception:
        pass
    print(alias or email, end='')
PYEOF
    fi
  fi
}

# Edit fields below
if [ "$(__field 'fast_mode')" = 'true' ]; then
  __emit '' '⚡'
else
  __items=('😺' '😽' '😸' '😻' '🙀' '😼' '🐈' '😹' '😾' '🐱')
  __idx=$(( RANDOM % 10 ))
  __emit '' "${__items[$__idx]}"
fi
__repeat_char ' ' 1
__v="$(__field 'model.display_name')"
__emit '38;2;187;154;247' "$__v"
__repeat_char ' ' 1
if [ "$(__field 'thinking.enabled')" = 'true' ]; then
  __v="$(__field 'effort.level')"
  __emit '38;2;187;154;247' "$__v"
fi
if [ -n "$(__field 'agent.name')" ]; then
  __repeat_char ' ' 1
  __emit '38;2;187;154;247' "[$(__field 'agent.name')]"
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
__sid="$(__field 'session_id')"
if [ -n "$__sid" ]; then
  __tdir="/tmp/claude-$(id -u)/$__sid"
  __ts_start=""
  __ts_stop=""
  [ -f "$__tdir/turn_start" ] && __ts_start="$(cat "$__tdir/turn_start" 2>/dev/null)"
  [ -f "$__tdir/turn_stop" ] && __ts_stop="$(cat "$__tdir/turn_stop" 2>/dev/null)"
  case "$__ts_start" in ''|*[!0-9]*) __ts_start="" ;; esac
  case "$__ts_stop" in ''|*[!0-9]*) __ts_stop="" ;; esac
  if [ -n "$__ts_start" ] && [ -n "$__ts_stop" ] && [ "$__ts_stop" -gt "$__ts_start" ]; then
    __elapsed_ms=$(( (__ts_stop - __ts_start) * 1000 ))
    if [ "$__elapsed_ms" -gt 5000 ]; then
      __emit '' '  '
      __out="$(__dur_human "$__elapsed_ms")"
      __emit '' "$__out"
    fi
  elif [ -n "$__ts_start" ]; then
    __now=$(date +%s)
    __elapsed_ms=$(( (__now - __ts_start) * 1000 ))
    if [ "$__elapsed_ms" -gt 5000 ]; then
      __spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
      __idx=$(( __now % 10 ))
      __frame="$(printf '%s' "$__spin" | awk -v i="$__idx" '{print substr($0, i+1, 1)}')"
      __emit '' "$__frame "
      __out="$(__dur_human "$__elapsed_ms")"
      __emit '' "$__out"
    fi
  fi
fi
__reset
printf '\n'
__reset
five_hour_pct="$(__field 'rate_limits.five_hour.used_percentage')"
seven_day_pct="$(__field 'rate_limits.seven_day.used_percentage')"
five_hour_pct_display="$(__norm_int "$five_hour_pct")"
seven_day_pct_display="$(__norm_int "$seven_day_pct")"
if awk -v a="$five_hour_pct" -v b="$seven_day_pct" 'BEGIN{exit !(a+0 > 90 || b+0 > 90)}'; then
    __emit '38;2;224;104;104' ''
elif awk -v a="$five_hour_pct" -v b="$seven_day_pct" 'BEGIN{exit !(a+0 > 30 || b+0 > 30)}'; then
    __emit '38;2;224;175;104' ''
else
    __emit '38;2;158;206;106' ''
fi
__repeat_char ' ' 1
if awk -v v="$five_hour_pct" 'BEGIN{exit !(v+0 < 75)}'; then
  __emit '38;2;158;206;106' "$five_hour_pct_display"
  __emit '38;2;158;206;106' '%'
elif awk -v v="$five_hour_pct" 'BEGIN{exit !(v+0 < 85)}'; then
  __emit '4;38;2;224;175;104' "$five_hour_pct_display"
  __emit '4;38;2;224;175;104' '%'
else
  __emit '1;38;2;224;104;104' "$five_hour_pct_display"
  __emit '1;38;2;224;104;104' '%'
  __v="$(__field 'rate_limits.five_hour.resets_at')"
  __out="$(__rel_time "$__v")"
  __emit '1;38;2;224;104;104' "$__out"
fi
__emit '' '/'
if awk -v v="$seven_day_pct" 'BEGIN{exit !(v+0 < 75)}'; then
  __emit '38;2;158;206;106' "$seven_day_pct_display"
  __emit '38;2;158;206;106' '%'
elif awk -v v="$seven_day_pct" 'BEGIN{exit !(v+0 < 85)}'; then
  __emit '4;38;2;224;175;104' "$seven_day_pct_display"
  __emit '4;38;2;224;175;104' '%'
else
  __emit '1;38;2;224;104;104' "$seven_day_pct_display"
  __emit '1;38;2;224;104;104' '%'
  __v="$(__field 'rate_limits.seven_day.resets_at')"
  __out="$(__rel_time "$__v")"
  __emit '1;38;2;224;104;104' "$__out"
fi
if awk -v a="$five_hour_pct" -v b="$seven_day_pct" -v t="$RATE_LIMIT_GATE_PCT" 'BEGIN{exit !(a+0>=t || b+0>=t)}'; then
  __resume_epoch="$(__cswap_resume_at)"
  if [ -n "$__resume_epoch" ]; then
    __repeat_char ' ' 1
    __now=$(date +%s)
    __wait_ms=$(( (__resume_epoch - __now) * 1000 ))
    if [ "$__wait_ms" -lt 0 ]; then __wait_ms=0; fi
    __out="$(__dur_human "$__wait_ms")"
    __emit '1;3;38;2;125;207;255' "⏸  Paused, resuming in $__out"
  fi
fi
__account_label="$(__account_segment)"
if [ -n "$__account_label" ]; then
  __repeat_char ' ' 1
  __emit '38;2;190;136;116' " $__account_label"
fi
__repeat_char ' ' 1
__repeat_char ' ' 1
__emit '2;38;2;211;134;155' '  '
__u="$(__tokens_used)"
__t="$(__tokens_total)"
__p="$(__tokens_pct_int)"
__uf="$(__fmt_token_compact "$__u")"
__tf="$(__fmt_token_compact "$__t")"
__emit '2;38;2;211;134;155' "$__uf/$__tf ($__p%)"

exit 0
