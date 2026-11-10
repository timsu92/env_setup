# gopls is installed with `go install ...@<pinned version>` (see
# claude_code_gopls_version), which has no update command of its own, so ask the
# module proxy for the latest release and confirm before installing it.
# This only updates the local installation: the Ansible role pins the version,
# so a later playbook run puts the pinned one back.
command -v go >/dev/null 2>&1 || return 0
command -v gopls >/dev/null 2>&1 || return 0

local gopls_current gopls_latest
gopls_current="$(gopls version 2>/dev/null | awk 'NR==1{print $2}')"
# @latest skips pre-releases, same as a plain `go install ...@latest` would.
gopls_latest="$(go list -m -f '{{.Version}}' golang.org/x/tools/gopls@latest 2>/dev/null)"
[[ -n $gopls_current && -n $gopls_latest ]] || return 0
[[ $gopls_current != "$gopls_latest" ]] || return 0

print -r -- "gopls 有可用的更新：${gopls_current} -> ${gopls_latest}"
echo -n "是否執行 go install？[y/N] "
if read -q; then
  echo
  go install "golang.org/x/tools/gopls@${gopls_latest}" || return $?
else
  echo
fi
