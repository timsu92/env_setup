command -v zplug >/dev/null 2>&1 || return 0

# zplug updates plugins in parallel background jobs. In an interactive shell
# (MONITOR on by default) that makes zsh print "[N] PID" job-control
# notifications, which race with zplug's own \r-driven progress spinner and
# garble the output. Suppress those notifications for this call only.
() {
  setopt local_options no_monitor
  zplug update
}
