# Bootstrap Requirements

Minimum requirements before running provisioning for each environment.

---

## Proxmox VM

**Execution model:** Ansible push from controller over SSH

### What must exist before provisioning starts

| Requirement | Notes |
|-------------|-------|
| SSH server running on target | `openssh-server` must be installed |
| SSH public key installed | Controller must be able to log in |
| Reachable IP / hostname | Must be accessible from the controller |
| Python 3 on target | Required by Ansible; pre-installed on Ubuntu 24.04 |

### Who executes provisioning

The **controller** (your workstation or another machine) runs `ansible-playbook` and pushes tasks to the target VM over SSH.

### Ansible installation

Ansible must be installed **on the controller**, not the target VM.

```bash
pip install ansible
# or
apt install ansible
```

### What the bootstrap covers

No automation script is provided for VMs — see `bootstrap/proxmox-vm/README.md`.  
Cloud-init can inject SSH keys and network configuration.

---

## Proxmox LXC

**Execution model:** Ansible push from controller over SSH

### What must exist before provisioning starts

| Requirement | Notes |
|-------------|-------|
| SSH server running on target | `apt install openssh-server` |
| SSH public key installed | `ssh-copy-id root@<LXC_IP>` |
| Reachable IP / hostname | Must be accessible from the controller |
| Python 3 on target | The bootstrap script will install it if missing |

### Who executes provisioning

The **controller** runs `ansible-playbook` and pushes tasks to the LXC container over SSH.

### What the bootstrap script does

`bootstrap/proxmox-lxc/bootstrap.sh <LXC_IP>` will:
1. Verify SSH connectivity
2. Install Python 3 on the target if absent
3. Print instructions for running the playbook

---

## Docker Container

**Execution model:** Ansible local (runs inside the container)

### What must exist before provisioning starts

| Requirement | Notes |
|-------------|-------|
| The container is running | `docker run ...` or compose-managed |
| This repo is available inside the container | Mount or COPY it in |

### No SSH required

Provisioning runs locally inside the container via `ansible-playbook -c local`.

### What the bootstrap script does

`bootstrap/container/bootstrap.sh` (run inside the container) will:
1. Install `python3`, `pip3`, `git` via apt
2. Install `ansible` via pip
3. Run `ansible-playbook -c local -i inventory/local.yml playbooks/container.yml`

---

## Devcontainer

**Execution model:** Ansible local (runs inside the devcontainer)

### What must exist before provisioning starts

Nothing beyond what VS Code's devcontainer setup provides. The bootstrap script  
handles all prerequisites itself.

### No SSH required

Provisioning runs locally inside the devcontainer.

### What the bootstrap script does

`bootstrap/devcontainer/bootstrap.sh` (run inside the devcontainer) will:
1. Install `python3`, `pip3`, `git` via apt if absent
2. Install `ansible` via pip
3. Run `ansible-playbook -c local -i inventory/local.yml playbooks/devcontainer.yml`

### Usage

```bash
# Inside devcontainer:
bin/setup-devcontainer
```

Or reference `bootstrap/devcontainer/bootstrap.sh` from your dotfiles repo `install.sh`.
