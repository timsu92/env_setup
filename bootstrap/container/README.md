# Bootstrap: Docker Container

Docker containers use the **Ansible local model** — Ansible is installed inside the container and runs locally. No SSH is used.

## How it works

The bootstrap script:
1. Installs `python3`, `pip3`, and `git` (if absent)
2. Installs `ansible` via pip
3. Runs `ansible-playbook -c local -i inventory/local.yml` with the container profile

## Running

```bash
# Inside the container:
bash bootstrap/container/bootstrap.sh

# Or with extra vars:
bash bootstrap/container/bootstrap.sh -e "setup_user=myuser"
```

## Notes
- No SSH port needed
- Run as root or a user with sudo access
- The container profile (`playbooks/container.yml`) is minimal — extend as needed
