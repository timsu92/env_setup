# Don't call `go env GOPATH` here: it spawns a process on every shell start.
# $HOME/go is Go's default GOPATH.
export PATH="$PATH:/usr/local/go/bin:${GOPATH:-$HOME/go}/bin"
