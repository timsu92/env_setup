# Bootstrap: Proxmox VM

Proxmox VMs use the **Ansible push model** — provisioning runs from a controller machine and pushes to the target VM over SSH.

## Prerequisites before running

The Ansible controller needs:
- Ansible installed (`pip install ansible` or distro package)
- SSH access to the target VM
- The target VM added to `ansible/inventory/pve_hosts.yml`

The target VM needs:
- SSH server running (`openssh-server`)
- SSH public key installed for your login user (typically `root`)
- Python 3 available (`python3`)
  - On Ubuntu 24.04 this is installed by default
  - If missing: `apt install python3`
- Network connectivity from controller to the VM

## No bootstrap script required

For Proxmox VMs, no bootstrap script is needed on the controller side beyond ensuring connectivity. Cloud-init or manual setup can inject the SSH key.

## Running provisioning

```bash
# 1. Copy and fill in the inventory
cp ansible/inventory/pve_hosts.yml.example ansible/inventory/pve_hosts.yml
# Edit pve_hosts.yml with the VM inventory entry

# 2. Run the base VM profile
bin/setup-vm --host pve-vm-01

# 3. Or run the full daily-driver profile
bin/setup-vm --host pve-vm-01 --profile pve-daily
```
