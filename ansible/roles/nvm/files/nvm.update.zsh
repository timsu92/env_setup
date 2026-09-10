# nvm has no first-class self-update command upstream (confirmed against
# the nvm-sh/nvm README: "To install or update nvm, you should run the
# install script"). When the install script had `git` available at
# provision time it clones nvm into NVM_DIR as a real git checkout pinned to
# a tag (see install_nvm_from_git in nvm's install.sh) — which is exactly
# what roles/nvm/tasks/main.yml relies on here. So this reuses the same
# shared git helper other tag-pinned repos (e.g. fzf) use instead of
# reimplementing "re-run the installer". The helper's own `.git` check makes
# this a no-op if nvm somehow ended up installed without git (script-only
# install, no tags to compare against).
_aptu_update_git_repo "${HOME}/.nvm" "nvm" tag
