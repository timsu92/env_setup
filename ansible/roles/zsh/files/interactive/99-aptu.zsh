# Run "$@" with root privileges: skip sudo entirely when already root (e.g.
# a Docker/devcontainer profile), otherwise require sudo to be available
# (WSL/PVE VM/LXC always have it, since setup_user needs it for
# provisioning in the first place).
_aptu_sudo() {
  emulate -L zsh
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    print -u2 "_aptu_sudo: need root privileges to run '$*' but sudo is unavailable"
    return 1
  fi
}

# aptu: update everything registered under ~/.config/zsh/update/*.update.zsh.
# Each *.update.zsh file performs its own update when sourced; see the
# per-role files under ~/.config/zsh/update/ for what's registered.
aptu() {
  emulate -L zsh
  local f
  typeset -a _aptu_errors
  for f in "${HOME}/.config/zsh/update/"*.update.zsh(N); do
    if ! source "$f"; then
      _aptu_errors+=("$f")
    fi
  done
  if (( ${#_aptu_errors[@]} )); then
    print -u2 "以下更新腳本執行失敗："
    printf '  %s\n' "${_aptu_errors[@]}" >&2
  fi
}

# Shared helper for *.update.zsh files that manage a git-cloned repo pinned
# by an Ansible role (via `version`/`refspec` on the `ansible.builtin.git`
# task). Only ever touches the local checkout — the Ansible role keeps
# whatever pin it has, so a future playbook re-run can reset a tag- or
# SHA-pinned repo back to that pin, undoing this update.
#
# Usage: _aptu_update_git_repo <repo_path> <display_name> <pin_style> [<branch>]
#   pin_style: tag  - track the latest tag (sorted by version)
#              head - track the latest commit on <branch> (or origin's
#                     default branch if <branch> is omitted)
#              sha  - same lookup as head; named separately because the
#                     role pins an exact commit rather than tracking HEAD,
#                     even though "newest commit on the branch it came from"
#                     is the same comparison
_aptu_update_git_repo() {
  emulate -L zsh
  local repo_path="$1" name="$2" pin_style="$3" branch="${4:-}"
  [[ -d "${repo_path}/.git" ]] || return 0

  local current_hash current
  current_hash="$(git -C "$repo_path" rev-parse --short HEAD 2>/dev/null)" || return 0
  current="$(git -C "$repo_path" log -1 --format='%h (%cd)' --date=short 2>/dev/null)"

  local target_hash
  case "$pin_style" in
    tag)
      target_hash="$(git -C "$repo_path" ls-remote --tags --sort=-v:refname origin 2>/dev/null | head -1 | awk '{print $1}')"
      ;;
    head | sha)
      [[ -n "$branch" ]] || branch="$(git -C "$repo_path" remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}')"
      [[ -n "$branch" ]] || return 0
      target_hash="$(git -C "$repo_path" ls-remote origin "refs/heads/${branch}" 2>/dev/null | awk '{print $1}')"
      ;;
    *)
      print -u2 "_aptu_update_git_repo: unknown pin style '${pin_style}'"
      return 1
      ;;
  esac
  [[ -n "$target_hash" ]] || return 0
  [[ "$target_hash" == "${current_hash}"* ]] && return 0

  git -C "$repo_path" fetch --quiet --depth 1 origin "$target_hash" 2>/dev/null
  local target
  target="$(git -C "$repo_path" log -1 --format='%h (%cd)' --date=short "$target_hash" 2>/dev/null)"
  [[ -n "$target" ]] || return 0

  echo -n "${name} 在 ${repo_path}：${current} → ${target}，是否更新？[y/N] "
  if read -q; then
    echo
    git -C "$repo_path" checkout --quiet "$target_hash"
  else
    echo "\n略過 ${name}。"
  fi
}
