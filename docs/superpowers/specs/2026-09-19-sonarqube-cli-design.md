# `claude_code` role：SonarQube CLI + MCP（含無容器備援）

## 問題

`sonarqube` plugin 需要三樣東西才完整可用：`sonar` CLI、`sonar integrate claude --global` 寫入的 secrets-scanning hooks 與 `sonarqube` MCP 項目、以及一個能跑起 MCP server 的環境。目前這三樣都是 2026-07-23 手動裝的，不在 Ansible 內，造成兩個實際問題：

1. **PATH 被 Ansible 洗掉。** SonarQube 官方 `install.sh` 會把 `export PATH=…/sonarqube-cli/bin` 用 `>>` 附加到 `~/.zshrc`。2026-09-18 zsh role 用 `copy` 整檔覆寫 `~/.zshrc`（`roles/zsh/tasks/main.yml:22`），該行消失；新開的 shell 找不到 `sonar`，`sonarqube` MCP 以 `ENOENT` 失敗。
2. **同一個機制還會再發生。** `sonar update` 底層會重跑同一支 `install.sh`（容器內實測：更新後 `.bashrc` 被改），所以只要有人執行 `sonar update`，`~/.zshrc` 又會被寫入。

此外 `sonar run mcp` 需要 Docker/podman/nerdctl。本 repo 的 `devcontainer` 與 `lxc-pve` profile 沒有 Docker role，這兩個環境目前不可能有 MCP。

## 目標

- `claude_code` role 以可重複執行（`changed=0`）的方式安裝並釘版本 `sonar` CLI（含 checksum 驗證）。
- 安裝與更新都不得改動使用者的 rc 檔。
- `sonar integrate claude --global` 由 Ansible 執行（hooks + MCP 項目），在 token 已填時。
- token 不進 repo。可在（已被 git 忽略的）inventory 以可選變數 `claude_code_sonarqube_token` 提供（push 目標用 `pve_hosts.yml`，WSL／devcontainer 用 `local.yml`），Ansible 直接部署；未提供時部署空殼供手動填寫，且不覆蓋手填內容。server URL 由 role 變數提供。
- 沒有可用容器 runtime 的環境，仍能用官方獨立 JAR 提供同名的 `sonarqube` MCP。
- 有 `sonarqube-cli.update.zsh`（`aptu` 使用），更新前詢問。
- 沒有任何 MCP 可用時，開 Claude Code 的橫幅要明確警告。

## 非目標

- 不做獨立 role（SonarQube 在此環境純粹為了 Claude Code 的 SonarQube MCP，放在 `claude_code` 內）。
- 不支援 SonarQube Cloud（不映射 `SONARQUBE_CLI_ORG`）；只支援自架 server。
- 不為 MCP JAR 寫 update script（它沒有自己的更新指令，升版靠改 pin 後重新 provision）。
- 不改變 `install_hooks.bash` 對 high-watermark hook 的既有註冊結果（只把寫死的路徑、事件、timeout 改為參數，見 §3f）。
- Alpine 與 macOS 不在本次範圍。Alpine 是已實測不支援（見「已驗證的事實」），不是待驗證；此外 repo 目前沒有任何 Alpine profile，`claude_code` role 本身也以 `apt` 為前提。
- 不更新 `BOOTSTRAP_REQUIREMENTS.md`：它描述的 `bootstrap/*/bootstrap.sh` 在 repo 中已不存在，其中的 `inventory/local.yml` 指令是舊資料。

## 已驗證的事實與來源

以下皆在 throwaway 容器（ubuntu:24.04，非 root 使用者）或讀原始碼確認：

| 事實 | 影響 |
|---|---|
| CDN 版本路徑為 `binaries.sonarsource.com/Distribution/sonarqube-cli/<版本>/linux/sonarqube-cli-<版本>-linux-{x86-64,arm64}.bin`，同目錄有 `.sha256`、`.asc` | 可直接 `get_url` + checksum，不必跑 `install.sh` |
| 版本號形如 `1.8.0.5274`；`sonar --version` 只印 `1.8.0` | 不能用 `--version` 精確比對 pin，改用檔案 checksum |
| `sonar update` 是正確指令；`self-update` 自 1.4 起 deprecated | update script 用 `sonar update` |
| `sonar update --status` 輸出 `Current version` / `Latest version` / `Update available`，離開碼恆為 0 | 只能用文字判斷是否有更新 |
| `sonar update` 會改 rc 檔；`PROFILE=/dev/null` 可阻止（`.bashrc` 實測 UNCHANGED） | update script 必須帶 `PROFILE=/dev/null` |
| `sonar integrate claude --global` 需要連得到 server 且 token 有效，否則 rc=1 且不寫任何檔案 | integrate 只能在 token 已填後執行 |
| `sonar run mcp` 在沒有容器 runtime 時立即以 rc=1 結束，訊息 `A container runtime … is required`；即使已設定自架 server 也一樣 | 容器是跑 MCP server 程式用的，與 SonarQube server 位置無關 |
| `sonarqube` plugin 的 `plugin.json` 只宣告 `hooks`，**沒有** `mcpServers`；MCP 項目（user scope `~/.claude.json`）是 `integrate` 寫的 | MCP 項目由 integrate 建立，之後由本設計取代 |
| plugin 的 SessionStart 橫幅只檢查 `sonar` 是否在 PATH 與 state.json 內有 hooks，不檢查容器 runtime 或 MCP 狀態 | 沒有容器時橫幅仍全綠，需要自己的 hook |
| MCP JAR：`Distribution/sonarqube-mcp-server/sonarqube-mcp-server-<版本>.jar`（最新 1.27.0.4335），有 `.sha256`；需要 Java 21+；環境變數 `SONARQUBE_TOKEN`、`SONARQUBE_URL`、`STORAGE_PATH` | JAR 備援的輸入 |
| `openjdk-21-jre-headless` 在 Ubuntu 22.04、24.04、26.04 與 Debian 13 有候選版本（容器內 `apt-cache policy` 實測）；**Debian 12 沒有** | Java 依發行版條件式安裝 |
| sonar CLI binary 是 glibc 動態連結（interpreter `/lib64/ld-linux-x86-64.so.2`）：在 Alpine 3.22 直接執行為 `not found`，加裝 `gcompat` 後仍失敗（`__pthread_key_create: symbol not found`）；CDN 只有 `linux-x86-64`、`linux-arm64` 兩種平台，沒有 musl 版 | Alpine 上 CLI（含 `integrate`、secrets hooks、`sonar run mcp`）無法運作，且無法在本 repo 修復；需明確擋下 |
| Alpine 有 `openjdk21-jre-headless`，MCP 的 JAR 是純 Java、不依賴 sonar CLI | JAR 在 Alpine 理論上可跑，但只能得到 MCP，沒有 hooks，功能不完整，本次不為此加 Alpine 專用分支 |
| `ansible/inventory/.gitignore` 只忽略 `/pve_hosts.yml`；`inventory/local.yml` 目前進版控、只有 `localhost` 與 `ansible_connection: local` | `local.yml` 必須比照 `pve_hosts.yml` 改成 example + gitignore 才能放 token（見 §4） |
| `bin/setup-vm`（wsl 分支）、`bin/setup-container`、`bin/setup-devcontainer` 都寫死 `-i inventory/local.yml`，且都在最前面 `reexec_with_sudo`（之後是 root）；`ansible.cfg` 的 `inventory = ansible/inventory/` 指向整個目錄 | 需要在 sudo 之前補建 `local.yml`（見 §4）；`.example` 不會被 inventory 載入器讀取，`pve_hosts.yml.example` 已與之共存 |
| 沒有 keychain（libsecret）的環境，官方文件指定用 `SONARQUBE_CLI_TOKEN` + `SONARQUBE_CLI_SERVER`；環境變數優先於 keychain；必須是 user token | token 用環境變數 |

## 設計

### 檔案配置（路徑除另有標示外，皆相對於 `ansible/roles/claude_code/`）

| 檔案 | 用途 |
|---|---|
| `tasks/sonarqube-cli.yml` | CLI 安裝、snippets、update script、integrate |
| `tasks/sonarqube-mcp.yml` | Java、MCP JAR、wrapper、MCP 項目註冊、警告 hook |
| `tasks/main.yml` | 末尾新增兩行 `include_tasks` |
| `defaults/main.yml` | 新增版本、路徑、server 變數（見下） |
| `files/non-interactive/14-sonarqube-cli-path.zsh` | PATH snippet |
| `templates/14-sonarqube-cli-server.zsh.j2` | `export SONARQUBE_CLI_SERVER=…` |
| `files/sonarqube-cli.update.zsh` | `aptu` 更新腳本 |
| `files/sonarqube-mcp` | wrapper（部署到 `~/.local/bin/sonarqube-mcp`，0755） |
| `files/hooks/sonarqube-mcp-check.sh` | SessionStart 警告 |
| `files/install_hooks.bash`（修改） | 改成參數化：`install_hooks.bash <hook 腳本路徑> <事件>[:<timeout>]…`，high-watermark 與新 hook 共用（見 §3f） |
| `tasks/high-watermark-auto-pause.yml`（修改） | 呼叫 `install_hooks.bash` 時帶入參數，取代原本寫死的路徑、事件與 timeout |
| `ansible/inventory/pve_hosts.yml.example`（修改） | 在 `pve-vm-01`、`pve-lxc-01` 各加一行被註解掉的可選 `claude_code_sonarqube_token`（沿用該檔對可選變數的註解寫法） |
| `ansible/inventory/local.yml` → `ansible/inventory/local.yml.example`（`git mv`） | 內容不變，另加被註解掉的可選 `claude_code_sonarqube_token` |
| `ansible/inventory/.gitignore`（修改） | 新增 `/local.yml` |
| `utils/common.sh`（修改） | 新增 `ensure_local_inventory`（見 §4） |
| `bin/setup-vm`、`bin/setup-container`、`bin/setup-devcontainer`（修改） | 在 `reexec_with_sudo` **之前**呼叫 `ensure_local_inventory`（`setup-vm` 只在 wsl 分支） |
| `CLAUDE.md`（修改） | `--syntax-check -i inventory/local.yml` 的範例旁註明：需先有 `local.yml`（跑過一次 `bin/setup-*`，或手動 `cp`） |
| `README.md`（修改） | 見「README」 |

`playbooks/vm-pve.yml`：`claude_code` 移到 `docker_rootless` **之後**（見「順序相依」）。

### 新增 defaults

```yaml
claude_code_sonarqube_cli_version: 1.8.0.5274
claude_code_sonarqube_cli_dir: "{{ setup_user_home }}/.local/share/sonarqube-cli/bin"
claude_code_sonarqube_server: http://sonarqube:9000
claude_code_sonarqube_token: ""  # 可選；空字串表示不由 Ansible 管理 token
claude_code_sonarqube_mcp_version: 1.27.0.4335
claude_code_sonarqube_mcp_dir: "{{ setup_user_home }}/.local/share/sonarqube-mcp"
```

CLI 的 `pin` 註解需說明：官方 `install.sh` 只會裝 stable，不支援指定版本，所以本 role 自行下載。

### 1. CLI 安裝（`sonarqube-cli.yml`）

0. **平台守衛（`sonarqube-cli.yml` 的第一個 task）：** `ansible.builtin.assert` 要求 `ansible_facts['distribution'] != 'Alpine'`，`fail_msg` 為「sonarqube-cli 的官方 binary 只有 glibc 版本，在 Alpine（musl）上無法執行（`gcompat` 也不行），本 role 不支援 Alpine」。用 `assert` 而不是 `ignore_errors`，符合 `ansible-lint` 的 production profile。目前 `claude_code` 前面的 `apt` task 在 Alpine 上本來就會先失敗，這個守衛的作用是：日後若 role 擴充到 Alpine，SonarQube 這一段仍會給出明確的原因，而不是一個難懂的 `not found`。
1. apt 安裝 `curl`（`sonar update` 的 `install.sh` 需要 curl 或 wget；依 CLAUDE.md 慣例，prerequisites 寫在 task 開頭）。
2. 建立 `claude_code_sonarqube_cli_dir`（owner `setup_user`）。
3. `ansible.builtin.get_url`：
   - `url`：`…/<版本>/linux/sonarqube-cli-<版本>-<平台>.bin`，平台由 `ansible_facts['architecture']` 映射（`x86_64` → `linux-x86-64`、`aarch64` → `linux-arm64`），不在對照表內的架構明確失敗。
   - `checksum: "sha256:<同 URL>.sha256"`、`dest: <dir>/sonar`、`mode: "0755"`、owner/group `setup_user`。
   - 預期行為：dest 存在但 checksum 不符時重新下載，因此跑過 `sonar update` 後重新 provision 會回到 pin，與 CLAUDE.md 對 git pin 的說明一致。**此行為在實作時以容器驗證**；若不成立，改為 `command: sonar --version` 比對 pin 的前三段。
4. 部署 `14-sonarqube-cli-path.zsh`（內容仿 `10-user-home-local-bin.zsh` 的 `case ":$PATH:"` 去重寫法，路徑改為 `sonarqube-cli/bin`）。此檔與 2026-09-19 手動放在 `~/.config/zsh/non-interactive/` 的檔案**同名**，role 會直接取代它。
5. 部署 server snippet（template）。
6. 部署 token 檔 `~/.config/zsh/non-interactive/15-sonarqube-cli.zsh`（`mode: "0600"`，owner `setup_user`），依 `claude_code_sonarqube_token` 是否非空分兩種：
   - **有值**（來自 `pve_hosts.yml`（push 目標）或 `local.yml`（WSL、devcontainer），也可用 `-e` 臨時提供）：`copy` 寫入 `export SONARQUBE_CLI_TOKEN={{ claude_code_sonarqube_token | quote }}`，`force` 用預設值 true（此時 Ansible 是唯一來源，inventory 改了就跟著改），並且 **`no_log: true`**，避免 token 出現在輸出與 `--diff`。
   - **空字串**：`copy` 部署空殼，`force: false`，內容是註解說明與被註解掉的 `# export SONARQUBE_CLI_TOKEN="<user token>"`。已存在的檔案（如本機現有的、含 token 的檔案）完全不動。
7. 部署 `sonarqube-cli.update.zsh` 到 `~/.config/zsh/update/`。

`sonarqube-cli.update.zsh` 行為：

- guard：`command -v sonar >/dev/null 2>&1 || return 0`
- 執行 `sonar update --status`，輸出含 `Update available` 才繼續；否則不輸出任何東西（與 `aptu` 其他腳本一致）。
- 顯示目前與最新版本，`read -q` 詢問 `[y/N]`；同意才執行 `PROFILE=/dev/null sonar update`。
- 檔案開頭註解說明兩點：這只改本機安裝，Ansible pin 不變、下次 provision 會回到 pin；`PROFILE=/dev/null` 是為了避免安裝腳本改寫 `~/.zshrc`。

### 2. integrate（`sonarqube-cli.yml`）

- 先檢查 token 檔是否已填：`grep -q '^export SONARQUBE_CLI_TOKEN=' <token 檔>`（`changed_when: false`、`failed_when` 僅在 rc > 1）。inventory 提供 token 時，前面的步驟已把它寫進該檔，所以這個檢查同時涵蓋「inventory 提供」與「手動填寫」兩種來源。
- 未填：`debug` 提示「填入 token 到 `~/.config/zsh/non-interactive/15-sonarqube-cli.zsh`，或在 `ansible/inventory/pve_hosts.yml`（VM、LXC）／`ansible/inventory/local.yml`（WSL、devcontainer）設定 `claude_code_sonarqube_token` 後重跑 playbook」，並跳過 integrate。
- 已填：`ansible.builtin.shell`，`executable: /bin/bash`，`become_user: "{{ setup_user }}"`，先 `. <server snippet>`、`. <token 檔>`，再 `sonar integrate claude --global --non-interactive`。`environment` 帶 `HOME` 與含 `sonarqube-cli/bin` 的 `PATH`。
- 冪等：`creates: "{{ claude_code_hook_dir }}/sonar-secrets/build-scripts/pretool-secrets.sh"`（即 `~/.claude/hooks/sonar-secrets/build-scripts/pretool-secrets.sh`，本機已存在），寫法同 `rtk.yml` 的 `creates:`。
- **失敗策略：** token 已填但 server 連不上或 token 無效時，task 失敗（不吞錯）。這個問題原本就是因為靜默失敗才被發現得太晚。

### 3. MCP 備援（`sonarqube-mcp.yml`）

**3a. 容器 runtime 偵測（provision 時）**：`command -v docker podman nerdctl`（`changed_when: false`、`failed_when: false`）。只判斷「有沒有裝」，不判斷「能不能用」，因為 `docker_rootless` 的 daemon 是 systemd user service，provision 當下未必已啟動。

**3b. 條件式安裝（僅在未偵測到任何容器 runtime 時）：**

- apt 安裝 `openjdk-21-jre-headless`，條件為「發行版是 Ubuntu，或是 Debian 且主版本 ≥ 13」。Ubuntu 22.04／24.04／26.04 與 Debian 13 已用容器確認有套件；Debian 12 確認沒有，因此跳過 Java 與 JAR，並以 `debug` 印出：「Claude Code 的 SonarQube MCP 無法安裝：此環境沒有容器 runtime，備援方案（獨立 JAR）也因為沒有 Java 21 而無法使用」（訊息後附發行版名稱與版本）。
- `get_url` 下載 `sonarqube-mcp-server-<版本>.jar` 到 `claude_code_sonarqube_mcp_dir/sonarqube-mcp-server.jar`，`checksum: sha256:<URL>.sha256`。

**3c. wrapper `~/.local/bin/sonarqube-mcp`（bash，0755）**，啟動時依序：

1. 有任一可用的容器 runtime（`docker info` / `podman info` / `nerdctl info` 成功）→ `exec sonar run mcp "$@"`。
2. 否則若 `java` 主版本 ≥ 21 且 JAR 存在 → 匯出 `SONARQUBE_URL="$SONARQUBE_CLI_SERVER"`、`SONARQUBE_TOKEN="$SONARQUBE_CLI_TOKEN"`、`STORAGE_PATH`（`${XDG_STATE_HOME:-$HOME/.local/state}/sonarqube-mcp`，先 `mkdir -p`），再 `exec java -jar <jar>`。
3. 否則向 **stderr** 印說明（啟動 Docker，或安裝 Java 21 與 JAR）並 `exit 1`。

wrapper 另支援 `sonarqube-mcp --check`：只判斷「能不能啟動」（能：exit 0；不能：exit 1，原因印到 stderr），不真的啟動。警告 hook 用它判斷，這樣偵測邏輯只有 wrapper 裡這一份，不會與實際執行的行為脫節。

wrapper 不得向 stdout 輸出任何內容（stdio MCP 協定佔用 stdout，多印一個字元就會破壞協定）。**這條限制與理由必須寫進 wrapper 的檔首註解**，讓之後修改它的人一眼看到（所有診斷訊息一律走 stderr）。

**3d. 註冊為 `sonarqube`：** 名稱必須維持 `sonarqube`，因為 plugin 的 reviewer agent 白名單是 `mcp__sonarqube__*`。

- 順序：**integrate 之後**執行，因為 integrate 會寫入 `sonarqube → sonar run mcp` 並可能覆蓋。
- 檢查：用 `slurp` 直接讀 `~/.claude.json` 的 `mcpServers.sonarqube.command`（不依賴 `jq`）；等於 wrapper 路徑則不變更；否則先 `claude mcp remove --scope user sonarqube`（僅在已有項目時），再 `claude mcp add --scope user sonarqube -- <wrapper>`。**不用 `claude mcp get`**：實測它會真的啟動 server 來回報 `Status`，對 integrate 寫入且啟動失敗的項目甚至不顯示 `Command:`，慢且不可靠；`claude mcp add` 在項目已存在時回傳 rc=1，所以必須先 remove。
- `changed_when` 判斷寫法參照 `drawio-mcp.yml`。
- 註冊不依賴 token 是否已填（wrapper 是在執行時才需要 token）。

**3e. 警告 hook（SessionStart）**：`sonarqube-mcp-check.sh` 呼叫 `sonarqube-mcp --check`；失敗（沒有可用容器 runtime，且沒有可用的 Java 21 + JAR）時輸出 `{"systemMessage": "…"}`。能啟動時、或 wrapper 根本沒安裝時，完全不輸出。由 `sonarqube-mcp.yml` 部署腳本到 `claude_code_hook_dir`，再呼叫參數化後的 `install_hooks.bash` 註冊到 `settings.json` 的 `hooks.SessionStart`（見 §3f）。

### 3f. `install_hooks.bash` 參數化

既有腳本的主要內容是 jq／python 兩套 `settings.json` 合併函數，但路徑、事件、timeout 都寫死成 high-watermark。與其複製一份，不如把這三者改成參數：

```
install_hooks.bash <hook 腳本路徑> <事件>[:<timeout 秒數>] [<事件>[:<timeout>] …]
```

- high-watermark 的呼叫改成：`install_hooks.bash {{ claude_code_hook_dir }}/high-watermark-auto-pause.sh PreToolUse:691200 UserPromptSubmit:691200 Stop`。原本腳本內「約 8 天」的 timeout 註解移到 `high-watermark-auto-pause.yml` 的該 task 上。
- 新 hook 的呼叫：`install_hooks.bash {{ claude_code_hook_dir }}/sonarqube-mcp-check.sh SessionStart`。
- 多次呼叫可共存：`upsert` 只移除「`command` 與本次腳本路徑相同」的項目再附加，所以不會互相覆蓋，也不動 `sonar integrate` 寫入的其他 hooks。
- 離開碼語意不變（0 = 有變動、10 = 無變動、其他 = 失敗），兩個 task 的 `changed_when` / `failed_when` 沿用現有寫法。
- 順帶的小改動：既有腳本每次執行都會 `cp settings.json settings.json.bak.<時間>`，即使沒有任何變動。改為兩次呼叫後備份會加倍，所以改成「合併結果與原內容不同時才備份」。

### 4. local inventory：改成 example + gitignore

為了讓 WSL、devcontainer 也能在 inventory 提供 token，`local.yml` 比照 `pve_hosts.yml`：`git mv` 成 `local.yml.example`，並在 `ansible/inventory/.gitignore` 加 `/local.yml`。

**為什麼不能只改檔名：**

- 三支 `bin/setup-*` 寫死 `-i inventory/local.yml`。全新 clone 或一次性的 Docker container 沒有這個檔，會多出一個不必要的手動步驟；`-i` 指到不存在的檔時 Ansible 預期只會警告並退回隱含的 localhost（未實測），不能依賴。
- 既有 checkout 在 `git pull` 到這個 commit 時，git 會把原本被追蹤的 `local.yml` 從工作目錄刪掉。

**做法：** `utils/common.sh` 新增 `ensure_local_inventory <repo_root>`：

- `ansible/inventory/local.yml` 不存在時，從 `local.yml.example` 以 `install -m 0600` 建立；已存在則完全不動。
- 建立失敗（例如目錄唯讀）只印警告，不中止。
- 若一開始就以 `sudo bin/setup-*` 執行（一開始即是 root、`SUDO_USER` 有值），建立後把檔案 `chown` 給 `SUDO_USER`，理由同上。
- 三支 script 在 `reexec_with_sudo` **之前**呼叫。sudo 之後是 root，此時建立會讓檔案屬於 root，使用者之後無法編輯 token。
- example 本身可直接使用（只有 `localhost`），所以自動建立不需要使用者介入；README 的手動 `cp` 只在想讓 Ansible 管理 token 時才需要。

不改 `ansible.cfg` 的 `inventory = ansible/inventory/`：載入器只解析 `.yml`／`.yaml`／`.json`，`.example` 不會被讀，`pve_hosts.yml.example` 已是同樣情況。

### 順序相依

3a 的偵測要能看到 Docker，因此 `claude_code` 必須排在 `docker_rootless`（其 meta 依賴 `docker_rootful`）之後：

| profile | 現況 | 動作 |
|---|---|---|
| `vm-daily-wsl` | `docker_rootless`（26）先於 `claude_code`（29） | 不需更動 |
| `vm-pve` | `claude_code`（28）先於 `docker_rootless`（29） | 交換兩者位置 |
| `vm-daily-pve` | `import_playbook: vm-pve.yml` | 隨之生效 |
| `lxc-pve`、`devcontainer` | 無 Docker role | 判定為無 runtime → 安裝 Java 與 JAR |

`vm-pve.yml` 中兩者之間沒有其他 role，交換不影響其他相依（`claude_code` 只需要 `zsh_config_dirs` 等既有依賴）。

### README

- role 目錄中 `claude_code` 的描述加入 SonarQube CLI／MCP。
- 「Notes」章節（目前只有 WireGuard 一條）新增一條 **SonarQube token**：可選的 `claude_code_sonarqube_token` 放在 `ansible/inventory/pve_hosts.yml`（VM、LXC）或 `ansible/inventory/local.yml`（WSL、devcontainer），範例見對應的 `.example`；設定後 Ansible 直接部署到 `~/.config/zsh/non-interactive/15-sonarqube-cli.zsh`；未設定則部署空殼，需手動填入該檔後重跑。填入 token 後建議 `chmod 600` 該 inventory 檔。
- 「WSL daily driver」與「Devcontainer」兩節，在指令前加上與「Proxmox VM」節（`# 1. Copy and configure inventory`）相同形式的步驟：`cp ansible/inventory/local.yml.example ansible/inventory/local.yml`，並註明「僅在要讓 Ansible 管理 SonarQube token 時才需要編輯；`bin/setup-*` 在檔案不存在時會自動由 example 建立」。「Docker container」節不加步驟（該 profile 不含 `claude_code`），只在「How to run」開頭用一句話說明 local profile 讀取 `ansible/inventory/local.yml`。
- Architecture 樹狀圖（README 第 27 行）的 `local.yml` 改為 `local.yml.example`，說明為 localhost inventory 範本。
- 同一條註明必須是 **user token**（project token、global token 不行）。

## 驗證計畫

全部依 CLAUDE.md，在 throwaway 容器內做，不在主機上跑真實 playbook。

1. `uv run ansible-lint`、各 profile 的 `--syntax-check`。
2. 單 role 測試 playbook（放在 scratchpad，不進 repo）連跑兩次，第二次 `changed=0`：
   - 情境 A：無容器 runtime、token 未填 → 安裝 CLI、Java、JAR、wrapper；integrate 被跳過。
   - 情境 B：token 已手動填入 → integrate 執行；第二次不再執行。
   - 情境 C：以 `-e claude_code_sonarqube_token=…` 提供 → token 檔為 0600 且內容正確；**輸出與 `--diff` 中不得出現 token**；integrate 執行；第二次 `changed=0`。
3. **integrate 成功路徑**：在容器內起 SonarQube Community，以 API 產生 user token，再對它執行 integrate，確認 `hooks/sonar-secrets` 與 `~/.claude.json` 的 MCP 項目被寫入。
4. wrapper 的 JAR 分支：對同一個 SonarQube Community 實際以 MCP `initialize` 請求測試。容器分支在有 Docker 的主機上單獨驗證（不在容器內做 Docker-in-Docker）。
5. `get_url` 在 dest checksum 不符時是否重新下載（先裝舊版，再套用 pin）。
6. `claude mcp remove` / `add` 連續執行的冪等性與 `changed_when` 判斷。
7. 發行版矩陣：Ubuntu 22.04、24.04、26.04 與 Debian 13 實際跑 Java 安裝路徑（套件可用性已用 `apt-cache policy` 確認；仍需確認安裝後 `java -version` 主版本 ≥ 21，且 JAR 能啟動）；Debian 12 確認 Java 與 JAR 被跳過並印出 §3b 的訊息。
8. `install_hooks.bash` 參數化的回歸測試：在相同的起始 `settings.json` 上，分別用改前（git 中的版本）與改後（帶 high-watermark 參數）執行，結果必須逐字相同；再註冊 SessionStart 後重跑一次得到 exit 10，且既有的其他 hooks（例如 `sonar integrate` 寫入的兩個）不被移除；確認無變動時不產生 `.bak` 檔。
9. local inventory：(a) 沒有 `local.yml` 時執行各 `bin/setup-*` 會自動建立，權限 0600，且建立者是呼叫者而不是 root（WSL 需以 `sudo` 前後對照）；(b) 已存在時不被覆蓋；(c) 模擬既有 checkout：`git pull` 使 `local.yml` 消失後再跑，能自動補回；(d) 在 `local.yml` 設定 token 後，經 `reexec_with_sudo` 的 WSL 流程仍能讀到並部署（情境 C 的 inventory 版）；(e) 從 repo 根目錄執行 `ansible-lint` 在有／沒有 `local.yml` 兩種情況下都正常。
10. Alpine 守衛：在 Alpine 容器內只執行 `sonarqube-cli.yml` 的守衛 task，確認以 §1 第 0 點的訊息失敗；不驗證 role 的其他部分（它們本來就不支援 Alpine）。

## 已知限制與取捨

- **Docker 已安裝但 daemon 未啟動**（如 rootless docker 尚未起來的 WSL）：provision 判定「有 runtime」而不裝 Java；wrapper 執行時容器不可用又找不到 Java，會走第 3 分支報錯。錯誤訊息與警告 hook 會指出兩種解法。這是「只在無 runtime 時才裝 Java」換取省下約 200 MB 的代價。
- 跑過 `sonar update` 後，下次 provision 會回到 pin（預期行為）。
- 在 `sonar integrate` 重跑時，它會再次寫入 `sonar run mcp`；本設計在同一次 run 的後續 task 取代它。若使用者手動單獨執行 `sonar integrate claude`，MCP 項目會被改回，需要重跑 playbook。
- 沒有在 inventory 設定 token 時（或 local 目標沒用 `-e`），仍需要一次手動步驟：填 token、重跑。
- inventory 有設定 token 時，該 token 檔由 Ansible 擁有，手動修改會在下次 provision 被覆蓋。
- 不寫進 inventory、臨時用 `-e claude_code_sonarqube_token=…` 時，token 會出現在 shell history 與執行期間的 process 清單；建議改寫進 inventory，或用 `-e @<檔案>`（`bin/setup-*` 的 `-e` 直接轉傳）。
