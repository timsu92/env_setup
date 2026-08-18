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
├─ .ansible-lint             # Ansible-lint configuration
├─ playbook_vars/
│  └─ local.yml              # shared vars for local execution profiles
├─ inventory/
│  ├─ local.yml              # localhost for local execution profiles
│  ├─ pve_hosts.yml.example  # template for remote PVE hosts
│  └─ group_vars/            # inventory-scoped group variables
├─ playbooks/                # profiles (one per target environment)
└─ roles/                    # reusable capability roles

utils/
├─ common.sh                 # shared bash helpers for bin/setup-*
└─ locale.sh                 # UTF-8 locale detection/generation

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

#### Infrastructure and environment setup

| Role | Description |
|------|-------------|
| `common_base` | apt update + upgrade |
| `apt_cacher_ng` | apt-cacher-ng proxy auto-detection |
| `apt_nycu_mirror` | NYCU apt mirror (Ubuntu + Debian) |
| `curl_or_wget` | curl/wget bootstrap dependency |
| `locale_term_env` | locale + terminal environment variables |
| `pve_cloud_init_dns` | Proxmox cloud-init DNS override |
| `zsh_config_dirs` | zsh config directory scaffolding |

#### Tools and services

| Role | Description |
|------|-------------|
| `git` | git + global config |
| `tmux` | terminal multiplexer |
| `zsh` | zsh core + modular loader |
| `nvm` | nvm install + zsh nvm snippets |
| `node` | Node.js install via nvm |
| `uv` | uv installer + shell completions |
| `zplug` | zplug + plugin snippets |
| `starship` | starship + prompt snippet |
| `docker_rootful` | Docker Engine (rootful) |
| `docker_rootless` | Docker Engine (rootless mode) |
| `wireguard_client` | WireGuard client config deployment + key output for server peer |
| `nfs_client` | NFS client |
| `dns_over_tls` | systemd-resolved DNS-over-TLS |
| `wsl_my_documents` | ~/documents → Windows Documents symlink |
| `proxmox_guest` | qemu-guest-agent + user creation |
| `sshd` | SSH server hardening + config |

#### Applications

| Role | Description |
|------|-------------|
| `vim` | vim editor |
| `helm` | Helm (k8s package manager) |
| `xpra` | Xpra remote desktop |
| `pigz` | pigz (parallel gzip) |
| `fzf` | fzf fuzzy finder |
| `github_cli` | GitHub CLI (gh) |
| `htop` | htop process viewer |
| `claude_code` | Claude Code + rtk |

---

## How to run

### WSL daily driver (local)

```bash
bin/setup-vm
# or explicitly:
bin/setup-vm --profile wsl
```

### Proxmox VM

**Prerequisites**: the target VM needs `openssh-server` running, an SSH
public key installed for the login user (`ansible_user` in `pve_hosts.yml`)
, and `python3` available (installed by default on Ubuntu
24.04; otherwise `apt install python3`). Cloud-init or manual setup can
inject the key — no bootstrap script is needed beyond ensuring
connectivity from the controller.

```bash
# 1. Copy and configure inventory
cp ansible/inventory/pve_hosts.yml.example ansible/inventory/pve_hosts.yml
# Edit and add your VM under the 'vm' group

# 2. Resend hostname to DNS server if needed (optional, only if ansible_host is a resolvable hostname that needs to be updated in DNS)
# Mostly, VMs use systemd-networkd with DHCP, so the command below is usable
# Run the command on the VM itself:
sudo networkctl reconfigure eth0

# 3. Base setup
bin/setup-vm --host pve-vm-01

# 4. Full daily-driver setup
bin/setup-vm --host pve-vm-01 --profile pve-daily
```

### Proxmox LXC

**Prerequisite**: in the Proxmox WebUI, give the container's `root` account
an SSH public key when creating it (the password field alone is not
enough — provisioning connects over SSH as `root`). Proxmox only ever
provisions `root`; see "Key variables" below for how `setup_user` gets
configured from there.

```bash
# 1. Copy and configure inventory
cp ansible/inventory/pve_hosts.yml.example ansible/inventory/pve_hosts.yml
# Edit and add your LXC under the 'lxc' group

# 2. Provision
bin/setup-lxc --host pve-lxc-01
```

**Security note** — On LXC, provisioning runs as `root`. Afterwards, any SSH
key that can log in as `root` can also log in as `setup_user`, and
`setup_user` has passwordless `sudo`.

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

Can also be invoked from a VS Code dotfiles repository's `install.sh`, or
called directly from a devcontainer lifecycle hook.

---

## Zsh Module Loading Model

The zsh setup is modular and split into two phases:

- `~/.zshenv` loads `~/.config/zsh/non-interactive/*.zsh(Non)`
- `~/.zshrc` (interactive shells only) loads `~/.config/zsh/interactive/*.zsh(Non)`

Loader behavior:

- Uses `Non` glob qualifier to keep numeric ascending order and safely skip when no files exist.
- Records failed module files and prints them to stderr after each phase.

Recommended ordering convention:

- `0x`: zsh core setup (must run first)
- `1x`: env vars and PATH
- `6x`: normal app/plugin setup
- `9x`: late hooks / final overrides

Examples in this repo:

- `00-zsh-core.zsh` in `interactive` for base shell settings
- `60-zplug-init.zsh` then `69-zplug-settings.zsh` for plugin manager init and plugin settings
- `95-zplug-load.zsh` for late zplug initialization to load all plugins

---

## Extending the project

### Adding a new role

1. Create `ansible/roles/<role_name>/tasks/main.yml`
2. Optionally add `defaults/main.yml`, `templates/`, `files/`, `handlers/main.yml`
3. Add the role to relevant playbooks in `ansible/playbooks/`

### Adding a new profile

1. Create `ansible/playbooks/<profile-name>.yml`
2. Choose a named inventory group for the target environment
3. List roles in execution order
4. Add a corresponding entry to `bin/` if needed

---

## Key variables

Defined in `ansible/inventory/group_vars/all.yml`, overridable per group or host:

| Variable | Default | Description |
|----------|---------|-------------|
| `setup_user` | current user | User whose dotfiles are configured |
| `setup_user_home` | `/home/<setup_user>` | Home directory |
| `git_user_name` | `timsu92` | git global user.name |
| `git_user_email` | `33785401+...` | git global user.email |

For PVE VM/LXC, `setup_user` is overridden to `tim` in `inventory/group_vars/vm.yml` and `inventory/group_vars/lxc.yml`.

For Proxmox push-model targets, `ansible_user` (set per host in
`pve_hosts.yml`) is a separate axis from `setup_user`: it is who Ansible
connects over SSH as, not who gets configured. LXC pins `ansible_user: root`
permanently (Proxmox provisions no other account); VM uses `setup_user`
directly since cloud-init already installs its key. See
`ansible/roles/proxmox_guest/tasks/login-access.yml` for how LXC grants
`setup_user` login access from `root`'s inherited key.

---

## Notes

- **WireGuard keys**: checkout `ansible/inventory/pve_hosts.yml.example` for example inventory vars needed to set up a WireGuard client.
