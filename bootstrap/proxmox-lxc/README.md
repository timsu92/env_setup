# Bootstrap: Proxmox LXC

Proxmox LXC containers use the **Ansible push model** — provisioning runs from a controller machine over SSH.

## Prerequisites before running

The Ansible controller needs:
- Ansible installed
- SSH access to the target LXC (public key installed for your user)

The target LXC needs:
- SSH server running: `apt install openssh-server`
- Your SSH public key installed: `ssh-copy-id root@<LXC_IP>`

## Steps

```bash
# 1. Run bootstrap to verify connectivity and Python
bash bootstrap/proxmox-lxc/bootstrap.sh <LXC_IP>

# 2. Add the LXC to inventory
cp ansible/inventory/pve_hosts.yml.example ansible/inventory/pve_hosts.yml
# Edit pve_hosts.yml and add the LXC under the 'lxc' group

# 3. Provision
bin/setup-lxc --host <LXC_IP>
```
