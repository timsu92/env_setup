# Don't call `go env GOPATH` here: it spawns a process on every shell start.
# $HOME/go is Go's default GOPATH.
# Prepend (unlike go.dev/doc/install) so the pinned /usr/local/go wins over a
# distro golang-go, and user-installed tools win over system ones. Keep the
# order in sync with claude_code/tasks/lsp.yml.
export PATH="${GOPATH:-$HOME/go}/bin:/usr/local/go/bin:$PATH"
