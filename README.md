# inkling2-small：三台 DGX Spark 跑 Inkling-2-Small（llama.cpp RPC over RDMA）

這個 repo 用 ConnectX-7 把三台 NVIDIA DGX Spark（GB10，各約 121 GiB 可用 unified memory）接成環狀網路，以 **llama.cpp RPC**（RDMA 傳輸）把 594B 的 [Inkling-2-Small](https://huggingface.co/thinkingmachines/Inkling-2-Small) 切成三段 layer 分給三台跑，提供 OpenAI 相容 API，並接進 [pi](https://github.com/badlogic/pi-mono) coding agent 使用（推理與工具預設開啟）。

| 項目 | 內容 |
|---|---|
| 模型 | Inkling-2-Small，594B，48 層（8 層 full attention + 40 層 SWA，window 1024），訓練 context 1,048,576 |
| 量化 | GGUF **IQ4_XS**，[`bartowski/Inkling-2-Small-GGUF`](https://huggingface.co/bartowski/Inkling-2-Small-GGUF)，9 個分檔共 322 GB |
| 推論引擎 | llama.cpp `beb9d49`（v1.1.0-dev），CUDA SM121 + `GGML_RPC`，RPC 走 RDMA |
| 平行方式 | Layer split（pipeline），head 跑 `llama-server`，另外兩台跑 `ggml-rpc-server` |
| 網路 | 三條 QSFP 線接成環，每條線 2 條 rail，RoCE v2，每條 rail 約 109 Gb/s |
| Context | **262,144 tokens（256K）**，單一 slot |
| 實測速度 | 生成約 **11～14 tok/s**，prefill 約 70～90 tok/s |
| 記憶體 | 載入後每台約用 113～116 GiB |
| API | `http://192.168.1.112:8090/v1`，model `inkling-2-small`，**不需要 API key** |
| 啟動時間 | 約 6～10 分鐘（讀 322 GB，其中約 2/3 透過 RDMA 送到 worker） |

> 目標是「放得下更大、更新的模型」，不是速度。三台合計約 384 GB，IQ4_XS 是能放進三台、還留得下 256K context 的最大量化。

---

## 快速開始

前提：三台已依下方「接線」接好，跑過 `setup-cluster.sh`，head 能免密碼 SSH 到另外兩台，三台都用 `scripts/build-llama.sh` 編好同一版 llama.cpp。

```bash
# 在 head（JoshDGX）上
git clone https://github.com/joshhu/inkling2-small ~/inkling2-small && cd ~/inkling2-small
scripts/download-model.sh        # 322 GB，只需要下載到 head
vi cluster.env                   # 改成你的路徑與 IP
./start.sh                       # 啟動兩台 rpc-server，再啟動 llama-server，等到 /health 回 200
./status.sh                      # 每台記憶體、rpc log、server log、health
./stop.sh
```

測試：

```bash
curl -s http://192.168.1.112:8090/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "inkling-2-small",
  "messages": [{"role":"user","content":"用一句話介紹你自己"}],
  "chat_template_kwargs": {"reasoning_effort": "low"},
  "max_tokens": 512
}' | jq -r '.choices[0].message.content'
```

**重開機後服務不會自己起來**，任何一台重開，都要在 head 上重跑 `./start.sh`。

---

## 怎麼做起來的

### 1. 先算記憶體：為什麼三台、為什麼 IQ4_XS

兩台 Spark 只有約 242 GiB，放不下 594B 的 4-bit 模型。第三台加入後是約 363 GiB 可用：

- IQ4_XS 權重 322 GB（約 300 GiB），平均每台約 100 GiB
- 剩下每台約 20 GiB 要分給 KV cache、compute buffer 與系統
- 更高的量化（Q4_K_M 以上）就放不下 256K context 了

### 2. 選推論引擎：為什麼是 llama.cpp RPC，不是 vLLM

- vLLM 的多機需要權重是它支援的格式（FP8/NVFP4/AWQ…），Inkling-2-Small 的官方 MXFP8 版要 600 GB 以上，三台放不下；vLLM 也不吃 GGUF 的 IQ 系列量化。
- llama.cpp 已支援 `inkling2` 架構（`src/models/inkling2.cpp`），而且 `ggml-rpc-server` 可以把任意一台機器當成遠端 GPU，做 layer split。
- 新版 llama.cpp 的 RPC 在偵測到 rdma-core 時會自動走 RDMA，不用另外設定。

代價是 layer split 一次只有一台在算，速度約 11～14 tok/s；但這個專案要的是「能跑更大的模型」。

### 3. 接線：三台接成環

每台 Spark 有 2 個 QSFP port（port 0、port 1），每個 port 在系統裡會出現成兩個 PCIe「半邊」（rail），例如 port 0 是 `rocep1s0f0` 與 `roceP2p1s0f0`。

接法是**每台的 port 0 接到下一台的 port 1**，三條線剛好成一個環：

```
JoshDGX (112) port0 ──── port1 JoshDGX2 (93)
JoshDGX2 (93) port0 ──── port1 JoshDGX3 (234)
JoshDGX3 (234) port0 ──── port1 JoshDGX (112)
```

> 不要接成開放的 daisy chain（A─B─C 不回接），`setup-cluster.sh` 不支援，而且 A 和 C 之間會沒有直連。

### 4. 設定網路：用 spark-vllm-docker 的 setup-cluster.sh

先讓 Mac 和 head 能免密碼 SSH、免密碼 sudo 到每台（新機器跑一次 `scripts/bootstrap-node.sh joshhu@<ip>`），然後在 head 上：

```bash
git clone https://github.com/eugr/spark-vllm-docker ~/workspace/spark-vllm-docker
cd ~/workspace/spark-vllm-docker
./setup-cluster.sh 192.168.1.112 192.168.1.93 192.168.1.234 --topology mesh --mtu 1500 --no-env --dry-run   # 先確認線有接對
./setup-cluster.sh 192.168.1.112 192.168.1.93 192.168.1.234 --topology mesh --mtu 1500 --no-env --yes
./setup-cluster.sh --doctor --dry-run                                                                       # 套用後檢查
```

- `--topology mesh`：三台環狀時，每兩台之間都有直連，工具會自動偵測哪個 port 接到哪台。
- `--no-env`：JoshDGX3 用 Wi-Fi（`wlP9s9`），管理介面名稱跟另外兩台不同，工具的 env 產生步驟會失敗，所以跳過。
- 它會寫 `/etc/netplan/98-spark-vllm-docker.yaml`，還原紀錄在 `~/.local/state/spark-vllm-docker/cluster-setup.json`，可用 `--restore` 還原。

產生的 IP 規劃（每條線兩條 rail，各一個 /24）：

| 節點 | port 0 rail 1 / rail 2 | port 1 rail 1 / rail 2 |
|---|---|---|
| JoshDGX 112 | `10.20.0.11` / `10.20.1.11`（往 93） | `10.20.4.11` / `10.20.5.11`（往 234） |
| JoshDGX2 93 | `10.20.2.12` / `10.20.3.12`（往 234） | `10.20.0.12` / `10.20.1.12`（往 112） |
| JoshDGX3 234 | `10.20.4.13` / `10.20.5.13`（往 112） | `10.20.2.13` / `10.20.3.13`（往 93） |

### 5. 測速：每條 rail 都要約 109 Gb/s

```bash
scripts/ibbw-ring.sh     # 在 head 上跑，六條 rail 逐一跑 ib_write_bw（RoCE v2，IPv4 GID）
```

實測六條 rail 雙向都在 108～110 Gb/s。第一次測時 234→112 只有 13.5 Gb/s，**把 234 和 112 重開機就好了**；遇到某條 rail 特別慢，先重開機再查。

### 6. 編譯 llama.cpp（三台都要，同一個 commit）

```bash
scripts/build-llama.sh   # GGML_CUDA + GGML_RPC，SM121，只編 llama-server / ggml-rpc-server / llama-bench / llama-cli
```

注意新版的改名：`rpc-server` 改叫 `ggml-rpc-server`；`--no-mmap` 拿掉了，改用 `-lm dio`（direct I/O 載入）。

### 7. 下載模型（只要 head）

`scripts/download-model.sh` 用 Docker 裡的 `huggingface_hub` 下載 `Inkling-2-Small-IQ4_XS/*`，主機不用裝 Python 套件。worker 不需要模型檔：`llama-server` 會把屬於它們的 layer 經 RPC 送過去，`ggml-rpc-server -c` 會快取在 worker 的 `~/.cache/llama.cpp/rpc`（每台約 107 GB），第二次啟動就快很多。

### 8. 記憶體調整：256K context 怎麼塞進去

這是最花時間的一步，關鍵是 **compute buffer 跟 `ctx × ubatch` 成正比**。Inkling2 的 relative attention 在 llama.cpp 裡沒有 flash-attn 路徑，attention 的中間矩陣會照 context 長度整塊配置：

| ctx | ubatch | 每台 compute buffer（約） | 結果 |
|---|---|---|---|
| 1,048,576 | 512 | ~205 GiB | 不可能；**實測會把 head 整台卡死，只能斷電重開** |
| 262,144 | 512 | ~51 GiB | 放不下 |
| 262,144 | 64 | ~6.6 GiB | ✅ 目前使用 |

`ubatch` 變小只影響 prefill 速度（約 70～90 tok/s），不影響生成速度。

> ⚠️ 不要用「直接開大 ctx 試試看」的方式找上限。超出記憶體時 GB10 的 unified memory 不會好好報 OOM，而是讓整台機器失去回應。先用上表的比例算，再保守地加。

第二個問題是 layer 分配不均。`-ts 1,1,1` 讓 JoshDGX2 拿到 109 GiB、幾乎沒空間給 KV。原因是 48 層不一樣大（full attention 層和最後的 output 層比較大），裝置順序又是 `RPC0（93）, RPC1（234）, CUDA0（112）`。改成 `-ts 15,16,17` 後三台各約 102 GiB 權重，預估剩餘 8.9 / 9.9 / 8.1 GiB。

最後的 `llama-server` 參數（見 `start.sh`）：

```
-ngl 999 -sm layer --fit on -c 262144 -ub 64 -ts 15,16,17 -np 1 -fa on -lm dio --jinja
```

### 9. 推理強度怎麼控制

Inkling 的 chat template **不看 `enable_thinking`**，而是看 `chat_template_kwargs.reasoning_effort`：

`none` / `minimal` / `low` / `medium` / `high` / `xhigh` / `max`（template 預設等同 high）

```json
{"chat_template_kwargs": {"reasoning_effort": "medium"}}
```

### 10. 接進 pi

把 `pi/models.json.example` 的 provider 合併進 `~/.pi/agent/models.json`，`pi/settings.snippet.json` 合併進 `~/.pi/agent/settings.json`（讓這個模型預設推理強度是 `high`）。重點：

- `thinkingFormat: "chat-template"` 加上 `chatTemplateKwargs.reasoning_effort = {"$var": "thinking.effort"}`，pi 的 thinking level 會直接變成 template 的 `reasoning_effort`。
- `apiKey: "local"` 只是佔位，伺服器沒有開 API key。
- `contextWindow: 262144`、`maxTokens: 32768`。
- pi 每次開 `/model` 都會重新讀 `models.json`，不用重開 pi；在 `/model` 搜尋 `3spark` 就找得到。

pi 的 system prompt 約 11K tokens，第一輪要先 prefill，約 2 分鐘；之後的輪次會用到 prompt cache，快很多。

### 11. 驗證

- 平行 tool call、tool result 回傳後繼續推理：正常。
- pi 實際任務（讀 CSV、算平均、寫出 `report.md`）：51 秒完成，結果正確。
- `./status.sh`：三台記憶體 113～116 GiB，`health=200`。

### 12. 踩到的坑

| 症狀 | 原因與解法 |
|---|---|
| `setup-cluster.sh` 說 Setup already recorded | 以前跑過；`--restore --yes` 可還原，但**會一併刪掉它建立的 cluster SSH key**，之後要重新授權 |
| `setup-cluster.sh` 卡在管理介面名稱不一致 | 一台用 Wi-Fi；加 `--no-env` |
| 某條 rail 只有 13 Gb/s | 兩端重開機 |
| `rpc-server` target 不存在 | 新版改名 `ggml-rpc-server` |
| `--no-mmap` 不認得 | 改用 `-lm dio` |
| 1M context 時 head 整台當機 | compute buffer ~205 GiB；改 256K + ub 64 |
| 一台記憶體爆、其他兩台很空 | 用 `-ts 15,16,17` 取代平均分配 |
| 關不掉推理 | 用 `reasoning_effort: none`，不是 `enable_thinking: false` |
| 監看腳本以為下載永遠沒結束 | `pgrep -f` 比對到自己的命令列；改用 `pgrep -x` 或打 `/health` |

---

## 調整

都在 `cluster.env`：

| 變數 | 說明 |
|---|---|
| `CTX` | context 長度。往上加之前先照第 8 節的比例算 compute buffer |
| `UBATCH` | prefill 的 micro-batch。加大會讓 prefill 變快，但 compute buffer 等比例變大 |
| `TENSOR_SPLIT` | 依序是 RPC0、RPC1、本機 CUDA0 的 layer 比例 |
| `PARALLEL` | 同時處理的請求數。每多一個 slot 就多一份 KV cache，256K 下目前只放得下 1 |
| `RPC_NODES` | `管理 IP=fabric IP`；fabric IP 要選**直接接到 head 的那條線**上的 IP |

## 已知限制

- 只有一個 slot，同時只能服務一個請求。
- 沒有 systemd 自動啟動；重開機要手動 `./start.sh`。
- JoshDGX 的 NVIDIA driver 是 595.99，另外兩台是 580.178；目前沒有影響，但建議統一。
- JoshDGX3 的管理網路是 Wi-Fi；RPC 與資料都走 CX7，只有 SSH 走 Wi-Fi。
- 改成環狀接線後，[dsv4-flash](https://github.com/joshhu/dsv4-flash) 的雙機設定（JoshDGX2 的介面、MTU 9000）要跟著改才能再用。

## 檔案結構

```
cluster.env               路徑、IP、ctx/ubatch/tensor split
start.sh                  啟動 rpc-server ×2 + llama-server，等 /health
stop.sh                   全部停掉
status.sh                 每台記憶體與 log
scripts/bootstrap-node.sh 新機器：SSH key + 免密碼 sudo
scripts/build-llama.sh    編譯 llama.cpp（三台都跑）
scripts/download-model.sh 下載 IQ4_XS GGUF（只在 head）
scripts/ibbw-ring.sh      六條 rail 的 RDMA 測速
pi/models.json.example    pi provider 設定
pi/settings.snippet.json  pi 預設推理強度
```

## 致謝與授權

- [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)（MIT）
- [eugr/spark-vllm-docker](https://github.com/eugr/spark-vllm-docker) 的 `setup-cluster.sh`
- 模型：[thinkingmachines/Inkling-2-Small](https://huggingface.co/thinkingmachines/Inkling-2-Small)，GGUF 量化：[bartowski](https://huggingface.co/bartowski/Inkling-2-Small-GGUF)；模型授權依原始 repo

本 repo 的腳本以 MIT 授權釋出。
