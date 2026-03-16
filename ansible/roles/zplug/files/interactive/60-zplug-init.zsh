source ~/.zplug/init.zsh

zplug 'zplug/zplug',                                hook-build:'zplug --self-manage'
zplug 'zsh-users/zsh-completions'
zplug 'zsh-users/zsh-autosuggestions'
zplug 'plugins/command-not-found',                  from:oh-my-zsh
zplug 'zdharma-continuum/fast-syntax-highlighting', use:'fast-syntax-highlighting.plugin.zsh'
zplug 'plugins/gitfast',                            from:oh-my-zsh
zplug 'plugins/git-auto-fetch',                     from:oh-my-zsh
zplug 'timsu92/vimrc',                              use:'dummy.file', hook-build:'bash $ZPLUG_REPOS/timsu92/vimrc/install.sh >/dev/null'
zplug 'timsu92/ee65b1285ae128ba91d88ce972c91a95',   from:gist, as:command, use:'mosh-ssh-bridge.bash'
zplug 'timsu92/ba3c31cd48d5a384cf5844a1329779c1',   from:gist, as:command, use:'rs'

# If ZPLUG_SKIP_PROMPT is set (by Ansible), skip the prompt and install directly.
# Otherwise, prompt the user interactively (normal login behavior).
if [[ -n "${ZPLUG_SKIP_PROMPT:-}" ]]; then
	# (zplug check --verbose || zplug install) 2>&1 | grep -v 'pipe syntax is deprecated' || true
	zplug check --verbose || zplug install
else
	if ! zplug check --verbose; then
		printf "Install zplug ? [y/N]: "
		if read -q; then
			echo; zplug install
		fi
	fi
fi
