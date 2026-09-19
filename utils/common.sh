#!/usr/bin/env bash
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

# Create ansible/inventory/local.yml from local.yml.example when it is missing.
# local.yml is git-ignored (it may hold claude_code_sonarqube_token), so a
# fresh clone, or a checkout that just pulled the commit which untracked it,
# has none. The example is usable as-is (localhost only), so this needs no
# input from the user.
#
# Call this BEFORE reexec_with_sudo: afterwards we are root, and a file created
# then would be root-owned inside the invoking user's checkout, leaving them
# unable to edit it. When already started via `sudo bin/setup-*` (root from the
# beginning), the file is handed to SUDO_USER for the same reason.
#
# Never fails: a missing local.yml only costs the optional inventory vars.
ensure_local_inventory() {
  local repo_root="$1"
  local inventory_dir="${repo_root}/ansible/inventory"

  [[ -e "${inventory_dir}/local.yml" ]] && return 0

  if install -m 0600 "${inventory_dir}/local.yml.example" "${inventory_dir}/local.yml"; then
    [[ -n "${SUDO_USER:-}" ]] && chown "${SUDO_USER}:" "${inventory_dir}/local.yml" 2>/dev/null
    echo "==> Created ansible/inventory/local.yml from local.yml.example"
  else
    echo "Warning: could not create ${inventory_dir}/local.yml from local.yml.example" >&2
  fi
  return 0
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
