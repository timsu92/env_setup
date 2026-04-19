#!/usr/bin/env bash
# bootstrap/devcontainer/bootstrap.sh
# Install Ansible locally inside the devcontainer and run the devcontainer profile.
# Designed to be called from a VS Code dotfiles repo or devcontainer lifecycle script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export ANSIBLE_CONFIG="${REPO_ROOT}/ansible.cfg"

echo "==> Updating apt cache ..."
apt-get update -q

echo "==> Installing Python3, pip3, and git ..."
apt-get install -y python3 python3-pip git

echo "==> Installing Ansible ..."
pip3 install --break-system-packages ansible 2>/dev/null || pip3 install ansible

# Ensure locale for Ansible is UTF-8
# shellcheck source=../../utils/locale.sh
source "${REPO_ROOT}/utils/locale.sh"
if ! ansible_locale="$(get_valid_utf8_locale)"; then
  echo "Error: No valid UTF-8 locale found. Please ensure a UTF-8 locale is generated and available in the container." >&2
  exit 1
elif [ "${ansible_locale:-}" != "en_US.UTF-8" ] && ! locale_exists "en_US.UTF-8"; then
  # VSCode sets LANG to en_US.UTF-8 if LANG isn't set in advanced
  # regardless of locally available locales
  (generate_en_us_utf8_locale && ansible_locale="en_US.UTF-8") || echo "Warning: Failed to generate en_US.UTF-8 locale, terminals in VS Code may display incorrectly."
fi

echo "==> Running devcontainer profile ..."
cd "${REPO_ROOT}/ansible"
LC_ALL="$ansible_locale" ansible-playbook -c local -i inventory/local.yml playbooks/devcontainer.yml "$@"

echo "==> Done."
