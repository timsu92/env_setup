# bun updates itself via `bun upgrade`, but that has no dry-run mode and runs
# without asking, so look up the latest release first and only ask when there
# is a newer one. The latest tag comes from the redirect of
# github.com/oven-sh/bun/releases/latest (-> .../releases/tag/bun-vX.Y.Z), which
# needs no API token. If the lookup fails, stay silent like the other update
# scripts do.
# This only updates the local installation: the Ansible role pins the version
# (bun_version), so a later playbook run puts the pinned one back.
# The completion file is a snapshot of `bun completions`, so it is regenerated
# after an upgrade to pick up new commands. The redirect is load-bearing: with a
# TTY stdout, `bun completions` would install ~/.bun/_bun instead of printing.
# Canary builds are not handled: the role only installs stable releases.
command -v bun >/dev/null 2>&1 || return 0
command -v curl >/dev/null 2>&1 || return 0

local bun_current bun_latest
bun_current="$(bun --version 2>/dev/null)"
bun_latest="$(curl -fsSLI --max-time 10 -o /dev/null -w '%{url_effective}' \
  https://github.com/oven-sh/bun/releases/latest 2>/dev/null)"
bun_latest="${bun_latest##*/bun-v}"
[[ -n $bun_current && $bun_latest == <->.<->.<-> ]] || return 0

autoload -Uz is-at-least
is-at-least "$bun_latest" "$bun_current" && return 0

print -r -- "bun 有可用的更新：${bun_current} -> ${bun_latest}"
echo -n "是否執行 bun upgrade？[y/N] "
if read -q; then
  echo
  bun upgrade || return $?
  SHELL=zsh bun completions >"${HOME}/.config/zsh/completions/_bun"
else
  echo
fi
