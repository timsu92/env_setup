autoload -U add-zsh-hook

load-nvmrc() {
  local node_version="$(nvm version)"
  local nvmrc_path="$(nvm_find_nvmrc)"

  if [[ -n "$nvmrc_path" ]]; then
    local nvmrc_node_version
    nvmrc_node_version="$(nvm version "$(<"${nvmrc_path}")")"

    if [[ "$nvmrc_node_version" = 'N/A' ]]; then
      nvm install
    elif [[ "$nvmrc_node_version" != "$node_version" ]]; then
      nvm use
    fi
  fi
}

if command -v nvm >/dev/null 2>&1; then
  add-zsh-hook chpwd load-nvmrc
  load-nvmrc
fi
