# Personal Environment Setup

A modular, idempotent provisioning project for my personal environments using Ansible.

## Supported targets

| Target | Execution model | Profile |
|--------|-----------------|---------|
| WSL daily driver | Ansible local | `vm-daily-wsl` |
| Proxmox VM (base) | Ansible push (SSH) | `vm-pve` |
| Proxmox VM (full) | Ansible push (SSH) | `vm-daily-pve` |
| Proxmox LXC | Ansible push (SSH) | `lxc-pve` |
| Docker container | Ansible local | `container` |
| Devcontainer | Ansible local | `devcontainer` |

---

## Architecture

```
ansible/
├─ ansible.cfg               # Ansible configuration
├─ inventory/
│  ├─ local.yml              # localhost for local execution
│  └─ pve_hosts.yml.example  # template for remote PVE hosts
├─ group_vars/               # per-group variable overrides
├─ playbooks/                # profiles (one per target environment)
└─ roles/                    # reusable capability roles

bootstrap/
├─ proxmox-vm/               # documentation for VM prerequisites
├─ proxmox-lxc/              # bootstrap script + README for LXC
├─ container/                # bootstrap script for Docker container
└─ devcontainer/             # bootstrap script for devcontainer

bin/
├─ setup-vm                  # WSL or Proxmox VM entrypoint
├─ setup-lxc                 # Proxmox LXC entrypoint
├─ setup-container           # Docker container entrypoint
└─ setup-devcontainer        # Devcontainer entrypoint
```

### Profiles

Profiles are top-level Ansible playbooks that represent a complete target environment. They compose roles in a clear, intentional order.

### Roles

Roles implement individual capabilities. Each role encapsulates everything needed for one tool or service: installation, configuration, and post-install actions.

| Role | Description |
|------|-------------|
| `common_base` | apt update + upgrade |
| `ap_cacher_ng` | apt-cacher-ng proxy auto-detection |
| `apt_nycu_mirror` | NYCU apt mirror (Ubuntu + Debian) |
| `git` | git + global config (~/.gitconfig) |
| `vim` | vim editor |
| `tmux` | tmux + ~/.tmux.conf |
| `zsh` | zsh + zplug + starship + dotfiles |
| `docker_rootful` | Docker Engine (rootful) |
| `docker_rootless` | Docker Engine (rootless mode) |
| `helm` | Helm (k8s package manager) |
| `wireguard_client` | WireGuard client tools |
| `nfs_client` | NFS client |
| `dns_over_tls` | systemd-resolved DNS-over-TLS |
| `xpra` | Xpra remote desktop |
| `pigz` | pigz (parallel gzip) |
| `proxmox_guest` | qemu-guest-agent + user creation |
| `wsl_my_documents` | ~/documents → Windows Documents symlink |

---

## How to run

### WSL daily driver (local)

```bash
bin/setup-vm
# or explicitly:
bin/setup-vm --profile wsl
```

### Proxmox VM

```bash
# 1. Copy and configure inventory
cp ansible/inventory/pve_hosts.yml.example ansible/inventory/pve_hosts.yml
# Edit and add your VM's IP under the 'vm' group

# 2. Base setup
bin/setup-vm --host 192.168.1.10 --profile pve

# 3. Full daily-driver setup
bin/setup-vm --host 192.168.1.10 --profile pve-daily
```

### Proxmox LXC

```bash
# Verify SSH access
bash bootstrap/proxmox-lxc/bootstrap.sh 192.168.1.20

# Provision
bin/setup-lxc --host 192.168.1.20
```

### Docker container

```bash
# Inside the container (from repo root):
bin/setup-container
```

### Devcontainer

```bash
# Inside the devcontainer:
bin/setup-devcontainer
```

---

## Extending the project

### Adding a new role

1. Create `ansible/roles/<role_name>/tasks/main.yml`
2. Optionally add `defaults/main.yml`, `templates/`, `files/`, `handlers/main.yml`
3. Reference docs from `docs/` in comments
4. Add the role to relevant playbooks in `ansible/playbooks/`

### Adding a new profile

1. Create `ansible/playbooks/<profile-name>.yml`
2. Choose `hosts: localhost` (local) or a named inventory group (push)
3. List roles in execution order
4. Add a corresponding entry to `bin/` if needed

---

## Key variables

Defined in `ansible/group_vars/all.yml`, overridable per group or host:

| Variable | Default | Description |
|----------|---------|-------------|
| `setup_user` | current user | User whose dotfiles are configured |
| `setup_user_home` | `/home/<setup_user>` | Home directory |
| `git_user_name` | `timsu92` | git global user.name |
| `git_user_email` | `33785401+...` | git global user.email |

For PVE VM/LXC, `setup_user` is overridden to `tim` in `group_vars/vm.yml` and `group_vars/lxc.yml`.

---

## Notes

- **WireGuard keys**: not managed here. Install wireguard-tools, then configure `/etc/wireguard/wg0.conf` manually.
- **WSL fractional scaling**: requires editing `%USERPROFILE%\.wslgconfig` on Windows — the role prints a reminder.
- **proxmox_guest user creation**: some groups (cdrom, floppy, etc.) may not exist in LXC; errors for those are ignored.
