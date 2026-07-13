# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A modular, idempotent Ansible provisioning project for the author's personal environments (WSL, Proxmox VM, Proxmox LXC, Docker container, devcontainer). See `README.md` for the supported-targets table and the full role catalogue — don't re-derive that here, just read it.

## Commands

Run all commands from the repo root unless noted otherwise.

```bash
# Install/sync Python deps (ansible, ansible-lint) via uv
uv sync
source .venv/bin/activate

# Lint (profile: production, see .ansible-lint.yml)
uv run ansible-lint

# Syntax-check a specific profile playbook without connecting to any host
cd ansible && ansible-playbook --syntax-check -i inventory/local.yml playbooks/vm-daily-wsl.yml

# Dry run against a real target (shows what would change, no actual changes).
# bin/setup-* wrappers only pass through `-e`, not arbitrary flags, so invoke
# ansible-playbook directly for --check:
cd ansible && ansible-playbook -i inventory/pve_hosts.yml -l pve-vm-01 playbooks/vm-daily-pve.yml --check --diff

# Actually provision — always go through bin/, not ansible-playbook directly,
# so ANSIBLE_CONFIG and cwd are set correctly (see "ansible.cfg" below)
bin/setup-vm            # WSL, local
bin/setup-vm --host <h> [--profile pve|pve-daily]   # Proxmox VM, push over SSH
bin/setup-lxc --host <ip>                            # Proxmox LXC, push over SSH
bin/setup-container      # inside a Docker container, local
bin/setup-devcontainer   # inside a devcontainer, local
```

There is no test suite (no CI, no `tests/`) — correctness is validated via `ansible-lint`, `--syntax-check`, and `--check --diff` dry runs against a real or throwaway target.

### ansible.cfg location matters

`ansible.cfg` lives at the **repo root**, not inside `ansible/`, so tools invoked from the repo root (VS Code Ansible extension, `ansible-lint`, `uv run ansible-lint`) pick it up automatically. The `bin/setup-*` scripts explicitly `export ANSIBLE_CONFIG="${REPO_ROOT}/ansible.cfg"` before `cd`-ing into `ansible/` and invoking `ansible-playbook` — replicate that pattern (or run from repo root) if invoking `ansible-playbook` manually, otherwise `roles_path`/`inventory` defaults won't resolve.

## Architecture

### Profiles compose roles; some profiles extend others

`ansible/playbooks/*.yml` are the units you actually run (one per target environment, listed in the README table). Roles are the reusable building blocks in `ansible/roles/`. A profile is just an ordered `roles:` list under a `hosts:` play — the order encodes real dependencies (e.g. `common_base` first, `apt_reboot_if_required` always last across every profile).

`vm-daily-pve.yml` doesn't repeat `vm-pve.yml`'s role list — it does `import_playbook: vm-pve.yml` and then adds a second play with the daily-driver-only roles. When editing either file, remember the daily profile's behavior is the union of both files, not just the one you're looking at.

Roles are parameterized inline where a role supports multiple modes, e.g.:

```yaml
- role: vim
  vars:
    vim_profile: minimal
```

`vim_profile` defaults to `full` (see `roles/vim/defaults/main.yml`) and every push/local profile except the plain WSL/PVE-base ones overrides it to `minimal` — check `defaults/main.yml` for a role before assuming what an omitted var resolves to.

### Variable layering

Three layers apply depending on execution model, later ones win:

1. `ansible/inventory/group_vars/all.yml` — global defaults (`setup_user`, git identity, apt-cacher-ng routing).
2. Push-model group vars: `inventory/group_vars/vm.yml` / `lxc.yml` override `setup_user` to `tim` and enable `apt_cacher_ng_enabled`.
3. Local-model vars: `ansible/playbook_vars/local.yml` (loaded via each local playbook's `vars_files:`) derives `setup_user`/`setup_user_home` from the actual invoking user instead of hardcoding `tim`.

If a variable's value seems wrong for a given target, check which of these three files last touched it for that execution model — `grep` across all three rather than assuming `group_vars/all.yml` is authoritative.

### Role internals: task-file splitting

Roles with more than one logical concern split `tasks/main.yml` into named files and pull them in with `include_tasks`, e.g. `roles/claude_code/tasks/main.yml` includes `claude-swap.yml`, `rtk.yml`, `winlab-skills.yml`, `hung-yi-lee-skill.yml`, `cswap-daemon.yml`. When adding a new sub-concern to an existing role, follow this pattern (new file + `include_tasks` line) instead of growing `main.yml` monolithically.

### `ansible.builtin.git`: `version` / `refspec` / `depth` interaction

This module's shallow-clone support is easy to get wrong silently (Ansible only `module.warn()`s, it doesn't fail) — several roles pin third-party repos to a specific commit, so get this right when adding or editing one:

- `version` is what actually gets checked out at the end (`switch_version()` always runs `git checkout --force <version>` after clone/fetch) — it must always be set to the commit/branch/tag you want, regardless of the other two.
- `depth` is only honored by the module when `version` is `HEAD`, or a branch/tag name, **or** `refspec` is also set. If `version` is a bare commit SHA and `refspec` is absent, Ansible silently drops `--depth` and does a full clone instead (warning: *"Ignoring depth argument. Shallow clones are only available for HEAD, branches, tags or in combination with refspec."*).
- To pin to a specific commit SHA **and** keep it shallow, set `refspec` to that same **full 40-character SHA** (abbreviated SHAs are not fetchable as a ref; GitHub's smart-HTTP backend allows fetching an arbitrary reachable full SHA, not a short one). Do not set `refspec` to the containing branch name instead — if the pinned commit later falls outside that branch's last `depth` commits (because upstream moved on), a fresh shallow clone will fail to fetch the exact commit you pinned.
- If `version` is `HEAD` or an actual branch/tag name, `depth` works with no `refspec` needed.

Reference implementations: `roles/claude_code/tasks/hung-yi-lee-skill.yml` and `roles/claude_code/tasks/winlab-skills.yml` (SHA pin + matching `refspec` + `depth: 1`) vs. `roles/vim/tasks/main.yml` (`version` defaults to `HEAD`, so `depth: 1` alone is enough) vs. `roles/fzf/tasks/main.yml` (`version` is a tag, so `depth: 1` alone is enough).

## Commit message convention

Commits mostly follow `type(scope): summary` (Conventional Commits–ish), where `type` is `feat`/`fix`/`refactor`/`perf`/`docs` and `scope` is the affected role — often abbreviated (`claude` for `claude_code`, `gh` for `github_cli`). Cross-cutting changes omit the scope (`feat: uv`). Match this style for new commits.
