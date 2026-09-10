# Local checkout only; the Ansible-pinned commit in hung-yi-lee-skill.yml is
# untouched, so a future playbook re-run resets this checkout back to it.
_aptu_update_git_repo "${HOME}/.claude/skills/hung-yi-lee" "hung-yi-lee-skill" sha
