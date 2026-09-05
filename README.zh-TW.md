# Niffler

[English](README.md) · [简体中文](README.zh.md) · 繁體中文

Niffler（重生版）是一個極簡、可自我擴展的 agent harness，理念上與
[Pi](https://pi.dev) 或新的 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
相近。但 Niffler 採用了完全不同的軟體組合方式：Unix 風格的「組件即行程」，
以 NATS 作為通訊平面。組件因此可以用不同語言撰寫、彼此嚴格隔離、
執行期重寫與重啟，甚至遠端執行。

Niffler 的設計是把它 clone 出來、以自己的 git 倉庫為「家」執行，從而可以自我擴展。

Agent 可以在執行期添加能力——寫原始碼、用 `builder` 組件編譯、
透過 `core.spawn` 啟動——全程發生在對話中途。設計理由：
[docs/research/REBOOT.md](docs/research/REBOOT.md)。線上協定：[docs/WIRE.md](docs/WIRE.md)。

```
core (Nim) ── NATS ──┬── store (Nim SDK)           ← 持久化
                     ├── bash (Nim SDK)            ← shell 執行
                     ├── builder (Nim SDK)         ← 組件編譯
                     ├── plugins (Nim SDK)         ← 組件生態
                     ├── skills (Nim SDK)          ← Agent Skills (SKILL.md)
                     ├── fetch (Nim SDK)           ← 網頁內容擷取
                     ├── models (Go SDK)           ← 可插拔模型目錄
                     ├── provider (Go SDK)         ← LLM 供應商登錄檔（持久化）
                     ├── llm (Go SDK)              ← 串流 LLM 配接器
                     ├── edit (Nim SDK)            ← 讀寫檔案工具 + 復原
                     ├── grep (Nim SDK)            ← 程式碼搜尋 + 檔案列表
                     ├── git (Nim SDK)             ← 唯讀倉庫檢查
                     ├── write (Nim SDK)           ← 原子整檔寫入
                     ├── observe (Nim SDK)         ← 匯流排即時檢查
                     ├── logfile (Nim SDK)         ← 輪替 JSONL 日誌
                     ├── cli (Nim SDK)             ← 依需腳本客戶端
                     ├── console (Nim SDK)         ← 依需匯流排檢視器
                     └── 你自己的工具（任何有 SDK 移植的語言）
```

Core 只講一種協定（基於 NATS 的 JSON envelope，見
[docs/WIRE.md](docs/WIRE.md)）；上面列出的每種能力都是獨立行程組件，
使用各自語言的 SDK，而不是編譯進 core 的程式碼。

正常啟動時，`manifest.yaml` 自動啟動 `store`、`bash`、`builder`、
`plugins`、`skills`、`fetch`、`models`、`provider`、`llm`、`edit`、
`grep`、`git`、`observe` 和 `logfile`。除 Go 撰寫的 `models`、`provider`、
`llm` 外，其餘均由 Nim SDK 驅動；`cli` 和 `console` 是內建的 Nim
客戶端，依需執行。另附一個極簡的非串流 Go 配接器 `llm-openai` 作為
替換範例。TypeScript SDK（`sdk/ts`）讓 agent 也可以在對話中途新增
Node.js 組件。

操作指南：[docs/MANUAL.md](docs/MANUAL.md)（環境變數、`.env`、匯流排、
核准、復原、排障，以及發現、模型目錄、觀測/日誌、供應商、fetch、外掛、技能、fabric 與子代理等參考章節）。
更新日誌：[CHANGELOG.md](CHANGELOG.md)。

社群：[Discord](https://discord.gg/ThJFEAJUAk)。

## 快速開始

```bash
make                    # 一次性建置全部
ui/build/bin/niffler-ui # 或點擊安裝好的桌面圖示
```

建置一次，然後啟動 UI——任何 UI（桌面應用、`niffler-tui` 之類的互動式
終端機外掛）都會在 core 未執行時自動啟動它，**最後一個關閉的 UI 會停掉
它啟動的 harness**。

想並行使用多個 UI？手動啟動 core：`./var/bin/niffler`；它的管理
shell 會一直執行，直到你主動停止。然後隨意啟動任意多個 UI。

## 環境需求

Core + 組件需要 **Nim** 和 **Go**（NATS 匯流排伺服器作為組件從原始碼建置——
`components/nats` → `var/bin/nats-server`）；TypeScript 組件和
桌面 UI 額外需要 **Node/npm**（builder 的 `lang: "ts"` 每次建置會從
npm registry 拉取 typescript）；UI 還需要 **wails CLI**，以及（Linux
上）WebKit/GTK 開發程式庫。

```bash
make setup    # 為你的平台安裝一切（Ubuntu/macOS）
make doctor   # 檢查缺了什麼
```

Makefile 會在 `~/go/bin` 裡找到 wails，即使它不在 PATH 上。下面的手動
指令就是 `make setup` 所執行的內容。

### Ubuntu 24.04+

```bash
# Go —— 或從 https://go.dev/dl 下載
sudo snap install go --classic

# Nim 2.x（Ubuntu apt 的版本太舊）—— 會把 ~/.nimble/bin 加入 PATH
curl -sSf https://nim-lang.org/choosenim/init.sh | sh

# nats-server —— 由 `make build` 從原始碼建置（components/nats），無需安裝

# Node/npm（前端；wails 會自己跑 npm install）。Ubuntu 24.04 內建
# node 18，可用。更舊的 Ubuntu 需要 NodeSource 或 nvm —— 見 docs/MANUAL.md。
sudo apt install nodejs npm

# Wails CLI（落在 ~/go/bin —— Makefile 會去那裡找）
go install github.com/wailsapp/wails/v2/cmd/wails@latest

# Wails 建置依賴：webkit2gtk 4.1、GTK3、建置工具
sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev build-essential pkg-config libssl-dev
```

### macOS（Homebrew）

```bash
brew install go nim node
go install github.com/wailsapp/wails/v2/cmd/wails@latest   # → ~/go/bin/wails
```

macOS 無需額外 GUI 依賴——Wails 使用系統 WebKit。請確保安裝了 Xcode
命令列工具（`xcode-select --install`）。

### Nim 套件

Niffler 的 Nim 依賴宣告在 `niffler.nimble` 中（`yaml`，以及來自 GitHub
的 `gokr/natswrapper` 和 `gokr/bitbarrel`），首次建置（`make build`）
時由 nimble 自動安裝。

## 執行

| 指令 | 作用 |
|---|---|
| `niffler-ui` | 桌面 UI——必要時自動啟動 core；最後一個 UI 會停掉自動啟動的 core |
| `./var/bin/niffler` | 終端機裡的 harness：管理 shell，永不自行退出 |
| `./var/bin/niffler --minimal` | 最小啟動設定：只有 `store`、`bash`、`llm` 服務 |
| `make run` | 帶 tty 管理 shell 的 harness（狀態指令） |
| `make test` | 匯流排契約測試套件（每個測試自建匯流排）—— `make test-<comp>` 跑單個組件契約，包括 `test-grep`、`test-git`、`test-edit`、`test-models`、`test-observe`、`test-logfile` |
| `make recover` | 停掉一切，從原始碼重建內建二進位檔，清掉已產生組件記錄，重啟（見下文 Recovery） |
| `make dev` | 瀏覽器裡的 Svelte 開發伺服器（橋接為 stub） |
| `make clean` | 刪除所有建置產物 |

### 最小啟動設定

`./var/bin/niffler --minimal` 啟動最小可用的持久 agent 設定：

| 組件 | 保留原因 |
|---|---|
| `store` | 對話/訊息持久化與組件記錄 |
| `bash` | 一個通用機器工具 |
| `llm` | OpenAI 相容的模型存取與串流輸出 |

Core 和 NATS 匯流排仍然執行；對話首次使用時系統會啟動一個暫時的
`session` runner——這些是控制面行程，不是 manifest 服務。其餘內建
服務——包括 `builder`、`models`、`provider`、檔案工具、plugins/skills、
觀測/日誌——保持停止。agent 自己新增並持久化的組件在此模式下不復原，
但記錄原樣保留，下次正常啟動時回來。這是啟動設定，不是鎖死：
`core.spawn` 之後仍可啟動組件。

沒有 `provider` 或 `models` 服務時，`llm` 直接使用環境變數/`.env`：

```bash
NIF_OPENAI_API_KEY=sk-... \
NIF_OPENAI_BASE_URL=https://api.deepseek.com/v1 \
NIF_OPENAI_MODEL=deepseek-chat \
NIF_OPENAI_CONTEXT=1000000 \
./var/bin/niffler --minimal
```

`NIF_OPENAI_CONTEXT` 可選；不設時 `llm` 使用內建小模型表，再退到
保守的 128K。桌面 UI 總是自動啟動正常設定，所以請先手動啟動
`--minimal`，再啟動 UI；它會掛到已經在跑的 core 上。`--minimal` 可與
`--recover` 組合。

**測試。** `make test` 跑整套：每個非 LLM 組件一個腳本，各自啟動私有
NATS 伺服器，在匯流排上驅動真實二進位檔快照（envelope 即契約——同一個
harness 同時測試 Nim 和 Go 組件）。可寫狀態放在唯一的暫時 `NIF_ROOT`
下，因此組件測試可以與彼此、與開發中的 live harness 並行。
可選開關：`NIF_TEST_INSTALL=1` 會真實安裝 `gokr/niffler-weather`
並驗證其工具；安裝管線本身透過本地 `file://` git 倉庫密封覆蓋。
詳見 [docs/MANUAL.md](docs/MANUAL.md#testing)。

**Harness 自動啟動。** 任何 UI 的第一件事都是 SDK 的 `ensureHarness`：
探測 live core（`NIF_NATS_URL` → `var/nats-url` → 127.0.0.1:4222），
否則自己拉起 `var/bin/niffler`（`NIF_AUTOSTART=1`）。互動式前端註冊
`"client": true`；自動啟動的 core 在最後一個客戶端離開後退出。Core
本身會重用預設連接埠上已在執行的匯流排，否則在那裡拉起內建的 nats-server
組件（`var/bin/nats-server`，4222 被佔用時退回隨機回送連接埠）並寫
`var/nats-url`。設定
`NIF_NATS_URL` 可掛到任意匯流排，包括遠端的。

**核准。** 會改變機器或 harness 的工具——包括 `bash`、`builder.build`、
`edit`/`write`（會寫檔案的工具）、`core.spawn`/`kill`/`remove`——都帶
`x-harness.approval: "always"`，需要真人把關：終端機 harness 裡是 y/N
提示，Web UI 裡是對話框。對話中，請求會路由到驅動該對話的特定互動
組件（其私有 `svc.approval.<name>.request` 主題，由呼叫的自報 `caller`
推導），客戶端不在時廣播兜底。無頭（沒有 UI 掛著）的呼叫會被拒絕——
絕不靜默放行。`NIF_AUTO_APPROVE=1` 可繞過（見
[docs/MANUAL.md](docs/MANUAL.md)）。

**金鑰。** `.env`（gitignored）保存 `NIF_OPENAI_API_KEY` 和
`NIF_OPENAI_BASE_URL`（預設指向 DeepSeek）；已有的 shell 環境變數總是
優先。服務模式（無 tty）：`NIF_NATS_URL=... NIF_OPENAI_API_KEY=...
./var/bin/niffler < /dev/null`。

## 目錄結構

```
docs/                MANUAL.md（操作指南）、WIRE.md（線上協定）、
                     ARCHITECTURE.md（核心邊界）、research/（設計歷史）
manifest.yaml        啟動組件清單
sdk/envelope.nim     envelope 編解碼（std/json，刻意保持可移植）
sdk/niffler/         Nim 組件 SDK（約 250 行）
sdk/go/              Go 組件 SDK（Nim 版的鏡像）
sdk/ts/              TypeScript/Node.js 組件 SDK（鏡像，npm 套件）
core/                catalog、supervisor、dispatch、對話迴圈
components/          Nim：store、bash、builder、plugins、skills、fetch、
                     edit（讀寫檔案工具）、grep、git、observe、logfile、
                     cli、console；Go：models、provider、llm
                     + llm-openai 範例
tests/               匯流排契約套件：helpers + 每組件一個 t_*.nim
ui/                  NATS 之上的 Web SPA —— 方向 + Wails 橋接設計
var/                 執行期：二進位檔、建置快取（gitignored）
```

## 持久化

`store` 和其他組件一樣——一個匯流排上的啞文件儲存
（`put/get/list/del`，基於 rev 的樂觀並行）。底層是**內嵌 BitBarrel**
（Bitcask KV，critbit 索引）的 critbit 模式；恰好一個行程擁有 barrel
檔案（`var/barrel-db`），其餘全部走 envelope——因此後端選擇是封閉、
可替換的（將來帶 FTS/向量的 store-tidb 變體用同樣的工具即可無縫替換）。

Barrel 自帶的 pubsub **刻意不用**——NATS 是唯一匯流排。Kind 鍵：
`component`、`conversation`、`message`、`plugin`（plugins 組件的安裝
記錄）。Core 持久化已產生組件（正常啟動時復原；`--minimal` 有意讓它們
停著）和對話訊息。

**復原。** 倉庫即快照；`var/` 是一次性建置輸出。如果組件損壞——
二進位檔被覆蓋、自加的組件壞了、記錄損壞——`make recover` 從原始碼重建
內建二進位檔、清掉已產生組件記錄並全新啟動（對話保留）。見
docs/MANUAL.md。

## 寫一個組件

Nim —— `import niffler/sdk`，型別化工具模式（doc 註解即 schema）：

```nim
import niffler/sdk

let comp = newComponent("weather", "0.1.0")
comp.tool:
  proc weather(city: string): JsonNode =
    ## Current weather for a city
    ## - city: the city name
    %*{"temp": 21}
comp.run()
```

Go —— `import sdk "niffler.dev/sdk"`，同樣的介面（`Tool`、`On`、`Emit`、
`Request`、`Run`）。

TypeScript —— 跑在 Node.js 下（`import sdk from "niffler-sdk"`，
同樣的介面，handler 可以是 async）：

```ts
import sdk from "niffler-sdk";
const comp = sdk.newComponent("weather", "0.1.0");
comp.tool("weather", {
  type: "object",
  description: "Current weather for a city",
  properties: { city: { type: "string" } },
  required: ["city"],
}, async (_c, args: any) => {
  return { temp: 21, city: args.city };
});
comp.run();
```

其他語言：移植 SDK——envelope 即契約（約 200 行）。

然後：`builder.build {lang, name, source}` → `core.spawn {name, binary}`
→ 工具上線。用 `core.remove {name}` 退役（`core.kill {name}` 暫時停掉）。
Agent 在對話中途自己完成這一切——這就是該架構的驗證標準。

## 組件生態

第三方組件套件以普通 GitHub 倉庫分發——一倉庫 = 一套件 = N 個組件，根目錄
有 `niffler.json` manifest。打上 GitHub topic
[`niffler-component`](https://github.com/topics/niffler-component) 的
倉庫可在對話中發現（說「給我找個天氣組件」）或用 `plugin_search` 搜；
`plugin_install {repo}` 把倉庫 clone 到 `var/plugins/<pkg>@<ref>/`，
透過 `builder` 從原始碼編譯每個組件（與 agent 自寫組件同一條路——無需
額外工具鏈，各平台用自己的編譯），然後 `core.spawn` 每個服務組件
（經真人核准）。Go 組件可以在 manifest 的 `"sources"` 陣列裡列出額外的
同套件檔案。標記 `"interactive": true` 的組件會建置進 `var/bin` 但不
自動啟動，由使用者在終端機裡手動開啟。
`plugin_update` / `plugin_remove` 管理已安裝的套件；安裝記錄存在 store
的 `plugin` 記錄裡，重啟後仍在。

範例套件：[`gokr/niffler-weather`](https://github.com/gokr/niffler-weather)
（Open-Meteo 天氣，無需 API key）。其 README 記錄了 manifest 格式；
其發布流程本身就是 dogfooding——拉起 harness，用 **cli 組件**
（`./var/bin/cli`：`catalog` / `wait` / `call` / `install <repo>[@<ref>]`，
成功即退出 0）驅動它，所以每個 tag 都證明該套件能裝、工具能用。
這套 cli 流程也是給任意外掛倉庫做 CI 的首選方式——Niffler 自己也在用。

## 里程碑狀態

- [x] wire spec、envelope、Nim + Go + TypeScript SDK
- [x] supervisor（spawn/monitor/restart/drain）、catalog、dispatch
- [x] bash + builder 組件、Go 串流 LLM 配接器（OpenAI 相容）
- [x] 型別化工具定義（nimcp 啟發：proc → schema + handler）
- [x] **agent 端到端給自己加工具**（docs/research/REBOOT.md 里程碑，用 DeepSeek
      實測：寫 → 建置 → 啟動 → 呼叫 `greet`）
- [x] **store 組件** —— 匯流排上 barrel 支撐的文件儲存（put/get/list/del，
      基於 rev 的樂觀並行）；core 持久化對話、訊息與已產生組件；已產生
      組件開機復原（形態持久化，跨重啟實測）
- [x] **session 服務** —— svc.core.call 的 `session` 回合 + ev.session.*
      事件；UI 的服務模式（無 tty）；實測通過
- [x] **session runner** —— 一對話 = 一程序：系統為每個對話確保
      `var/bin/session <id>`，並把回合轉發到 `svc.session.<id>.call`；
      runner 是暫時的、從 store 復原；殺掉一個只丟進行中的回合
      （實測：新 runner + 復原 + 乾淨 drain）
- [x] **Wails SPA 外殼** —— Go 橋接（匯流排公民）、Svelte 5 聊天：store
      裡的對話、即時工具卡片、markdown、對話復原、模型/token/上下文
      顯示；建置 + 端到端驗證
- [x] **核准** —— dispatch 裡的 x-harness.approval 攔截器：終端機提示
      （tty）或定向到呼叫方的 UI 核准（帶 ack、廣播兜底、
      ev.approval.resolved 清理）；無人在場即拒絕；端到端驗證（service
      + tty 探針）
- [x] **復原模式** —— `--recover` / `make recover`：從原始碼重建內建
      二進位檔、清已產生組件記錄、保留對話
- [x] **最小啟動設定** —— `--minimal` 只啟動 `store`、`bash`、`llm`，
      直接用 `NIF_OPENAI_*`，已持久化的額外組件保持停止且不刪記錄
- [x] **plugins 組件** —— 匯流排服務形式的生態發現 + 安裝：GitHub topic
      搜尋、`niffler.json` 套件 manifest、總是經 builder 從原始碼建置
      （或用 `file://` 本地倉庫密封安裝）、spawn/update/remove、store
      記錄；用 `gokr/niffler-weather` 端到端實測
- [x] **UI 自持生命週期** —— 任何互動客戶端經 SDK 的 `ensureHarness`
      自動啟動 core；自動啟動的 core 在最後一個互動客戶端離開後退出，
      手動啟動的永不退出。沒有啟動腳本——桌面圖示即整個系統
- [x] **models 組件** —— models.dev 基線 + 內嵌離線種子、驗證過的原子
      快取、嚴格模型解析、可搜尋的能力/限制/價格，以及確定性的
      `x-models-source` 外掛修補與 last-known-good 回退；`llm` 消費其
      上下文元資料
- [x] **provider 組件** —— store 支撐的 LLM 供應商登錄檔
      （add/list/switch/active/remove/export/import，list 永不洩漏
      金鑰）、`ev.provider.switch` 通知、live 後端切換：`llm` 從啟用的
      儲存供應商解析預設值，缺失時回退 `NIF_OPENAI_*` / `NIF_LLM_PROVIDERS`
- [x] **grep + write 組件** —— ripgrep 支撐的程式碼搜尋（`grep`：
      path:line:match 結果，處理 .gitignore/hidden/binary；`files`：排序
      倉庫列表）與核准門控的原子整檔寫入（暫存檔 + rename、保留
      權限）
- [x] **observe 組件** —— 一個精確的原始匯流排 tap、有界 live ring 與
      listen/trace 探針、請求/回應關聯、安全的抓包匯出，以及
      core 發現的 nats-server 監控
- [x] **logfile 組件** —— 所有 SDK 的結構化 `ev.log.*` 事件、輪替
      JSONL 持久化、有界新到舊搜尋、原始整匯流排擷取、顯式的 sink 健康
      上報
- [x] **console 組件** —— 被動匯流排檢視器：訂閱一切，可讀地渲染線上
      流量（第二個終端機裡跑）
- [x] **skills 組件** —— Agent Skills（SKILL.md）：跨標準 agent 目錄
      發現、線上 skills.sh 搜尋（`npx skills find` 後端）、漸進揭露
      載入、依需資源、git 安裝到 `~/.niffler/skills` / 專案
      `.opencode/skills`（無需 Node）、刪除僅限 Niffler 管理的目錄
- [x] **fetch 組件** —— 老 Niffler 的 `fetch` 工具匯流排化：http/https
      支援方法/標頭/內文、Trafilatura 優先的 HTML→文字擷取（純 Nim 回退）、
      重新導向、逾時與大小上限、超大內容落到 `var/fetch` 檔案
- [x] **cli 組件** —— 從終端機或腳本驅動 harness（`catalog` / `wait` /
      `call` / `install`），成功即退出 0；給外掛倉庫做 CI 的首選方式
      （niffler-weather 的 workflow 在用）
- [x] **core 重入** —— dispatch 輪詢私有 inbox，在回合進行中服務
      `svc.core.call`，因此組件回呼 core（`plugin_install` →
      `core.spawn`）不會死鎖對話；並行對話請求排隊，絕不巢狀
- [x] **匯流排契約測試套件** —— `make test`：每個非 LLM 組件一個腳本
      （含 models、observe、logfile、edit），各自在私有 NATS 上驅動
      真實二進位檔；`file://` 密封外掛安裝；網路項在
      `NIF_TEST_INSTALL`/`NIF_TEST_NETWORK` 之後
- [x] **串流輸出** —— `llm` 配接器串流發 `ev.llm.token` 增量（內容 +
      推理），core 轉發為 `ev.session.token`，UI 追加到 live assistant
      氣泡；按呼叫取消（`llm.cancel.<sessionId>`）；最終 assistant 事件
      總是攜帶完整內容
- [x] **hashline-edit** —— 雜湊錨定的 `hashline_read`/`hashline_replace`/`hashline_undo`
      （pi-hashline-edit-pro 的 Nim 移植），錨點跨編輯穩定；已抽出為
      [niffler-hashline](https://github.com/gokr/niffler-hashline) 外掛
- [x] **edit 組件** —— 檔案工具：`read`（純文字、可分頁）、精確文字
      `edit` 作為主編輯器：強制 old_string 唯一（歧義匹配帶次數拒絕）、
      一次呼叫多個不重疊編輯、守護式回退級聯（尾部空白、縮排、Unicode
      標點、塊錨點、轉義文字）、`replace_all`、LF 正規化、原子 `write`
      （自原 write 組件併入）、核准門控、跨重啟持久化的單層
      `undo_last_edit`
- [x] **git 組件** —— 唯讀倉庫檢查（`git_status`/`git_diff`/`git_log`/
      `git_show`/`git_blame`）：無需核准、固定 argv（無 shell）、路徑
      限定在 harness 根目錄並做參數校驗、帶收窄提示的輸出上限、乾淨
      的非倉庫處理；變更類操作留在 bash
- [x] **TypeScript SDK** —— sdk/ts（npm 套件，Go SDK 的鏡像）；builder 經
      tsc 把 `lang: "ts"` 組件編進 node wrapper 二進位檔；實測（builder →
      spawn → 從 Node.js 呼叫）
- [x] **漸進式工具發現** —— 一個完整的全域 catalog，但每個對話凍結
      一個小型不可變直接工具集（13 個內建）；`discover` 把提示/完整
      schema 回傳進 append-only 歷史，`invoke` 經正常核准/逾時路徑呼叫
      任意 live 非隱藏工具（docs/MANUAL.md）；UI Live Components 面板
      按活動對話給 direct/seen/demand/internal 上色
      （tests/t_discover.nim）
- [x] **定向核准路由** —— 核准請求經私有
      `svc.approval.<caller>.request` 路由到驅動回合的組件（ack 門控、
      驅動方不在時廣播兜底、`ev.approval.resolved` 清過期彈窗）；四個
      SDK 的呼叫 envelope 都帶自報 `caller`；Web UI 在私有主題上 ack +
      應答
- [x] **介面在地化** —— Web UI 與 niffler-tui 支援 en/zh/zh-TW 三語
      （自動偵測 + 執行期切換）；CJK 安全的截斷與編輯；面向模型的字串
      保持英文
- [ ] Level 1 UI 動態化：x-ui schema 提示 + 通用渲染器登錄表
- [ ] 終端機 harness + UI 的取消（ev.cancel 流程打磨）

## 任務 —— Niffler 自己該做的事（或者我們閒著的時候做）

1. **store-sqlite 對比** —— 把 components/store/main.nim 移植到 SQLite
   （如 nim-community/libsql），同樣的工具，兩個都跑，對比。契約即
   產物；Niffler 能讀自己的原始碼（`bash cat …/store/main.nim`）、建置、
   拉起並基準測試該變體——真正的 dogfooding 任務。
2. **node/TS 組件 SDK** —— 把 sdk/go（約 200 行）移植到 TypeScript；
   讓 agent 無需編譯步驟就能加 JS 工具。（已完成 —— sdk/ts + builder
   的 `lang: "ts"`；經 tsx 免編譯跑 JS 仍是可能的後續。）
3. **pipewrap** —— stdio/NDJSON 橋，讓普通腳本也能成為組件。
4. **Level 2 UI 動態化** —— builder 把 Svelte 組件編成 JS 模組，
   catalog 註冊 ui-modules，橋接服務 var/ui/，SPA blob 匯入（見
   ui/README.md）。
5. **store-tidb** —— 同樣的工具，SQL 表，FTS + 向量搜尋用於對話記憶；
   跨 harness/主機共享。
6. **組件套件範本倉庫** —— 把 niffler-weather 的倉庫佈局 + 發布 CI 做成
   可 `gh repo create` 的範本；可選地做一個精選索引倉庫用於
   `plugin_search` 排序。
