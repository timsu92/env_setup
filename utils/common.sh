#!/usr/bin/env bash
# utils/common.sh
# Shared helpers for bin/setup-* entrypoints. Source, do not execute.

# Print $1's home directory. Falls back to a conventional guess
# (/root or /home/$1) if the account doesn't exist in passwd yet.
resolve_home() {
  local user="$1"
  local home
  home="$(getent passwd "$user" | cut -d: -f6)"
  if [[ -n "$home" ]]; then
    printf '%s\n' "$home"
  elif [[ "$user" == "root" ]]; then
    printf '/root\n'
  else
    printf '/home/%s\n' "$user"
  fi
}

# Populate the global array CALLER_ANSIBLE_VARS with -e setup_user=... -e
# setup_user_home=... for the user who invoked the (possibly sudo'd) script.
# Always prefers SUDO_USER over the current euid so that `sudo bin/setup-*`
# resolves to the human who ran sudo, not to root.
caller_ansible_vars() {
  local caller_user caller_home
  caller_user="${SUDO_USER:-$(id -un)}"
  caller_home="$(resolve_home "$caller_user")"
  # shellcheck disable=SC2034  # consumed by the sourcing bin/setup-* script
  CALLER_ANSIBLE_VARS=(
    -e "setup_user=${caller_user}"
    -e "setup_user_home=${caller_home}"
  )
}

# Re-exec $1 (with the remaining args) under sudo, preserving PATH, unless
# already running as root. Exits with an error if root is required but sudo
# is unavailable. Returns (without exec'ing) only when EUID is already 0.
reexec_with_sudo() {
  local script="$1"
  shift
  if [[ "$EUID" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo env "PATH=${PATH}" bash "$script" "$@"
    else
      echo "Requires root privileges to setup using Ansible." >&2
      echo "Please run this script with sudo or as root." >&2
      exit 1
    fi
  fi
}

# Install Ansible locally if ansible-playbook isn't already on PATH. Only
# for disposable local-model targets (container/devcontainer) — LXC/VM are
# push model and never need Ansible installed on the target itself.
ensure_ansible() {
  if command -v ansible-playbook >/dev/null 2>&1; then
    return 0
  fi

  echo "==> Updating apt cache ..."
  apt-get update -q

  echo "==> Installing Python3, pip3, and git ..."
  apt-get install -y python3 python3-pip git

  echo "==> Installing Ansible ..."
  pip3 install --break-system-packages ansible 2>/dev/null || pip3 install ansible
}
