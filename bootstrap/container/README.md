# Bootstrap: Docker Container

Docker containers use the **Ansible local model** — Ansible is installed inside the container and runs locally. No SSH is used.

## How it works

The bootstrap script:
1. Installs `ansible` via apt
2. Runs `ansible-playbook -c local` with the container profile

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
