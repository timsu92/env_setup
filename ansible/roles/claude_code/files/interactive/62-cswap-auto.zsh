# User `flock -n` to put a lock when the process is still running. When the process ends (no matter
# if it ends normally or abnormally) the lock will be released automatically.
#   `-n` means "do not wait for the lock, just fail if the lock is already held by another process".
#   `>|` means "overwrite the log file if it already exists", ignoring `noclobber` option which prevents
#     overwriting existing files.
#   `&!` means "run the command in the background and disown it.
flock -n "$HOME/.cache/cswap-auto.lock" -c 'exec cswap auto --threshold 95 >| "$HOME/.cache/cswap-auto.log" 2>&1' &!
