command -v rtk >/dev/null 2>&1 || return 0
# rtk has no self-update/upgrade subcommand (checked `rtk --help`; no such
# command is listed on github.com/rtk-ai/rtk either) — re-run the upstream
# install script, same as the Ansible role does, which is safe to re-run.
curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh
