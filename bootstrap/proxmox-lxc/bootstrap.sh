#!/usr/bin/env bash
# bootstrap/proxmox-lxc/bootstrap.sh
# Prepare SSH access to a Proxmox LXC for Ansible push provisioning.
# Run this from the CONTROLLER (not inside the LXC).
set -euo pipefail

LXC_IP="${1:-}"
SSH_USER="${2:-root}"

if [[ -z "$LXC_IP" ]]; then
  echo "Usage: $0 <LXC_IP> [ssh_user]"
  echo "  <LXC_IP>   IP address or hostname of the LXC container"
  echo "  [ssh_user] SSH user to connect as (default: root)"
  exit 1
fi

echo "==> Checking SSH connectivity to ${SSH_USER}@${LXC_IP} ..."
ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "${SSH_USER}@${LXC_IP}" echo "SSH OK"

echo "==> Checking Python3 on target ..."
ssh "${SSH_USER}@${LXC_IP}" "command -v python3 || apt-get install -y python3"

echo "==> Target is ready. Add it to ansible/inventory/pve_hosts.yml under the 'lxc' group."
echo "    Then run: bin/setup-lxc --host <name_under_pve_hosts.yml>"
