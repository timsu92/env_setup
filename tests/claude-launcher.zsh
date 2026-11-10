#!/usr/bin/env zsh
# Tests the `claude` launcher function (65-claude-screen.zsh) with a stub screen
# and a stub claude on PATH, so nothing reaches a real session.
# ---- isolation header: a test must never reach the real session or account ----
unset TMUX TMUX_PANE STY WINDOW CLAUDECODE CLAUDE_LAUNCHER_ASSUME_TTY
TESTS_DIR="${0:A:h}"
ISO="$(mktemp -d)"
mkdir -p "$ISO/home" "$ISO/stub/real"
export HOME="$ISO/home" CLAUDE_CONFIG_DIR="$ISO/claude" XDG_DATA_HOME="$ISO/xdg" \
  FAKE_LOG="$ISO/log" STUB_STATE="$ISO/stub/state"
: > "$FAKE_LOG"
# stub claude: a symlink to another name, so a launcher that resolves symlinks shows up
cat > "$ISO/stub/real/claude-real" <<'STUB'
#!/bin/sh
{ printf 'claude'; for a in "$@"; do printf ' <%s>' "$a"; done; printf '\n'; } >> "$FAKE_LOG"
STUB
# stub screen: logs argv, remembers the -dmS name, lists it once STUB_LS_AFTER ls calls were made
cat > "$ISO/stub/screen" <<'STUB'
#!/bin/sh
{ printf 'screen'; for a in "$@"; do printf ' <%s>' "$a"; done; printf '\n'; } >> "$FAKE_LOG"
prev=''
for a in "$@"; do
  [ "$prev" = -dmS ] && printf '%s' "$a" > "$STUB_STATE.name"
  prev="$a"
done
if [ "$1" = -ls ]; then
  n=$(cat "$STUB_STATE.ls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_STATE.ls"
  if [ "$n" -gt "${STUB_LS_AFTER:-0}" ] && [ -r "$STUB_STATE.name" ]; then
    printf 'There is a screen on:\n\t4242.%s\t(Detached)\n1 Socket in /run/screen/S-x.\n' "$(cat "$STUB_STATE.name")"
  else
    printf 'No Sockets found in /run/screen/S-x.\n'
  fi
fi
exit 0
STUB
chmod +x "$ISO/stub/real/claude-real" "$ISO/stub/screen"
ln -s "$ISO/stub/real/claude-real" "$ISO/stub/claude"
export PATH="$ISO/stub:$TESTS_DIR/fakes:$PATH"
for c in tmux screen cswap claude; do
  p="$(command -v $c)"
  [[ "$p" == "$TESTS_DIR"/fakes/* || "$p" == "$ISO"/stub/* ]] || { echo "ISOLATION: '$c' resolves to '${p:-nothing}'" >&2; exit 2; }
done
# ---- end isolation header ----
trap 'rm -rf "$ISO"' EXIT
zmodload zsh/datetime

snippet="${TESTS_DIR:h}/ansible/roles/claude_code/files/interactive/65-claude-screen.zsh"
source "$snippet" || { echo "FAIL cannot source $snippet"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1${2:+: $2}"; fail=$((fail + 1)); }
reset() { : > "$FAKE_LOG"; rm -f "$STUB_STATE.name" "$STUB_STATE.ls"; unset STUB_LS_AFTER; }
log() { cat "$FAKE_LOG"; }
claude_path="$ISO/stub/claude"

# direct(): the call goes straight to claude, screen is never touched
direct() {  # $1 label; rest: env assignments are done by the caller; args after --
  local label="$1"; shift
  local want="claude"; local a; for a in "$@"; do want+=" <$a>"; done
  if [[ "$(log)" == "$want" ]]; then ok "$label"; else bad "$label" "log was: $(log | tr '\n' '|')"; fi
}

reset; TMUX=/tmp/x,1,0 claude hi </dev/null >/dev/null; direct "inside tmux: direct" hi
reset; STY=1.x CLAUDE_LAUNCHER_ASSUME_TTY=1 claude hi; direct "inside screen: direct" hi
reset; CLAUDE_LAUNCHER_ASSUME_TTY=1 claude -p hi; direct "-p: direct" -p hi
reset; CLAUDE_LAUNCHER_ASSUME_TTY=1 claude --model opus -p q; direct "--model opus -p q: direct" --model opus -p q
reset; CLAUDE_LAUNCHER_ASSUME_TTY=1 claude --version; direct "--version: direct" --version
reset; CLAUDE_LAUNCHER_ASSUME_TTY=1 claude mcp list; direct "mcp list: direct" mcp list
reset; CLAUDE_LAUNCHER_ASSUME_TTY=1 claude --model opus mcp list; direct "--model opus mcp list: direct" --model opus mcp list
reset; CLAUDE_LAUNCHER_ASSUME_TTY=1 claude update; direct "update: direct" update
reset; claude hi </dev/null; direct "non-tty stdin: direct" hi
reset; claude hi </dev/null >/dev/null; direct "non-tty stdout: direct" hi

# interactive
reset
CLAUDE_LAUNCHER_ASSUME_TTY=1 claude --model opus "two words" 'it'\''s'
lines=("${(@f)$(log)}")
name="$(cat "$STUB_STATE.name" 2>/dev/null)"
if [[ "$name" =~ '^claude-[0-9]+-[0-9]+$' ]]; then ok "session name is claude-<pid>-<epoch>"; else bad "session name" "got '$name'"; fi
want_dm="screen <-e> <^\q> <-dmS> <$name> <$claude_path> <--model> <opus> <two words> <it's>"
[[ "$lines[1]" == "$want_dm" ]] && ok "screen -e -dmS name <claude path> args (symlink path kept, spaces survive)" || bad "dmS line" "got: $lines[1]"
idx_bind=${lines[(i)screen <-S> <$name> <-X> <bindkey> <^Z> <suspend>]}
idx_r=${lines[(i)screen <-r> <$name>]}
idx_ls=${lines[(i)screen <-ls>]}
(( idx_ls <= $#lines && idx_ls < idx_bind )) && ok "screen -ls polled before bindkey" || bad "ls before bindkey" "$(log | tr '\n' '|')"
(( idx_bind <= $#lines && idx_bind < idx_r && idx_r == $#lines )) && ok "-X bindkey ^Z suspend, then -r <name> last" || bad "bindkey then -r" "$(log | tr '\n' '|')"
[[ "$(log | grep -c '^claude')" == 0 ]] && ok "stub claude not run directly by the launcher" || bad "claude run directly"

# retry: the session shows up in screen -ls only after 3 polls
reset; STUB_LS_AFTER=3 CLAUDE_LAUNCHER_ASSUME_TTY=1 claude
nls=$(log | grep -c '^screen <-ls>')
(( nls >= 4 )) && [[ "$(log | grep -c '<bindkey>')" == 1 ]] && ok "waits for screen -ls to list the session ($nls polls)" || bad "retry" "$(log | tr '\n' '|')"

# never listed: gives up after about 2 s, still attempts -r (which reports the error itself)
reset
t0=$EPOCHREALTIME; STUB_LS_AFTER=99999 CLAUDE_LAUNCHER_ASSUME_TTY=1 claude; t1=$EPOCHREALTIME
el=$(( t1 - t0 ))
(( el < 4 && el >= 1.5 )) && [[ "$(log | grep -c '<-r>')" == 1 ]] && ok "gives up polling after about 2 s" || bad "poll timeout" "elapsed $el; $(log | tr '\n' '|')"

# no leaked names, options untouched
reset
print -l ${(k)parameters} | sort > "$ISO/params.before"; setopt > "$ISO/opts.before"
CLAUDE_LAUNCHER_ASSUME_TTY=1 claude hi
print -l ${(k)parameters} | sort > "$ISO/params.after"; setopt > "$ISO/opts.after"
cmp -s "$ISO/params.before" "$ISO/params.after" && ok "no variables leaked" || bad "leaked variables" "$(diff "$ISO/params.before" "$ISO/params.after" | tr '\n' ' ')"
cmp -s "$ISO/opts.before" "$ISO/opts.after" && ok "shell options unchanged" || bad "options changed"

# odd user options do not break argv handling
reset
setopt ksh_arrays sh_word_split no_glob
CLAUDE_LAUNCHER_ASSUME_TTY=1 claude "a b" '*'
unsetopt ksh_arrays sh_word_split no_glob
log | grep -qF "<-dmS> <$(cat "$STUB_STATE.name")> <$claude_path> <a b> <*>" && ok "ksh_arrays/sh_word_split/no_glob" || bad "odd options" "$(log | tr '\n' '|')"

# no screen on PATH: falls back to running claude directly
reset
mkdir -p "$ISO/nostub"; ln -s "$ISO/stub/claude" "$ISO/nostub/claude"
( PATH="$ISO/nostub"; CLAUDE_LAUNCHER_ASSUME_TTY=1 claude hi )
direct "no screen installed: direct" hi

echo "total: $pass pass, $fail fail"
(( fail == 0 ))
