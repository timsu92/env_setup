command -v uv >/dev/null 2>&1 || return 0
uv tool list 2>/dev/null | grep -q '^claude-swap ' || return 0
uv tool upgrade claude-swap

# The completion parses `claude-swap --help` and `list --json` at TAB time, so
# an upgrade that reshuffles either would silently leave it with no candidates.
# Run the same parser once here, in a subshell so its functions don't leak into
# this session, and say so if it comes back empty.
local claude_swap_comp="${HOME}/.config/zsh/completions/_claude-swap"
[[ -r $claude_swap_comp ]] || return 0
if ! (
  source "$claude_swap_comp"
  typeset -a verbs opt_names
  typeset -A verb_desc verb_arg1 verb_arg2 opt_meta
  _claude_swap_parse_help
  (( ${verbs[(Ie)list]} && ${verbs[(Ie)switch]} && ${opt_names[(Ie)--json]} )) &&
    command claude-swap list --json 2>/dev/null | python3 -I -c '
import json, sys
for a in json.load(sys.stdin)["accounts"]:
    a["number"], a["email"]
'
); then
  print -u2 "警告：claude-swap 升級後，zsh 補全解析 --help 或 list --json 失敗，補全可能失效。請更新 ~/.config/zsh/completions/_claude-swap 的解析邏輯"
fi
