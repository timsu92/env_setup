command -v claude >/dev/null 2>&1 || return 0
# `claude update` (alias `claude upgrade`): "Check for updates and install if
# available", per `claude --help`.
claude update
