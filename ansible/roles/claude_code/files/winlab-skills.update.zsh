# Local checkout only; the Ansible-pinned commit in winlab-skills.yml is
# untouched, so a future playbook re-run resets this checkout back to it.
_aptu_update_git_repo "${HOME}/.claude/plugins/self-download/winlab-skills" "winlab-skills" sha
