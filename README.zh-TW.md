# stingray

[English](README.md) | **繁體中文**

[![tests](https://github.com/Nanako0129/stingray/actions/workflows/tests.yml/badge.svg)](https://github.com/Nanako0129/stingray/actions/workflows/tests.yml) [![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> 專給「話說完、事沒做」的對話輪次使用的 Claude Code `Stop` hook。它攔截三種半途收尾：停下來卻什麼都沒做、宣告動作卻沒呼叫對應工具、承諾盯著背景工作卻沒有任何排程或輪詢正在執行。hook 會攔下收尾並送出提示，不讓那一輪帶著空頭支票結束。

魟魚貼在沙地上不動，沒踩到就不會有動靜。這個 hook 原理相同：正常對話保持安靜，只有在該繼續做卻提早收尾時介入。所有判斷都交給 [Jev](https://typesafe.ai)：這一輪有沒有動手、有沒有違背自己說的話、有沒有承諾要盯著什麼、是不是用錯語言。唯一在本機計算的是背景有什麼正在跑。

```
你：      修掉那個 timeout，然後跑測試
claude：  我現在就改設定值，然後跑測試套件。
          〔對話結束。什麼都沒改，什麼都沒跑。〕

          ── stingray ──────────────────────────────────────────
          這一輪看起來停在半路
          （宣告了要做的事，但這一輪的動作交代不了它）

claude：  〔改設定、跑測試〕
```

## 目錄

- [它抓什麼](#它抓什麼)
- [摩擦只會往上加](#摩擦只會往上加)
- [安裝](#安裝)
- [API key](#api-key)
- [開關（預設全關）](#開關預設全關)
- [什麼東西會離開你的電腦](#什麼東西會離開你的電腦)
- [校準](#校準)
- [延遲](#延遲)
- [迴圈防護](#迴圈防護)
- [已知限制](#已知限制)
- [Stop hook 的實測契約](#stop-hook-的實測契約)
- [目錄結構](#目錄結構)
- [測試](#測試)
- [支持](#支持)
- [授權](#授權)

---

## 它抓什麼

| # | 形狀 | 由誰判斷 |
|---|------|----------|
| 1 | `no_action` ── 停下來卻什麼都沒做，而當下本可執行動作 | [Jev](https://typesafe.ai) |
| 2 | `broken_promise` ── 宣告了動作，但本輪工具呼叫無法交代 | Jev |
| 3 | `unwatched` ── 承諾盯著外部進度（CI、建置、PR 審查） | Jev，對照本機計數（詳見下文） |
| 4 | `wrong_language` ── 最後一則訊息不是設定裡指定的語言 | Jev |

形狀 3 請 Jev 判斷最後一則訊息是否承諾要盯著某個外部結果，或宣稱它設下的監看正在進行（`watch_claim`），再拿這個答案對照本機計算的數字：

- **沒有東西在跑：** 執行中的背景工作數、`session_crons` 數，加上交給其他 Claude session、還在等回覆的交辦數，總和**等於 0**。承諾背後什麼都沒有，開了 `STINGRAY_SHAPE3=1` 就攔下。
- **有東西在跑：** 計數**大於 0**，但這不代表在跑的就是承諾要盯的那個──背景在跑建置，承諾盯的卻是 PR 審查，數字一樣大於 0。這點也問 Jev（`watch_mismatch`，同一次請求），而且只有開了 `STINGRAY_SHAPE3_JUDGE=1` 才會攔。

交辦指的是用 `SendMessage` 送給另一個 Claude session（結果會寫明對象是另一個 session），而 transcript 裡在那之後還沒有那個 session 發回的 `<cross-session-message>`。「已交給 Windows session，等它回報」曾經在真的這樣交辦過的一輪被攔下，因為 Stop 的 payload 裡，兩份清單都看不到「已送出、等回覆」的訊息。送給同一個 session 內 subagent 的訊息不算：執行中的 subagent 本來就算背景工作。

計數是確定的；有沒有承諾是判斷。0.3.0 以前這部分是一組正規表達式，它讀的是主題而不是承諾：只是**引用**「keep an eye on」這幾個字的回覆會把自己攔下，而「I'll keep monitoring the build」以及任何日文、韓文的承諾都抓不到。在 `tests/watch-fixture.tsv` 的 50 則標好答案的句子上（包含每一句曾經誤攔真實對話的；原文屬於私人 session 的，改用合成的替身），承諾都在 0.68 以上，其他都在 0.20 以下，「keep an eye on the review」則落在門檻上。

攔下收尾時送出的提示為固定字串，輸出至 stderr，並非針對個案生成的批評。提示提供三種因應方式：完成工作、啟動輪詢，或具體說明卡在哪個決策。

形狀 4 從 Claude Code 的設定讀 `language`，順序是專案的 `.claude/settings.local.json`、專案的 `.claude/settings.json`，最後是 `CLAUDE_CONFIG_DIR` 底下的使用者 `settings.json`，再請 Jev 判斷最後一則訊息的正文是不是用這個語言寫的。任何目標語言都可以；`zh-TW` 這類常見代碼會轉成名稱「繁體中文（台灣，zh-TW）」再送，Jev 讀名稱遠比讀代碼可靠。提示會要求用該語言把同一則訊息重寫一次，code 與識別字維持原樣。

只有正文夠多時才會問：拿掉 code、inline code、URL、引用區塊與路徑之後至少 12 個單位，漢字、假名、韓文各算一個，其他文字系統以字詞計。沒有這個下限時，一行測試結果會被判定「不是中文」──說得沒錯，但沒有用。

它跟形狀 1、2 一樣需要 API key，送出的也是同一份遮蔽過的最後一則訊息。它取代了一條本機規則：那條規則拿漢字對英文字詞計數，只看得見英文──日文會被算成中文，韓文和俄文則什麼都算不到。

語言題看到的訊息，語言**名稱**會先換成佔位詞 `〔語言〕`。問 Jev「這則是不是用繁體中文寫的」時，它會把只是**提到**簡體中文的回覆，當成用簡體中文寫的：「E（簡體中文，#142）已用 merge commit 合併。…」連續攔了三輪，分數 0.62–0.79。換掉名稱後，這則和它被攔後的重寫版透過 hook 得 0.09–0.12；真正用簡體中文、英文、日文、韓文寫的回覆，仍以 0.64–0.97 被攔下。改寫題目的判斷標準則沒用：誤判仍在 0.62–0.91，還讓一則韓文回覆掉到門檻以下。形狀 1、2 收到的訊息不受影響。

## 摩擦只會往上加

所有例外路徑皆會以 exit 0 退出：缺少 API key、缺少 `jq`、找不到 `questions.json`、非 loopback 的純 HTTP 端點、送出前掃描命中憑證特徵、網路逾時、HTTP 非 200 回應、格式錯誤的回傳本體、評分超出 [0, 1] 或低於門檻、無法讀取 `background_tasks`，以及無法寫入攔阻計數。

在任何失敗情況下，行為與未安裝此 plugin 完全一致。stingray 只能督促模型繼續處理，無法替模型免除工作。所有失敗皆屬字面意義上的 fail-open──對話輪次依原樣結束。由於被扣下的是一句提示而非執行權限，設定失效不會讓它核准任何工作。但服務中斷確實代表這一輪沒有被檢查過就結束了──那跟你沒裝這個 plugin 的處境相同，這也正是這個失敗方向安全的理由，只是它不等於「檢查過了」。

## 安裝

> **提醒：** 下面每一行指令都寫成 **user scope**──裝一次，每個專案都能用。

### Claude Code plugin

```bash
# 安裝
claude plugin marketplace add Nanako0129/stingray
claude plugin install stingray@stingray --scope user

# 更新
claude plugin marketplace update stingray
claude plugin update stingray

# 移除
claude plugin uninstall stingray
```

> **提示：** 對話中的 `/plugin install` 選單會詢問安裝範圍，請選擇 **User**。

> **驗證說明：** manifest 與上述指令皆已對本機原始碼實際驗證：marketplace 註冊成功、`plugin install` 回報成功、`plugin list` 顯示 `stingray@stingray` 在 user scope 啟用。在未設定開關的情況下，輸入本會觸發形狀 3 的資料，hook 回傳 exit 0 且未建立狀態目錄。`Nanako0129/stingray` 形式亦於合併後以相同方式驗證：自 GitHub 加入 marketplace、以 user scope 安裝，確認未設開關時依舊 exit 0 且不寫入狀態檔。

**僅完成安裝不會執行任何動作。** 未設定開關前 hook 保持關閉。開關請寫在 `~/.claude/settings.json` 的 `env` 區塊：

```json
{
  "env": {
    "STINGRAY_SHAPE3": "1",
    "STINGRAY_LANG": "1"
  }
}
```

`STINGRAY_SHAPE3` 是監看檢查，`STINGRAY_LANG` 是語言檢查。兩者都由 Jev 判斷，所以都需要 API key、都會送出遮蔽過的最後一則訊息；沒有免 key 的模式。已取得 API key 的話，改從 `"STINGRAY_SHADOW": "1"` 開始：呼叫 Jev、寫入決策紀錄，但絕不攔下收尾。改完檔案後重新啟動 Claude Code。

> **為什麼不在 shell 裡 `export`：** Claude Code 啟動時會自己讀 `settings.json`，所以不管用什麼方式啟動，每個 session 都拿得到開關。shell 的 `export` 只對「那一行加進去之後才開的 shell」所啟動的 session 有效；之前就開著的終端機分頁、桌面版、IDE 擴充都讀不到，hook 就會什麼都不做、也不告訴你。這是實際踩過的：一個開了八天的分頁，啟動的 session 一個開關都沒有。

確認 plugin 已載入且未主動攔截：

```bash
claude plugin list | grep stingray
tail -f ~/.local/state/stingray/decisions.jsonl   # 形狀 3 攔下收尾前也會寫入
```

### Codex plugin

建議直接從 GitHub marketplace 安裝 Codex hook：

```bash
codex plugin marketplace add Nanako0129/stingray
codex plugin add stingray@stingray
```

根目錄的 `.codex-plugin/plugin.json` 明確指定 `hooks/hooks.codex.json`，
所以 Codex 不會載入 Claude 的 `hooks/hooks.json`。兩份 manifest 使用相同
版本，CI 會檢查一致；Git tag 本身就包含該版本的兩種 plugin，不需另外附 ZIP。
更新時執行 `codex plugin marketplace upgrade stingray`，再執行
`codex plugin add stingray@stingray`。

安裝或更新後請開新 Codex session。啟用前先用 `/hooks` 檢查並信任下載的
Stop hook，因為它會在本機執行 shell 指令。安裝本身不會啟用 Stingray 檢查。
請在 **Codex 程序的環境變數**設定 `STINGRAY`、`STINGRAY_SHAPE3` 或
`STINGRAY_SHADOW`，並提供 `TYPESAFE_API_KEY` 或
`~/.config/typesafe/api_key`。從 v0.3.0 起，形狀 3 也需要 key，並會把遮蔽過的
最後訊息送到 TypeSafe；在 shell 裡設定環境變數，不會影響已在執行的 Codex
桌面程序。目前 Codex Stop payload 若未提供背景工作狀態，形狀 3 會視為未知，
不會用這項檢查攔阻。

在 Codex 裡，形狀 1、2 是在看不到這一輪工具清單的情況下判斷的：payload 沒有可用來切
transcript 的 `prompt_id`，所以 hook 送出的是「這一輪的工具清單無法取得」，而不是
「沒有呼叫任何工具」。用 5 則已完成工作的回覆實測：沒有一則被攔，但 `no_action`
從有工具清單時的 0.06–0.15 升到沒有時的 0.32–0.38，門檻 τ = 0.5。81.8% 不涵蓋
Codex；在 Codex 請先從 `STINGRAY_SHADOW=1` 開始。

### 手動串接 hook

亦可直接以 shell 腳本形式掛載：

```bash
git clone https://github.com/Nanako0129/stingray ~/stingray
```

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command",
                     "command": "/bin/bash \"$HOME/stingray/hooks/stingray.sh\"",
                     "timeout": 10 } ] }
    ]
  }
}
```

請務必明定 `timeout`。Claude Code 對 hook 的預設逾時為 **600 秒**；明確設定可避免端點無回應時卡住收尾長達十分鐘。

### 環境需求

macOS 與一般 Linux 發行版皆內建 `bash`、`curl` 與 `perl`。**macOS 預設未安裝 `jq`**。若缺少 `jq`，hook 會在判斷任何形狀前直接 exit 0，並輸出 `(stingray: unavailable — jq not found)`：

```bash
command -v jq || brew install jq      # macOS
command -v jq || sudo apt install jq  # Debian/Ubuntu
```

不需安裝額外 SDK 或相依套件。

`STINGRAY_ENDPOINT` 僅接受 HTTPS URL，或限定 loopback 本機測試伺服器的純 HTTP。請求一律帶有 `Authorization: Bearer` 標頭；非 loopback 的未加密連線會遭拒絕，避免憑證以明文傳輸。

## API key

每一項檢查都會呼叫 TypeSafe System One（`jev-1.13.0`）：形狀 1、形狀 2、形狀 3 的承諾與對應判斷，以及語言檢查。

1. 前往 <https://typesafe.ai> 取得 key。
2. 存入 `~/.config/typesafe/api_key`（`chmod 600`），或設定環境變數 `TYPESAFE_API_KEY`。建議使用檔案儲存，環境變數容易暴露給子行程。

**未設定 key 時，stingray 什麼都不做。** 它會在每個 session 輸出一次 `(stingray: unavailable — no key; Jev checks skipped)`，不會無聲停擺。

## 開關（預設全關）

每個開關控制 hook 是否介入對話。在預設情況下，所有開關都是關閉的，hook 會直接結束，不執行任何檢查、不送出網路請求，也不建立檔案。

開關優先順序與行為：

1. **未設定（預設）：** hook 立即以 exit 0 退出。不執行檢查、不送出請求、不建立檔案。
2. **`STINGRAY_SHAPE3=1`（監看檢查）：** Jev 判定最後一則訊息承諾要盯著某件事、而背景沒有任何工作或排程時，攔下收尾。需要 API key，會送出遮蔽過的最後一則訊息。不會問形狀 1、2。
3. **`STINGRAY_SHADOW=1`（觀察模式，優先序最高）：** 呼叫 Jev 評估形狀 1 與 2，並將決策寫入紀錄檔，但**絕不攔下收尾**。若設定了此變數，它會覆蓋 `STINGRAY=1` 與 `STINGRAY_SHAPE3=1` 的攔阻行為。有 API key 時建議從這裡開始。
4. **`STINGRAY=1`（主動攔阻模式）：** 啟用形狀 1 與 2 的主動介入。由 Jev 判定為未執行動作或未履行承諾時，攔下收尾並提示助理繼續完成。
5. **`STINGRAY_LANG=1`（語言檢查）：** Jev 判定最後一則訊息不是設定的 `language` 時攔下收尾。需要 API key，會把遮蔽過的最後一則訊息連同一個題目送出；同時開了 `STINGRAY=1` 的話，就併在同一次請求裡。它不會順帶打開形狀 3，也不會問形狀 1、2。
6. **`STINGRAY_SHAPE3_JUDGE=1`（形狀 3 語意比對）：** 額外允許形狀 3 的判斷層攔下收尾（當背景有工作在跑，但模型判定在跑的工作與承諾不符）。需同時啟用 `STINGRAY_SHAPE3=1`。即使啟用形狀 3 攔阻，此項預設仍然關閉，因為該門檻尚未經過量測。

| 變數 | 效果 |
|---|---|
| *（未設定）* | **預設。** hook 立即以 exit 0 退出。不執行檢查、不發送請求、不建立狀態檔。 |
| `STINGRAY_SHADOW=1` | 呼叫 Jev 評估並記錄決策，**絕不攔下收尾**。優先序高於 `STINGRAY=1`、`STINGRAY_SHAPE3=1` 與 `STINGRAY_LANG=1`。有 key 時建議由此開始。 |
| `STINGRAY=1` | 依 Jev 判讀結果，在形狀 1 與形狀 2 觸發時攔下收尾。 |
| `STINGRAY_SHAPE3=1` | Jev 判定有承諾要盯、而背景沒有任何工作或排程時攔下收尾。需要 key，會送出遮蔽過的最後一則訊息。優先序低於 `STINGRAY_SHADOW=1`。 |
| `STINGRAY_LANG=1` | 針對形狀 4 攔下收尾：Jev 判定最後一則訊息不是設定的 `language`。需要 key，會送出遮蔽過的最後一則訊息。優先序低於 `STINGRAY_SHADOW=1`，後者只記錄不攔。 |
| `STINGRAY_SHAPE3_JUDGE=1` | 允許形狀 3 的**對應判斷**攔下收尾（背景工作數大於 0，但模型判定與承諾不符）。預設關閉；需同時設定 `STINGRAY_SHAPE3=1`。不論開關為何，皆會記錄判斷。 |

最小的設定是單獨開 `STINGRAY_SHAPE3=1`：每一輪一個題目，問回覆有沒有承諾要盯著什麼。背景有東西在跑時，同一次請求會再帶第二題（`watch_mismatch`），而且連同工具清單與背景狀態一起送出；即使 `STINGRAY_SHAPE3_JUDGE` 沒開，也會問、也會記錄。

其餘參數設定：`STINGRAY_TAU`（0.5）、`STINGRAY_TIMEOUT`（6 秒）、`STINGRAY_MAX_BLOCKS`（每 session 上限 3 次）、`STINGRAY_STATE_DIR`（`~/.local/state/stingray`）、`STINGRAY_REDACT_WORDS`（額外指定遮蔽字串），以及 `STINGRAY_JEV_MODEL`（`jev-1.13.0`，釘死版本以避免分類器無預警變更）。

## 什麼東西會離開你的電腦

只會傳輸下列欄位，且只有在設定 API key 後才會發送：

| 欄位 | 內容 |
|---|---|
| `final_text` | 助理最後一則訊息，經遮蔽後截斷至最後 2400 **位元組**──約 800 個中文字，但純 ASCII 約為 2400 字元。英文對話送出的字元量約為基準量測情境的三倍。 |
| `tools` | 本輪呼叫的工具**名稱**與次數，不含任何參數。 |
| `background` | 背景工作的狀態與**描述**；排程 cron 的**指令提示**（prompt）。兩者與訊息走相同遮蔽管線，並預先過濾憑證特徵。命令列指令一律不送出。還在等回覆的交辦只送對方 session 的**名稱**，不送訊息內容。 |
| `language` | 設定的語言，以名稱送出──只在語言題上，那一題只帶這個與 `final_text`，不帶其他東西。這一題的 `final_text` 會先把「簡體中文」「English」這類語言名稱換成 `〔語言〕`。 |

使用者輸入給 Claude 的 prompt 絕不傳送。工具參數、檔案內容、diff 與終端機指令亦絕不傳送。

**排程 cron 的指令提示會被送出。** 欲判定排程工作是否符合當初承諾，必須讀取交代給該排程的工作內容。

資料遮蔽管線會移除 code fence、引用區塊、inline code 與 URL；整行刪除含有絕對路徑、相對路徑或檔名的文字；並遮蔽 commit SHA、issue 編號與專案名稱。專案名稱由 hook 所在目錄及 git remote URL 動態推導。對話中提及的周邊專案無法自動推知；若需遮蔽，請列入 `STINGRAY_REDACT_WORDS`。

截斷處理發生在資料遮蔽**之後**。若先截斷再遮蔽，可能切斷 code fence 標記，破壞結構配對而導致程式碼區塊外洩。

請求送出前會經過兩道憑證防護：
1. 遮蔽管線第一階段移除 `Authorization` 標頭、獨立的 Bearer 或 Basic 權杖、名稱為 `api_key`、`auth_token`、`secret`、`password` 的欄位，以及 `github_pat_`。
2. 發送前掃描 payload，檢查是否含有 `sk-`、`gh[pousr]_`、`github_pat_`、`AKIA` 或 PEM 標頭。一旦命中即刻取消發送，該對話輪次正常結束。

### 檢視實際送出的內容

```bash
./tests/show-payload.sh 50
```

該腳本使用真實 hook 對本機記錄伺服器執行，並將實際送上網路的位元組寫入 `payload-audit.txt`。此機制檢視的是真實封包，而非過濾器預期移除的項目。

### 遮蔽機制的上限

**資料遮蔽無法達成「零私有內容」，本文檔亦未主張此種標準。**

在 48 份擷取自真實對話的 payload 中，工具統計的八項洩漏類別全數歸零：code fence、絕對路徑、相對路徑、檔名、URL、commit SHA、issue 編號、行號範圍。檢測計數為零代表預設類別「未被發現」，絕不等於資料「純淨」。

**工作任務的核心內容依然留存於文字中。** 閱讀這些 payload 可得知某個配額視窗讀取值為 80% 而同視窗內 47 個樣本記錄為 77%、某個 60 秒盲輪詢仍在運作，以及某目錄下存在六個標註日期為 2026-08-22 的復原檔。特定識別碼已被移除，但正在開發的模組、發生的故障細節，以及預計採用的解法依然可讀。

TypeSafe 的資料處理位於美國境內，也未聲明資料保留期限。它的 Master Customer Agreement 把責任上限壓得夠低，真的外洩了拿不到實質的財務救濟。條文請讀現行版本，不要讀這裡的轉述──條文會改，轉述不會跟著改。啟用網路傳輸前請詳閱 `payload-audit.txt`。`STINGRAY_SHADOW=1` 依舊會送出資料。預設未設定時完全不發出網路請求。任何一個開關一旦有東西要問，都會送出遮蔽過的最後一則訊息。

## 校準

使用 124 輪擷取自維護者真實對話紀錄進行離線量測，標籤依據為使用者當下是否需手動輸入「繼續」（`jev-1.13.0`，2026-09-21）：

| payload | 精確率 | 召回率 | 誤報率 |
|---|---|---|---|
| **full**（經遮蔽，約 800 字） | **81.8%** | 14.1% | 3.3% |
| 僅最後兩句 | 61.1% | 17.2% | 11.7% |
| 僅結構化旗標 | — | — | `no_action` 從未觸發 |

在 full payload 條件下逐題分析：`no_action` 精確率 85.7%、誤報率 1.7%；`broken_promise` 精確率 66.7%、誤報率 3.3%。若將 payload 刪減至最後兩句，精確率下降 20 個百分點，誤報率提升至三倍，因此必須傳送完整的遮蔽訊息。

高精確率搭配低召回率符合本工具定位：錯誤提示會白白消耗一輪對話，漏抓則維持原本互動節奏。

**此實驗無法定論模型判讀能力。** 量測結果受限於以下三點：
1. 標籤判定存在結構性低估：使用者僅在特定情境下會手動輸入「繼續」，其餘時候往往直接接續其他指令或結束操作。
2. 在 τ=0.5 條件下產生的兩筆誤報中，逐筆比對發現其中一筆為標籤標註錯誤而非模型預測失誤；經人工判讀，十一筆判定命中中有十筆正確。
3. 離線實驗採用的是遮蔽工具的**測試副本**（使用寫死的專案清單），出貨版本則改為動態推導。81.8% 係於近似出貨程式碼的環境測得，非實際出貨程式碼的精準量測。
4. 81.8% 量測時，一次請求打包了好幾輪，每輪各問形狀 1、2 與一題舊版的形狀 3。出貨的請求只帶一輪，題目只有開關與背景狀態需要的那幾題。用 6 組輸入各送兩次，比較有無同時帶 `watch_claim` 與 `wrong_language`：兩項分數的平均最多變動 0.04，和同一個請求送兩次本身的最大差距（0.04）相同，也沒有任何一組因此跨過 τ。六組輸入只能說沒有大的影響，不能說沒有影響。

**形狀 3 的承諾判斷以 `tests/watch-fixture.tsv` 的 50 則標好答案的句子量測。** 直接把題目送給 Jev，除了「keep an eye on the review」（0.49）以外，承諾都在 0.68 以上，其他都在 0.20 以下。`tests/watch-fixture.sh` 透過出貨的 hook 即時重跑：τ = 0.5 時，有評分的 49 則全部一致，其中「keep an eye on the review」落在門檻邊緣（見已知限制）。其中「poll-coderabbit.sh 的參數解析有缺陷」這一則含有檔名，遮蔽後整則消失，從未被問到。0.3.0 以前的題目文字是在 59 則上量的（當時的這 44 則加 15 則合成句子，後者已未保存）；0.3.1 讓它不再把「你先操作再回我，我再看 log」當成承諾，起因是這類回覆誤攔了一輪真實對話（在舊文字下重播得 0.53–0.58）。同樣 50 則，舊文字判錯 3 則，其中包括那則回覆的合成替身（原文來自私人 session，不放進 repo），非承諾最高給到 0.82。**它的對應判斷從未量過。** 門檻沿用其他題目的數值，未經獨立驗證。

任一判斷機制在獲准攔下收尾前，必須各自通過兩道獨立檢驗標準：

| 評估項目 | 獲准攔下收尾的門檻 |
|---|---|
| 形狀 1 與 2（`STINGRAY=1`） | 累積 ≥ 40 筆 shadow 紀錄、人工判讀精確率 ≥ 70%、每 100 次收尾誤推 ≤ 3 次、τ 值落於分數叢集間的空隙並附推導過程 |
| 形狀 3 承諾（`STINGRAY_SHAPE3=1`） | 尚未訂定。在 50 則標好答案的句子上量過，而且從第一輪就會攔阻──見已知限制 |
| 形狀 3 對應判斷（`STINGRAY_SHAPE3_JUDGE=1`） | 累積 ≥ 20 筆 shadow 紀錄、人工判讀精確率 ≥ 70% |
| 形狀 4 語言（`STINGRAY_LANG=1`） | 尚未訂定。只用 20 則合成回覆量過，而且從第一輪就會攔阻──見已知限制 |

判定紀錄寫入 `$STINGRAY_STATE_DIR/decisions.jsonl`，一行一筆，附帶 `qset_hash`──即 `questions.json` 的 SHA-256 雜湊，**非請求內容的雜湊**。修改判斷標準字句會改變模型評分分佈，導致既有門檻失效；若使用每輪變動的請求雜湊，將無法追蹤題本版本漂移。

## 延遲

在 shadow 模式下於 hook 執行點量測台灣至 `api.typesafe.ai` 的連線耗時，共執行三輪獨立測試，每輪 20 次請求：

| | p50 | p95 | 預算 |
|---|---|---|---|
| shadow 模式 | 0.742–0.760 秒 | 0.818–0.888 秒 | 1.0 秒 |

測試結果刻意標記為數值區間，因為跨輪次的連線延遲無法精準重現，標示單一數值會造成誤導。

1.0 秒的延遲預算同樣適用於 shadow 模式：shadow 模式承擔相同的網路往返時間。若 p95 超出預算，應停用 hook 或調低 `STINGRAY_TIMEOUT`。退回 shadow 模式無法消除延遲負擔。

上述預算僅適用於端點連線正常的狀況。當端點無回應時，連線將等待至 `STINGRAY_TIMEOUT`：**在預設 6 秒設定下實測為 6.15 秒**。若此耗時在斷線時過長，請調低 timeout。

只開 `STINGRAY_SHAPE3=1` 或 `STINGRAY_LANG=1` 時，每一輪只要有東西要問，也會多這一次往返；在 0.3.0、0.2.0 以前則分別完全沒有。只帶一個題目的請求在 12 次呼叫中耗時 0.68–1.03 秒──這是直接用相同格式的請求打端點量的，不是在 hook 執行點量的；透過出貨的 hook 則是 0.70–0.99 秒。開了多個開關時，各自的題目共用同一次請求，不會多一次往返。

開了 `STINGRAY_SHAPE3=1` 時，hook 還會在本機、送出請求之前讀 transcript 找交辦：55 MB 的 transcript 在 load average 14 下花 0.32–0.72 秒。

## 迴圈防護

具備兩道獨立防禦機制，避免單一布林值失效而導致對話無窮迴圈：

1. harness 提供的 `stop_hook_active` 旗標──重新進入 hook 時為 `true`，防止對同一收尾事件重複介入。
2. 每個 session 獨立計算的攔阻收尾次數上限（`STINGRAY_MAX_BLOCKS`，預設 3 次），不依賴 harness 旗標狀態。

## 已知限制

- 交辦在對方回覆前都會算數。如果對方一直沒回，這個 session 剩下的時間裡，形狀 3 都會把那個承諾當成有機制在等。
- 交辦偵測依賴 2026-09-26 觀察到的 Claude Code transcript 格式：`SendMessage` 的結果寫著「another Claude session」，回覆以 `<cross-session-message … from-name="…">` 送達。如果改的是送出的格式，就看不到交辦，這類回合會跟以前一樣被攔，沒有提供 transcript 的呼叫者也是如此。如果只改了回覆的格式，送出仍認得、回覆卻認不出來：交辦會在這個 session 剩下的時間裡一直算成在等，讓該攔的承諾被放行。
- `questions.json` 內的判斷標準以繁體中文撰寫，此為測得 81.8% 這個數字的語料基礎。英文標準未經實測驗證，任意替換將導致該準確率指標失效。在英文環境使用需重寫題本並重新校準。
- 形狀 3 的對應判斷無法離線量測：`background_tasks` 欄位只存在於 hook 執行當下，無法從 transcript 重建。承諾判斷則可以量，也量了──見 `tests/watch-fixture.sh`。
- 形狀 3 看不見和檔案路徑寫在同一行的承諾。遮蔽會在 Jev 讀到之前刪掉那一行，刪完如果沒剩任何文字，這一輪根本不會被問。透過出貨的 hook 實測：「我會盯著 src/main.rs 的 CI 結果」沒有被問；同樣的承諾把路徑放到另一行，就以 0.97 被攔下。它取代的正規表達式讀的是原文、看得見這種寫法；這是這次唯一放棄的東西。
- 「keep an eye on the review」透過 hook 跑五次得 0.47–0.53，攔不攔等於擲硬幣。它沒有主詞，也可以讀成叫使用者去看。
- 資料遮蔽機制具備明確上限，無法清除工作任務核心脈絡，詳見前述章節。
- 形狀 4 在 0.2.0 用 20 則合成回覆量過，0.3.2 再加 9 則；另外重播了兩則真實回覆找誤判原因，這兩則在當初誤攔時就已經由 hook 送出過。除此之外，沒有為了量它送出任何 transcript。zh-TW 回覆得分 0.10–0.23（包含一則全是識別字、一則引用英文原句）；英文、日文、韓文、俄文回覆 0.97–0.98；夾著中文詞的英文 0.77；目標語言設錯方向時 0.95–0.98。τ 沿用共用的 0.5。它在你自己的文字上表現如何，要看 `decisions.jsonl`──紀錄名稱是 `wrong_language` 與 `language_ok`。
- 形狀 4 分不太出簡體與繁體：0.2.0 時一則簡體回覆對上 zh-TW 設定只得 0.29；0.3.2 量的兩則則以 0.64、0.90 被攔下。
- 討論簡體在地化、又引用大陸用語（「軟件」「用戶」）的繁體回覆，仍會以 0.77–0.79 被攔：佔位詞只換掉語言名稱，換不掉被引用的詞。
- harness 會把它自己的英文通知以助理訊息的形式寫進 transcript，例如「You've hit your session limit …」「API Error: Connection lost mid-response …」。hooks 文件寫明，因 API 錯誤而結束的一輪會觸發 `StopFailure` 而非 `Stop`，照這樣它們不會到這個 hook。這是文件依據，沒有實測。如果真的送到了，形狀 4 會判斷一次，重新進入的防護會擋掉第二次。
- `network.sh --live` 於某次測試曾出現 8/9 的結果；後續重複執行五次皆無法重現該錯誤，未能查明特定失敗項目。該紀錄已載於測試檔案註解。

## Stop hook 的實測契約

針對 Claude Code v2.1.278（2026-09-21）實際執行驗證。官方文件存在三處陳述錯誤：

| 項目 | 官方文件記載 | 實際執行行為 |
|---|---|---|
| 攔下收尾 | 以 `exit 2` 退出並在 stdout 輸出 `hookSpecificOutput` JSON | `exit 2` 確實能攔截收尾，但 **stdout 內容無法傳遞給模型**。原因字串必須輸出至 **stderr** |
| `stop_hook_active` | 未記載；需自行實作計數邏輯 | **實際存在**，重新進入 hook 時值為 `true` |
| `stop_reason`、`scratchpad_dir`、`effort` | 記載為提供欄位 | **實際並未提供** |

hook 實際接收的 JSON 欄位：`session_id`、`prompt_id`、`transcript_path`、`cwd`、`permission_mode`、`hook_event_name`、`stop_hook_active`、`last_assistant_message`、`background_tasks` 以及 `session_crons`。

transcript 格式解析限制：助理訊息中每個 content block 皆以獨立 JSONL 記錄儲存，而 `promptId` **僅**標註於使用者訊息上。若依賴 `promptId` 過濾助理內容，會導致工具呼叫次數恆判定為零，進而頻繁誤觸發形狀 1。詳見 [`hooks/turn-tools.jq`](hooks/turn-tools.jq)。

## 目錄結構

```text
stingray/
├── .claude-plugin/              # plugin.json 與 marketplace.json
├── .coderabbit.yaml             # 程式碼審查指示，以及 <10 星自動審查到期日的紀錄
├── .github/workflows/tests.yml  # 離線測試套件與突變檢查，支援 Linux 與 macOS
├── hooks/
│   ├── hooks.json               # Stop hook 註冊設定，明定逾時時間
│   ├── stingray.sh              # 完整邏輯：各種形狀、資料遮蔽、fail-open 路徑、提示字串
│   ├── turn-tools.jq            # 從 transcript 切出單一對話輪次
│   └── handoffs.jq              # 交給其他 session、還在等回覆的交辦
├── questions.json               # 五道 Jev 判斷標準──分類器契約，釘死 jev-1.13.0
└── tests/
    ├── acceptance.sh            # 離線執行實際 hook：不需 key、不連網
    ├── network.sh               # fail-open 路徑測試；--live 會發送請求至真實端點
    ├── watch-fixture.sh         # 用 watch-fixture.tsv 即時校準形狀 3；需要 key
    ├── hook-shell.sh            # 用 hooks.json 出貨的直譯器執行 hook
    ├── mutants.sh               # 驗證防護機制在程式碼遭破壞時能否如期攔截
    ├── show-payload.sh          # 於本機擷取實際送出的 payload 位元組
    ├── stub_server.py           # 端點本機替身；--list-modes 可列出支援模式
    └── latency.py               # 比對延遲預算計算 p50 與 p95，超標即以非零狀態退出
```

## 測試

```bash
./tests/acceptance.sh        # 離線執行實際 hook：不需 key、不連網
./tests/network.sh           # 對本機 stub 測試 fail-open 路徑
./tests/network.sh --live    # 發送請求至真實端點，僅傳送合成文字
./tests/mutants.sh           # 測試防護機制是否能正確攔截損壞程式碼
./tests/show-payload.sh 50   # 於本機擷取實際送出的 payload 位元組
./tests/watch-fixture.sh     # 用標好答案的句子對真實端點測形狀 3；需要 key
```

測試案例以真實 stdin 驅動真實 hook 腳本，直接驗證 exit code 與 stderr 輸出，不透過檢視原始碼斷言。線上測試僅採用合成文字，避免執行測試時外洩對話資訊。

兩項測試案例專門防範特定實作疏失，並由 `mutants.sh` 植入錯誤驗證：

- **案例 8：** 有輪詢在跑時，被判定為承諾的回覆不得攔下。忽略計數的話，每個承諾都會像背景空無一物一樣被攔。
- **案例 9：** 輸入缺少 `background_tasks` 欄位時，不得誤判為「無任何工作在執行」，否則形狀 3 會在判定有承諾時一律攔下收尾。

## 支持

stingray 免費開源且不需註冊專案帳號。使用上唯一產生的費用為使用者自身呼叫 TypeSafe API 的開銷（每百萬輸入 token 美金 0.042 元；單輪對話傳輸量遠低於一千 token）。歡迎透過 Patreon 支持維護者。

[![Support on Patreon](https://img.shields.io/badge/Support_on_Patreon-FF424D?style=for-the-badge&logo=patreon&logoColor=white)](https://www.patreon.com/cw/Nanako0129/membership)

## 授權

MIT
