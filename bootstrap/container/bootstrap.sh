#!/usr/bin/env bash
# bootstrap/container/bootstrap.sh
# Install Ansible locally inside the container and run the container profile.
# Run this INSIDE the Docker container.
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
fi

echo "==> Running container profile ..."
cd "${REPO_ROOT}/ansible"
LC_ALL="$ansible_locale" ansible-playbook -c local -i inventory/local.yml playbooks/container.yml "$@"

echo "==> Done."
