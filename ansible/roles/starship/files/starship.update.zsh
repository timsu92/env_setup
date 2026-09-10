command -v starship >/dev/null 2>&1 || return 0

# starship has no self-update subcommand; the official update method is
# re-running the install script (https://starship.rs/install.sh). It's
# installed to /usr/local/bin, so updating it needs sudo. --yes/-y skips
# the script's own "install to <dir>?" confirmation, so this runs like
# `uv self update` with no extra aptu-level prompt.
if command -v curl >/dev/null 2>&1; then
  curl -sS https://starship.rs/install.sh | _aptu_sudo sh -s -- --yes
elif command -v wget >/dev/null 2>&1; then
  wget -qO- https://starship.rs/install.sh | _aptu_sudo sh -s -- --yes
else
  print -u2 "starship.update.zsh: 找不到 curl 或 wget，無法更新 starship"
  return 1
fi
