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

echo "==> Installing Ansible ..."
apt-get install -yqq ansible

echo "==> Running container profile ..."
cd "${REPO_ROOT}/ansible"
ansible-playbook -c local -i inventory/local.yml playbooks/container.yml "$@"

echo "==> Done."
