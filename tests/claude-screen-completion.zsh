#!/usr/bin/env zsh
# Tests 97-claude-screen-completion.zsh: `claude` is an alias to claude-screen, so completion
# looks up `claude-screen`, and the mapping must survive zplug's compinit (95-zplug-load.zsh)
# loading a .zcompdump made before the mapping existed. That is the order a fresh provision
# gives: the zplug role's install shell builds the dump, then claude_code deploys the launcher.
# A stub _claude stands in for the zplug plugin, and `compinit -d` stands in for `zplug load`,
# so nothing is cloned and nothing touches the real home.
# ---- isolation header ----
TESTS_DIR="${0:A:h}"
ISO="$(mktemp -d)"
mkdir -p "$ISO/home" "$ISO/fpath" "$ISO/bin"
export HOME="$ISO/home" ZDOTDIR="$ISO/home"
# zplug exports fpath (`typeset -gx fpath`), so even `zsh -f` inherits the real ~/.zplug _claude
unset FPATH
trap 'rm -rf "$ISO"' EXIT
# ---- end isolation header ----

SNIPPETS="${TESTS_DIR:h}/ansible/roles/claude_code/files/interactive"
printf '#compdef claude\n_claude() { compadd mcp; }\n' > "$ISO/fpath/_claude"
printf '#!/bin/sh\n' > "$ISO/bin/claude-screen"
chmod +x "$ISO/bin/claude-screen"

pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1${2:+: $2}"; fail=$((fail + 1)); }
check() { [[ "$3" == "$2" ]] && ok "$1" || bad "$1" "expected '$2', got '$3'"; }

# Run a login-like sequence in a clean zsh and print the claude-screen mapping.
#   $1 dump file, $2 fpath dir for the stub (or empty), $3 PATH prefix (or empty),
#   $4 code run between 00's compinit and the zplug-style compinit (where 65 runs),
#   $5 code run after it (where 97 runs)
shell_run() {
  zsh -f -c "
    fpath=(${2:+$2} \$fpath); PATH=${3:+$3:}/usr/bin:/bin  # never the real ~/.local/bin/claude-screen
    autoload -Uz compinit && compinit -d '$ISO/home/.zcompdump'
    $4
    compinit -d '$1'
    $5
    print -r -- \"\${_comps[claude-screen]:-none}|\${_comps[claude]:-none}\"
  " 2>&1
}

# Build a dump the way the zplug role's install shell does: _claude is there, claude-screen is not.
stale="$ISO/stale.zcompdump"
shell_run "$stale" "$ISO/fpath" "" "" "" >/dev/null
grep -q "'claude' '_claude'" "$stale" && ! grep -q "'claude-screen'" "$stale" \
  && ok "precondition: dump knows claude but not claude-screen" \
  || bad "precondition: dump knows claude but not claude-screen"

# The trap itself: a compdef before the zplug-style compinit is replaced by the stale dump.
# If this starts mapping, the test no longer reproduces the provision order.
out="$(shell_run "$stale" "$ISO/fpath" "$ISO/bin" "compdef _claude claude-screen" "")"
check "compdef before the stale dump is lost" "none|_claude" "$out"

out="$(shell_run "$stale" "$ISO/fpath" "$ISO/bin" "source '$SNIPPETS/65-claude-screen.zsh'" \
  "source '$SNIPPETS/97-claude-screen-completion.zsh'")"
check "97 maps claude-screen to claude's completion after a stale dump" "_claude|_claude" "$out"

out="$(shell_run "$ISO/fresh.zcompdump" "$ISO/fpath" "$ISO/bin" "source '$SNIPPETS/65-claude-screen.zsh'" \
  "source '$SNIPPETS/97-claude-screen-completion.zsh'")"
check "97 maps claude-screen with no dump yet" "_claude|_claude" "$out"

# Without a completion for claude (no zplug plugin), no mapping that would make TAB fail.
out="$(shell_run "$ISO/nocomp.zcompdump" "" "$ISO/bin" "" \
  "source '$SNIPPETS/97-claude-screen-completion.zsh' || print sourcing-failed")"
check "no claude completion: no mapping, sourcing succeeds" "none|none" "$out"

# Without the launcher, claude is not aliased and needs no mapping.
out="$(shell_run "$stale" "$ISO/fpath" "" "" \
  "source '$SNIPPETS/97-claude-screen-completion.zsh' || print sourcing-failed")"
check "no claude-screen: no mapping, sourcing succeeds" "none|_claude" "$out"

# 65 must not register the mapping itself: that is the placement the stale dump undoes.
grep -q compdef "$SNIPPETS/65-claude-screen.zsh" \
  && bad "65 does not call compdef" || ok "65 does not call compdef"

echo "$pass passed, $fail failed"
(( fail == 0 ))
