# macOS latency audit (Lumen)

> Status: **review draft — findings only, no code changes are proposed or implied by this document.**
> Every `file:line` reference below was read in the tree at the commit listed below. Items that could
> not be confirmed in code are isolated in [Section E](#e-unverified-suspicions) and must not be
> treated as facts.

中文摘要：這份文件整理 macOS 上 capture/encode、audio、input 三條路徑的延遲审计結果。
A 段是「已經是最佳、不用動」的項目；B 段是 11 個可改進項（每項都有位置／事實／推論／建議／風險）；
C 段是明確不該動的地方；D 段是要先補的量測；E 段是還沒證實、需要覆核者判斷的懷疑點。
所有行號都在 `ae2cd04b` 這棵樹上核過。

| | |
|---|---|
| Audited at | `ae2cd04b` — `fix(macos): serialize capture callbacks and fix frame lifetime` |
| Host | macOS 27.2 (build 26B123), Apple Silicon, SDK 27.0 |
| Runtime under test | `/opt/homebrew/Cellar/lumen/1.0.0/bin/lumen`, UUID `3B4CB3A4-997D-3595-A85A-B1C88547F68D` |
| Method | Read-only source audit (capture/encode, audio, input). No profiling runs, no instrumentation. |
| Reproduce | `cmake -B cmake-build-macos -DBUILD_TESTS=ON` → `cmake --build cmake-build-macos --target lumen test_sunshine` → `./cmake-build-macos/tests/test_sunshine --gtest_filter='Macos*'` |

---

## A. Already optimal — do not spend review effort here

| Item | Evidence |
|---|---|
| Zero-copy capture → VideoToolbox for 8-bit and 10-bit. No `swscale` in the streaming path. | `src/video.cpp:1375-1386` (`AV_PIX_FMT_NV12`, `AV_PIX_FMT_P010`, `vt_init_avcodec_hardware_input_buffer`); `src/platform/macos/display.mm:311-321` returns `nv12_zero_device` for `nv12`/`p010`; `nv12_zero_device::convert()` puts the `CVPixelBufferRef` in `av_frame->data[3]` and attaches an `AVBufferRef` so `avcodec_send_frame()` takes a reference instead of copying |
| VideoToolbox realtime mode is on by default and is passed to the encoder | `docs/configuration.md:3164` (`vt_realtime` default `enabled`), `src/video.cpp:1392` (`"realtime"` option) |
| Encoder is asked to prioritise speed | `src/video.cpp:1393` (`"prio_speed", 1`). Note the runtime warning `PrioritizeEncodingSpeedOverQuality property is not supported on this device` — the property is unavailable on this GPU, so this option is inert on this host |
| HEVC/AV1 pinned to 1 reference frame | `src/video.cpp:1394` (see [C2](#c2-h264-must-not-get-max_ref_frames1) for why H.264 deliberately omits it) |
| Capture frame interval is derived from the client-requested fps, not a hard-coded value | `src/platform/macos/display.mm:445` passes `config.framerate`; `src/platform/macos/sc_capture.m:238` `config.minimumFrameInterval = CMTimeMake(1, captureFrameRate)` |
| Cursor compositing off in the observed session (`show_cursor = false`) | user config, echoed at session start in `~/.config/sunshine/sunshine.log` |
| No audio pacing: no `sleep`/timer in the audio capture or encode path — fully demand-driven | `src/audio.cpp`, `src/platform/macos/microphone.mm`, `src/platform/macos/av_audio.mm` (no pacing sleeps found) |
| Audio capture thread is raised to the highest QoS class | `src/audio.cpp:234` → `src/platform/macos/misc.mm:242-263` |
| System audio uses a CoreAudio **process tap**, no third-party loopback driver needed | `src/platform/macos/av_audio.mm:629` (`initStereoGlobalTapButExcludeProcesses:`), `:660` (`AudioHardwareCreateProcessTap`), `:687-690` (aggregate device with `kAudioSubTapDriftCompensationKey: @YES`) |
| Gamepad uses real virtual HID with timestamps | `src/platform/macos/hid_gamepad.m:223-237` (`IOHIDUserDeviceCreateWithProperties`), report submission with timestamp at `:382`; selection logic `src/platform/macos/gamepad_bridge.mm:111-114` |
| Video and audio are structurally decoupled (separate threads and sockets) | `src/audio.cpp:110` uses `mail::audio_packets`; video uses `mail::video_packets` (`src/video.cpp:2447`) |

---

## B. Findings

Impact legend: **high** = plausibly tens of ms or a visible stall; **medium** = measurable under load; **low** = hygiene.
Confidence legend: **verified** = read in code; **inferred** = follows from code but the OS behaviour is not observed on this host.

### Video / capture

#### V1. No stale-frame drop, and the capture callback runs on a serial queue that can be blocked — queue backlog becomes visible latency
- **Confidence:** verified (mechanism), inferred (magnitude)
- **Location:** `src/platform/macos/sc_capture.m:80-83` (serial `videoQueue`), `src/platform/macos/sc_capture.m:243` (`config.queueDepth = 16`), `src/video.cpp:1692` (`std::this_thread::sleep_for(1ms)` retry while the image pool is empty), `src/video.cpp:1601` (`capture_buffer_size = 12`)
- **Fact:** ScreenCaptureKit delivers samples on a **serial** queue. The delivery handler calls `push_captured_image_cb` inline, and that callback sleeps 1 ms and retries when the capture image pool is exhausted. While the handler is blocked, SCK keeps producing samples into its queue (`queueDepth = 16`).
- **Inference:** when the encoder thread falls behind, up to ~15 undelivered samples (≈250 ms at 60 fps) can be queued and are then delivered back-to-back. The client sees a burst of old frames — i.e. a latency spike, not a frame drop.
- **Context:** `queueDepth` was raised from 5 to 16 in `ae2cd04b` to stop SCK recycling an IOSurface that the encoder still referenced (the crash root cause). The depth increase is a correctness fix; this finding is its side effect.
- **Suggestion:** drop samples whose `CMSampleBufferGetPresentationTimeStamp()` is more than one frame interval older than the last accepted frame, before pulling an image from the pool. Keep `queueDepth` ≥ pool size so the lifetime guarantee is preserved.
- **Risk:** dropping frames changes the frame sequence sent to the client; the first drop after a stall may need an IDR. Needs a bounded-drop counter plus a log line so it is observable.

#### V2. Idle display re-delivery is unconditional and runs at full capture rate
- **Confidence:** verified
- **Location:** `src/platform/macos/sc_capture.m` (`stream:didOutputSampleBuffer:ofType:` handler: `pixelBuffer == NULL` ⇒ re-deliver `lastValidSampleBuffer`); available metadata: `SCStream.h:41-56` (`SCFrameStatusComplete/Idle/Blank/Suspended/Started/Stopped`), `SCStream.h:415` (`SCStreamFrameInfoStatus`), both `macos(12.3)+`
- **Fact:** ScreenCaptureKit explicitly reports *why* a sample was produced via `SCStreamFrameInfo` attached to the sample buffer. The current handler does not read it; it treats "no image buffer" as "re-deliver the cached sample".
- **Inference:** for static content, the encoder is fed duplicate full-rate frames, the 12-image pool churns continuously, and VideoToolbox stays busy — so a genuine screen change queues behind synthetic duplicates.
- **Suggestion:** read `SCStreamFrameInfoStatus`; on `Idle` either skip or rate-limit duplicates to `minimum_fps_target` (default is half the stream fps — `src/video.cpp:2442-2444`). Keep the current behaviour behind a config switch so it can be A/B tested.
- **Risk:** some clients expect a continuous frame flow (see `docs/configuration.md:1568` on `minimum_fps_target`). Skipping entirely may cause client-side stall detection; rate-limiting is the safer default.

#### V3. Capture queue QoS is below interactive
- **Confidence:** verified
- **Location:** `src/platform/macos/sc_capture.m:80-83` — `QOS_CLASS_USER_INITIATED` for `videoQueue`/`audioQueue`
- **Fact/Suggestion:** the capture callback is latency-critical; the audio capture thread already runs at `QOS_CLASS_USER_INTERACTIVE` (`src/audio.cpp:234`, `src/platform/macos/misc.mm:242-263`), the capture queues do not. One-line change.
- **Risk:** low; only affects scheduling under system load.

#### V4. Session is running 10-bit (P010) without HDR
- **Confidence:** verified (log), inferred (cost)
- **Location:** session log `Creating encoder [hevc_videotoolbox]` / `Color coding: SDR (Rec. 601)` / `Color depth: 10-bit`
- **Fact:** 10-bit SDR selects `p010` and therefore a wider buffer and more encode work per frame than 8-bit NV12 for the same codec.
- **Suggestion:** if HDR is not wanted, set the client to 8-bit 4:2:0. Note 4:4:4 is not supported on macOS at all: `src/platform/macos/display.mm:319-320` logs `Unsupported Pixel Format.` and returns `nullptr`.
- **Risk:** none server-side; it is a client/session setting.

#### V5. `vt_software` default allows a silent fallback to software encoding
- **Confidence:** verified (option plumbing), inferred (consequence)
- **Location:** `docs/configuration.md:3123` (default `auto`), `src/video.cpp:1390-1391` (`allow_sw` / `require_sw`), `src/config.cpp:1680-1681`
- **Fact:** with `auto`, FFmpeg decides; a VideoToolbox session failure can silently encode in software.
- **Suggestion:** set `vt_software = disabled` so such a failure becomes a visible stream failure instead of a ~30-60 ms latency regression.
- **Risk:** loses the fallback entirely (which is the point); must be an explicit operator choice.

### Audio

#### A1. The IOProc cadence actually granted by CoreAudio is never observed
- **Confidence:** verified (absence), inferred (cost)
- **Location:** `src/platform/macos/av_audio.mm:712-741` sets `kAudioDevicePropertyBufferFrameSize` (`:730`) to 240 frames (5 ms) best-effort. No `kAudioDevicePropertyBufferFrameSizeRange` read-back, and `kAudioDevicePropertyLatency` / `kAudioDevicePropertySafetyOffset` are not queried anywhere in `src/platform/macos`. Ring buffer: `av_audio.mm:526` `int ringBufferSize = 6 * 240 * channels * sizeof(float);` (≈30 ms), `:529`.
- **Inference:** if CoreAudio clamps the aggregate device to a larger frame size (512/1024 frames = 10.7/21.3 ms is common), Sunshine's 5 ms frames are cut out of a much larger OS burst and the ring holds roughly one callback — i.e. a steady, invisible 10-25 ms of audio latency.
- **Suggestion:** query `BufferFrameSizeRange`, clamp the request into it, then read back `BufferFrameSize` + `Latency` + `SafetyOffset` and log them at session start. This is a measurement change first; only then tune.
- **Risk:** none for the logging step. Any later change in requested frame size may be refused by the device.

#### A2. 150 ms sample queue whose overflow policy drops everything
- **Confidence:** verified
- **Location:** `src/audio.cpp:236` `auto samples = std::make_shared<sample_queue_t::element_type>(30);` (30 × 5 ms = 150 ms); `src/thread_safe.h:401-404` (`drop_oldest` = "Clear the queue and accept the new item (current default behavior)"), `:412` (default policy `drop_oldest`), `:432-436` (`_queue.clear()` when full)
- **Inference:** if the Opus encode thread lags, latency ramps up to 150 ms and then the whole queue is discarded at once — an audible jump. A deep demand-driven queue buys no smoothness, only latency.
- **Suggestion:** reduce capacity (e.g. 6-8 = 30-40 ms) and/or switch to `overflow_policy_e::reject`, and log the drop count.
- **Risk:** a shorter queue makes brief encoder hiccups audible as gaps instead of absorbed delay — measure before shipping.

#### A3. `AudioConverterFillComplexBuffer` runs inside the IOProc, and its output buffer is larger than the ring
- **Confidence:** verified
- **Location:** `src/platform/macos/av_audio.mm:153-166` (conversion inside the IOProc), `:807` and `:833` (converter created only when rate or channel count differs), `:844` `UInt32 maxFrames = self->ioProcData->clientRequestedFrameSize * 8;` (1920 frames ≈ 40 ms) vs the ≈30 ms ring at `:526`
- **Fact:** a full converter output larger than the ring's free space cannot be enqueued (`TPCircularBuffer` returns false and copies nothing), so the whole block is lost.
- **Suggestion:** make the tap nominal rate and channel layout match the client so the converter is not created at all; if a converter is required, size its output against the ring's free space and move conversion off the real-time IO thread.
- **Risk:** moving conversion off the IO thread changes the synchronisation structure of the audio path — the largest audio change in this list.

#### A4. 5 s underrun timeout, silence is generated and then discarded, and there is no device/tap change listener
- **Confidence:** verified
- **Location:** `src/platform/macos/microphone.mm:44` (`5LL * NSEC_PER_SEC`), `:49` (`std::fill(sample_in.begin(), sample_in.end(), 0.0f)`), `src/audio.cpp:256` (`case platf::capture_e::timeout:`); ScreenCaptureKit audio fallback waits in 0.1 s slices at `microphone.mm:102`
- **Fact:** on a stall the path can wait up to 5 s, and the generated silence is not sent. No `AudioObjectPropertyListener` for device or tap changes was found.
- **Suggestion:** shorten the timeout (≈200 ms) and rebuild the tap on device/tap changes.
- **Risk:** reliability change more than latency; a too-short timeout could thrash tap creation (which is expensive).

#### A5. `platf::send` blocks indefinitely on `EAGAIN`
- **Confidence:** verified
- **Location:** `src/platform/macos/misc.mm:527` (`while (bytes_sent < 0 && errno == EAGAIN)`) and `:533` (`poll(&pfd, 1, -1)`)
- **Inference:** if the audio socket backs up, the audio thread parks with no timeout and no queue bound.
- **Suggestion:** bounded wait plus a drop-oldest policy for audio packets, or an explicit stall counter in the log.
- **Risk:** dropping audio is user-visible; needs a policy decision.

#### A6. Per-5 ms allocations
- **Confidence:** verified
- **Location:** `src/audio.cpp:249-250` (`std::vector<float> sample_buffer;` + `resize()`, see `src/audio.cpp:29` `sample_queue_t`), `src/audio.cpp:139` `buffer_t packet {1400};`
- **Inference:** ~200 allocations/second for 5 ms frames; small, but it is on the audio latency path.
- **Suggestion:** pool or reuse buffers. Low priority on its own.

### Input

#### I1. Keyboard events are posted at the session tap; mouse events at the HID tap
- **Confidence:** verified
- **Location:** `third-party/libvirtualhid/src/platform/macos/macos_backend.cpp:497` and `:548-549` — `CGEventPost(kCGSessionEventTap, ...)`; `:710` and `:762` — `CGEventPost(kCGHIDEventTap, ...)`; sources at `:389-391` (mouse: `kCGEventSourceStateHIDSystemState`, keyboard: `kCGEventSourceStatePrivate`)
- **Suggestion:** use the HID tap (and a matching event source state) for keyboard as well, so both device classes enter the system at the same point.
- **Risk:** third-party code (`third-party/libvirtualhid`) — needs an upstream-side change or a fork patch; behaviour of apps that read modifier flags must be re-tested.

#### I2. Every absolute mouse event performs a window-server position query and a cursor warp
- **Confidence:** verified (code), inferred (cost)
- **Location:** `macos_backend.cpp:671-683` (`CGEventCreate(state_->source)` + `CGEventGetLocation` + `CFRelease`, per event); `:701-711` (`CGEventSetLocation`, `CGEventSetDoubleValueField(kCGMouseEventDeltaX/Y)`, `CGEventPost(kCGHIDEventTap, …)`, then `CGWarpMouseCursorPosition(location)`)
- **Inference:** a synchronous state query plus a warp per move event; at 120 Hz pointer updates this is a real per-event cost, and setting both an absolute location and relative deltas invites the pointer accelerator to act on the delta.
- **Suggestion:** cache the last known position instead of querying per event, and avoid carrying both absolute and relative fields in the same event.
- **Risk:** the warp exists to keep the OS cursor in sync in absolute mode; removing it changes cursor behaviour. Needs pointer-mode regression tests.

#### I3. Input handlers share one thread pool worker, and one of them sleeps 100 ms
- **Confidence:** verified
- **Location:** `src/main.cpp:394` `task_pool.start(1);`; input packets are dispatched with `task_pool.push` (`src/input.cpp:2145`); the gamepad Home emulation sleeps inside the task (`src/input.cpp:1647`), scheduled via `pushDelayed` at `:1656`
- **Fact:** pressing Home blocks the single worker for 100 ms, queueing every other input event behind it.
- **Suggestion:** replace the sleep with a second `pushDelayed(..., 100ms)` for the Home release.
- **Risk:** low; ordering of the press/release pair must be preserved.

#### I4. Pointer acceleration is not addressed
- **Confidence:** verified (absence)
- **Location:** no `IOHIDSetConstantScale`, `kCGMouseEventScaleDelta`, or tap accounting anywhere in the input layer (grep over `src/platform/macos`, `third-party/libvirtualhid`)
- **Inference:** relative deltas posted at the HID tap (`macos_backend.cpp:706-710`) are subject to the system pointer-acceleration setting.
- **Suggestion:** there is no supported per-process API; document that pointer acceleration should be off for gaming, and avoid adding a second motion field (see I2).
- **Risk:** none (documentation only).

#### I5. Scroll configuration is self-contradicting in the observed config
- **Confidence:** verified
- **Location:** `src/input.cpp:1227` and `:1250` — `if (config::input.high_resolution_scrolling || config::input.macos_smooth_scrolling)`; defaults `src/config.cpp:865-871` (`high resolution scrolling = true`, `macos_smooth_scrolling = true`); host-side inertia thread `src/platform/macos/smooth_scroll.mm:182` (`FRAME_DURATION = 8ms`), `:254` (`sleep_for(FRAME_DURATION)`), `:187` (`QOS_CLASS_USER_INTERACTIVE`), mutexes `:32-33`
- **Fact:** the observed session config sets `high_resolution_scrolling = disabled`, but `macos_smooth_scrolling` stays `true`, so the pixel path is still taken (also `src/platform/virtualhid_input.cpp:1069-1073`). The 8 ms inertia loop is a deliberate simulation, not a bug.
- **Suggestion:** decide one path explicitly; for lowest scroll latency set `macos_smooth_scrolling = disabled`.

#### I6. `virtual_display` is `disabled` in the observed config — correct for latency, with a known trade-off
- **Confidence:** verified
- **Location:** default `src/config.cpp:797` (`"enabled"`); `src/display_device.cpp:862-874` — after creating the display it waits `std::this_thread::sleep_for(5s)` (`:869`); helper waits `usleep(500000)` at `src/platform/macos/vd_helper.m:281,322,334`
- **Fact:** the 5 s wait happens on the session-handshake path, so a new client connection stalls. With `virtual_display` disabled there is no mode-switch stall, but the client-requested resolution is never applied (no `CGDisplaySetDisplayMode` in the macOS layer; only inside the helper at `vd_helper.m:312`) — capture stays at the display's native size and is scaled.
- **Suggestion:** if resolution control is wanted, re-enable it and shorten/condition the 5 s wait (e.g. poll for the display to appear). Otherwise leave disabled and document the resolution behaviour.

#### I7. Gamepad keyboard/mouse emulation fallback is chatty
- **Confidence:** verified
- **Location:** `src/platform/macos/gamepad.m:97,107,147,179` (`CGEventPost(kCGHIDEventTap, …)`), an extra `CGEventCreate(self.eventSource)` position query per click at `:168`, hard-coded `mouseSensitivity = 15.0f` at `:40`, deadzone applied at `:263`; the lvh macOS gamepad backend is unimplemented (`macos_backend.cpp:790`), so the native path is always used (`gamepad_bridge.mm:111-114`)
- **Fact:** `hid_gamepad.m:166` creates a throwaway `IOHIDUserDevice` to probe, then creates the real one at `:223-237`.
- **Suggestion:** keep the native path (already used); treat the emulation fallback and the probe device as start-up cost, not steady-state latency. Pen/touch backends are unimplemented (`macos_backend.cpp:819,823,830`) while `native pen/touch support` defaults to `true` (`src/config.cpp:871`) — capability negotiation cost only.

---

## C. Explicitly out of scope — do not change

### C1. AV1
`Error: Couldn't open [av1_videotoolbox]` is expected on this host and was declared out of scope by the maintainer. Do not spend review time on AV1 encoder availability.

### C2. H.264 must not get `max_ref_frames=1`
`src/video.cpp:1423-1427` documents that VideoToolbox on Apple Silicon produces all-IDR output when `ReferenceBufferCount=1` for H.264 (≈3× bandwidth, frame drops; upstream LizardByte/Sunshine#5013). HEVC/AV1 keep the option.

### C3. Do not lower `config.queueDepth` back to 5
`src/platform/macos/sc_capture.m:243` was raised from 5 to 16 to stop ScreenCaptureKit recycling buffers that the capture pool and encoder still reference. That depth is a lifetime guarantee, not a tuning knob; V1 must be fixed by dropping stale samples, not by shrinking the queue.

---

## D. Measurements to add before tuning

Without these, V1/V2/A1/A2 trade-offs cannot be judged.

1. **Video pipeline histogram** — per frame: capture callback entry time → `convert()` return → packet enqueued. Report p50/p95 every N seconds at `debug`. Also count stale frames dropped (V1) and idle duplicates (V2).
2. **Audio device reality check** — log `BufferFrameSizeRange`, the granted `BufferFrameSize`, `kAudioDevicePropertyLatency`, `kAudioDevicePropertySafetyOffset`, and whether an `AudioConverter` was created (`av_audio.mm:807`). One log line per session, no hot-path cost.
3. **Audio queue occupancy** — max and p95 depth of the `sample_queue_t` (`src/audio.cpp:236`) plus drop count from `thread_safe.h:432-436`.
4. Existing regression gate: `./test_sunshine --gtest_filter='Macos*'` (26 tests as of `ae2cd04b`, including `MacosCaptureGuard.*`, `MacosImgGeometry.*`, `MacosNv12.*`).

---

## E. Unverified suspicions

Listed separately so reviewers can challenge them; none of the B-section suggestions depend on these.

1. Whether CoreAudio really clamps the aggregate device above 240 frames (A1) — needs the read-back in D2.
2. Whether macOS pointer acceleration is actually applied to `kCGMouseEventDeltaX/Y` posted at the HID tap (I4) — inferred from the absence of any acceleration handling, not observed.
3. Whether posting keyboard events at `kCGSessionEventTap` (I1) measurably costs more than the HID tap, or is only a consistency/app-compatibility issue.
4. Whether the 10-bit session (V4) is operator-selected or negotiated by the client — the log shows the result, not the decision path.
5. Whether Moonlight's reported latency includes enough of the server-side pipeline to validate D1 — treat Moonlight numbers as end-to-end only.

---

## Appendix 1 — why this audit starts now

`ae2cd04b` fixed a crash in `sc_display_t::capture()` caused by two threads mutating the capture image pool. Evidence from the crashed session log (`~/.config/sunshine/sunshine.log.3`, 13:49→16:07):

| Log window | Binary | Duration | Sessions | `Encoder did not produce IDR frame when requested!` |
|---|---|---|---|---|
| `sunshine.log.3` | before `ae2cd04b` | 2 h 19 m | 1 | 251 |
| `sunshine.log.2` | before `ae2cd04b` | 57 m | 2 | 21 |
| `sunshine.log` (current) | after `ae2cd04b` | 9 m | 1 (23 s of streaming) | 1 (0.4 s after `CLIENT CONNECTED`) |

The IDR message is emitted at `src/video.cpp:1867-1869` when a submitted frame carried `AV_FRAME_FLAG_KEY` but the returned packet lacked `AV_PKT_FLAG_KEY`. Part of the improvement is attributed to `dummy_img()` now allocating in the capture backend's configured pixel format instead of hard-coded `32BGRA` (`src/platform/macos/display.mm` `dummy_img`, `src/platform/macos/av_img_t.h:fill_img_geometry`).

**Not yet demonstrated:** that the crash is gone. The pre-fix crash appeared after 2 h 19 m of uptime; the post-fix binary had only ~9 minutes of runtime at audit time, and the faulting path (the capture thread's probe pull, taken when ScreenCaptureKit delivers no frames) needs an idle period to be exercised. A long session with idle stretches is required.

## Appendix 2 — suggested review order

1. V1, V2 (SCK sample selection semantics — same file, interacts with `capture_cb_guard_t` from `ae2cd04b`)
2. A1 + A2 (measurement + audio queue bound)
3. I1 + I3 (3 lines total, both in different components)
4. A3 (audio converter placement — largest structural change in the list)
5. Config-only items: V4, V5, I5

---

## F. Change status and known behaviours

### Status since this audit was written

Fixed on `main` of this fork:

| Item | Commit | Note |
|---|---|---|
| Capture callback race, sample-buffer lifetime, dummy-frame format, `nv12_zero_device` lifetime | `ae2cd04b` | Also raised `SCStreamConfiguration.queueDepth` from 5 to 16 for buffer lifetime, not throughput. |
| N1 missing `frame_timestamp` | `5954394f` | `frame_processing_latency` sent to the client and the RTP clock now use real capture time instead of rate-control pacing. |
| N3 + A4 audio semaphore | `b53ab893` | Signal only when the consumer is parking; wait timeout 5s → 200ms; timeout silence is now submitted instead of discarded. |
| A3 unconverted audio on conversion failure | `3e3b6cf6` | Replaced with silence in the client's channel layout, counted and reported off the IOProc. |
| V3 capture queue QoS | `81c736a9` | `QOS_CLASS_USER_INTERACTIVE`, with the queueing delay now measured. |
| I3 100 ms sleep on the input worker | `188b5bac` | Second delayed task; cancellable through `home_release_id`. |
| A2 whole-queue audio drop | this pass | `safe::queue_t::overflow_policy_e::drop_one_oldest` plus an overflow counter reported every 10 s. |
| V2 idle re-delivery | this pass | ScreenCaptureKit status deliveries with no image are skipped and counted. |
| N2 unconditional pixel-buffer lock | this pass | `requires_cpu_copy()` plus a lazy lock; measured offline in `tests/unit/platform/macos/test_pixel_buffer_lock.cpp`. |

Not changed, with the reasons below: I1, I2, I4, I5, I6, I7.

### I2 (open) — per-event WindowServer position query and cursor warp

**Where:** `third-party/libvirtualhid/src/platform/macos/macos_backend.cpp` at the pinned submodule commit `53e1a949`: `current_location()` (a `CGEventCreate` + `CGEventGetLocation` round-trip per call) is invoked from `submit_relative_motion()`, `submit_absolute_motion()` and `submit_button()`, and `post_mouse()` ends with an unconditional `CGWarpMouseCursorPosition(location)`.

**Why it is not patched here:** the file lives in a submodule whose remote is the LizardByte upstream. This fork must not modify upstream code, `saxlamen/libvirtualhid` does not exist yet, and moving the submodule gitlink to a commit that exists only in a local checkout would break every other build. Applying the change therefore requires a fork of the library first.

**To apply later:** fork `LizardByte/libvirtualhid` into the user's GitHub account, add a branch with the patch below, push it, then point the submodule at that commit and record the bump with a `chore(deps):` commit. Re-test the three pointer paths (relative motion, absolute motion, button click) plus pointer-acceleration feel, because the warp is what keeps the OS cursor in sync in absolute mode.

**Suggested patch (illustrative; `post_mouse()` is `const`, so the cache members are `mutable` and must be guarded by the existing `mutex_`):**

```diff
       CGPoint current_location() const {
+        // This process warps the cursor, so it already knows where it put it. The WindowServer
+        // round-trip is only needed for the first event after the backend opens.
+        if (has_last_location_) {
+          return last_location_;
+        }
         const auto snapshot_event = CGEventCreate(state_->source);
         if (!snapshot_event) {
           const auto display_bounds = CGDisplayBounds(state_->display);
           return display_bounds.origin;
         }
 
         const auto current = CGEventGetLocation(snapshot_event);
         CFRelease(snapshot_event);
+        last_location_ = current;
+        has_last_location_ = true;
         return current;
       }
 
       OperationStatus post_mouse(
         CGMouseButton button,
         CGEventType type,
         CGPoint raw_location,
         CGPoint previous_location,
-        int click_count
+        int click_count,
+        bool warp_cursor
       ) const {
         ...
         CGEventPost(kCGHIDEventTap, event);
-        CGWarpMouseCursorPosition(location);
+        if (warp_cursor) {
+          CGWarpMouseCursorPosition(location);
+          // Without this the WindowServer suppresses local cursor motion for ~250ms after a warp.
+          CGEventSourceSetLocalEventsSuppressionInterval(state_->source, 0.0);
+        }
+        last_location_ = location;
+        has_last_location_ = true;
         return OperationStatus::success();
       }
 
       OperationStatus submit_relative_motion(std::int32_t delta_x, std::int32_t delta_y) {
         const auto current = current_location();
         const auto location = CGPoint {current.x + delta_x, current.y + delta_y};
         const auto motion = macos_mouse_motion(mouse_down_);
-        return post_mouse(motion.button, motion.event_type, location, current, 0);
+        // The event already carries the deltas; warping here additionally drags the OS cursor
+        // through the pointer accelerator on every motion event.
+        return post_mouse(motion.button, motion.event_type, location, current, 0, false);
       }
 
-Mutable members to add: `mutable CGPoint last_location_ {}; mutable bool has_last_location_ {false};`
```

### I1 (open) — keyboard at the session tap, mouse at the HID tap
Same submodule boundary as I2. Keyboard events go to `kCGSessionEventTap` while mouse events go to `kCGHIDEventTap`, with different event source states. Moving keyboard posting to the HID tap is a one-line change per call site but changes how applications observe modifier flags, so it needs a modifier-heavy regression pass. Deferred with I2.

### I4 (documented, no change) — pointer acceleration
There is no supported per-process API to disable pointer acceleration for injected events. Keep the guidance: turn pointer acceleration off on the host when playing games, and do not add a second motion field to an event that already carries an absolute location (see I2).

### I5 (documented, no change) — scroll configuration
`high_resolution_scrolling` and `macos_smooth_scrolling` both gate the pixel path, and the host-side inertia simulation runs an 8 ms loop at `QOS_CLASS_USER_INTERACTIVE`. That loop is a deliberate touch-pad simulation, not a defect. For the lowest scroll latency set `macos_smooth_scrolling = disabled`; the setting is per-user, so it is not changed in code.

### I6 (documented, no change) — `virtual_display = disabled`
Disabling it keeps the 5 second display-creation wait off the session handshake, at the cost of never applying a client-requested resolution: capture stays at the display's native mode and the frame is scaled. If resolution control is wanted, re-enable it and replace the fixed 5 s wait with a poll for the display to appear.

### I7 (documented, no change) — gamepad emulation fallback
The native IOKit gamepad path is always used on macOS; the CGEvent keyboard/mouse fallback and the throwaway `IOHIDUserDevice` probe are start-up cost rather than steady-state latency. Pen and touch backends are unimplemented in the library while the corresponding capability flags default to on, which costs capability-negotiation noise only.
