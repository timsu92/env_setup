command -v uv >/dev/null 2>&1 || return 0
uv tool list 2>/dev/null | grep -q '^claude-swap ' || return 0
uv tool upgrade claude-swap
