# bun updates itself via `bun upgrade`, but that runs without asking, so
# confirm first. The completion file is a snapshot of `bun completions`, so it
# is regenerated after an upgrade to pick up new commands. The redirect is
# load-bearing: with a TTY stdout, `bun completions` would install
# ~/.bun/_bun instead of printing.
command -v bun >/dev/null 2>&1 || return 0

echo -n "bun 目前版本 $(bun --version)，是否執行 bun upgrade？[y/N] "
if read -q; then
  echo
  bun upgrade || return $?
  SHELL=zsh bun completions >"${HOME}/.config/zsh/completions/_bun"
else
  echo
fi
