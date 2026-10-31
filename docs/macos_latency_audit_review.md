# macOS Latency Audit — 覆核報告 (Review & Verification)

> **覆核對象：** `docs/macos_latency_audit.md`
> **基準 Commit：** `ae2cd04b` (`fix(macos): serialize capture callbacks and fix frame lifetime`)
> **覆核結論：** **部分同意（約 70% 同意，30% 不同意或需修正關鍵事實，另補齊 3 項原審計遺漏的關鍵延遲／資源問題）**

---

## 1. 逐項覆核總表 (Verdict Summary)

| 原報告項目 | 覆核結論 | 簡要說明 |
|---|---|---|
| **Section A** | **部分同意** | 整體判斷正確，但 Zero-copy 路徑中 `av_pixel_buf_t` 仍對每幀執行了不必要的 `CVPixelBufferLockBaseAddress`（見新增項目 **N2**）。 |
| **V1** | **不同意（機制誤判）** | `capture_ctx_t::images` 是 1-slot `safe::event_t`（覆寫最新幀）而非 FIFO queue，且 `img` 在 `convert()` 後立即釋放，單一串流下 12 張的影像池不會因編碼器落後而耗盡阻塞。 |
| **V2** | **完全同意（可進一步簡化）** | `encode_run` 的 `images->pop(max_frametime)` 已原生實作 `minimum_fps_target` 重複編碼上一張 `AVFrame`，`sc_capture.m` 只需在 `pixelBuffer == NULL` 時直接略過即可。 |
| **V3** | **完全同意** | `sc_capture.m` 的 `videoQueue` / `audioQueue` 應提升至 `QOS_CLASS_USER_INTERACTIVE`（與 `AVVideo` 及音訊擷取執行緒對齊）。 |
| **V4, V5** | **完全同意** | 屬於客戶端／伺服器設定層面的合理建議。 |
| **A1** | **完全同意** | 應先查詢 `BufferFrameSizeRange` 並讀回 `BufferFrameSize`、`Latency`、`SafetyOffset` 寫入日誌。 |
| **A2** | **部分同意（反對 `reject`）** | 同意縮小 30 幀（150 ms）佇列容量，但**反對改用 `overflow_policy_e::reject`**（會保留舊音訊、丟棄最新音訊，鎖死最高延遲）；應改為逐一丟棄最舊元素（pop front）。 |
| **A3** | **部分同意（反對移出 IOProc）** | `1920 frames` 只是緩衝區上限，實際每次輸出僅對應當次 IOProc 的 `inputFrames`。在 IOProc 內使用預分配緩衝區做 `AudioConverterFillComplexBuffer` 符合 CoreAudio 即時規範，不應移出 IOProc；應改為動態放大 `ringBufferSize` 並修正轉換失敗時的錯誤 fallback。 |
| **A4** | **完全同意** | 縮短 5 秒 timeout 並補上裝置／Tap 變更監聽屬合理的可靠性與恢復速度改進。 |
| **A5** | **部分同意（分類與影響範圍修正）** | `platf::send` 不只影響音訊；因 macOS `send_batch` 回傳 `false`，**視訊與音訊**的 Broadcast 執行緒皆使用 `platf::send`。上游有 32 元素佇列上限不會無限堆積，但 `poll(..., -1)` 應加上有限 timeout 以免關閉時卡死。 |
| **A6** | **完全同意** | 每 5 ms 配置一次 `std::vector<float>` 與 `buffer_t` 屬低優先度衛生改進。 |
| **I1** | **完全同意** | 鍵盤事件改發送至 `kCGHIDEventTap` 並對齊 event source state 合理。 |
| **I2** | **同意且嚴重度低估** | 不只是絕對座標（Absolute），**相對移動（Relative）與滑鼠按鍵（Button）**也都在每個事件呼叫 `current_location()` 查詢 WindowServer 並呼叫 `CGWarpMouseCursorPosition`（預設還會觸發 250 ms 硬體事件抑制）。 |
| **I3** | **完全同意** | `task_pool` 只有 1 個 worker，Gamepad Home 模擬的 `sleep_for(100ms)` 會阻塞所有輸入 100 ms，應改為第二個 `pushDelayed`。 |
| **I4, I5, I6, I7** | **完全同意** | 診斷與取捨分析皆正確。 |
| **C1, C2, C3** | **完全同意** | AV1 超出範圍、H.264 不可加 `max_ref_frames=1`、不可將 `queueDepth` 降回 5 皆完全正確。 |
| **D1 / E5** | **需修正（已有內建機制但因 Bug 失效）** | Sunshine 在 `stream.cpp` 已內建 `frame_processing_latency_logger` 與傳給 Moonlight 的 `frame_processing_latency` 欄位，但因 macOS 的 `process_frame()` 漏設 `img->frame_timestamp` 而永遠為 0（見新增項目 **N1**）。 |
| **D2, D3, D4** | **完全同意** | 量測項目與回歸測試門檻清楚明確。 |

---

## 2. 不同意或需修正之處詳解 (Detailed Corrections)

### 2.1 修正 V1：影像池（`capture_buffer_size = 12`）不會因編碼器落後而耗盡

- **原報告推論（`docs/macos_latency_audit.md:48-55`）：**
  認為當編碼器落後時，`capture_buffer_size = 12`（`src/video.cpp:1601`）會被耗盡，使 `pull_free_image_callback` 進入 `sleep_for(1ms)` 重試（`src/video.cpp:1692`），進而阻塞串行的 `videoQueue`，讓 ScreenCaptureKit 的 `queueDepth = 16` 堆積最多 15 幀（约 250 ms）的舊畫面。
- **程式碼核實：**
  1. **最新幀覆寫機制：** `capture_ctx_t::images` 的型別是 `safe::event_t<std::shared_ptr<platf::img_t>>`（定義於 `src/video.h:120`、`src/thread_safe.h:24-50`），**它不是 FIFO 佇列，而是單一槽位（1-slot mailbox）**。當 `push_captured_image_callback` 呼叫 `capture_ctx->images->raise(img)`（`src/video.cpp:1714`）時，若編碼執行緒尚未取走上一幀，`_status` 會直接被新幀覆寫，舊幀的 `std::shared_ptr<platf::img_t>` 參考計數立即退回 `1`（回到可用狀態）。
  2. **轉換後立即釋放 `img_t`：** 在編碼迴圈 `encode_run`（`src/video.cpp:2483-2493`）中：
     ```cpp
     if (!requested_idr_frame || images->peek()) {
       if (auto img = images->pop(max_frametime)) {
         frame_timestamp = img->frame_timestamp;
         if (session->convert(*img)) { ... }
       } else if (!images->running()) {
         break;
       }
     }
     ```
     `nv12_zero_device::convert(*img)`（`src/platform/macos/nv12_zero_device.cpp:36-68`）只對底層 `CVPixelBufferRef` 執行 `CFRetain` 並掛載至 `av_frame->buf[0]`（耗時微秒級）。在離開第 2493 行的 `if` 區塊、**尚未呼叫第 2509 行的 `encode()` 之前**，區域變數 `img` 就已經解構，使 `imgs` 池中的 `std::shared_ptr<platf::img_t>` `use_count()` 降回 `1`。
  3. **結論：** 在單一客戶端串流下，`imgs` 池中 `use_count() > 1` 的物件最多只有 **2～3 個**（1 個在 `images->_status`、1 個正由 `convert()` 或 `probe_img` 短暫持有），**12 個槽位的 `imgs` 池絕不會因為編碼器變慢而耗盡**，且 `safe::event_t` 本身已經會在編碼器落後時自動丟棄中間舊幀。
  4. **V1 真正該防禦的情境：** 只有當 `videoQueue` 執行緒本身因系統排程延遲（QoS 過低，即 V3）或與擷取執行緒爭搶 `capture_cb_guard_t::cb_mutex`（`src/platform/macos/capture_guard.h:81`）時，SCK 佇列才可能累積超過 1 幀。

---

### 2.2 修正 V2：無需自訂限速器，直接跳過 `pixelBuffer == NULL` 即可

- **原報告建議（`docs/macos_latency_audit.md:57-63`）：**
  讀取 `SCStreamFrameInfoStatus`，在 `Idle` 時於 `sc_capture.m` 內做限速（rate-limit）至 `minimum_fps_target`。
- **程式碼核實：**
  - `encode_run`（`src/video.cpp:2442-2444, 2483-2510`）已經實作了 `max_frametime = 1000.0 / minimum_fps_target`。當畫面靜止、沒有新幀推入 `images` 時，`images->pop(max_frametime)` 會在等待 `max_frametime` 後超時返回空值，接著第 2509 行 `encode()` **會自動直接重編碼 `nv12_zero_device` 保留在 `av_frame->buf[0]` 的上一張 `CVPixelBufferRef`**。
  - 因此，`sc_capture.m:383-404` 在 `pixelBuffer == NULL` 時重送 `self.lastValidSampleBuffer` 完全是多餘的，不僅白跑整段 `pullImage` → `process_frame` → `pushImage` → `convert`，還額外 `CFRetain` 住一張 `CMSampleBufferRef`。
  - **建議改法：** 當 `CMSampleBufferGetImageBuffer(sampleBuffer) == NULL` 時直接 `return`，亦可移除 `lastValidSampleBuffer` 屬性，完全交由 `video.cpp` 原生的 `minimum_fps_target` 機制控管。

---

### 2.3 修正 A2：音訊佇列溢位策略不應使用 `overflow_policy_e::reject`

- **原報告建議（`docs/macos_latency_audit.md:94-99`）：**
  將 `src/audio.cpp:236` 的 `samples` 佇列從 30 降到 6～8，並改用 `overflow_policy_e::reject`。
- **程式碼核實：**
  - `src/thread_safe.h:401-404, 432-437` 中，`overflow_policy_e::drop_oldest` 實際執行的是 `_queue.clear()`（清空全部元素，相當於 `drop_all`）。
  - 但若改為 `overflow_policy_e::reject`，當佇列滿時會**拒絕最新擷取到的音訊樣本、保留佇列中舊的樣本**。一旦編碼執行緒曾經落後填滿佇列，後續只要消費者速度與生產者相當，佇列就會一直維持在滿載狀態（永久維持最大佇列延遲）或不斷丟棄最新聲音。
  - **建議改法：** 縮小容量至 6～8（30～40 ms）同意；但溢位行為應在 `safe::queue_t` 新增或修正為**真正的單筆丟棄最舊元素（`_queue.erase(_queue.begin())`）**，確保佇列永遠保留最新的音訊。

---

### 2.4 修正 A3：`AudioConverter` 實際輸出量與執行緒模型

- **原報告陳述（`docs/macos_latency_audit.md:101-106`）：**
  認為 `AudioConverterFillComplexBuffer` 的輸出緩衝區 `maxFrames = 1920`（約 40 ms）大於 `ringBufferSize`（約 30 ms，1440 frames），會導致 `TPCircularBufferProduceBytes` 失敗整塊丟包，並建議把格式轉換移出即時 IOProc 執行緒。
- **程式碼核實：**
  1. `maxFrames = 1920`（`src/platform/macos/av_audio.mm:844`）只是預分配緩衝區 `conversionBuffer` 的容量上限。在 `systemAudioIOProc`（`src/platform/macos/av_audio.mm:139-166`）中，`audioConverterComplexInputProc`（`:76-99`）只提供當次 IOProc 收到的 `inputFrames`；一旦提供完畢就回傳 `*ioNumberDataPackets = 0`，因此轉換後的 `outputFrameCount` 只等於 `inputFrames * (clientSampleRate / deviceSampleRate)`，不會填滿 1920 frames（除非 CoreAudio 實際給的 `inputFrames` 超過 1440 frames）。
  2. 在 CoreAudio IOProc 中使用預先分配（無 `malloc`、無 Objective-C 訊息派發）的緩衝區呼叫 `AudioConverterFillComplexBuffer` 是標準的即時音訊做法；若移到另一條執行緒，反而增加一次執行緒喚醒與排程抖動。
  3. **真正需要修的兩件事：**
     - `ringBufferSize`（`av_audio.mm:526`）目前寫死 `6 * 240 * channels * sizeof(float)`，若 CoreAudio 實際配置的 `deviceFrameSize` 為 512 或 1024 frames，ring buffer 只裝得下 1～2 次 callback。應先讀回實際 `deviceFrameSize`，將 `ringBufferSize` 設為 `std::max(6 * clientFrameSize, 4 * actualDeviceFrameSize) * channels * sizeof(float)`。
     - **移除 `av_audio.mm:167-171` 的危險 fallback：**
       ```cpp
       } else {
         // Fallback: write original data
         TPCircularBufferProduceBytes(&avAudio->audioSampleBuffer, inputBuffer.mData, inputBuffer.mDataByteSize);
         didWriteData = true;
       }
       ```
       當需要格式轉換卻轉換失敗時，將**未轉換格式（不同取樣率或不同聲道數）**的原始資料直接寫入 ring buffer 會破壞聲道對齊與音高，應改為忽略或填入靜音。

---

### 2.5 修正 A5：`platf::send` 同時位於 Video 與 Audio 傳送熱路徑

- **原報告陳述（`docs/macos_latency_audit.md:115-120`）：**
  將 `src/platform/macos/misc.mm:527-533` 的 `platf::send` 歸類在 Audio 下，並推論 socket 塞住時音訊執行緒會無上限阻塞。
- **程式碼核實：**
  - macOS 的 `platf::send_batch`（`src/platform/macos/misc.mm:445-448`）固定回傳 `false`，因此 `videoBroadcastThread`（`src/stream.cpp:1792-1809`）與 `audioBroadcastThread`（`src/stream.cpp:1915, 1942`）**全部都是逐包呼叫 `platf::send`**。
  - 呼叫 `platf::send` 的是 `stream::videoBroadcast` 與 `stream::audioBroadcast` 執行緒，而非擷取或編碼執行緒；且 `mail::video_packets` 與 `mail::audio_packets` 預設皆為 `max_elements = 32` 的 `safe::queue_t`，不會無上限撐爆記憶體。
  - 建議將 `poll(&pfd, 1, -1)` 改為有限 timeout（例如 `poll(&pfd, 1, 100)` 並檢查終止條件），同時評估在 macOS 實作批次發送以降低每個視訊幀數十次 `sendmsg` 系統呼叫的開銷。

---

### 2.6 修正 I2：所有滑鼠事件（含 Relative 與 Button）皆存在重複 WindowServer 查詢與 Warp

- **原報告陳述（`docs/macos_latency_audit.md:136-141`）：**
  標題寫「Every **absolute** mouse event performs a window-server position query and a cursor warp」。
- **程式碼核實：**
  - 檢視 `third-party/libvirtualhid/src/platform/macos/macos_backend.cpp:672-745`：
    - `submit_relative_motion`（`:715-720`）呼叫了 `current_location()` 與 `post_mouse(...)`。
    - `submit_absolute_motion`（`:722-727`）呼叫了 `CGDisplayBounds()`、`current_location()` 與 `post_mouse(...)`。
    - `submit_button`（`:729-745`）也呼叫了 `current_location()` 與 `post_mouse(...)`。
    - `post_mouse`（`:684-713`）內部每次都呼叫 `CGDisplayBounds(state_->display)`、`CGEventPost(kCGHIDEventTap, event)`，接著**無條件呼叫 `CGWarpMouseCursorPosition(location)`（`:711`）**！
  - **嚴重性：**
    1. 即使是一般遊戲最常用的**相對滑鼠移動（Relative motion）**，在 125～1000 Hz 回報率下，每一個封包都會執行：`CGEventCreate` + `CGEventGetLocation` + `CFRelease` + `CGDisplayBounds` + `CGEventPost` + `CGWarpMouseCursorPosition`（至少 3～4 次跨行程 WindowServer 查詢／操作）。
    2. `CGEventPost` 送出 `kCGEventMouseMoved` / `Dragged` 本就會移動系統游標；後面緊接著呼叫 `CGWarpMouseCursorPosition` 不僅多餘，且在 macOS 上預設會觸發 **250 ms 的本地硬體事件抑制期（Local Events Suppression Interval）**。這項問題的優先度應提高至第一梯隊。

---

## 3. 原審計遺漏的 3 項關鍵問題 (Newly Identified Findings)

### N1. 【高影響／關鍵遺漏】macOS 從未設定 `img->frame_timestamp`，導致 RTP 時間戳失真與延遲量測全部失效
- **位置：** `src/platform/macos/display.mm:53-79`（`process_frame`）、`src/video.cpp:1688`、`src/stream.cpp:1532, 1585-1596, 1724-1730`
- **事實：**
  - `pull_free_image_callback` 在每次取出影像時會執行 `img_out->frame_timestamp.reset()`（`src/video.cpp:1688`）。
  - Windows 與 Linux 擷取後端都會在擷取完成時填入 `img->frame_timestamp`，唯獨 macOS 的 `process_frame()` **完全沒有設定 `img->frame_timestamp`**。
- **造成的後果：**
  1. **每一幀都被標記為重複幀（`frame_is_dupe = true`）：** 在 `videoBroadcastThread`（`src/stream.cpp:1724-1730`）中，因為 `packet->frame_timestamp` 永遠是 `std::nullopt`，每一幀都被視為 duplicate frame！
  2. **RTP 90 kHz 時間戳退化：** 因為 `packet->frame_timestamp` 為空，所有視訊封包的 RTP timestamp 都被迫改用 `ratecontrol_next_frame_start`（上一幀發送節流結束的時間點），而非畫面實際擷取時間，直接影響客戶端（Moonlight）的 frame pacing 與 jitter buffer 判斷。
  3. **內建延遲統計與 Moonlight 顯示全部為 0（直接解答原報告 D1 與 E5）：** `src/stream.cpp:1585-1596` 原本就有計算擷取到發送的處理延遲並寫入 `frame_header.frame_processing_latency`（供 Moonlight HUD 顯示「Host processing latency」）以及 `frame_processing_latency_logger`（在 `debug` 等級定期印出 min/max/avg 延遲），因為 `frame_timestamp` 未設定，在 macOS 上這兩者永遠是 `0`。
- **建議：** 在 `src/platform/macos/display.mm` 的 `process_frame()` 中補上 `img->frame_timestamp = std::chrono::steady_clock::now();`（或將 `CMSampleBufferGetPresentationTimeStamp(sampleBuffer)` 從 `CMClockGetHostTimeClock()` 換算至 `steady_clock`）。

### N2. 【中影響／Zero-Copy 瑕疵】`av_pixel_buf_t` 在 Zero-Copy 路徑上對每一幀執行 `CVPixelBufferLockBaseAddress`
- **位置：** `src/platform/macos/display.mm:61`、`src/platform/macos/av_img_t.h:98-118`、`src/platform/macos/nv12_zero_device.cpp:36-68`
- **事實：**
  - `process_frame()` 對每一幀建立 `av_pixel_buf_t`，其建構子無條件呼叫 `CVPixelBufferLockBaseAddress(buf, kCVPixelBufferLock_ReadOnly)`，並呼叫 `CVPixelBufferGetBaseAddress(buf)` 存入 `img->data`。
  - 但在 `nv12_zero_device`（NV12 / P010 硬體零拷貝）路徑下，VideoToolbox 只透過 `av_frame->data[3]` 取用 `CVPixelBufferRef`（底層為 GPU `IOSurface`），**CPU 從頭到尾不會讀取 `img->data`**。
- **推論：** 對 GPU 產生的 `IOSurface` 每幀執行 `CVPixelBufferLockBaseAddress` / `UnlockBaseAddress` 會強制驅動程式進行不必要的 CPU 位址映射與快取同步（cache coherency synchronization）。
- **建議：** 僅在軟體編碼路徑（`kCVPixelFormatType_32BGRA` / `yuv420p`）或實際需要讀取 `data()` 時才 lock base address；Zero-Copy 路徑只需保留 `CVPixelBufferRef` 與幾何資訊（`fill_img_geometry` 不需要 lock base address）。

### N3. 【中影響／CPU 空轉與假性超時失效】`av_mic_t::sample` 的 `audioSemaphore` 計數無限累積導致 Busy-Spin
- **位置：** `src/platform/macos/av_audio.mm:207, 378`、`src/platform/macos/microphone.mm:38-62`
- **事實：**
  - 生產端（`systemAudioIOProc` 與 `captureOutput:didOutputSampleBuffer:`）在每次寫入資料後都會無條件呼叫 `dispatch_semaphore_signal(avAudio->audioSemaphore)`。
  - 消費端 `av_mic_t::sample`（`src/platform/macos/microphone.mm:40-53`）卻寫成：
    ```cpp
    void *tail = TPCircularBufferTail(&av_audio_capture->audioSampleBuffer, &avail);
    if (avail == 0) {
      dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC);
      if (dispatch_semaphore_wait(av_audio_capture->audioSemaphore, timeout) != 0) { ... }
      continue;
    }
    ```
  - 只要呼叫 `sample()` 時 ring buffer 內已有資料（`avail > 0`，例如 CoreAudio 一次 callback 送來 512 frames，可讓 `sample()` 連續讀取兩次 240 frames 而不進 `if (avail == 0)`），`audioSemaphore` 的計數就會只增不減，在串流數分鐘後累積上萬個訊號 token。
- **造成的後果：**
  1. 當下一次遇到 `avail == 0`（等待下一個硬體音訊 callback）時，`dispatch_semaphore_wait` **不會睡眠等待**，而是立即扣減歷史累積的 token 並返回 `0`，使處於 `QOS_CLASS_USER_INTERACTIVE`（最高即時優先權）的音訊執行緒在 `while (remaining > 0)` 迴圈中**高速 busy-spin 空轉**，直到把累積的數千個 token 扣光或新資料抵達。
  2. 若音訊裝置真的中斷，必須先把累積的數萬個 token 在迴圈中扣完，才會真正進入 5 秒等待。
- **建議：** 改用條件變數／事件旗標，或在成功從 `TPCircularBuffer` 讀出資料後將多餘的 semaphore count 排空（`while (dispatch_semaphore_wait(sem, DISPATCH_TIME_NOW) == 0) {}`）。

---

## 4. 修訂後的建議執行順序 (Revised Action Plan)

1. **階段一：零風險高價值修正與量測打通（優先執行）**
   - **N1（補上 `img->frame_timestamp`）**：於 `src/platform/macos/display.mm` 的 `process_frame()` 設定擷取時間戳，立即修復 RTP 時間戳退化，並自動啟用 `stream.cpp` 的 `frame_processing_latency`（Moonlight 延遲顯示與 `debug` 日誌統計）。
   - **V3（提升 SCK 佇列 QoS）**：將 `src/platform/macos/sc_capture.m:80-83` 的 `videoQueue` 與 `audioQueue` 改為 `QOS_CLASS_USER_INTERACTIVE`。
   - **I3（消除 Input Worker 100 ms 睡眠）**：將 `src/input.cpp:1647` 的 `sleep_for(100ms)` 拆為第二個 `task_pool.pushDelayed`。
   - **A1 + D2（CoreAudio 實際參數觀測）**：在 `src/platform/macos/av_audio.mm` 查詢並記錄 `BufferFrameSizeRange`、實際 `BufferFrameSize`、`Latency` 與 `SafetyOffset`。

2. **階段二：Capture / Input 核心熱路徑減負**
   - **V2（移除靜止畫面重複投遞）**：在 `src/platform/macos/sc_capture.m:383-404` 遇到 `pixelBuffer == NULL` 時直接返回，交由 `video.cpp:2484` 的 `max_frametime` 控制靜態畫面最低幀率。
   - **N2（Zero-Copy 免 Lock BaseAddress）**：重構 `av_pixel_buf_t`（`src/platform/macos/av_img_t.h`），在 NV12/P010 零拷貝路徑避免每幀呼叫 `CVPixelBufferLockBaseAddress`。
   - **I2 + I1（macOS 滑鼠與鍵盤事件熱路徑優化）**：在 `third-party/libvirtualhid/src/platform/macos/macos_backend.cpp` 快取游標位置與顯示器邊界、移除相對移動與按鍵時多餘的 `current_location()` 及 `CGWarpMouseCursorPosition`，並將鍵盤事件統一發送至 `kCGHIDEventTap`。

3. **階段三：Audio 緩衝與穩定度重整**
   - **N3（修復 `audioSemaphore` 累積 Busy-Spin）**：修正 `src/platform/macos/microphone.mm:40-53` 的等待邏輯。
   - **A3（動態 Ring Buffer 大小與移除錯誤 Fallback）**：在 `src/platform/macos/av_audio.mm` 依據實際 `deviceFrameSize` 配置 `ringBufferSize`，並移除轉換失敗時寫入未轉換原始資料的 fallback。
   - **A2（縮小 `sample_queue_t` 並改為單筆丟棄最舊樣本）**：將 `src/audio.cpp:236` 佇列容量降至 6～8，並在 `src/thread_safe.h` 支援單筆 pop-oldest 策略。
