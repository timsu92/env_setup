# Run interactive Claude Code sessions inside GNU screen, so the ideal-compact
# hooks can send keys to them (tmux has its own path) and the session survives
# a closed terminal. Escape key is Ctrl-\ (`-e '^\q'`): Claude Code does not bind
# it, while Ctrl-A (line start) and Ctrl-] are taken. Ctrl-Q was tried first but
# never reached screen when checked inside tmux (likely tty XON/XOFF handling).
# `<esc> d` detaches, Ctrl-Z suspends the attach to the outer shell (`fg` reattaches).
claude() {
  emulate -L zsh

  # Already inside a multiplexer, or not a terminal session: nothing to wrap.
  if [[ -n $TMUX || -n $STY ]] \
    || [[ -z $CLAUDE_LAUNCHER_ASSUME_TTY && ! ( -t 0 && -t 1 ) ]]; then
    command claude "$@"
    return
  fi

  # Flags and subcommands that never open the interactive UI.
  local arg
  for arg in "$@"; do
    case $arg in
      -p|--print|-h|--help|-v|--version|mcp|plugin|plugins|auth|update|upgrade|install|doctor|migrate-installer|setup-token|config|auto-mode|gateway|import|logs|purge|respawn|rm|stop|kill|ultrareview)
        command claude "$@"
        return
        ;;
    esac
  done

  # The path as found on PATH, never its realpath: the process must stay named `claude`.
  local claude_bin=$(whence -p claude)
  local screen_bin=$(whence -p screen)
  if [[ -z $claude_bin || -z $screen_bin ]]; then
    command claude "$@"
    return
  fi

  local name="claude-$$-$(date +%s)"
  "$screen_bin" -e '^\q' -dmS "$name" "$claude_bin" "$@" || return

  # The session needs a moment before screen -X can reach it.
  local i
  for i in {1..20}; do
    [[ "$("$screen_bin" -ls 2>/dev/null)" == *".$name"[[:space:]]* ]] && break
    sleep 0.1
  done
  "$screen_bin" -S "$name" -X bindkey '^Z' suspend >/dev/null 2>&1

  "$screen_bin" -r "$name"
}
