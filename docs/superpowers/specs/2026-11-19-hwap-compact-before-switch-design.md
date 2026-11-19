# hwap：切帳號前先 compact

## 目標

`high-watermark-auto-pause.sh`(hwap)在帳號用量到門檻、helper 回 `switch <n>` 時，原本立刻 `cswap switch`。換帳號後新帳號要全價重讀整段 context，所以改成先在舊帳號 compact (cache 還熱，便宜)，compact 完才切帳號，再讓 agent 接著做。沒有 tmux/screen 可以送鍵時維持原本的直接切換。

hwap 有自己的狀態機，跟 ideal-compact 的狀態機分開。兩者的交會點列在「與 ideal-compact 的交會點」，兩邊的程式碼都要寫註解指向對方。

## 已驗證 (2026-11-19，Claude Code 2.1.328，tmux，Haiku)

spike 的 hook 只記錄事件並在指定時機用 `tmux send-keys` 送 `/compact`。

- **工作中送 `/compact`**：在主 agent 的 `PreToolUse` hook 裡送出，`/compact` 會排隊，等這一輪 `Stop` 之後約 0.1 秒才執行，不會插在兩個 tool call 之間。送出後同一輪剩下的 `PreToolUse` 全部照常觸發 (實測 4 次)。排隊的 `/compact` 不觸發 `UserPromptSubmit`
- **背景工作**：主 agent `Stop` 時就算 `background_tasks` 有 `shell` 或 `subagent`，`/compact` 也立刻執行。背景 shell 與 subagent 跨過 compact 繼續跑，結束後照常把結果送回主 agent
- **Agent tool 一律在背景跑**：要求前景時 Agent tool 也在 0.3 秒內回傳，subagent 在背景跑。所以主 agent 不會被 subagent 卡住而無法 `Stop`。在 subagent 自己的 `PreToolUse` 裡送 `/compact`，主 agent 已經停著，`/compact` 0.1 秒後就執行，subagent 不受影響
- **handback 是 `UserPromptSubmit`**：subagent 的 `SubagentHandback` 與背景 shell 結束的通知都會觸發主 agent 的 `UserPromptSubmit`，`prompt` 開頭分別是 `<agent-message ` 與 `<task-notification>`
- **compact 會觸發一次 `SubagentStop`**：是 compact 用的摘要 agent，hwap 不註冊這個事件
- **block 使用者 prompt 再送 `/compact`**：在 `UserPromptSubmit` hook 裡先送 `/compact` 再輸出 `{"decision":"block",...}`，`/compact` 立刻執行，被 block 的 prompt 會被放回輸入框 (游標在文字尾端)，畫面上另有一則 `UserPromptSubmit operation blocked by hook` 附原本的 prompt

spike 腳本與 log 放在這個 session 的 scratchpad，沒有保留。

實作後的端對端測試 (同一環境，stub helper 只回一次 `switch 2`，假的 `cswap`)：

- **主 agent 的 tool call 觸發**：agent 跑完第 1 個 tool 就照停下指示結束這一輪，排隊的 `/compact` 在 `Stop` 後執行，PostCompact 送出「繼續」，agent 依摘要跑完第 2 到第 5 個
- **使用者 prompt 觸發**：prompt 被 block，`/compact` 立刻執行，被放回輸入框的 prompt 跟存下的一致，PostCompact 只送 CR，prompt 照常執行
- **沒有對話時 `/compact` 會失敗**：新 session 的第一個 prompt 就觸發時，`/compact` 回「Not enough messages to compact」，`PreCompact` 有觸發但 `PostCompact` 不會，流程就會卡在 `compacting`。所以啟動條件加上條件 0

## 狀態

`<session dir>/hwap-compact-state`，key=value 行，跟 ideal-compact 的狀態檔同一種讀寫方式 (不 source，temp 檔加 mv，寫入者持 `<session dir>/hwap-compact-state.lock`)。

- `phase`：`idle`(預設)、`queued`、`stopping`、`compacting`、`waiting`
- `phase_at`：`phase` 最後一次改變的時間
- `stop_pending`：1 表示有一個停下指示要在主 agent 下一次 tool 事件送出
- `interrupted`：1 表示停下指示確實送到了主 agent
- `pc_pid`：`waiting` 時 PostCompact hook 的 pid
- 被 block 的 prompt 原文存在另一個檔 `<session dir>/hwap-compact-prompt`，因為它可能有多行

| phase | 意義 |
|---|---|
| `idle` | 沒事，gate 照舊 |
| `queued` | 已送 `/compact`，等這一輪 `Stop` |
| `stopping` | 主 agent 已 `Stop`，等 `/compact` 開始 |
| `compacting` | `PreCompact` 已確認，等 `PostCompact` |
| `waiting` | `PostCompact` 正在切帳號或等可用帳號 |

## 轉換表

由上而下比對，逾時最先處理。表裡沒有的組合不改狀態。「主 agent」指 hook 輸入沒有 `agent_id`。「handback」指 `prompt` 以 `<agent-message ` 或 `<task-notification>` 開頭。

| 從 | 事件 | 條件 | 到 | 副作用 |
|---|---|---|---|---|
| `stopping` | 任何事件 | 距 `phase_at` 超過 `HWAP_STOPPING_TTL_SEC`(120) | `idle` | 鍵遺失，清 `stop_pending`、`interrupted`、prompt 檔 |
| `compacting` | 任何事件 | 距 `phase_at` 超過 `IDEAL_COMPACT_COMPACT_TTL_SEC`(900) | `idle` | 同上 |
| `waiting` | 任何事件 | `pc_pid` 已不存在 | `idle` | 同上 (PostCompact 被 SIGKILL) |
| `idle` | 主 agent `PreToolUse`，gate 回「要切換」 | 可以啟動 (見下) | `queued` | 送 `/compact`，`interrupted=1`，輸出 `PreToolUse` `additionalContext` 停下指示 |
| `idle` | subagent `PreToolUse`，gate 回「要切換」 | 可以啟動 | `queued` | 送 `/compact`，`stop_pending=1`，不輸出 (subagent 照常做事) |
| `idle` | 使用者 `UserPromptSubmit`，gate 回「要切換」 | 可以啟動 | `queued` | 存 prompt 檔，送 `/compact`，輸出 `decision: block` |
| `idle` | handback `UserPromptSubmit`，gate 回「要切換」 | 可以啟動 | `queued` | 送 `/compact`，`interrupted=1`，輸出 `UserPromptSubmit` `additionalContext` 停下指示，不 block (擋掉會遺失結果) |
| `idle` | 上面四種 | 不能啟動 | `idle` | 原本的 gate，直接切帳號 |
| `compacting` | 主 agent `PreToolUse` | 無 | `idle` | compact 進行中主 agent 不會呼叫工具，有就代表 compact 失敗了 (不會有 PostCompact)，接著照 `idle` 處理這次呼叫 |
| `queued`、`stopping`、`compacting` | `PreToolUse`、`UserPromptSubmit` | 無 | 不變 | 放行，不跑 gate，不重送。主 agent 的事件 (含 handback) 遇到 `stop_pending=1` 時清掉它、設 `interrupted=1`、輸出停下指示 |
| `queued`、`stopping` | 主 agent `PostToolUse` | `stop_pending=1` | 不變 | 同上，輸出 `PostToolUse` `additionalContext` |
| `queued` | `Stop` | 無 | `stopping` | 無 |
| `queued`、`stopping` | `PreCompact` | 無 (`manual` 或 `auto` 都算) | `compacting` | 清 `stop_pending`，不設 `interrupted` |
| `compacting` | `PostCompact` | 無 | `waiting` | 記 `pc_pid`，跑 `__gate`(會直接切帳號，沒有可用帳號就等) |
| `waiting` | `PreToolUse`、`UserPromptSubmit` | 無 | 不變 | 原本的 gate (剛 compact 完，直接切幾乎不花錢) |
| `waiting` | gate 放行 (或 helper 錯誤) | 重讀仍是 `waiting`，有後端 | `idle` | 見「compact 之後送什麼」 |
| `waiting` | SIGTERM、SIGHUP | 無 | `idle` | 不送任何東西，以 1 結束 |
| 任何 | `SessionStart` `startup`、`resume`、`clear` | 無 | `idle` | 清空所有欄位與 prompt 檔 |

**可以啟動**的條件，全部成立才進 `queued`：

0. transcript 在最後一個 `compact_boundary` 之後有 `"role":"assistant"` 的行 (讀不到 transcript 時視為有)。沒有的話 `/compact` 會失敗，而 context 這麼短，直接切帳號也不貴
1. `__mux_backend` 找得到後端
2. ideal-compact 的 `phase` 是 `standby`、`armed` 或 `stopped`。其他 phase 代表它自己的 compact 正在進行或剛結束，見交會點
3. `__mux_inputbox_state` 是 `empty` 或 `placeholder`
4. 持鎖重讀 hwap 的 `phase` 仍是 `idle`。不是的話別的 hook 已經啟動了，這次照 `queued` 的那一列處理 (放行，有 `stop_pending` 就帶出停下指示)
5. 持 ideal-compact 的鎖重讀它的 `phase`，仍是 `standby`、`armed` 或 `stopped`。不是的話 hwap 退回 `idle`，走原本的 gate。`/compact` 送失敗時也退回 `idle`，並把啟動時設的 `skip` 還原

**`interrupted` 的意義**：停下指示確實送到了主 agent，也就是主 agent 是被 hwap 打斷的。subagent 觸發時主 agent 如果正在等待，沒有 tool 事件可以帶出指示，`/compact` 會在它 `Stop` 時就執行，`interrupted` 保持 0。主 agent 如果沒呼叫 tool 就自己結束這一輪，也保持 0。

### compact 之後送什麼

依序判斷，鍵送出前先寫 `idle`：

1. 有 prompt 檔：被 block 的 prompt 已經被 Claude Code 放回輸入框
   - 輸入框是 `draft`，而且 (只有 tmux 能比對) 框內文字去掉所有空白後等於 prompt 去掉所有空白：只送 CR
   - 輸入框是 `empty` 或 `placeholder`，prompt 只有一行：用 `__mux_send` 打 prompt
   - 其他 (內容不符、screen 的 draft、多行 prompt 而框是空的、`unsure`)：不送，使用者可能在打字，stderr 留一行說明
2. `interrupted=1`：輸入框是 `empty` 或 `placeholder` 才送「繼續」(`IDEAL_COMPACT_CONTINUE_TEXT`)，否則不送
3. 其他：不送。主 agent 原本就在等背景工作，handback 會叫醒它

## 文字

常數放在 `common-helpers.sh`，跟 ideal-compact 的放在一起。

- `HWAP_STOP_TEXT`：停下指示。帳號用量到上限，系統已排定在這一輪結束時 compact 並切帳號。這個工具呼叫 (或這則訊息) 處理完就停下，不再呼叫工具，不開始新工作，一句話說明做到哪裡就結束這一輪。背景 subagent、shell 可以繼續跑，不用等。compact 後系統會叫你繼續
- `HWAP_COMPACT_TEXT`：接在 `/compact` 後面的摘要指示。保留正在做的工作做到哪一步、下一步、還在背景跑的工作、等使用者回答的問題，compact 後依摘要接著做
- `HWAP_BLOCK_REASON`：block 的理由，讓使用者知道 prompt 會在 compact 與切帳號後自動送出

## 與 ideal-compact 的交會點

兩個狀態機各自一個狀態檔。交會點只有以下幾個，每一點兩邊都要有註解：

1. **hwap 讀 ideal-compact 的 `phase` 決定能不能啟動**(條件 2)。讀取與設 `skip` 都在 ideal-compact 的鎖 `ideal-compact-state.lock` 之下
   - `standby`：啟動。ideal-compact 的 `PreCompact` 在 `standby` 時只加 `dirty`
   - `armed`：搶過來。啟動時持 ideal-compact 的鎖重讀，仍是 `armed` 就設 `IC_skip=1`(跟 `/ideal-compact-skip` 一樣，擋下這一輪的 `idle_prompt` compact)。之後 ideal-compact 的 `PreCompact` 看到不是自己送的 manual compact，依原本規則接手：回到 `standby`、設 `suppress`。切帳號後 `suppress` 因帳號 key 改變而解除
   - `stopped`：主 agent 已停下，不會有 `PreToolUse`，只可能由 prompt 或 handback 觸發。跟 `armed` 一樣搶過來 (設 `IC_skip=1`)，使用者的 prompt 另外也會讓 ideal-compact 自己接手
   - `to-compact`、`compacting`：ideal-compact 的 `/compact` 已在排隊或進行，它的 `PostCompact` 會切帳號。hwap 不啟動，走原本的 gate
   - `waiting`、`continuing`：ideal-compact 的 `PostCompact` 已經或正在選帳號。hwap 不啟動，走原本的 gate。這時背景 subagent 的 tool call 可能讓 hwap 的 gate 直接切帳號，跟 ideal-compact 的 `__pick_switch` 挑的帳號可能不同，最壞是多切一次
2. **同一個 `PreCompact`/`PostCompact` 兩邊都會收到**：各自只看自己的 phase。hwap 的 compact 讓 ideal-compact 進 `standby`，所以 ideal-compact 的 `PostCompact` 不動作，只有 hwap 送後續的鍵。ideal-compact 自己的 compact 進行時 hwap 不會在 `queued`/`stopping`(條件 2)，所以 hwap 的 `PostCompact` 不動作
3. **hwap 送的「繼續」與重送的 prompt 經過 ideal-compact 的 `UserPromptSubmit`**：ideal-compact 只在自己是 `continuing` 時把「繼續」當系統訊息。這時它是 `standby`，當成一般 prompt，而 `standby` 時一般 prompt 只加 `dirty`，不觸發接手
4. **ideal-compact 的 `Stop` 檢查**：hwap 的停下指示不要求 `[[STOP_FOR_COMPACT]]`。ideal-compact 在 `armed` 時看到沒有標記的 `Stop` 就維持 `armed`，接著被 `PreCompact` 轉成 `standby`
5. **共用的程式碼**：`__gate`、`__mux_*`、`__lock`、`__session_dir`、`__state_read`/`__state_write`(讀寫 ideal-compact 狀態)、handback 的判斷

## `__gate` 的改動

`__gate [abort_fn] [defer]`：`defer` 是 1 時，helper 回 `switch <n>` 不切換，回傳 5。PostCompact 切換時會重新問 helper，所以不保留帳號編號。hwap 啟動不了 compact 流程時再呼叫一次不帶 `defer` 的 `__gate`，照原本切換。PostCompact 的等待一律不帶 `defer`。ideal-compact 的呼叫不變。

共用的新函式：`__proc_claude_alive`(從 ideal-compact 的 `__ic_wait_abort` 抽出)、`__is_handback`(從 ideal-compact 的 `__on_prompt` 抽出)、`__mux_box_text`(tmux 輸入框文字，去掉空白)、`__mux_cr`(只送 CR)。

## 註冊

hwap 的事件從 `PreToolUse:691200 UserPromptSubmit:691200 Stop` 改成再加上 `PostToolUse PreCompact PostCompact:691200 SessionStart`。

`PostToolUse` 每個工具呼叫都會跑，快速路徑：狀態檔不存在，或 `phase` 是 `idle`，或 `stop_pending` 不是 1，就立刻結束，不呼叫 helper。

## 不做的事

- 被 block 的 prompt 含有圖片：先不處理
- statusline 不顯示 hwap 的 phase
- 沒有 mux 時不嘗試停下 agent，直接切帳號 (跟原本一樣)
