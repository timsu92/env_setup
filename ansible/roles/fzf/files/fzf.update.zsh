# NOTE: updating fzf's checkout isn't enough on its own -
# ansible/roles/fzf/tasks/main.yml's "Run fzf setup" task is what actually
# builds/downloads the fzf binary and generates the completion/keybinding
# shell integration for the checked-out version. Replicate that here:
# compare the commit before/after the shared helper runs, and re-run
# install only if it moved.
local _fzf_dir="${HOME}/.fzf"
[[ -d "${_fzf_dir}/.git" ]] || return 0

local _fzf_before
_fzf_before="$(git -C "$_fzf_dir" rev-parse --short HEAD 2>/dev/null)"

_aptu_update_git_repo "$_fzf_dir" "fzf" tag

if [[ -n "$_fzf_before" && "$(git -C "$_fzf_dir" rev-parse --short HEAD 2>/dev/null)" != "$_fzf_before" ]]; then
  echo "fzf 已更新，重新執行 install..."
  "${_fzf_dir}/install" --completion --key-bindings --no-update-rc --no-bash --no-fish
fi
