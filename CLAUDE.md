# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A modular, idempotent Ansible provisioning project for the author's personal environments (WSL, Proxmox VM, Proxmox LXC, Docker container, devcontainer). See `README.md` for the supported-targets table and the full role catalogue — don't re-derive that here, just read it.

## Commands

Run all commands from the repo root unless noted otherwise.

```bash
# Install/sync Python deps (ansible, ansible-lint) via uv.
# Run every ansible tool through `uv run` (not a bare `ansible-playbook` from
# PATH or an activated venv), so the project-pinned version is what executes.
uv sync

# Lint (profile: production, see .ansible-lint.yml)
uv run ansible-lint

# Syntax-check a specific profile playbook without connecting to any host
cd ansible && ANSIBLE_CONFIG=../ansible.cfg uv run ansible-playbook --syntax-check -i inventory/local.yml playbooks/vm-daily-wsl.yml

# Dry run against a real target (shows what would change, no actual changes).
# bin/setup-* wrappers only pass through `-e`, not arbitrary flags, so invoke
# ansible-playbook directly for --check:
cd ansible && ANSIBLE_CONFIG=../ansible.cfg uv run ansible-playbook -i inventory/pve_hosts.yml -l pve-vm-01 playbooks/vm-daily-pve.yml --check --diff

# Actually provision — always go through bin/, not ansible-playbook directly,
# so ANSIBLE_CONFIG and cwd are set correctly (see "ansible.cfg" below)
bin/setup-vm            # WSL, local
bin/setup-vm --host <h> [--profile pve|pve-daily]   # Proxmox VM, push over SSH
bin/setup-lxc --host <ip>                            # Proxmox LXC, push over SSH
bin/setup-container      # inside a Docker container, local
bin/setup-devcontainer   # inside a devcontainer, local
```

There is no test suite (no CI, no `tests/`) — correctness is validated via `ansible-lint`, `--syntax-check`, and `--check --diff` dry runs against a real or throwaway target.

### Verifying a role: run it in Docker, never on the host

Whenever a real (non-`--check`) run is needed — to confirm a role installs, or that a second run reports `changed=0` — do it in a throwaway container with the repo mounted read-only. Running it on the host installs into the developer's real `$HOME` and can edit their dotfiles. Write a one-role playbook with `setup_user`/`setup_user_home` set, put it and the script below outside the repo (e.g. the scratchpad), then run the playbook **twice** and compare the recaps:

```bash
docker run --rm -v "$PWD":/app:ro -v <dir-with-test-playbook>:/scratch:ro ubuntu:24.04 bash -c '
  apt-get update -qq && apt-get install -y -qq curl ca-certificates acl sudo python3 python3-apt
  useradd -m -s /bin/bash tim
  curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
  export UV_PROJECT_ENVIRONMENT=/opt/venv ANSIBLE_CONFIG=/app/ansible.cfg   # /app is read-only: keep the venv elsewhere
  cd /app/ansible && uv sync --project /app --locked
  uv run --project /app --locked ansible-playbook -i localhost, /scratch/test.yml -e ansible_python_interpreter=/usr/bin/python3'
```

`sudo` and `acl` are there because the roles `become_user` an unprivileged `setup_user` (normally installed by `common_base`/`proxmox_guest`, absent from a bare image). Expect the second run to be `changed=0`.

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

The primary glossary of global variables (`setup_user`, `setup_user_home`, git identity) lives in README.md:220-231 — don't duplicate it here. One global var missing from that table: `apt_https_repo_prefix` — any role adding an apt repository over HTTPS must build the URL with `{{ apt_https_repo_prefix }}` (e.g. `roles/docker_rootful/tasks/debian.yml`) instead of hardcoding `https://`. The role doesn't need to know or care whether that resolves to apt-cacher-ng or plain `https://` — that's `apt_cacher_ng_enabled`'s job, not the role's.

Adding a third-party apt repository also means checking its pin priority against the NYCU mirror's. `apt_nycu_mirror` pins `origin "{{ apt_cacher_ng_host if apt_cacher_ng_enabled else '<mirror-host>' }}"` to `501` (`roles/apt_nycu_mirror/tasks/main.yml`). A new repo defaults to APT's standard `500` — if it happens to ship the exact same package (e.g. WakeMeOps carrying a newer `glab` than Ubuntu/Debian's own archive), APT still prefers the mirror at `501` and the new repo's package is silently never installed, even though the repo itself is configured correctly. Give that package its own `/etc/apt/preferences.d/<name>` pinning the new repo's origin to `501` (or higher) — see `Pin glab to the WakeMeOps apt repository` in `roles/gitlab_cli/tasks/main.yml:56-65`.

### Identity model: `ansible_user` vs `setup_user`

Two independent axes, easy to conflate:

| Axis | Variable | Meaning |
|---|---|---|
| Connection identity | `ansible_user` (per host in `pve_hosts.yml`) | who Ansible SSHes in as *during* provisioning |
| Configured identity | `setup_user` (`group_vars/{lxc,vm}.yml`) | who dotfiles/tooling are installed for, *after* provisioning |

They decouple because `ansible.cfg` sets `become = True` / `become_user = root`
globally — every role escalates to root regardless of which account it
connected through. LXC pins `ansible_user: root` permanently (Proxmox
provisions no account but root); VM connects directly as `setup_user`.

`roles/proxmox_guest` is what bridges the two on LXC: it creates `setup_user`,
copies `root`'s `authorized_keys` to it, and grants it passwordless sudo —
only when `ansible_user != setup_user` (see
`roles/proxmox_guest/tasks/login-access.yml`).

**Ordering dependency**: `proxmox_guest` installs `sudo` and creates
`setup_user`. Every role after it in `lxc-pve.yml`/`vm-pve.yml` that uses
`become_user: "{{ setup_user }}"` needs both to already exist —
`proxmox_guest` must stay before every such role in the `roles:` list.

#### Choosing `become_user` per task

Don't default every task to root, and don't reflexively override every task to `setup_user` either — decide per task based on who the *result* needs to belong to, not by copying whatever the previous task in the role did. `roles/vim/tasks/main.yml` shows all three outcomes inside one role:

- `apt` install → leave the global root default alone (system-level, nothing to override).
- `git`-checkout into `{{ vim_repo_dest }}` (under the user's home) and running its `install.sh` → explicit `become_user: "{{ setup_user }}"`, because the checked-out files must be owned by `setup_user` and `$HOME`/`NVM_DIR` must resolve to *their* home, not root's.
- Deploying a static file via `ansible.builtin.copy` → no `become_user` needed at all; `copy` sets `owner`/`group` directly, and root already has permission to chown.

The question to ask for each task: does it need `$HOME` to resolve to `setup_user`'s home, or must the resulting file/directory be owned by `setup_user`? If yes, override `become_user`. If it's system-level (apt, `/etc`, services) or uses a module that can set ownership without actually running as that user, leave the root default in place.

### Role internals: task-file splitting

Roles with more than one logical concern split `tasks/main.yml` into named files and pull them in with `include_tasks`, e.g. `roles/claude_code/tasks/main.yml` includes `claude-swap.yml`, `rtk.yml`, `winlab-skills.yml`, `hung-yi-lee-skill.yml`, `cswap-daemon.yml`. When adding a new sub-concern to an existing role, follow this pattern (new file + `include_tasks` line) instead of growing `main.yml` monolithically.

### Multi-distro support target

Priority order for new roles (highest first): Ubuntu 26/24/22 → Debian 13/12 → Alpine. Most existing roles don't cover all of these yet — check a role's `defaults/main.yml`/`tasks/*.yml` for what it actually handles before assuming full coverage, and extend rather than assume it's already there.

Split into per-OS task files (`tasks/ubuntu.yml`, `tasks/debian.yml`, ..., included conditionally from `tasks/main.yml` on `ansible_facts['distribution']`) when *several* steps differ per distro — see `roles/docker_rootful/tasks/{ubuntu,debian}.yml`: the GPG key URL differs, the legacy-package purge list differs, and even the method used to write the apt source differs (module vs. hand-written file). When nearly every task needs its own OS-specific value, a single file full of per-task conditionals gets harder to read than two plain files. Keep Ubuntu and Debian in one file behind an `ansible_facts['distribution']` conditional only when the difference really is a couple of parameters on an otherwise-identical task (e.g. just the repo URL path or `signed_by` value) — don't split for splitting's sake.

### Zsh dotfile placement

A role that needs to add shell config must not write directly to `~/.zshrc`/`~/.zshenv`. Deploy a numbered snippet into `~/.config/zsh/{interactive,non-interactive}/` instead — see README.md:176-199 for the loader model and numbering convention (`0x` core, `1x` env/PATH, `6x` app/plugin, `9x` late hooks).

Before doing that, check the installer's own script/flags: many install scripts try to append their own integration lines to `~/.bashrc`/`~/.zshrc`, which would conflict with the numbered-snippet system. Suppress that and let the role's snippet be the only integration point — see `roles/fzf/tasks/main.yml`'s `install --completion --key-bindings --no-update-rc --no-bash --no-fish`, and its update script `roles/fzf/files/fzf.update.zsh:17` re-passing the same flags so a re-install triggered by `aptu` doesn't silently reintroduce rc edits.

A role's `files/` mirrors the directory each snippet is deployed to: `files/non-interactive/NN-<tool>.zsh` and `files/interactive/NN-<tool>.zsh` (see `roles/nvm/files/`), with `<program>.update.zsh` directly under `files/`. Don't drop a snippet flat into `files/` — the sub-directory is what says which loader picks it up, and a PATH/env snippet belongs in `non-interactive/` so scripts and non-interactive shells see it too.

### Piping downloaded files to shells

Don't pipe a downloaded file into a shell in one `command`/`shell` task (`command-instead-of-module` from lint, and the download can't be told apart from the install for idempotence). Split it in three tasks — see `roles/bun/tasks/main.yml`:

1. `ansible.builtin.get_url` to `/tmp/<tool>-install.sh` (`mode: "0700"`, owned by the user who will run it) with `changed_when: false` — a download is not a change to the machine, and doing it unconditionally keeps the run free of `stat`/`when` bookkeeping.
2. Run the script with `ansible.builtin.command` and a `creates:` pointing at the installed binary, so **this** task is the one that reports `changed` — and nothing else does on the second run.
3. `ansible.builtin.file` `state: absent` on the script, also `changed_when: false`.

If the file is only *read* — e.g. its content is written out with `ansible.builtin.copy` and never executed — skip the file: fetch it with `ansible.builtin.uri` and `return_content: true`, register the result, and use the variable in the later task.

### Required role files, dependencies, and updates

README.md:203-209 lists which files a role *can* have; this expands on *when*:

- **`meta/main.yml`**: declare a dependency here only for another *Ansible role* that must run first (e.g. `roles/zplug/meta/main.yml` depends on `locale_term_env`, `zsh`, `vim`, `node`). It doesn't cover apt packages. In particular `curl_or_wget` only guarantees *one of* curl/wget: if an script calls `curl` or `wget` specifically (check the script), `apt`-install `curl` in the role's own tasks instead of depending on `curl_or_wget`.
- **apt prerequisites**: install them at the top of the role's own `tasks/*.yml`, even if every profile you personally use already has them installed elsewhere. This project supports being invoked as a standalone role in a stripped-down container, so never skip a package install because "it's usually already there." It's fine for a role to only be *useful* when paired with another it doesn't formally depend on (e.g. dotfiles from a role depending only on `zsh_config_dirs` are inert without `zsh` actually installed) — that's a legitimate minimal-test setup; don't add defensive checks to special-case it. When a package in the list isn't self-evidently required — a paired/optional extra rather than a hard dependency — say why with a trailing YAML comment, e.g. `chewing-editor  # 自訂詞彙編輯器` next to the actually-required `fcitx5`/`fcitx5-chewing` in `roles/xpra/tasks/main.yml:118-122`.
- **Update scripts** (`files/<program>.update.zsh` — named for what it updates, not the role; a role can own more than one update target, e.g. `common_base`'s `apt.update.zsh` and `snap.update.zsh` — deployed to `~/.config/zsh/update/`, run by `aptu`, see `roles/zsh/files/interactive/99-aptu.zsh`): write one when the tool has its own out-of-band update path that `apt`/`snap` doesn't cover (e.g. `roles/nvm/files/nvm.update.zsh` re-runs the pinned git-checkout comparison via the shared `_aptu_update_git_repo` helper). Skip it when:
  - the tool updates via `apt`/`snap` — already covered by `roles/common_base/files/{apt,snap}.update.zsh`.
  - the tool updates itself so frequently in normal use that a separate step is pointless (e.g. `claude_code` self-updates on every run — don't write one for the CLI itself; its plugins/skills that don't self-update still need their own, see `roles/claude_code/tasks/*.yml`).
  - Ask the user before actually updating, unless the underlying installer/command already asks (see `_aptu_update_git_repo`'s `[y/N]` prompt and how `roles/common_base/files/snap.update.zsh` prompts before `snap refresh`).
  - These scripts only ever touch the local checkout/installation — they never change the version an Ansible role pins. A later playbook re-run resets a tag/SHA-pinned repo back to its pin (see the `ansible.builtin.git` section below); that's expected, not a bug to fix.
- **Version pinning**: when the upstream installer supports specifying a version, pin it as a role default var instead of tracking "latest" — see `nvm_version` interpolated into the install script URL in `roles/nvm/tasks/main.yml`, or `fzf`'s `version: v0.71.0` on the `git` module. Not every installer supports this (`starship`, `uv` currently install whatever's latest) — check before assuming it's impossible, but don't retrofit unrelated roles as a side effect of another change.
- After adding, removing, or renaming a role, update its entry in the README role catalogue tables (under "Roles" in README.md) — they're the only place role → purpose mappings are documented outside the code itself.

### `ansible_facts` access: bracket notation only

Use `ansible_facts['distribution_release']`, never `ansible_facts.distribution_release`. `ansible-lint` (profile: production, see `.ansible-lint.yml`) does not catch dot-notation access — it's silent both in lint and in normal runs — but dot access on a fact whose name collides with a dict method (or isn't a valid Python attribute name) can misbehave instead of returning the value. See `roles/proxmox_guest/tasks/login-access.yml` (`ansible_facts['getent_passwd'][ansible_user][4]`) for the correct form.

### `ansible.builtin.git`: `version` / `refspec` / `depth` interaction

This module's shallow-clone support is easy to get wrong silently (Ansible only `module.warn()`s, it doesn't fail) — several roles pin third-party repos to a specific commit, so get this right when adding or editing one:

- `version` is what actually gets checked out at the end (`switch_version()` always runs `git checkout --force <version>` after clone/fetch) — it must always be set to the commit/branch/tag you want, regardless of the other two.
- `depth` is only honored by the module when `version` is `HEAD`, or a branch/tag name, **or** `refspec` is also set. If `version` is a bare commit SHA and `refspec` is absent, Ansible silently drops `--depth` and does a full clone instead (warning: *"Ignoring depth argument. Shallow clones are only available for HEAD, branches, tags or in combination with refspec."*).
- To pin to a specific commit SHA **and** keep it shallow, set `refspec` to that same **full 40-character SHA** (abbreviated SHAs are not fetchable as a ref; GitHub's smart-HTTP backend allows fetching an arbitrary reachable full SHA, not a short one). Do not set `refspec` to the containing branch name instead — if the pinned commit later falls outside that branch's last `depth` commits (because upstream moved on), a fresh shallow clone will fail to fetch the exact commit you pinned.
- If `version` is `HEAD` or an actual branch/tag name, `depth` works with no `refspec` needed.

Reference implementations: `roles/claude_code/tasks/hung-yi-lee-skill.yml` and `roles/claude_code/tasks/winlab-skills.yml` (SHA pin + matching `refspec` + `depth: 1`) vs. `roles/vim/tasks/main.yml` (`version` defaults to `HEAD`, so `depth: 1` alone is enough) vs. `roles/fzf/tasks/main.yml` (`version` is a tag, so `depth: 1` alone is enough).

### Shell scripting gotchas (`bin/`, `bootstrap/`, `utils/`)

- **Subshell vs. command group**: `( cmd && var=x ) || ...` runs in a subshell — `var` never reaches the calling shell. Use `{ cmd && var=x; } || ...` (a command group) when a variable assigned inside a conditional needs to survive outside it. See the fix in `bin/setup-devcontainer` (commit `098c263`).
- **Root check before privileged commands**: don't shell out to `sudo` unconditionally — check `[[ "$EUID" -eq 0 ]]` first and skip `sudo` entirely if already root (minimal containers may run as root with no `sudo` binary installed at all), falling back to `sudo` only if available and failing loudly otherwise. See `run_privileged()` in `utils/locale.sh` and `reexec_with_sudo()` in `utils/common.sh`.
- **Check readability, not just existence, before sourcing**: use `[[ -r "$file" ]]`, not `[[ -f "$file" ]]`, before `source`-ing it — `-f` is true even when the current user can't read the file, which then fails the `source`. See `roles/zsh/files/interactive/01-linux-motd.zsh`.

### UTF-8 locale dependency

Any role whose shell integration renders Unicode/nerd-font glyphs or otherwise depends on locale (prompt icons, job-control messages — see `starship`, `zplug`) should add a `meta/main.yml` dependency on `locale_term_env`. Note the asymmetry: `locale_term_env` only deploys the `LANG`/`TERM` zsh env vars (`templates/10-locale-term.zsh.j2`) — it does not generate the `en_US.UTF-8` locale itself. Locale *generation* only happens at bootstrap time, in `utils/locale.sh`, for local-model targets (container/devcontainer) before Ansible even runs. Push-model targets (VM/LXC) are assumed to already have the locale from their base image; this project doesn't verify it there.

## Commit message convention

Commits mostly follow `type(scope): summary` (Conventional Commits–ish), where `type` is `feat`/`fix`/`refactor`/`perf`/`docs` and `scope` is the affected role — often abbreviated (`claude` for `claude_code`, `gh` for `github_cli`). Cross-cutting changes omit the scope (`feat: uv`). Match this style for new commits.
