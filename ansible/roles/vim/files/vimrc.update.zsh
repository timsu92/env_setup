# NOTE: unlike a plain git-tracked repo, updating vimrc's checkout isn't
# enough on its own - ansible/roles/vim/tasks/main.yml only runs install.sh
# when the checkout actually changed ("Run vimrc install.sh", gated on
# vim_vimrc_repo_checkout.changed), because that script is what actually
# installs/updates plugins for the new state. Replicate that here: compare
# the commit before/after the shared helper runs, and re-run install.sh
# only if it moved.
local _vimrc_dir="${HOME}/vimrc"
[[ -d "${_vimrc_dir}/.git" ]] || return 0

local _vimrc_before
_vimrc_before="$(git -C "$_vimrc_dir" rev-parse --short HEAD 2>/dev/null)"

_aptu_update_git_repo "$_vimrc_dir" "vimrc" head

if [[ -n "$_vimrc_before" && "$(git -C "$_vimrc_dir" rev-parse --short HEAD 2>/dev/null)" != "$_vimrc_before" ]]; then
  echo "vimrc 已更新，重新執行 install.sh..."
  ( . "${HOME}/.nvm/nvm.sh" 2>/dev/null; cd "$_vimrc_dir" && bash install.sh )
fi
