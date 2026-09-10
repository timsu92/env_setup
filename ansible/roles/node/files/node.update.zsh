# node itself has no self-update command (it's whatever version(s) `nvm
# install` downloaded). Unlike uv/zplug, nvm *does* offer a real "what's new"
# preview here (`nvm version-remote --lts` vs. the locally resolved `default`
# alias), so this follows the git-repo helper's style — list old -> new,
# read -q to confirm — rather than running unconditionally.
[[ -s "${HOME}/.nvm/nvm.sh" ]] || return 0
export NVM_DIR="${HOME}/.nvm"
\. "${NVM_DIR}/nvm.sh"
command -v nvm >/dev/null 2>&1 || return 0

current="$(nvm version default 2>/dev/null)"
[[ -n "$current" && "$current" != "N/A" ]] || return 0
latest="$(nvm version-remote --lts 2>/dev/null)"
[[ -n "$latest" && "$latest" != "N/A" ]] || return 0
[[ "$current" == "$latest" ]] && return 0

echo -n "node default 版本 ${current} → 最新 LTS ${latest}，是否更新？[y/N] "
if read -q; then
  echo
  # --reinstall-packages-from carries over globally-installed npm packages;
  # --latest-npm bumps npm too (reinstalling packages alone does not, per
  # the nvm README). `nvm install` only auto-sets `default` on the very
  # first-ever install, so repoint it explicitly afterward.
  nvm install --reinstall-packages-from=current --latest-npm 'lts/*'
  nvm alias default 'lts/*'
else
  echo "\n略過 node。"
fi
