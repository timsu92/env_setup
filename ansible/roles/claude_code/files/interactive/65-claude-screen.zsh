# Run interactive Claude Code sessions inside GNU screen (see claude-screen, deployed to
# ~/.local/bin, for what it does and why). It is an alias to a script and not a function, because
# a job stopped by Ctrl-Z inside a zsh function leaves a stray subshell that breaks `fg`.
# Without the script on PATH nothing is defined and `claude` stays the plain binary.
# `command claude` or `\claude` skips the alias.
(( $+commands[claude-screen] )) && alias claude=claude-screen

# Completion expands the alias first and then looks up `claude-screen`, so point it at the
# _claude that zplug installs (60-zplug-init.zsh). Without zplug there is no _claude, and
# the mapping would turn TAB into a "function definition file not found" error.
# An `if`, not `&&`: a false test as the last command would make sourcing this file fail.
if (( $+commands[claude-screen] && $+functions[zplug] )); then
  compdef _claude claude-screen
fi
