# Bootstrap: Devcontainer

Devcontainers use the **Ansible local model** — Ansible runs locally inside the devcontainer without SSH.

## How it works

The bootstrap script:
1. Installs `python3`, `pip3`, and `git` (if absent)
2. Installs `ansible` via pip
3. Runs `ansible-playbook -c local` with the devcontainer profile

## Typical usage

Reference this script from a VS Code dotfiles repository's `install.sh`, or call it directly in a devcontainer lifecycle hook.

```bash
# Inside the devcontainer, from repo root:
bash bootstrap/devcontainer/bootstrap.sh

# Or via bin/ wrapper:
bin/setup-devcontainer
```

## Notes
- No SSH port needed
- Works without `postCreateCommand` in devcontainer.json
- Devcontainer profile is intentionally minimal (currently just installs git)
- Extend `ansible/playbooks/devcontainer.yml` to add more roles
