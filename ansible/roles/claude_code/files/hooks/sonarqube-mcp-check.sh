#!/usr/bin/env bash
# SessionStart hook: warn when the SonarQube MCP server cannot start.
#
# The sonarqube plugin's own banner only checks that `sonar` is on PATH, so on
# a machine with neither a container runtime nor Java 21 + the MCP server JAR
# it shows all green while the `sonarqube` MCP tools quietly never load.
# Whether the server could start is decided by the sonarqube-mcp wrapper
# itself (`--check`), so this hook cannot drift from what actually runs.
# Silent when the server can start.
wrapper="${HOME}/.local/bin/sonarqube-mcp"
[[ -x "$wrapper" ]] || exit 0
"$wrapper" --check >/dev/null 2>&1 && exit 0

cat <<'JSON'
{"systemMessage": "SonarQube MCP 無法啟動：這台機器沒有可用的容器 runtime（docker / podman / nerdctl），備援用的 Java 21 與 MCP JAR 也不齊全，所以 mcp__sonarqube__* 工具不會載入。請啟動 Docker，或安裝 Java 21 並確認 ~/.local/share/sonarqube-mcp/sonarqube-mcp-server.jar 存在。"}
JSON
