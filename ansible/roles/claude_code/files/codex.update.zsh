# The Codex CLI is installed with `npm install -g @openai/codex@<pinned version>`
# (see claude_code_codex_version), so ask the npm registry for the latest
# release and confirm before installing it.
# This only updates the local installation: the Ansible role pins the version,
# so a later playbook run puts the pinned one back.
command -v npm >/dev/null 2>&1 || return 0
command -v codex >/dev/null 2>&1 || return 0

local codex_current codex_latest
codex_current="$(codex --version 2>/dev/null | awk '{print $NF}')"
codex_latest="$(npm view @openai/codex version 2>/dev/null)"
[[ -n $codex_current && -n $codex_latest ]] || return 0
[[ $codex_current != "$codex_latest" ]] || return 0

print -r -- "codex 有可用的更新：${codex_current} -> ${codex_latest}"
echo -n "是否執行 npm install -g \"@openai/codex@${codex_latest}\"？[y/N] "
if read -q; then
  echo
  npm install -g "@openai/codex@${codex_latest}" || return $?
else
  echo
fi
