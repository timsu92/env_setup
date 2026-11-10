#!/usr/bin/env bash
# Claude Code hook for the checkpoint-compact flow: pause at a task boundary,
# /compact through the terminal multiplexer, switch account, send 繼續.
# Registered on PostToolUse, Stop, Notification, PreCompact, PostCompact,
# SessionStart and UserPromptSubmit. This file handles SessionStart,
# UserPromptSubmit, PreCompact, PostToolUse, Stop and Notification; PostCompact
# is a stub for now.
# It never blocks Claude Code: exit 0 on every path (never 2), and nothing on
# stdout except PostToolUse's additionalContext JSON.
set -u

# Relative to this script (~/.claude/hooks/), so a moved ~/.claude keeps working.
LIB="$(dirname "${BASH_SOURCE[0]}")/../common-helpers.sh"
# shellcheck source=../common-helpers.sh
if [ -r "$LIB" ] && . "$LIB"; then
  :
else
  echo "ideal-compact: common-helpers.sh not found" >&2
  exit 0
fi

INPUT="$(cat)"

# __py: the name of a Python interpreter, or nothing.
__py() {
  if command -v python3 >/dev/null 2>&1; then printf python3
  elif command -v python >/dev/null 2>&1; then printf python
  fi
}

# __field <key>: a top-level field of the hook input as text. A nested value
# (tool_input) comes back as compact JSON.
__field() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r --arg k "$1" '(.[$k] // empty) | if type == "string" then . else tojson end' 2>/dev/null
  else
    local py
    py="$(__py)"
    [ -z "$py" ] && { printf ''; return; }
    IC_INPUT="$INPUT" IC_KEY="$1" "$py" - <<'PYEOF' 2>/dev/null
import json, os
d = json.loads(os.environ.get('IC_INPUT', '{}') or '{}')
v = d.get(os.environ.get('IC_KEY', ''), '')
print(v if isinstance(v, str) else json.dumps(v, separators=(',', ':'), ensure_ascii=False), end='')
PYEOF
  fi
}

EVENT="$(__field hook_event_name)"
TPATH="$(__field transcript_path)"
CWD="$(__field cwd)"
SDIR="$(__ic_session_dir "$TPATH" "$(__field session_id)")"
[ -n "$SDIR" ] || exit 0
LOCK="$SDIR/ideal-compact-state.lock"

# __hist_path: the history file of the project the stored ledger (else the
# cwd) belongs to; /dev/null when the project directory is unknown. Reads the
# state the caller just read into IC_*.
__hist_path() {
  local pdir
  if [ -n "$IC_ledger" ]; then
    pdir="$(__ic_project_dir "$(dirname "$IC_ledger")" "$TPATH")"
  else
    pdir="$(__ic_project_dir "$CWD" "$TPATH")"
  fi
  if [ -n "$pdir" ]; then printf '%s/ideal-compact-history' "$pdir"; else printf /dev/null; fi
}

# __ic_takeover <expected> [inputbox_fail]: the user (or something else) took
# the session over while the flow was running, or a step failed. Sets phase
# standby with suppress=1 for the window the budget is currently counted on,
# so the flow does not re-arm until that window resets. <expected> is a phase
# name or `nonstandby`; the takeover happens only when the phase still is that
# (checked again under the lock) and returns 1 changing nothing otherwise. Any
# second argument also sets inputbox_fail=1 in the same write.
# The helper and the budget run BEFORE the lock (the lock never spans them);
# when the helper fails or the budget is unknown, armed_* is used instead.
__ic_takeover() {
  local expected="$1" fail="${2:-}" cur='' acc='' hist budget bwin='' key r5 r7
  local s_key='' s_win='' s_resets=0
  if [ -x "$__IC_HELPER" ]; then
    cur="$("$__IC_HELPER" current 2>/dev/null)"
    acc="$("$__IC_HELPER" accounts 2>/dev/null)"
  fi
  case "$cur" in error:*) cur='' ;; esac
  __ic_state_read "$SDIR"
  hist="$(__hist_path)"
  if [ -n "$cur" ]; then
    budget="$(__ic_budget "$hist" "$cur" "$acc")"
    bwin="${budget#* }"
    # `current` is: tag key p5 r5 p7 r7 ...
    read -r _ key _ r5 _ r7 _ <<< "$cur"
    case "$bwin" in
      5h) s_key="$key" s_win=5h s_resets="$r5" ;;
      7d) s_key="$key" s_win=7d s_resets="$r7" ;;
      *) bwin='' ;;
    esac
  fi
  __ic_lock "$LOCK" || return 1
  __ic_state_read "$SDIR"
  if [ "$expected" = nonstandby ]; then
    [ "$IC_phase" != standby ] || { __ic_unlock; return 1; }
  else
    [ "$IC_phase" = "$expected" ] || { __ic_unlock; return 1; }
  fi
  if [ -z "$bwin" ]; then
    s_key="$IC_armed_key" s_win="$IC_armed_win" s_resets="$IC_armed_resets"
  fi
  __ic_set_phase standby
  IC_suppress=1 IC_suppress_key="$s_key" IC_suppress_win="$s_win" IC_suppress_resets="${s_resets:-0}"
  [ -n "$fail" ] && IC_inputbox_fail=1
  __ic_state_write "$SDIR"
  __ic_unlock
  return 0
}

# Every event first lets an overdue phase go back to standby (with suppress),
# so the handlers below never see an expired one.
__ttl_step() {
  __ic_lock "$LOCK" || exit 0
  __ic_state_read "$SDIR"
  if __ic_ttl_check "$(date +%s)"; then __ic_state_write "$SDIR"; fi
  __ic_unlock
}

# New session (not the one /compact restarts): nothing of an old flow applies.
# dirty stays, it counts activity that already happened.
__on_session_start() {
  case "$(__field source)" in startup|resume|clear) ;; *) return 0 ;; esac
  __ic_lock "$LOCK" || return 0
  __ic_state_read "$SDIR"
  if [ "$IC_phase" != standby ] || [ "$IC_skip" != 0 ] || [ "$IC_suppress" != 0 ] || [ -n "$IC_ledger" ] \
     || [ -n "$IC_pending_inject" ] || [ "$IC_ledger_done" != 0 ]; then
    __ic_set_phase standby
    IC_suppress=0 IC_suppress_key='' IC_suppress_win='' IC_suppress_resets=0 IC_ledger='' IC_ledger_done=0
    __ic_state_write "$SDIR"
  fi
  __ic_unlock
}

__on_prompt() {
  local prompt first kind=other seen
  prompt="$(__field prompt)"
  # A background agent's hand-back is not the user speaking (Task 1 ruling).
  case "$prompt" in '<agent-message '*) return 0 ;; esac
  read -r first _ <<< "$prompt"
  if [ "$first" = /ideal-compact-skip ] || [[ "$prompt" == *'<!-- ideal-compact:skip -->'* ]]; then
    kind=skip
  elif [ "$first" = /ideal-compact-standby ] || [[ "$prompt" == *'<!-- ideal-compact:standby -->'* ]]; then
    kind=standby
  elif [ "$prompt" = "$IDEAL_COMPACT_CONTINUE_TEXT" ]; then
    kind=continue
  fi
  __ic_lock "$LOCK" || return 0
  __ic_state_read "$SDIR"
  IC_dirty=$(( IC_dirty + 1 ))
  case "$kind" in
    skip)
      IC_skip=1 ;;
    standby)
      case "$IC_phase" in armed|stopped) __ic_set_phase standby ;; esac
      IC_skip=0 IC_suppress=0 IC_suppress_key='' IC_suppress_win='' IC_suppress_resets=0 ;;
    continue)
      # Our own keyed 繼續 ends the flow. The same word typed in any other
      # phase is an ordinary prompt.
      if [ "$IC_phase" = continuing ]; then
        __ic_set_phase standby
        IC_suppress=0 IC_suppress_key='' IC_suppress_win='' IC_suppress_resets=0
      else
        kind=other
      fi ;;
  esac
  seen="$IC_phase"
  __ic_state_write "$SDIR"
  __ic_unlock
  if [ "$kind" = other ] && [ "$seen" != standby ]; then
    __ic_takeover nonstandby || true
  fi
}

__on_precompact() {
  local seen moved=0
  __ic_lock "$LOCK" || return 0
  __ic_state_read "$SDIR"
  IC_dirty=$(( IC_dirty + 1 ))
  if [ "$IC_phase" = to-compact ] && [ "$(__field trigger)" = manual ]; then
    # Our own /compact reached the CLI.
    __ic_set_phase compacting
    moved=1
  fi
  seen="$IC_phase"
  __ic_state_write "$SDIR"
  __ic_unlock
  # Any other compaction while the flow is active is not ours.
  if [ "$moved" = 0 ] && [ "$seen" != standby ]; then
    __ic_takeover nonstandby || true
  fi
}

# ---- PostToolUse: task completions, arming and cancelling ----

# __get_cur: the helper's `current` line into CUR, asked once per run.
CUR='' CUR_ASKED=0
__get_cur() {
  [ "$CUR_ASKED" = 1 ] && return 0
  CUR_ASKED=1
  [ -x "$__IC_HELPER" ] && CUR="$("$__IC_HELPER" current 2>/dev/null)"
  return 0
}

# __obs_key: the key (helper's rule: <email>-<organizationUuid or personal>,
# [^A-Za-z0-9._@+-] -> _) of the account in the config file the statusline's
# __oauth_email reads, same lookup order. Nothing when unknown.
__obs_key() {
  local home cfg py
  home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  if [ -f "$home/.config.json" ]; then
    cfg="$home/.config.json"
  else
    cfg="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
  fi
  [ -f "$cfg" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r 'def clean: tostring | gsub("[^A-Za-z0-9._@+-]"; "_");
      (.oauthAccount // {}) as $a
      | if ($a.emailAddress // "") == "" then empty
        else "\($a.emailAddress | clean)-\(if ($a.organizationUuid // "") == "" then "personal" else ($a.organizationUuid | clean) end)" end' \
      "$cfg" 2>/dev/null
  else
    py="$(__py)"
    [ -n "$py" ] || return 0
    IC_CFG="$cfg" "$py" - <<'PYEOF' 2>/dev/null
import json, os, re
def clean(x):
    return re.sub(r'[^A-Za-z0-9._@+-]', '_', str(x))
try:
    with open(os.environ['IC_CFG'], encoding='utf-8') as f:
        a = json.load(f).get('oauthAccount') or {}
    e, o = a.get('emailAddress') or '', a.get('organizationUuid') or ''
    if e:
        print('%s-%s' % (clean(e), clean(o) if o else 'personal'), end='')
except Exception:
    pass
PYEOF
  fi
}

# __cheap_obs: OBS = "<key> <r5> <r7>" without asking cswap: the key from
# __obs_key and the resets from its statusline usage hint. When either is
# missing, the helper's `current` key and resets instead; empty when that
# fails too.
OBS=''
__cheap_obs() {
  local key r5='' r7='' _x
  key="$(__obs_key)"
  if [[ "$key" =~ ^[A-Za-z0-9._@+-]+$ ]]; then
    { read -r _x r5 _x r7 _x < "${HWAP_HINT_DIR:-/tmp/claude-$(id -u)}/usage-$key"; } 2>/dev/null
  fi
  if ! [[ "$r5" =~ ^[0-9]+$ && "$r7" =~ ^[0-9]+$ ]]; then
    __get_cur
    OBS=''
    case "$CUR" in error:*|'') return 0 ;; esac
    read -r _x key _x r5 _x r7 _x <<< "$CUR"
    [ -n "$key" ] && [ "$key" != - ] || return 0
  fi
  OBS="$key $r5 $r7"
}

# Words of a tool_input text, one per line: split at quotes, blanks and
# shell/JSON punctuation (JSON escapes split at the backslash).
__IC_DELIMS="\"' "$'\t\n'':=,;()<>|&`\\'
__words() { printf '%s' "$1" | tr -s "$__IC_DELIMS" '\n'; }
__abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$CWD" "$1" ;; esac; }
# __phys <path>: physical absolute path (its directory must exist), or nothing.
__phys() {
  local d
  d="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || return 0
  printf '%s/%s' "$d" "$(basename "$1")"
}

# __find_ledger <tool_input text>: the ledger this call names, as a physical
# absolute path, or nothing. `task-done <plan>`: the .superpowers/sdd/*/progress.md
# whose plan is that plan, under the cwd's repo root, then the plan's. Else the
# first word ending in progress.md that is a file.
__find_ledger() {
  local words w prev='' plan='' root seen='' f
  words="$(__words "$1")"
  if [[ "$1" == *task-done* ]]; then
    while IFS= read -r w; do
      case "$prev" in task-done|*/task-done) plan="$w"; break ;; esac
      prev="$w"
    done <<< "$words"
    [ -n "$plan" ] && plan="$(__phys "$(__abs "$plan")")"
    if [ -n "$plan" ]; then
      for root in "$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" \
                  "$(git -C "$(dirname "$plan")" rev-parse --show-toplevel 2>/dev/null)"; do
        [ -n "$root" ] && [ "$root" != "$seen" ] || continue
        seen="$root"
        for f in "$root"/.superpowers/sdd/*/progress.md; do
          [ -f "$f" ] || continue
          [ "$(__ic_ledger_plan "$f")" = "$plan" ] && { __phys "$f"; return 0; }
        done
      done
    fi
  fi
  if [[ "$1" == *progress.md* ]]; then
    w="$(awk '/progress\.md$/ { print; exit }' <<< "$words")"
    [ -n "$w" ] || return 0
    f="$(__phys "$(__abs "$w")")"
    [ -n "$f" ] && [ -f "$f" ] && printf '%s' "$f"
  fi
  return 0
}

# __suppress_holds <key> <win> <resets>: 0 while the stored account and
# window still match `current` (resets within the helper's tolerance).
# Nothing stored, or `current` unknown, also holds.
__suppress_holds() {
  local key r5 r7 tol r
  [ -n "$1" ] || return 0
  case "$CUR" in error:*|'') return 0 ;; esac
  read -r _ key _ r5 _ r7 _ _ _ tol _ <<< "$CUR"
  [ -n "$key" ] && [ "$key" != - ] || return 0
  [ "$key" = "$1" ] || return 1
  case "$2" in 5h) r="$r5" ;; 7d) r="$r7" ;; *) return 0 ;; esac
  awk -v a="$r" -v b="$3" -v t="${tol:-3}" 'BEGIN { d = a - b; exit !(d <= t && -d <= t) }'
}

# __inject <text>: PostToolUse's additionalContext JSON on stdout.
__inject() {
  local t="${1//\\/\\\\}"
  t="${t//\"/\\\"}"
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$t"
}

__on_post_tool_use() {
  local sub=0 pend='' ledger hist='' pdir done latest record=0 completion=0 d0 res
  local seen changed=0 acc budget n bwin backend key r5 r7 text='' kind=''
  [ -n "$(__field agent_id)" ] && sub=1
  __ic_state_read "$SDIR"
  # The agent called a tool after it stopped: it is working again.
  if [ "$IC_phase" = stopped ]; then
    __ic_lock "$LOCK" || return 0
    __ic_state_read "$SDIR"
    if [ "$IC_phase" = stopped ]; then __ic_set_phase armed; __ic_state_write "$SDIR"; fi
    __ic_unlock
    return 0
  fi
  # A text queued by a subagent call reaches the main agent now, if it still fits.
  if [ "$sub" = 0 ] && [ -n "$IC_pending_inject" ]; then
    __ic_lock "$LOCK" || return 0
    __ic_state_read "$SDIR"
    case "$IC_pending_inject:$IC_phase" in
      pause:armed) pend="$IDEAL_COMPACT_PAUSE_TEXT" ;;
      cancel:standby) pend="$IDEAL_COMPACT_CANCEL_TEXT" ;;
    esac
    IC_pending_inject=''
    __ic_state_write "$SDIR"
    __ic_unlock
  fi

  ledger="$(__find_ledger "$TI")"
  if [ -n "$ledger" ] && [ "$ledger" != "$IC_ledger" ]; then
    __ic_lock "$LOCK" || return 0
    __ic_state_read "$SDIR"
    IC_ledger="$ledger" IC_ledger_done=0
    __ic_state_write "$SDIR"
    __ic_unlock
  fi
  [ -n "$ledger" ] || ledger="$IC_ledger"

  # Completion: the ledger's done count grew past its newest history entry
  # and past the count this session already evaluated (ledger_done), so a
  # completion the history skipped (current not `usage`) is not evaluated
  # again on every call. A lower count (the ledger was recreated) is recorded
  # as a new baseline, once per count.
  if [ -n "$ledger" ] && [ -r "$ledger" ]; then
    pdir="$(__ic_project_dir "$(dirname "$ledger")" "$TPATH")"
    if [ -n "$pdir" ]; then
      hist="$pdir/ideal-compact-history"
      done="$(__ic_ledger_done "$ledger")"
      case "$done" in ''|*[!0-9]*) done=0 ;; esac
      latest="$(__ic_history_latest "$hist" "$ledger" | awk -F'\t' '{ print $3 }')"
      case "$latest" in *[!0-9]*) latest='' ;; esac
      if [ "$done" -ge 1 ] && { [ -z "$latest" ] || [ "$done" -gt "$latest" ]; } && [ "$done" -gt "$IC_ledger_done" ]; then
        completion=1 record=1
      elif [ -n "$latest" ] && [ "$done" -lt "$latest" ] && [ "$done" != "$IC_ledger_done" ]; then
        record=1
      fi
    fi
  fi
  if [ "$record" = 1 ]; then
    __get_cur
    __ic_state_read "$SDIR"
    d0="$IC_dirty"
    res="$(__ic_history_record "$hist" "$ledger" "$done" "$CUR" "$d0")"
    if __ic_lock "$LOCK"; then
      __ic_state_read "$SDIR"
      # Only what this record carried: a prompt meanwhile stays counted.
      case "$res" in baseline|counted) IC_dirty=$(( IC_dirty > d0 ? IC_dirty - d0 : 0 )) ;; esac
      [ "$IC_ledger" = "$ledger" ] && IC_ledger_done="$done"
      __ic_state_write "$SDIR"
      __ic_unlock
    fi
  fi

  # Evaluate on a completion, or in armed when the account or a window's
  # reset changed (main agent only). Other phases only record. A subagent's
  # call cannot carry text to the controller, so its text is queued in
  # pending_inject (set after __ic_set_phase, which clears it).
  __ic_state_read "$SDIR"
  seen="$IC_phase"
  if [ "$seen" = standby ] || [ "$seen" = armed ]; then
    # Built only where it is used: arming on a completion, or armed.
    [ "$sub" = 0 ] && { [ "$seen" = armed ] || [ "$completion" = 1 ]; } && __cheap_obs
    [ "$sub" = 0 ] && [ "$seen" = armed ] && [ -n "$OBS" ] && [ "$OBS" != "$IC_cheap_obs" ] && changed=1
  fi
  if [ "$completion" = 1 ] || [ "$changed" = 1 ]; then
    __get_cur
    acc=''
    [ -x "$__IC_HELPER" ] && acc="$("$__IC_HELPER" accounts 2>/dev/null)"
    if [ -z "$hist" ]; then
      pdir="$(__ic_project_dir "$CWD" "$TPATH")"
      hist=/dev/null
      [ -n "$pdir" ] && hist="$pdir/ideal-compact-history"
    fi
    case "$CUR" in error:*|'') budget='unknown -' ;; *) budget="$(__ic_budget "$hist" "$CUR" "$acc")" ;; esac
    n="${budget%% *}" bwin="${budget#* }"
    case "$n" in ''|*[!0-9]*) n='' ;; esac
    key='' r5='' r7=''
    case "$CUR" in error:*|'') ;; *) read -r _ key _ r5 _ r7 _ <<< "$CUR" ;; esac
    backend="$(__ic_backend)"
    __ic_lock "$LOCK" || return 0
    __ic_state_read "$SDIR"
    if [ "$IC_phase" = standby ] && [ "$seen" = standby ]; then
      if [ "$IC_suppress" = 1 ]; then
        if [ -n "$IC_suppress_key" ]; then
          __suppress_holds "$IC_suppress_key" "$IC_suppress_win" "$IC_suppress_resets"
        else
          __suppress_holds "$IC_armed_key" "$IC_armed_win" "$IC_armed_resets"
        fi || IC_suppress=0 IC_suppress_key='' IC_suppress_win='' IC_suppress_resets=0
      fi
      if [ "$IC_suppress" = 0 ] && [ -n "$n" ] && [ "$n" -le "$IDEAL_COMPACT_ARM_TASKS" ] && [ -n "$backend" ]; then
        __ic_set_phase armed
        IC_armed_key="$key" IC_armed_win="$bwin"
        if [ "$bwin" = 7d ]; then IC_armed_resets="$r7"; else IC_armed_resets="$r5"; fi
        [ "$sub" = 0 ] && IC_cheap_obs="$OBS"
        kind=pause
      fi
      [ "$sub" = 1 ] && [ -n "$kind" ] && IC_pending_inject="$kind"
      __ic_state_write "$SDIR"
    elif [ "$IC_phase" = armed ] && [ "$seen" = armed ]; then
      if [ -z "$backend" ] || { [ -n "$n" ] && [ "$n" -gt "$IDEAL_COMPACT_WARN_TASKS" ]; }; then
        __ic_set_phase standby
        kind=cancel
      elif [ -n "$n" ] && [ "$n" -le "$IDEAL_COMPACT_ARM_TASKS" ]; then
        # Still armed: follow the account and window the budget is now counted on.
        IC_armed_key="$key" IC_armed_win="$bwin"
        if [ "$bwin" = 7d ]; then IC_armed_resets="$r7"; else IC_armed_resets="$r5"; fi
        [ "$completion" = 1 ] && kind=pause
      fi
      [ "$sub" = 0 ] && [ -n "$OBS" ] && IC_cheap_obs="$OBS"
      [ "$sub" = 1 ] && [ -n "$kind" ] && IC_pending_inject="$kind"
      __ic_state_write "$SDIR"
    fi
    __ic_unlock
  fi
  [ "$sub" = 1 ] && return 0
  case "$kind" in
    pause) text="$IDEAL_COMPACT_PAUSE_TEXT" ;;
    cancel) text="$IDEAL_COMPACT_CANCEL_TEXT" ;;
    *) text="$pend" ;;
  esac
  [ -n "$text" ] && __inject "$text"
  return 0
}

# ---- Stop and Notification ----

# __trim <text>: without leading and trailing whitespace.
__trim() {
  local t="$1"
  t="${t#"${t%%[![:space:]]*}"}"
  printf '%s' "${t%"${t##*[![:space:]]}"}"
}

# The agent stopped. Its last message ends with the marker and nothing runs
# in the background (both lists present and empty): armed -> stopped, a
# repeated one refreshes stopped. Anything else sends stopped back to armed.
__on_stop() {
  local last quiet=0 ok=0
  last="$(__field last_assistant_message | awk 'NF { l = $0 } END { print l }')"
  [ "$(__trim "$last")" = "$IDEAL_COMPACT_MARKER" ] || last=''
  [ "$(__trim "$(__field background_tasks)")" = '[]' ] && [ "$(__trim "$(__field session_crons)")" = '[]' ] && quiet=1
  [ -n "$last" ] && [ "$quiet" = 1 ] && ok=1
  __ic_lock "$LOCK" || return 0
  __ic_state_read "$SDIR"
  case "$IC_phase:$ok" in
    armed:1|stopped:1) __ic_set_phase stopped; __ic_state_write "$SDIR" ;;
    stopped:0) __ic_set_phase armed; __ic_state_write "$SDIR" ;;
  esac
  __ic_unlock
}

# The user is away (idle_prompt) while stopped: send /compact, or 繼續 when
# the budget says the paused window has room again. The input box check, the
# helper and the budget run before the lock; the lock only re-reads and
# writes the phase, the keys go out after it.
__on_notification() {
  local backend box cur='' acc='' budget n next text
  local -a bw
  [ "$(__field notification_type)" = idle_prompt ] || return 0
  __ic_state_read "$SDIR"
  [ "$IC_phase" = stopped ] && [ "$IC_skip" = 0 ] || return 0
  backend="$(__ic_backend)"
  if [ -z "$backend" ]; then
    __ic_takeover stopped || true
    return 0
  fi
  read -r -a bw <<< "$backend"
  box="$(__ic_inputbox_state "${bw[@]}")"
  case "$box" in
    empty|placeholder) ;;
    unsure) __ic_takeover stopped 1 || true; return 0 ;;
    *) __ic_takeover stopped || true; return 0 ;;
  esac
  if [ -x "$__IC_HELPER" ]; then
    cur="$("$__IC_HELPER" current 2>/dev/null)"
    acc="$("$__IC_HELPER" accounts 2>/dev/null)"
  fi
  n=''
  case "$cur" in
    error:*|'') ;;
    *) budget="$(__ic_budget "$(__hist_path)" "$cur" "$acc")"; n="${budget%% *}" ;;
  esac
  case "$n" in ''|*[!0-9]*) n='' ;; esac
  if [ -n "$n" ] && [ "$n" -gt "$IDEAL_COMPACT_WARN_TASKS" ]; then
    next=continuing text="$IDEAL_COMPACT_CONTINUE_TEXT"
  else
    next=to-compact text="/compact $IDEAL_COMPACT_COMPACT_TEXT"
  fi
  __ic_lock "$LOCK" || return 0
  __ic_state_read "$SDIR"
  if [ "$IC_phase" != stopped ] || [ "$IC_skip" != 0 ]; then
    __ic_unlock
    return 0
  fi
  __ic_set_phase "$next"
  IC_inputbox_fail=0
  __ic_state_write "$SDIR"
  __ic_unlock
  __ic_send "${bw[@]}" "$text" || true
}

# Fast path, before any lock: an idle standby with nothing queued and no
# ledger in sight is the common tool call and costs no helper, cswap or git.
# standby has no timeout, so skipping __ttl_step is safe.
TI=''
if [ "$EVENT" = PostToolUse ]; then
  TI="$(__field tool_input)"
  __ic_state_read "$SDIR"
  if [ "$IC_phase" = standby ] && [ -z "$IC_pending_inject" ]; then
    case "$TI" in *progress.md*|*task-done*) ;; *) exit 0 ;; esac
  fi
fi

__ttl_step
case "$EVENT" in
  SessionStart) __on_session_start ;;
  UserPromptSubmit) __on_prompt ;;
  PreCompact) __on_precompact ;;
  PostToolUse) __on_post_tool_use ;;
  Stop) __on_stop ;;
  Notification) __on_notification ;;
  PostCompact) : ;;   # Task 13
esac
exit 0
