# `sonar update` upgrades sonarqube-cli in place but does not ask, so check
# first and confirm. It re-runs the official install.sh, which appends a PATH
# line to ~/.zshrc; PROFILE=/dev/null tells that script to leave rc files alone
# (PATH is set by 14-sonarqube-cli-path.zsh instead).
# This only updates the local installation: the Ansible role pins the version,
# so a later playbook run puts the pinned one back.
command -v sonar >/dev/null 2>&1 || return 0

local sonarqube_cli_status
sonarqube_cli_status="$(sonar update --status 2>&1)"
[[ "$sonarqube_cli_status" == *"Update available"* ]] || return 0

print -r -- "sonarqube-cli 有可用的更新："
# Unquoted on purpose: inside double quotes the nested (f) array would be
# joined into one string before the filter sees it.
print -rl -- ${(M)${(f)sonarqube_cli_status}:#*ersion:*}
echo -n "是否執行 sonar update？[y/N] "
if read -q; then
  echo
  PROFILE=/dev/null sonar update || return $?
else
  echo
fi
