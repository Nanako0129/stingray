# stingray

[English](README.md) | **繁體中文**

[![tests](https://github.com/Nanako0129/stingray/actions/workflows/tests.yml/badge.svg)](https://github.com/Nanako0129/stingray/actions/workflows/tests.yml) [![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> 一個給「話講完、事沒做完」那一輪用的 Claude Code `Stop` hook。它抓三種半途而廢：什麼都沒做、宣告了動作卻沒執行、說要盯著 CI 卻沒有任何東西在輪詢——然後擋下收尾、推它一把，而不是讓那一輪帶著一張空頭支票結束。

魟魚平常貼在沙地上不動，你不踩到它就不會有事。這個東西一樣：正常的一輪它不出聲，只有在該動卻停下來的那一輪才戛你一下。三個判斷裡有兩個交給 [Jev](https://typesafe.ai)，第三個是純算術——因為它的兩半都是確定值，把確定換成機率是降級。

```
你：      修掉那個 timeout，然後跑測試
claude：  我現在就改設定值，然後跑一次測試套件。
          〔這一輪結束。什麼都沒改。什麼都沒跑。〕

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
| 1 | `no_action` — 停下來卻什麼都沒做，而它本來能動手 | [Jev](https://typesafe.ai) |
| 2 | `broken_promise` — 宣告了動作，但這一輪的工具呼叫交代不了它 | Jev |
| 3 | `unwatched` — 說要盯著 CI 或 PR 審查，卻沒有任何東西在輪詢 | 本機算出來 |

形狀 3 能用算術決定的部分就用算術，決定不了的才交給模型。如果一輪宣告要盯著某個東西，而**完全沒有**任何背景工作或排程在跑，那不需要判斷：那句承諾背後沒有任何機制。這種情況不需要 key 也不需要網路，所以 `STINGRAY_SHAPE3=1` 單獨使用仍然是最便宜的有用設定。

但**有東西在跑**的時候，計數就不再是答案。一輪承諾要跟 PR 審查，而背景在跑的是建置——「有東西在跑」成立，漏做卻完全沒被抓到。在跑的工作跟承諾的工作對不對得上是判斷，所以這種情況（也只有這種情況）交給 Jev，把收尾發言與在跑的工作擺在一起看。沒有 key 就放著不管，那就是你今天的行為。

這一節先前寫著「兩半都是確定值」。其中一半錯了：`background_tasks` 確實是確定欄位，但「它有沒有宣告要盯著什麼」是語言判斷、由 regex 近似，而上線第一輪就抓到它漏掉最平常的講法。

督促訊息是固定的一段話，不是針對個案生成的評論。它給三條出路——把事做完、把 polling 掛上去、或講清楚卡在哪一個決定——因為一輪會停在半路有這三種理由，而只有模型知道是哪一種。

## 摩擦只會往上加

每一條失敗路徑——沒有 key、找不到 `jq`、找不到 `questions.json`、端點既不是 HTTPS 也不是 loopback、送出的 bytes 裡掃到密鑰、逾時、非 200、回應格式錯、分數超出 [0,1] 或低於門檻、`background_tasks` 讀不出來，甚至連擋人次數寫不進去——都會 `exit 0`，行為跟沒裝這個 plugin 完全相同。

stingray 可以要求模型多做事，永遠不能讓它少做事。每一次失敗都是字面意義上的 fail-open——那一輪就照原本的樣子結束——而在這裡那是安全的方向，因為被收回的是一句督促，不是一項許可。這條規則讓所有失效模式都很無聊：沒有任何一種設定會讓壞掉的 stingray 放行什麼，也沒有任何一次服務中斷會變成一次無聲的通過。

## 安裝

> **提醒：** 下面每一行指令都寫成 **user scope**——裝一次，每個專案都能用。

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

> **小提醒：** session 內的 `/plugin install` 對話框會問你要哪個 scope，選 **User**。

> **這裡的「已驗證」是什麼意思：** manifest 與上面兩行指令都對著本機 checkout 實際跑過——marketplace 註冊成功、`plugin install` 回報成功、`plugin list` 顯示 `stingray@stingray` 在 user scope 且 enabled。在沒有 export 任何開關的情況下，餵進一筆本來會觸發形狀 3 的 payload，它 `exit 0` 且不建立任何 state 目錄，所以剛裝好的狀態確實是惰性的。`Nanako0129/stingray` 那種寫法在合併後也照樣跑過一遍：從 GitHub 加 marketplace、以 user scope 安裝，然後餵一筆本來會觸發形狀 3 的 payload，仍然 exit 0 且不建立 state 目錄。

**光是裝好它不會做任何事。** 沒設開關之前 hook 是關的，這是刻意的：一個落地就開始打斷你的 plugin，你沒辦法評估它。挑一個，放進你 shell 會 export 的地方：

```bash
# 免費的本機檢查：不用帳號、不用 key、不發請求
export STINGRAY_SHAPE3=1

# 或者：呼叫 Jev、寫決策紀錄、永不擋人。有 key 的話從這裡開始。
export STINGRAY_SHADOW=1
```

確認它載入了、而且還沒開始動作：

```bash
claude plugin list | grep stingray
tail -f ~/.local/state/stingray/decisions.jsonl   # 進 shadow 或 active 之前不會有東西
```

### 或者自己接 hook

不需要 plugin 那套機制——它就是一支腳本：

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

`timeout` 一定要明寫。Claude Code 對 hook 的預設值是 **600 秒**，所以一個卡住的端點會讓你的收尾卡十分鐘。

### 需要的工具

`bash`、`curl`、`perl` 是 macOS 與任何一般 Linux 都內建的。**`jq` 在 macOS 不是內建的**，而 hook 沒有它會直接 exit 0 並印出 `(stingray: unavailable — jq not found)`：

```bash
command -v jq || brew install jq      # macOS
command -v jq || sudo apt install jq  # Debian／Ubuntu
```

無 SDK，其餘不用裝任何東西。

`STINGRAY_ENDPOINT` 接受 HTTPS URL，或只對 loopback 接受純 HTTP（測試 stub 住在那裡）。請求帶著 `Authorization: Bearer`，其他情況會讓 key 以明文上線路，所以一律拒送。

## API key

形狀 1 與 2 會呼叫 TypeSafe 的 System One（`jev-1.13.0`）。形狀 3 的**確定**情況——宣告要盯著某個東西、背後什麼都沒在跑也沒排程——不需要 key，也不需要網路。但它的對應關係判斷需要，因為那一題是問模型「在跑的工作跟承諾的對不對得上」。

1. 到 <https://typesafe.ai> 申請 key。
2. 放進 `~/.config/typesafe/api_key`（`chmod 600`），或 export `TYPESAFE_API_KEY`。建議用檔案：環境變數對你啟動的每一個 process 都看得見。

**沒有 key 的時候，stingray 的行為跟沒裝一模一樣。** 它會每個 session 印一次 `(stingray: unavailable — no key; shapes 1/2 skipped)`，並且讓形狀 3 繼續運作。它永遠不會無聲地什麼都不做。

## 開關（預設全關）

| 變數 | 效果 |
|------|------|
| *（什麼都沒設）* | **預設。** hook 立刻退出。什麼都不跑，什麼都不送。 |
| `STINGRAY_SHADOW=1` | 呼叫 Jev、寫決策紀錄、**永不擋人**。從這裡開始。 |
| `STINGRAY=1` | 對形狀 1 與 2 擋人。 |
| `STINGRAY_SHAPE3=1` | 對形狀 3 的**確定**情況擋人——宣告要盯著某個東西，但背後什麼都沒在跑也沒排程。不需要 key 也不需要網路，所以光設這一個就能啟用 hook，而不會打開那些有自己門檻要過的 Jev 判斷（見[校準](#校準)）。`STINGRAY_SHADOW=1` 的優先序高於它。 |
| `STINGRAY_SHAPE3_JUDGE=1` | 額外允許**對應關係判斷**擋人：有東西在跑，而模型說那不是它答應要盯的那個。即使形狀 3 已經在擋人，這個仍然預設關——因為那個答案是機率、門檻是借來的、背後沒有任何量測。不論開關，它從第一輪就會記錄。 |

最便宜的有用設定是單獨一個 `STINGRAY_SHAPE3=1`：不用帳號、不用 key、不發請求——就只有「說要盯著某個東西，背後有沒有東西真的在跑」這個檢查。它仍然會讀 payload 並跑一次 regex，所以不是零成本，只是不碰網路也不碰 TypeSafe。

其他旋鈕：`STINGRAY_TAU`（0.5）、`STINGRAY_TIMEOUT`（6 秒）、`STINGRAY_MAX_BLOCKS`（每 session 3 次）、`STINGRAY_STATE_DIR`（`~/.local/state/stingray`）、`STINGRAY_REDACT_WORDS`（額外要遮蔽的名字）、`STINGRAY_JEV_MODEL`（`jev-1.13.0`，釘死——`jev-latest` 會在你不知情的時候換掉分類器）。

## 什麼東西會離開你的電腦

三個欄位，而且只有設了 key 才會送：

| 欄位 | 內容 |
|------|------|
| `final_text` | 助理最後那則訊息，先剝除、再截尾到最後 2400 **bytes**——約 800 個中文字，但純 ASCII 大約是 2400 個字元，所以英文的一輪送出的文字量大約是下面那些準確率數字量測條件的三倍 |
| `tools` | 這一輪的工具**名稱**與次數——不含任何參數 |
| `background` | 每個背景工作的 status 與 **description**；每個排程 cron 的 **prompt**，也就是寫給它的指令。兩者都走與訊息同一條剝除管線，並先剝掉憑證形狀。指令列一律不送。 |

你打給 Claude 的 prompt 永遠不會被送出。工具參數、檔案內容、diff 也不會。但**排程 cron 的 prompt 會被送出**——要判斷排程的工作跟承諾的事對不對得上，就得讀它被交代了什麼；那是唯一會離開的、prompt 形狀的東西。

剝除會拿掉 code fence、引用區塊、inline code 與 URL，丟掉任何帶有絕對路徑、相對路徑或檔名的整行，並遮蔽 commit SHA、issue 編號與專案名。專案名是**衍生**的，不是寫死的：hook 回報的目錄，以及它 git remote 指向的 repository。你順口提到的其他專案，從那裡推不出來——想遮就列進 `STINGRAY_REDACT_WORDS`。

截尾發生在剝除**之後**。反過來會把 code fence 切成半邊，配對失效，整塊外洩。

在任何請求離開之前，送出的 bytes 會被掃過一次密鑰特徵（`sk-`、`ghp_`、`AKIA`、PEM 標頭）。命中就丟棄請求，那一輪照常進行。

### 自己看過再決定

```bash
./tests/show-payload.sh 50
```

這會用**真正的 hook** 對一個本機的記錄伺服器跑一遍，把它實際放上線路的 bytes 寫進 `payload-audit.txt`。它報告的是送出去的東西，不是剝除程式打算拿掉的東西。另外寫一份 redactor 副本去量會跟出貨版漂移——這件事在這裡發生過一次，而當時 README 還宣告著程式沒有的規則。

### 剝除的天花板，量在真正送出的 bytes 上

**剝除達不到「零私有內容」，這裡的任何一句話都不該被當成那個意思。**

48 份從真實對話捕捉到的 payload 裡，工具會數的每一個洩漏類別都是零：code fence、絕對與相對路徑、檔名、URL、commit SHA、issue 編號、行號範圍。那個零的意思是「沒找到」，永遠不是「乾淨」——掃描只找得到有人想得到的類別。

明顯活下來的是**工作本身的內容**。讀那些 payload 會知道某個額度視窗讀到 80% 而同一個窗的 47 個樣本說 77%、有個 60 秒的盲輪詢還在跑、某個目錄裡有六個日期是 2026-08-22 的復原檔。識別碼不見了；你在做什麼、哪裡壞了、你怎麼決定要怎麼修，沒有不見。

TypeSafe 在美國處理資料、未聲明保存期限、責任上限 USD 50。請在這些事實擺在眼前、並且開著 `payload-audit.txt` 的情況下決定。`STINGRAY_SHADOW=1` **仍然會送**。只有預設的關閉狀態什麼都不送。

## 校準

離線量測，對象是 124 個來自某位維護者真實 transcript 的對話輪次，標籤是「那個人當時有沒有必須自己打『繼續』」（`jev-1.13.0`，2026-09-21）：

| payload | 精確率 | 召回率 | 誤報率 |
|---------|--------|--------|--------|
| **full**（剝除後、約 800 字） | **81.8%** | 14.1% | 3.3% |
| 只有最後兩句 | 61.1% | 17.2% | 11.7% |
| 只有結構化旗標 | — | — | `no_action` 完全不觸發 |

逐題，在 full payload 下：`no_action` 精確率 85.7%、誤報率 1.7%；`broken_promise` 66.7%、3.3%。把 payload 砍到最後兩句要付 20 個百分點的精確率、誤報率變成三倍，所以送的是整則訊息。

高精確率配低召回率在這裡是對的形狀。推錯一次的代價是浪費一輪；漏掉一次完全沒有代價。

**那個實驗不足以裁決這件事，本文件也沒有把它寫成足以裁決的樣子。** 標籤系統性低估正例：一個人只有「有時候」會打「繼續」，其他時候他直接回別的、或是算了。τ=0.5 的兩個誤報，逐筆讀過之後發現其中一筆是標籤錯不是預測錯；十一個命中裡十個經人工判讀是對的。另外一條必須講清楚的但書，因為同一種分歧已經在這裡造成過一個缺陷：離線實驗跑的是 redactor 的**副本**，那份副本遮蔽的是一張寫死的專案名清單，而出貨版是衍生的。所以請把 81.8% 當成「量在一個很接近出貨版的鄰居上」，不是量在出貨版上。

因此：預設全關、`STINGRAY_SHADOW=1` 當第一個設定，而且任一判官要開始擋人之前，要各自過**兩條互相獨立的門檻**。形狀 3 不能搭形狀 1、2 校準的便車。

| 判官 | 開始擋人之前要過的門檻 |
|------|------------------------|
| 形狀 1 與 2（`STINGRAY=1`） | 累積 ≥ 40 筆 shadow 紀錄、你自己逐筆判讀精確率 ≥ 70%、每 100 個 Stop 點誤推 ≤ 3 次、τ 落在分數叢集之間的空帶且旁邊附上推導 |
| 形狀 3 的確定情況（`STINGRAY_SHAPE3=1`） | 無——算術，沒有門檻要校 |
| 形狀 3 的對應判斷（`STINGRAY_SHAPE3_JUDGE=1`） | 累積 ≥ 20 筆 shadow 紀錄、人工判讀精確率 ≥ 70% |

紀錄會落在 `$STINGRAY_STATE_DIR/decisions.jsonl`，一個決策一行，每行帶著 `qset_hash`——那是 `questions.json` 的 hash，不是請求的 hash。改動一行 criteria 會移動整個分數分佈，所以在舊措辭下校出來的門檻就作廢了，而一個每輪都不一樣的 hash 沒辦法告訴你這件事。它原本 hash 的是請求本體，直到 CodeRabbit 指出那讓它對唯一的用途失效為止。

## 延遲

量在 hook 的位置、shadow 模式下，不是用裸的 `curl` 量——重點是那一輪實際等了多久。台灣到 `api.typesafe.ai`，三次各 20 發的獨立量測：

| | p50 | p95 | 預算 |
|---|-----|-----|------|
| shadow 模式 | 0.742–0.760 秒 | 0.818–0.888 秒 | 1.0 秒 |

寫成區間而不是單一數字，因為確切數值跨次量測不可重現，而一個小數點會讓人以為它可以。

預算同樣適用於 shadow：shadow 才是你大部分時間會待的模式，而且它付的是同一趟往返。如果你的 p95 超過預算，請關掉 plugin 或把 `STINGRAY_TIMEOUT` 調低——退回 shadow 不會移除延遲來源，所以那不是補救。

那個預算只涵蓋健康的情況。端點卡住時，那一輪會等到 `STINGRAY_TIMEOUT` 才繼續：對著一個「接受連線但永不回應」的 stub **實測是 6.15 秒**。如果那個數字在壞日子裡太久，就把 timeout 調低。

## 迴圈防護

兩道守衛，因為單一個布林值是單點失效，而它的失效方向是無限迴圈：

1. harness 給的 `stop_hook_active`——擋過一次後重新進入時為 true，所以同一個收尾不會被推兩次。
2. 一個不依賴前者的、每 session 的擋人次數上限（預設 3）。

## 已知限制

- `questions.json` 裡的 Jev criteria 是繁體中文寫的，因為那就是量出 81.8% 的那份語料。英文 criteria 零實測，換過去那個數字就作廢。如果你用英文工作，請預期要重寫它們並重新校準。
- 形狀 3 的準確率**完全無法離線量測**：它的證據 `background_tasks` 只存在於 hook 執行的那一刻，從 transcript 重建不出來。測試套件能證明那個分支在合成輸入下行為正確；它會不會在「對的那些輪次」觸發，只有你自己的 shadow log 說了算。
- 剝除有一個量過的天花板，見上文。

## Stop hook 的實測契約

Claude Code v2.1.278，2026-09-21。官方文件有三處是錯的，所以下面這些是實際跑出來的：

| | 文件說 | 實際上 |
|---|--------|--------|
| 擋收尾 | `exit 2` 並在 stdout 印 `hookSpecificOutput` JSON | `exit 2` 擋得住，但 **stdout 送不到模型**。理由必須寫 **stderr** |
| `stop_hook_active` | 未記載，叫你自己寫計數器 | **存在**，重新進入時為 `true` |
| `stop_reason`、`scratchpad_dir`、`effort` | 會提供 | **沒有** |

實際會拿到的欄位：`session_id`、`prompt_id`、`transcript_path`、`cwd`、`permission_mode`、`hook_event_name`、`stop_hook_active`、`last_assistant_message`、`background_tasks`、`session_crons`。

還有一件來自 transcript 格式的事：assistant 訊息的每一個 content block 都是獨立一筆 JSONL 紀錄，而 `promptId` **只**出現在 user 紀錄上。它可以用來定位一輪從哪裡開始，但不能用來過濾 assistant 紀錄。搞錯這件事會讓「這一輪呼叫了哪些工具」在每一輪都讀成零，形狀 1 就會狂噴。見 [`hooks/turn-tools.jq`](hooks/turn-tools.jq)。

## 目錄結構

```text
stingray/
├── .claude-plugin/              # Claude Code 打包（plugin.json、marketplace.json）
├── .coderabbit.yaml             # 審查指示，以及 <10 星自動審查到期日的明文紀錄
├── .github/workflows/tests.yml  # 離線套件＋變異檢查，Linux 與 macOS
├── hooks/
│   ├── hooks.json               # Stop hook 註冊，明寫 timeout
│   ├── stingray.sh              # 全部邏輯：三形狀、剝除、fail-open 路徑、督促
│   └── turn-tools.jq            # 從 transcript 切出這一輪
├── questions.json               # 兩道 Jev criteria — 分類器的契約，釘死 jev-1.13.0
└── tests/
    ├── acceptance.sh            # 離線驅動真正的 hook：不需 key、不連網
    ├── network.sh               # fail-open 路徑；--live 另外打真實端點
    ├── mutants.sh               # 重新推導每個守衛被弄壞時是否仍會失敗
    ├── show-payload.sh          # 在本機捕捉真正會送出去的東西
    ├── stub_server.py           # 端點的本機替身；--list-modes 會列出它的模式
    └── latency.py               # 對照預算算 p50／p95，超標就 exit 非零
```

## 測試

```bash
./tests/acceptance.sh        # 離線驅動真正的 hook：不需 key、不連網
./tests/network.sh           # 對本機 stub 跑 fail-open 路徑
./tests/network.sh --live    # 另外打真實端點，只送合成文字
./tests/mutants.sh           # 那些守衛還守得住嗎？
./tests/show-payload.sh 50   # 在本機捕捉真正會送出去的東西
```

每個案例都用真實的 stdin 驅動真正的 hook，斷言的是觀測到的 exit code 與 stderr。沒有任何一個案例是去讀原始碼。打真實端點的案例刻意使用合成的助理訊息，所以跑這套測試本身不構成一次資料揭露。

其中兩個案例各自只為了抓一個特定的實作錯誤而存在，而且各自都對著「會犯那個錯」的 mutant 驗過：

- **案例 7** — 形狀 3 的 regex 必須跑在未剝除的原文上。它的宣告句跟一個路徑同行，因為剝除會把那種行整行丟掉。早期版本用的是 URL，那是沒有價值的：URL 是就地替換，整行還在，錯誤的實作照樣會過。
- **案例 9** — 缺少 `background_tasks` 鍵不得讀成「沒有東西在跑」，那會讓形狀 3 退化成「regex 命中就擋」。

## 支持

stingray 免費，也不需要帳號。它唯一可能產生的費用是你的，不是這個專案的：TypeSafe 的輸入計價是每百萬 token US$0.042，而一輪送出去的遠低於一千。你可以在 Patreon 支持維護者。

[![Support on Patreon](https://img.shields.io/badge/Support_on_Patreon-FF424D?style=for-the-badge&logo=patreon&logoColor=white)](https://www.patreon.com/cw/Nanako0129/membership)

## 授權

MIT
