# Completion expands the `claude` alias (65-claude-screen.zsh) first and then looks up
# `claude-screen`, so let it complete like `claude` (_claude, from 60-zplug-init.zsh).
# After 95-zplug-load.zsh on purpose: its compinit may load a .zcompdump made before this
# mapping existed, and that replaces the whole _comps table.
# Skipped when nothing completes `claude`, which would leave TAB with nothing to call.
if (( $+commands[claude-screen] && $+_comps[claude] )); then
  compdef claude-screen=claude
fi
