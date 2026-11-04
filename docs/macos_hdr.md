# macOS HDR: what it would take

This document records what is known about adding real HDR (HDR10 / SMPTE ST 2084 PQ / BT.2020)
streaming to the macOS host. It is a survey of the current code, the operating system
capabilities, the client contract, and the prior art, followed by the implementation options and
the measurements still needed. It deliberately does not decide anything on its own.

Everything about the operating system below was read out of the installed SDK (macOS 27.2 SDK,
Xcode toolchain) or measured on this machine, not from blog posts.

## 1. Why HDR cannot appear today

The encoding, protocol and client plumbing already exists in this tree. The macOS platform layer
simply never tells it that HDR is possible.

| Step | Where | What happens today |
|---|---|---|
| Display says HDR | `src/platform/common.h:756` (`display_t::is_hdr()` returns `false`), `:767` (`get_hdr_metadata()` returns `false`) | Nothing on macOS overrides either one, so both defaults stand |
| Colour space gate | `src/video.cpp:2633` → `src/video_colorspace.cpp:33` | `bt2020` requires `config.dynamicRange > 0 && hdr_display`, so the second half is always false |
| HDR10 metadata | `src/video.cpp:2337-2369` | Mastering-display and content-light side data are only produced when `colorspace_is_hdr()` is true, so never |
| Client notification | `src/stream.cpp:1137`, `IDX_HDR_MODE = 11` | The out-of-band `control_hdr_mode_t` message is what makes Moonlight treat a frame as HDR, and `hdr_info->enabled` stays false |
| Capture colour | `src/platform/macos/sc_capture.m:228-256` | The `SCStreamConfiguration` sets size, frame interval, pixel format, `queueDepth` and cursor only: no colour space and no dynamic range request |
| Capture format | `src/platform/macos/nv12_zero_device.cpp:81` | Requests `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` for 10-bit, which is the right container but without PQ tagging |
| Colour attachments | whole of `src/` | No `kCVImageBuffer*` attachment is ever read or written, so whatever the capture layer tags is dropped on the floor. Measured 2026-11-02: today's capture tags nothing anyway, only a `CGColorSpace` naming the display profile, see section 10.2 |

`config.dynamicRange` does survive the SDR fallback in `src/video.cpp:171-187` because the encoder
probe reports `DYNAMIC_RANGE` for VideoToolbox, which is why the macOS stream is **10-bit SDR**
today, exactly as recorded as finding V4 in `docs/macos_latency_audit.md`.

Two further macOS limits are structural: YUV444 slots are `AV_PIX_FMT_NONE`
(`src/video.cpp:1388-1389`), and HDR display-device requests are refused outright
(`src/display_device.cpp:951-955`, "macOS HDR changes are not supported by libdisplaydevice").

## 2. What the operating system provides

All availability annotations are from the installed headers.

| Capability | Symbol | Availability |
|---|---|---|
| Ask ScreenCaptureKit for HDR frames | `SCStreamConfiguration.captureDynamicRange`, values `.sdr`, `.hdrLocalDisplay`, `.hdrCanonicalDisplay` | macOS 15.0, Apple Silicon only (Intel: no effect) |
| Ready-made HDR capture configuration | `SCStreamConfiguration(preset:)` with `.captureHDRStreamLocalDisplay` / `.captureHDRStreamCanonicalDisplay` | macOS 15.0 |
| HDR10 recording preset that preserves the SDR range | `SCStreamConfigurationPresetCaptureHDRRecordingPreservedSDRHDR10` | macOS 26.0, recording outputs only, and a recording output cannot be combined with HDR capture |
| Requested colour space and matrix | `SCStreamConfiguration.colorSpaceName`, `.colorMatrix` | macOS 12.3 (matrix only for `420v`/`420f`) |
| 10-bit capture containers | `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` (`x420`), `...FullRange` (`xf20`) | long standing |
| Colour and HDR10 tags on a buffer | `kCVImageBufferColorPrimariesKey`, `...TransferFunctionKey`, `...YCbCrMatrixKey`, `kCVImageBufferMasteringDisplayColorVolumeKey` (24 byte SEI payload), `kCVImageBufferContentLightLevelInfoKey` (4 byte) | 10.8 / 10.13 |
| Read every tag at once | `CVBufferCopyAttachments(buffer, .shouldPropagate)` | macOS 12.0 |
| Let the encoder write HDR10 SEI itself | `kVTCompressionPropertyKey_HDRMetadataInsertionMode`, default `Auto` ("determine what type of HDR metadata to insert based on the output color space") | macOS 11.0 |
| Ask the encoder to preserve the SDR range | `kVTHDRMetadataInsertionMode_RequestSDRRangePreservation` | macOS 26.0 |
| Explicit mastering display and MaxCLL | `kVTCompressionPropertyKey_MasteringDisplayColorVolume`, `...ContentLightLevelInfo` | macOS 10.13 |
| 10-bit encoder profile and bit depth | `kVTProfileLevel_HEVC_Main10_AutoLevel`, `kVTCompressionPropertyKey_OutputBitDepth` | 10.13 / 12.3 |
| Detect HDR capability of a screen | `NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue` (> 1 means HDR capable) | macOS 10.15 |
| Detect HDR currently in use | `NSScreen.maximumExtendedDynamicRangeColorComponentValue` rises above 1.0 only while something requests EDR; macOS 26 adds `applicationShouldSuppressHighDynamicRangeContent` and its notifications | 10.11 / 26.0 |

The gap: **no public API puts a display into HDR mode**. CoreGraphics exposes no EDR display
function at all, and the practical route is BetterDisplay (HDR virtual screens, forced HDR
switching, EDID overrides) or a physically HDR display. Sunshine's own display-device layer cannot
help here on macOS, see the citation in section 1.

Note also that `SCStreamConfiguration.queueDepth` is documented as "should not exceed 8 frames",
while Lumen deliberately uses 16 for IOSurface lifetime reasons (see
`docs/macos_latency_audit_thread.md` rounds 3-8). That mismatch is harmless in the measurements
done so far, but it must be re-checked under HDR where a third party reported a per-frame copy
penalty from a queue/pool mismatch.

## 3. What the client actually needs

1. Codec capability: `SCM_HEVC_MAIN10` / `SCM_AV1_MAIN10` advertised by the host
   (`src/nvhttp.cpp:1178-1191`) and selected by the client. Already satisfied on macOS.
2. The negotiated dynamic range: `hdrMode` (`src/nvhttp.cpp:501`) → RTSP
   `x-nv-video[0].dynamicRangeMode` (`src/rtsp.cpp:1129`) → `config.dynamicRange` →
   `AV_PROFILE_HEVC_MAIN_10` (`src/video.cpp:2090`). Already satisfied.
3. The **out-of-band HDR flag**: `control_hdr_mode_t` with `SS_HDR_METADATA`
   (`src/stream.cpp:279-285`, `:1137`). 10-bit pixels alone never make the client display HDR.
   This is currently suppressed on macOS because `is_hdr()` is false.
4. In-stream signalling: the client picks its output colour space from the decoded
   `color_trc == SMPTE2084`, and uses mastering-display/MaxCLL when present, falling back to its own
   tone mapping otherwise. So HDR10 SEI is useful, not mandatory.
5. VideoToolbox ignores the FFmpeg `AV_FRAME_DATA_MASTERING_DISPLAY_METADATA` side data that
   `src/video.cpp:2337-2369` attaches — the FFmpeg VideoToolbox encoder forwards only CEA-608 and
   sets the primaries/transfer/matrix session properties from `AVCodecContext` instead. So the
   mastering-display values that reach the client come from VideoToolbox's own `Auto` insertion,
   not from Sunshine's side data, unless the properties are set explicitly.

## 4. Prior art

Upstream Sunshine has four macOS capture/HDR efforts, all closed or open without being merged:

| PR | Author, state | Technical content |
|---|---|---|
| [5957](https://github.com/LizardByte/Sunshine/pull/5957) | Cartterr, closed unmerged 2026-10-19 | Full HDR10: `captureDynamicRange = SCCaptureDynamicRangeHDRCanonicalDisplay` plus `colorSpaceName = kCGColorSpaceITUR_2100_PQ` feeding `hevc_videotoolbox`; `is_hdr()` implemented as `maximumPotentialExtendedDynamicRangeColorComponentValue > 1`; mastering metadata synthesised because macOS does not expose it; reports that SCK puts SDR white at 100 nits, which looks grey next to the client's own SDR, and adds a Metal pass scaling PQ by 2.03 with a `vt_hdr_sdr_white` option |
| [5817](https://github.com/LizardByte/Sunshine/pull/5817) | andygrundman, open | Adds a config option `capture_dynamic_range_macos = hdr_canonical \| hdr_local \| sdr`; maps `colorspace_e::bt2020` to BT.2020 primaries, PQ transfer and the 2020 matrix; uses `kCGColorSpaceDisplayP3_PQ` rather than ITU-R 2100 |
| [5511](https://github.com/LizardByte/Sunshine/pull/5511) | martona, open | ScreenCaptureKit backend, no HDR |
| [5190](https://github.com/LizardByte/Sunshine/pull/5190) and friends | Nottlespike, closed unmerged | Reports that asking `AVCaptureScreenInput` for a 10-bit surface silently returned 8-bit BGRA; argues that EDR must be gated on the *negotiated* HDR state and not on pixel depth, otherwise PQ buffers are emitted into a stream the SDP calls SDR; chose `HDRLocalDisplay` deliberately |

Merged upstream and already present in this tree: `resolve_dynamic_range()` downgrading to SDR
when the probe says HDR is unsupported (PR 5429), and only advertising Main10 when the 10-bit probe
succeeded (PR 5690, visible as `active_hevc_mode` and the per-codec `DYNAMIC_RANGE` flags).

Third-party implementations, checked from their sources:

| Project | HDR today | How |
|---|---|---|
| [kilde](https://github.com/kilde-team/kilde) | yes | `captureDynamicRange` plus the macOS 26 `...PreservedSDRHDR10` preset (recording, not streaming) |
| [Onset #169](https://github.com/kirich1409/Onset/issues/169) | recipe, in progress | The most complete written recipe: `captureDynamicRange`, `x420`, `kVTProfileLevel_HEVC_Main10_AutoLevel`, BT.2020 primaries/PQ/matrix, `HDRMetadataInsertionMode`, EDR detection through `maximumExtendedDynamicRangeColorComponentValue` |
| [aetherdesk](https://github.com/stormlantern-dev/aetherdesk) | no | SDR only: BGRA or 420v8p, HEVC Main profile |
| [simlock](https://github.com/callstackincubator/simlock) | no | BGRA, `CGColorSpaceCreateDeviceRGB` |

On the display side, BetterDisplay used to state that dummy displays cannot do HDR because of the
`CGVirtualDisplay` API ([#141](https://github.com/waydabber/BetterDisplay/issues/141)), which was
superseded by [#5257 "Add HDR support for virtual screens"](https://github.com/waydabber/BetterDisplay/issues/5257),
closed completed in 2026-05: HDR colour profiles and forced HDR switching for virtual screens, with
some of it behind the paid tier. MonitorControl only speaks DDC/CI, so it cannot add HDR capability
to a display.

## 5. The three layers

HDR only works if all three layers agree; two of them are already done in this tree.

1. **The display must really be HDR.** If it is not, macOS tone-maps HDR content to SDR before
   anything is captured, and there is nothing HDR to encode. This layer is now satisfied on the
   development machine: with HDR support switched on in BetterDisplay, the virtual screen reports
   `maximumPotentialExtendedDynamicRangeColorComponentValue` of 5.0 instead of the 1.0 measured on
   2026-10-31, and section 10 confirms real PQ frames. No physically HDR panel turned out to be
   necessary, and `maximumExtendedDynamicRangeColorComponentValue` is 5.0 as well, which means macOS
   is holding EDR headroom for the session already.
2. **Capture must request HDR.** `captureDynamicRange` alone is not enough: measured 2026-11-02, the
   canonical dynamic range without a `colorSpaceName` hands back buffers carrying only an sRGB/BT.709
   ICC profile, with no transfer-function tag at all. Both properties are required, and
   `kCGColorSpaceITUR_2100_PQ` is the spelling that yields the full Rec.2100 set, primaries, PQ
   transfer and the BT.2020 matrix. ScreenCaptureKit then tags the buffers, and the zero-copy path
   already hands the same `CVPixelBuffer` to FFmpeg, which keeps the IOSurface and its attachments.
3. **The host must say HDR.** `is_hdr()` has to reflect the display state, `get_hdr_metadata()` has
   to produce something (real values if readable, otherwise a synthesised BT.2020/0.005-1000 nits
   default, as PR 5957 did), and only then do the existing paths produce PQ tagging, Main10, the
   VideoToolbox colour properties, the HDR10 SEI and the client HDR flag.

## 6. Options

| Option | Content | Effort | Risk |
|---|---|---|---|
| A. Follow PR 5817 naming, PR 5957 mechanics | Config `capture_dynamic_range_macos = sdr \| hdr_canonical \| hdr_local`, `captureDynamicRange` plus `kCGColorSpaceITUR_2100_PQ`, `is_hdr()` from the potential-EDR query, synthesised `get_hdr_metadata()`, EDR gated on negotiated HDR rather than pixel depth | roughly 150-250 lines plus tests; a day of iteration including measurements | Upstream PRs are unmerged, so the config name may still move; HDR changes capture timing, so the drain cadence work has to be re-measured |
| B. Minimal switch | A boolean `vt_hdr` that only turns `captureDynamicRange` on, leaving `is_hdr()` alone | about 40 lines | Half done: the client is still told HDR is off, so the desktop looks right and the stream stays SDR-tagged. Useful only as a probe step |
| C. Wait for upstream | Do nothing, adopt whatever LizardByte merges | no effort | Unknown schedule; four attempts have already stalled |

Whatever is chosen, layer 1 (the display) has to be fixed on the machine first, otherwise every
measurement is meaningless. That is done, see section 10.1, and option A's mechanics are now the
measured ones rather than the ones inferred from the upstream pull requests.

## 7. Measurements still to run

`scripts/hdrprobe.swift` prints the EDR state of every screen, dumps the colour attachments of
captured frames for SDR and for both HDR presets, and since 2026-11-02 also paints flat colour and
extended-range windows on screen to measure luminance. It is built and signed by
`scripts/hdrprobe_bundle.sh`, and Screen Recording has been granted, so the checklist below has
measured answers in section 10. The checklist:

1. With mirroring off, read `potentialEDR` for the physical display, to learn whether the panel can
   do HDR at all.
2. SDR capture with permission granted, to record the baseline attachments.
3. HDR canonical capture with the display in SDR mode, to see whether ScreenCaptureKit refuses or
   silently tone-maps.
4. HDR canonical capture with the display in HDR mode, expecting PQ plus BT.2020; this is the
   decisive measurement.
5. Only then: an Lumen build with the switch on, measuring `Video: encode rate`,
   `Video: encoder output latency`, `Frame processing latency` and the queueDepth-8 question under
   10-bit HDR, at both 2560x1920 and 4K, because HDR at 4K is precisely the saturation case where
   `vt_drain` matters.

### Status of the checklist

Items 2 and 4 are measured, item 1 is measured for the display in use, item 3 needs a BetterDisplay
switch flipped off and item 5 is still parked. All numbers are in section 10.

Item 1 is closed for the capture question. The BetterDisplay virtual screen with HDR enabled reports
`maximumPotentialExtendedDynamicRangeColorComponentValue` of 5.0, and canonical capture produces
BT.2020 PQ frames on it, so no physically HDR panel is required to develop and measure this feature.
The physical panel's own capability is still unread, because mirroring is on and only the mirror
master is enumerated; that matters for how the host renders, not for what canonical capture emits.

Item 3 is partly answered from the other side: SDR capture on an HDR-enabled screen still works and
still returns an sRGB-tagged picture, so switching the host display out of HDR is not a prerequisite
for the SDR path. The literal case, an HDR capture request against a display in SDR mode, has not
been run because it needs BetterDisplay's HDR switch turned off.

Item 5 is parked next to `vt_drain`, whose own 4K leg is unmeasured and tracked as V6a in
`docs/macos_latency_audit.md`. The two are the same question: canonical HDR capture is 10-bit 4K by
construction, the HDR decisions deliberately avoid the extra Metal pass that would hide encoder cost,
and a drain cadence that costs frame rate at 4K SDR costs it at 4K HDR too. Whoever picks HDR up
should close V6a first. Note also that the probe captures at `SCDisplay.width` in points, 1280x960
here rather than 2560x1920, so any latency run has to set the frame size explicitly.

## 8. Open questions

These were the questions raised for review; section 9 records what was decided about each one, and
section 10 records what the measurements then said about the ones they could answer.

1. Canonical or local dynamic range, given that local display tone mapping is reported as
   unreliable on some macOS 15 builds while Nottlespike chose it deliberately for a different
   reason. Measured: on this machine the two are numerically identical for flat patches, 509/381/245/64
   code values in both, because a virtual screen has no panel characterisation for local tone mapping
   to use. Canonical additionally avoids the `AlphaChannelMode` attachment local mode brings.
2. How to handle the SDR white level: PR 5957 needed a Metal pass to scale PQ by 2.03 because SCK
   puts SDR white at 100 nits. A GPU pass costs latency, which is the one thing this project has
   spent its time buying back. The macOS 26 `RequestSDRRangePreservation` insertion mode may make
   that pass unnecessary, and is worth testing before writing any Metal code. Measured: the 100 nit
   figure is confirmed, 99.9 nit SDR white, and the deficit turned out to be a uniform luminance scale
   over the whole picture, see section 10.4 and 10.6, which is what makes a metadata-only or
   client-only fix worth investigating before any shader.
3. Whether to read real display mastering metadata (nothing public, and PR 5957 synthesised it) and
   whether VideoToolbox's `Auto` HDR10 insertion is good enough, or whether the mastering-display
   and content-light properties should be set explicitly from `get_hdr_metadata()`. Measured: there is
   nothing to read, no mastering-display or content-light attachment appears in any capture
   configuration, so synthesis or encoder insertion is the only route.
4. Whether the HDR path should force HEVC/AV1 only. H.264 asserts non-HDR in
   `src/video.cpp:2081`, so HDR means HEVC Main10 or AV1 by construction.
5. Whether to gate `is_hdr()` on the negotiated session (`config.dynamicRange` and the client
   `hdrMode`) rather than on raw display capability, which is the mistake the closed PRs flagged.

## 9. Decisions

Recorded on 2026-10-31 after the review in `docs/macos_latency_audit_thread.md` round 54, which
returned `PI_HDR_PROBE_FIRST` and approved the survey and the three-layer model as written.

1. **Measure before writing code.** Implementation does not start until layer 1 is real on the
   development machine and the probe has captured PQ plus BT.2020 attachments. Everything measured
   before that point is meaningless, because macOS has already tone-mapped the content to SDR.
2. **Canonical dynamic range.** `.hdrCanonicalDisplay`, because the picture is rendered on a remote
   client and should carry the Rec.2100 PQ reference rather than a tone mapping tuned to the host
   panel. The local-display preset is also reported unreliable on some macOS 15 builds.
3. **No Metal pass.** Scaling PQ by 2.03 with a GPU pass is rejected: it would spend the zero-copy
   path and the 9 ms of host latency measured in the drain work on a white-level difference. The
   macOS 26 `kVTHDRMetadataInsertionMode_RequestSDRRangePreservation` insertion mode is tried first,
   and if it does not settle the 100 nit SDR white question, that question is reopened rather than
   answered with a shader.
4. **The option is called `capture_dynamic_range_macos`.** It names a capture-layer property, matches
   the upstream spelling in PR 5817, and keeps a future merge cheap. A value set to `sdr` must keep
   today's behaviour byte for byte.
5. **Two gates instead of one.** HDR is offered only when the negotiated session asks for
   `dynamicRange > 0` *and* the display reports capability above 1.0. Capability alone would push PQ
   samples into a stream an SDR client asked for, which is the failure the closed upstream PRs
   warned about.

## 10. Measurements, 2026-11-02

All of this was measured on the development machine, macOS 27.2 build 26B123, Apple M5 Ultra, with
HDR support switched on for the BetterDisplay virtual screen `Virtual 16:12`, mirrored to a
`HDP-V104`. Every capture run delivered 8 frames and every flat patch reported `min == median == max`,
so the numbers below are not averages of a moving picture.

### 10.1 Layer 1 is real now

```
screen 0: Virtual 16:12
  maximumEDR=5.0 potentialEDR=5.0
```

Both values were exactly 1.0 before the BetterDisplay HDR switch was turned on. Canonical capture
produces BT.2020 PQ frames on this screen, so the whole feature can be built and measured without a
physically HDR panel.

### 10.2 What each capture configuration returns

| Request | Container | Primaries / transfer / matrix returned |
|---|---|---|
| SDR, `kCVPixelFormatType_32BGRA`, today's Lumen request | BGRA | no colour keys at all, only `CGColorSpace` naming the display profile |
| SDR, `420v10p`, today's 10-bit path | `x420` | same: no primaries, no transfer, no matrix |
| Canonical preset | **`xf44`**, 4:4:4 10-bit full range | `P3_D65` / `SMPTE_ST_2084_PQ` / `ITU_R_709_2` |
| Local preset | `xf44` | same, plus `AlphaChannelMode: StraightAlpha` |
| `.hdrCanonicalDisplay` plus `x420`, **no `colorSpaceName`** | `x420` | **only an ICC profile attachment**, plus `ITU_R_709_2` |
| `.hdrCanonicalDisplay` plus `x420` plus `kCGColorSpaceITUR_2100_PQ` | `x420` | `ITU_R_2020` / `SMPTE_ST_2084_PQ` / `ITU_R_2020` |
| `.hdrCanonicalDisplay` plus `420f10p` plus `kCGColorSpaceITUR_2100_PQ` | `xf20` | `ITU_R_2020` / `SMPTE_ST_2084_PQ` / `ITU_R_2020` |
| `.hdrCanonicalDisplay` plus `x420` plus `kCGColorSpaceDisplayP3_PQ` | `x420` | `P3_D65` / `SMPTE_ST_2084_PQ` / `ITU_R_709_2` |
| `.hdrLocalDisplay` plus `x420` plus `kCGColorSpaceITUR_2100_PQ` | `x420` | `ITU_R_2020` / `SMPTE_ST_2084_PQ` / `ITU_R_2020`, plus alpha |
| Canonical plus `420v10p` plus 2100 PQ plus an explicit `ITU_R_2020` matrix | `x420` | identical to the row without it |

Five things follow from this table, and three of them contradict what this document assumed when it
was written.

1. `captureDynamicRange` without `colorSpaceName` produces no PQ signalling at all. It is not refused
   and not tone mapped into a PQ-tagged buffer: the frames come back carrying an ICC profile and
   nothing else. That profile was dumped and parsed, 3376 bytes, ICC 2.1, Apple 2026, description
   `Display`, white D65, primaries red (0.6484, 0.3308), green (0.3212, 0.5979), blue (0.1559, 0.0661),
   and a 1024 entry `curv` tone curve that matches the sRGB curve sample for sample. An encoder handed
   that buffer has no transfer function to write. `colorSpaceName` is mandatory, not a refinement.
2. `kCGColorSpaceITUR_2100_PQ` gives the complete HDR10 triple, and the BT.2020 matrix arrives without
   asking for `colorMatrix`. So the `kCGColorSpaceDisplayP3_PQ` compromise of PR 5817 is not needed
   here: real Rec.2100 tags are available on this machine, with no `colorMatrix` property to negotiate
   and its macOS 12.3 range restrictions to work around.
3. The Apple HDR presets capture `xf44`, which is 4:4:4 10-bit full range
   (`CoreVideo/CVPixelBuffer.h:116`), not 4:2:0. At 4K that is half again the bytes per frame of the
   4:2:0 container Lumen wants. Building the configuration by hand, as the middle rows do, avoids it.
4. Neither container range matters for levels: `x420` and `xf20` report the same luminance once each
   container's own range is normalised. `x420` spends 876 of 1024 codes on the PQ domain, `xf20` all
   1024, so full range is marginally finer, and full range also matches what HDR10 HEVC streams
   usually declare.
5. **No configuration produced `CVImageBufferMasteringDisplayColorVolume` or
   `CVImageBufferContentLightLevelInfo`.** There is no real HDR10 metadata to read on macOS, which
   closes open question 3 in favour of synthesising it or letting VideoToolbox insert its own.

### 10.3 SDR white sits at 100 nits

An opaque borderless window covering the captured display, ordinary SDR content, centre third of the
frame sampled, canonical capture with `kCGColorSpaceITUR_2100_PQ`. The 10-bit luma code values:

| Painted | `x420` video range | `xf20` full range | local range `x420` | Decoded PQ |
|---|---|---|---|---|
| white 1.0 | 509 | 520 | 509 | **99.9 / 100.2 cd/m2** |
| 0.5 grey | 381 | 371 | 381 | 21.2 cd/m2 |
| 0.18 grey | 245 | 212 | 245 | 2.7 cd/m2 |
| black | 64 | 0 | 64 | 0.0 cd/m2 |

The three levels are internally consistent, which is what makes the white figure trustworthy: an sRGB
0.5 grey has relative luminance 0.2140, and 0.2140 x 99.9 = 21.4, matching the 21.2 measured; an sRGB
0.18 grey is 0.0272, and 0.0272 x 99.9 = 2.72, matching the 2.7 measured. So the whole SDR range is a
clean scaling of content into a 100 cd/m2 white, with no tone compression applied.

PR 5957's report of a 100 nit SDR white, and with it the 2.03 deficit against the 203 cd/m2 reference,
is therefore reproduced on this machine. It is not a second-hand claim any more.

### 10.4 EDR content is passed through, linearly, up to the PQ ceiling

The same window with an extended-range colour, requested as a linear multiple of SDR white, canonical
capture. The prediction is 100 cd/m2 per unit, because that is where white was measured to sit.

| Requested | Predicted cd/m2 | Measured cd/m2 |
|---|---|---|
| 1x | 100 | 99.9 |
| 4x | 400 | 397.2 |
| 8x | 800 | 797.4 |
| 16x | 1600 | 1591.4 |
| 32x | 3200 | 3181.7 |
| 64x | 6400 | 6349.4 |
| 128x | 12800 | 9891.5, saturating at the 10000 cd/m2 PQ reference |

Two conclusions, one of which overturns a prediction made during the review:

- ScreenCaptureKit carries extended-range content through at its rendered level, exactly linearly,
  all the way to the PQ maximum. The range of a canonical stream is 0 to 10000 cd/m2, the same range a
  Windows HDR-mode desktop hands its encoder, so this is not a limited-range path.
- The 5.0 in `maximumExtendedDynamicRangeColorComponentValue` did **not** clamp the capture: 64x
  went through as 6349 cd/m2. The earlier reasoning that the host headroom caps the stream at about
  500 cd/m2 was wrong for this path. The caveat is that the probe painted an extended-range `NSWindow`,
  while real HDR video arrives as a `CAMetalLayer` with `wantsExtendedDynamicRangeContent`, whose
  documented behaviour is to clamp at that value. Real video content is the remaining test, see 10.6.

### 10.5 What today's SDR capture does with the same content

With the extended-range window at 2x and 5x above white, ordinary SDR capture returned luma 940, the
video-range ceiling, in every frame. Highlights are hard clipped, not soft tone mapped. That is the
concrete value of turning the HDR capture switch on for video: the pixels above SDR white exist and
today they are thrown away.

### 10.6 Real content, an HDR clip playing full screen

`--live` captures whatever is on screen with no window of our own over it and samples the whole frame.

| Percentile, canonical capture | Code | cd/m2 | Relative to SDR white |
|---|---|---|---|
| p50 | 250 | 3.0 | 0.03x |
| p99 | 570 | 197.1 | **1.97x** |
| p99.99 | 578 | 215.1 | 2.15x |
| max | 590 to 597 | 245 to 264 | 2.45x to 2.65x |
| black | 64 | 0.0 | clean |

The same frames through SDR capture reported p99 and max both equal to 940, so at least one percent of
the picture was crushed onto the ceiling. Real HDR highlights, roughly two and a half times SDR white,
exist on screen today and are destroyed by the current capture path.

The two paths agree where they should, which validates the instrument: in an earlier live run against
SDR content, the SDR capture's p99 code 668 normalises to 0.6895, decodes through sRGB to 0.4333
linear, and at a 99.9 cd/m2 white that is 43.3 cd/m2, against the 42.9 cd/m2 the canonical capture
reported directly. Two thirds of a percent apart.

Because 10.4 established that the mapping from rendered value to reported luminance is linear, the
gap between this stream and an HDR10 master with a 203 cd/m2 white is a single scale factor: the
measured 197, 215 and 245 cd/m2 would be 401, 437 and 498 cd/m2 at 203. The picture is uniformly 2.03
times too dim, highlights included. Nothing about the tone structure is distorted, which is why
fixing it without a GPU pass is plausible: a client-side gain, or mastering-display metadata whose
maximum luminance tells the client's tone mapper to lift by that factor, both cost the host nothing.

### 10.7 Reproducing this

`scripts/hdrprobe_bundle.sh` compiles `scripts/hdrprobe.swift`, wraps it in
`cmake-build-vtpoc/hdrprobe.app` with `CFBundleIdentifier com.saxlamen.hdrprobe`, signs it with a
Developer ID and registers it with LaunchServices. Run it with:

```sh
open -n --stdout /tmp/hdrprobe.log --stderr /tmp/hdrprobe.err \
  cmake-build-vtpoc/hdrprobe.app --args [--edr-only | --live]
```

Two things about that arrangement are load bearing. Screen Recording permission is keyed to the code
signing identity, so a Developer ID signature survives rebuilds and an ad-hoc signature does not.
And a bare binary launched from a terminal inherits the terminal's TCC identity, which here is tmux,
so the bundle is what makes the grant appear in the Privacy list at all. Reset the grant with
`tccutil reset ScreenCapture com.saxlamen.hdrprobe`.

### 10.8 What this changes, and what it does not

- Decision 1 of section 9 is satisfied: layer 1 is real and the probe has captured PQ plus BT.2020.
  Nothing now stands between this document and an implementation of option A.
- Decision 3 of section 9 stands, and the client does not rescue it. Section 10.9 reads the client
  actually in use, VoidLink, and finds no client-side gain and no automatic rescale: the only free
  route is the mastering metadata, and whether that lifts the picture is an on-device experiment, not
  something the source can settle.
- Decision 4 and decision 5 are untouched by any of this.
- Still unmeasured: checklist item 3, the behaviour of an HDR capture request against a display in SDR
  mode; checklist item 5, encode rate, encoder latency and the queueDepth question at 10-bit 4K, which
  is the same object as V6a; whether a real `CAMetalLayer` HDR layer is clamped at the reported
  headroom; and what `kVTHDRMetadataInsertionMode_RequestSDRRangePreservation` actually writes, which
  needs an encode, not a capture.

### 10.9 What the client does with it, VoidLink

Read from a clone of [ExecFox/VoidLink](https://github.com/ExecFox/VoidLink) at HEAD on 2026-11-02, an
iOS and tvOS fork of Moonlight. Its wire layer is a submodule pointing at
`TrueZhuangJia/voidlink-c`, so `SS_HDR_METADATA` itself is only called here, not defined. Line numbers
below are from that clone.

**HDR has to be asked for.** The Main10 formats are offered only when the user toggle `enableHdr` is on
(`VoidLink/Database/TemporarySettings.m:48`) and the device reports `AVPlayerHDRModeHDR10`
(`VoidLink/ViewControllers/MainFrameViewController.m:907-924`). Outside tvOS no defaults
are registered for that key, so it is off until the user turns on "Request HDR Video"
(`Moonlight TV/Settings.bundle/Root.plist:235-237`).

**Two renderers, and the default is the one that delegates to the OS.** `RENDER_AVSB = 0` is the
default (`VoidLink/Utility/Plot.h:32-35`, selected at `VoidLink/Stream/VideoDecoderRenderer.m:164-191`)
and its `AVSampleBufferDisplayLayer` is created with no colour space, no EDR flag and no metadata of
its own (`VideoDecoderRenderer.m:62-92`) — the system tone maps from the format description, into which
`setHdrMode:` injects the mastering volume and content light level taken from the host
(`:1034-1108`, HEVC `:772-778`, AV1 `:655-659`). The Metal renderer sets
`wantsExtendedDynamicRangeContent`, `MTLPixelFormatRGBA16Float` and either
`kCGColorSpaceExtendedLinearITUR_2020` or `kCGColorSpaceITUR_2100_PQ` and recognises HDR purely from
the PQ transfer key (`VoidLink/Metal/MetalVideoRenderer.m:278-301`, `:178`, `:409`).

**PQ is rendered as an absolute luminance, so the 2.03 deficit arrives intact.**
`VoidLink/Metal/Shaders-Linear.metal:106-113` runs the inverse PQ EOTF to 0-10000 nits and then divides
by `referenceWhite = 100.0f`, and `MetalVideoRenderer.m:311` passes `opticalOutputScale: 100.0f` to
`CAEDRMetadata`. The SDK defines that number as a scale, not an anchor: "denoting the
opticalOutputScale as C1 (cd/m^2), the relationship is C = C1 * y"
(`QuartzCore/CAEDRMetadata.h:43-52`). A layer value of 1.0 is therefore 100 cd/m² of optical output,
which means the client reproduces whatever absolute luminance the stream carries. A host whose SDR
white sits at 100 cd/m² is shown at 100 cd/m². The tone mapping that could lift it,
`scaleEDR(linear_rgb / referenceWhite, peakWhite / referenceWhite, edrHeadroom)`, is commented out
(`Shaders-Linear.metal:115-116`), so the headroom the renderer polls from
`[UIScreen currentEDRHeadroom]` is uploaded to the shader (`MetalVideoRenderer.m:249-257`, `:795-797`)
and then ignored.

**There is no user control that could absorb it either.** Nothing in `VoidLink/`, `Limelight/` or
`Moonlight TV/` exposes brightness, gain, gamma or an HDR level; the only HDR setting is the on/off
toggle, and the EDR path is a hard-coded `static BOOL useEDR = YES` carrying the comment "EDR
tone-mapping is possible but it's unclear how best to tone-map Windows content"
(`MetalVideoRenderer.m:105-107`).

**The metadata route is still open, and it is the only free one.** Both renderers consume the mastering
volume the host sends, and in the Metal path the fallback when no mastering data arrives is a fixed
0.005 / 1000 cd/m² pair (`MetalVideoRenderer.m:307-323`). The fork's own comment there says the host's
max nits do arrive when connecting to Windows but that using them for tone mapping "would break apps
not using system calibration" (`:312-314`). So writing a mastering volume whose maximum luminance
describes what the capture really produces, instead of a nominal 1000, is the experiment worth running,
but what Apple's tone mapper does with those numbers is a measurement on the device, not something this
reading can settle.

**tvOS is a different problem again.** The EDR metadata path is compiled out entirely on tvOS
(`MetalVideoRenderer.m:235`, `:454-460`, `:794`); instead the client asks the TV to enter HDR10 mode
through `AVDisplayCriteria` (`VoidLink/ViewControllers/StreamFrameViewController.m:1433`, called
from `setHdrMode:` at `:1445-1450`). On a TV the white-level question then belongs to the TV.


## 11. What is implemented, 2026-11-02

Option A of section 6 is in the tree. The naming of decision 4 and the gates of decision 5 are kept
exactly as written there.

### 11.1 The switch

`capture_dynamic_range_macos = sdr | hdr_local | hdr_canonical`, default `sdr`. It is parsed with
`string_restricted_f()`, so an unrecognised value keeps whatever was already in effect, and a host that
never mentions the option captures byte for byte what it captured before. It lives in the VideoToolbox
group of the configuration (`config::video.vt.capture_dynamic_range_macos`) because that is the tab the
web UI and `docs/configuration.md` group it under; the config consistency test requires the option to
appear in `src/config.cpp`, `config.html`, `docs/configuration.md` and `en.json`, and it appears in all
four. There is no widget in the VideoToolbox tab, as with `vt_drain`, so it is edited in sunshine.conf.

### 11.2 The gates

Four gates, all of them required:

| Gate | Where it is decided | Covered by |
|---|---|---|
| The operator asked for an HDR capture range | `macos_hdr::dynamic_range_from_view()` and `macos_hdr::hdr_capture_enabled()` in `src/platform/macos/hdr_capture.h` | `tests/unit/platform/macos/test_hdr_capture.cpp`, `MacosHdrCapture.MapsConfiguredNamesToADynamicRange` and friends |
| The machine can deliver one | `platform_supports_hdr_os()` (`@available(macOS 15.0, *)`) and the `hw.optional.arm64` sysctl in `src/platform/macos/display.mm` | `MacosHdrCapture.RequiresEveryGateBeforeEnablingHdr` for the decision; the two calls themselves need a run |
| The screen can display one | `display_potential_edr()` reads `NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue`, and `macos_hdr::display_can_hdr()` requires it strictly above 1.0 | `MacosHdrCapture.TreatsHeadroomAboveUnityAsCapability` and `RejectsHeadroomThatIsNotANumber` |
| The session negotiated 10 bit | `macos_hdr::hdr_capture_enabled()` requires `session_requests_10bit`, which the factory fills from `config.dynamicRange > 0`; `colorspace_from_client_config()` in `src/video.cpp` checks the same condition again before it believes `is_hdr()` | `MacosHdrCapture.RequiresEveryGateBeforeEnablingHdr` |

The last gate is not redundant with the one in `src/video.cpp`. That one decides what the stream is
*labelled*; this one decides what the capture *delivers*, because the pixel buffer goes to the encoder
unconverted. Requesting an HDR capture for an 8 bit client would put PQ samples under BT.709 labels,
which is the failure decision 5 exists to prevent.

`src/platform/macos/hdr_capture.h` is deliberately free of Objective-C and of ScreenCaptureKit, which is
what makes all of that testable. The decision is taken once, in the display factory, and stored on
`sc_display_t` as `hdr_capture` and `maximum_potential_edr`; `is_hdr()` returns the stored value, because
the capture cannot change underneath a running encoder.

### 11.3 The capture

`SCCapture` gained `captureDynamicRange` (the raw `SCCaptureDynamicRange` numbers, 1 for local and 2 for
canonical) and `hdrColorSpaceName`. Both are applied to the `SCStreamConfiguration` inside
`@available(macOS 15.0, *)`, and the dynamic range is snapshotted under `_stateLock` with the other
capture settings. `hdrColorSpaceName` is set once, in the factory, to `kCGColorSpaceITUR_2100_PQ`, and
section 10.2 is why it is not optional next to the dynamic range.

Two things are deliberately not changed. The container stays `x420`, the 4:2:0 10-bit video-range
container the 10-bit path already used, because that row of the section 10.2 table already returns
`ITU_R_2020` / `SMPTE_ST_2084_PQ` / `ITU_R_2020`; `xf20` is measured to be fractionally finer but is a
larger change to a zero-copy path that works. And the AVFoundation backend keeps the base `is_hdr()` of
false: `AVCaptureScreenInput` was never shown to deliver an HDR picture here, so an HDR claim on that
path would be a lie.

### 11.4 What the client is told

`sc_display_t::get_hdr_metadata()` writes the BT.2020 primaries and D65 white point from the
specification, because section 10.2 found no mastering-display attachment to read, and the luminances
from `macos_hdr::mastering_defaults()`. Every number is resolved most specific first: the environment,
then sunshine.conf, then derived from the captured screen.

| Field | Environment | Configuration | Unset means | Written as |
|---|---|---|---|---|
| Peak | `LUMEN_HDR_MAX_LUMINANCE` | `hdr_max_luminance_macos` | -1: 100 cd/m² of SDR white times the screen's EDR headroom | `maxDisplayLuminance`, in nits |
| Black | `LUMEN_HDR_MIN_LUMINANCE` | `hdr_min_luminance_macos` | -1: 0.005 cd/m² | `minDisplayLuminance`, in units of 1/10000 cd/m² |
| maxCLL | `LUMEN_HDR_MAX_CLL` | `hdr_max_cll_macos` | -1: follows the resolved peak | `maxContentLightLevel`, in nits |
| maxFALL | `LUMEN_HDR_MAX_FALL` | `hdr_max_fall_macos` | -1: leave it out | `maxFrameAverageLightLevel`, in nits |

They began as environment variables only, because they were an experiment and the section 10.9 question
of whether a client reacts to them at all was still open. Section 12 answered that they do react, and an
experiment that works has to survive a reboot, which `open --env` does not: the app starts as a login
item, and a login item inherits neither a shell environment nor a `launchctl setenv` made after login.
So the configuration options are the normal way to set them, and the environment keeps the first word
because it is still the knob used while measuring a client. A content light level of 0, from either
source, makes `src/video.cpp` leave that side data out of the stream, which is what to try for a client
that renders the metadata badly. Anything above the declared peak is clamped down to it: content
brighter than its own mastering display cannot exist, and the mismatch is a reasonable thing for a
renderer to clamp on, which the 245-against-1000 rounds of section 12 ran with. The values in effect are
logged on every HDR session start.

Deriving the peak rather than shipping a constant is section 12.4 item 4's conclusion. 1000 cd/m² was a
number copied from a Linux panel; on this host the brightest picture that can exist is 500 cd/m², and
section 12 measured that a declared peak above what the content reaches makes the whole frame darker on
this client. A derived default is right on a host nobody has measured yet, and it can never
over-declare. Installed with no configuration entry and no environment override, a session on this host
logged `peak 500 nits, black 0.005 nits, maxCLL 500 nits, maxFALL 0 nits` on a screen reporting five
headroom, which is the derivation and the content light level pairing both arriving without being told.

### 11.5 Tests

`tests/unit/platform/macos/test_hdr_capture.cpp` covers the decision, the metadata resolution and the
chromaticity scaling. The resolution tests pin the three sources in order, the derivation from headroom
including a screen that cannot do HDR and a headroom that is not a number, the clamp of a content light
level above the declared peak, and that a configured or environment 0 still suppresses the side data.
`tests/unit/test_config.cpp` gained `MacosHdrCaptureConfigTest`, which reads the capture switch through
the real parser from sunshine.conf text, `MacosHdrMetadataConfig`, which reads the four luminances the
same way and pins that a value outside the accepted range is refused, and one test that pins the
"unknown value keeps the current value" behaviour. The ScreenCaptureKit, AppKit and sysctl calls in
`display.mm` and `sc_capture.m` are not covered automatically, exactly as with the rest of the capture
backends; the session log is the check, see section 11.6.

### 11.6 What the first HDR session still has to answer

1. Read the log. A working HDR capture logs `Capturing hdr_canonical HDR from display ...` and
   `Synthesised HDR10 metadata for a macOS screen: ...`; a refused one logs why, in
   `capture_dynamic_range_macos = ... but capturing SDR: ...`. On the capture side ScreenCaptureKit
   itself logs `HDR capture requested: dynamicRange=... colorSpace=...`.
2. Watch the client. VoidLink needs "Request HDR Video" on, see section 10.9. Then the A/B from that
   section: raise `LUMEN_HDR_MAX_LUMINANCE` and see whether the picture brightens. If it does, the
   metadata route works and decision 3 stays satisfied forever. If it does not, the 100 cd/m² question
   is reopened, not answered with a shader. Answered on 2026-11-02, see section 12: it does, with the
   opposite sign.
3. Check the stream, not just the capture. Nothing in `src/` sets
   `kVTCompressionPropertyKey_HDRMetadataInsertionMode`, so VideoToolbox keeps its default `Auto`, and
   whether the encoded stream carries BT.2020 primaries, the PQ transfer, the mastering SEI written from
   the frame side data, or all three, has not been inspected on a Lumen-encoded stream. The probe's own
   encode is not evidence here, because the probe supplies its own format description.
4. Renegotiation. The decision is taken in `platf::display()`, and `src/video.cpp` recreates the
   display when a new session context arrives, which is what a client changing between 8 and 10 bit
   does. If that ever stops being true, an HDR capture left running underneath an 8 bit session would
   put PQ samples into a BT.709 stream, so the pixel format change in
   `nv12_zero_device::set_frame()` is the place to re-take the decision.
5. Checklist items 3 and 5 of section 7 are still open, and item 5 is the same object as V6a in
   `docs/macos_latency_audit.md`.

## 12. On-device A/B: the mastering block behaves like a global gain, 2026-11-02

Section 11.6 item 2 asked whether `LUMEN_HDR_MAX_LUMINANCE` changes anything the client shows. It
changes everything, and with the opposite sign to a mastering display: declaring a *higher* peak makes
the picture *darker*.

### 12.1 What was varied

`capture_dynamic_range_macos = hdr_canonical` in sunshine.conf throughout, `LUMEN_HDR_MAX_LUMINANCE`
changed by relaunching the app with `open -n --env LUMEN_HDR_MAX_LUMINANCE=<n> /Applications/Sunshine.app`,
VoidLink streaming fullscreen. The client is a 13-inch iPad Pro with the M4 tandem OLED panel: 2752x2048,
ProMotion 10-120 Hz, and per Apple's specifications around 1000 cd/m² of full-screen brightness with a
1600 cd/m² HDR peak. That is a brighter panel than the host display, and it explains why the same declared
peak reads differently on the two ends; it does not change what should be declared, because the declared
value describes the content the host produced, see section 12.4 item 4. It does mean any value tuned here
belongs to this host and this client together. The 2048x1536 in the client's overlay is 4:3, which matches
that panel and is what identifies the photographs in section 12.2 as the client rather than the host's own
mirror. Auto-brightness and True Tone move the measured levels by more than the effect being measured, so
rounds should be taken with brightness locked. Rounds, in order: 1000 (the built-in default), 245, 4000, `sdr` (capture
switch off), then 245 against 4000 again as a controlled pair, then 500. Every round was confirmed on the
host log at the same minute: `Capturing hdr_canonical HDR from display ...`, `Color coding: HDR (Rec. 2020
+ SMPTE 2084 PQ)`, `Color depth: 10-bit`, and `Synthesised HDR10 metadata ... peak <n> nits` on the
25 Mbps session line, not only on the 1 Mbps encoder-validation pass.

### 12.2 How it was measured, and what the method can and cannot see

The quantity of interest is light leaving a panel, so the input is photographs of the client device.

- A screenshot records what the app submitted, not what the panel emitted. If the scaling happened in
  display composition, two screenshots would read identical while the eye sees a difference. That test is
  still open, section 12.6.
- AE/AF lock is not sufficient. In the controlled pair the two physical references in frame, the wall
  behind the device and the keyboard in front of it, both moved by +21% and +25% between the 245 and the
  4000 shot, so the camera gain itself shifted. Absolute patch levels are therefore not comparable across
  shots; every patch in a shot is divided by that same shot's wall patch, which cancels gain and ambient
  at once. Framing also moved by a few percent, which is why patches were chosen as fractions of the
  frame and re-checked per shot.
- Pasting an image into a chat re-encodes it: the four photographs arrived as Display P3 8-bit JPEG with
  no HDR signal left. Originals were analysed with `sips` plus a small linear-luma percentile tool over
  named patches (percentiles of luma after sRGB decode; ratios are exposure invariant). The tool is
  `scripts/lumastats.swift`: `swiftc -O -o lumastats scripts/lumastats.swift && ./lumastats <img>...`.

### 12.3 Results

Uncontrolled round, normalised by the SDR white inside the same photograph (the YouTube UI band, whose
p99 was 0.583-0.597 in all four shots, so the shots were comparable conditions):

| declared peak | video highlights p99 | video blacks p5 | patch contrast p95/p5 |
| --- | --- | --- | --- |
| 1000 | 1.05x white | 0.38% of white | 109 |
| 245 | 0.93x white | 0.30% of white | 155 |
| 4000 | 0.49x white | 1.36% of white | 26 |
| HDR capture off (`sdr`) | 0.86x white | 0.66% of white | 58 |

Controlled AE-locked pair, normalised by the wall in the same photograph:

| declared peak | SDR desktop, right of the video | video highlights p99 | video blacks p5 | patch contrast p95/p5 |
| --- | --- | --- | --- | --- |
| 245 | 0.268 | 0.912 | 0.0038 | 84 |
| 4000 | 0.191, that is 0.71x | 0.580, 0.64x | 0.0068, 1.8x | 38, 0.45x |

The two rounds agree in sign and roughly in size, which is the point of repeating it: the effect is
reproducible and is not a frame of video, a framing change, or camera gain. Turning HDR capture off also
moved the picture in the expected direction, consistent with section 10.5, where SDR capture clips EDR
content at 940 codes while the clip in section 10.6 peaks at 2.45x white.

### 12.4 What it means

1. `maxLuminance` is a whole-frame scale reference on this client, not a ceiling for highlights alone.
   The proof is the region that moved in the controlled pair: the desktop wallpaper to the right of the
   video contains no highlight content at all, is SDR in the stream, and went 29% darker when only the
   declared peak changed. VoidLink, or rather AVSampleBuffer rendering of a PQ picture with MDCV
   metadata, therefore does not anchor SDR white at 100 cd/m² and tone-map only the top of the range; it
   normalises the picture by the declared peak.
2. Section 10.9's question is answered and decision 3 of section 4 holds: the deficit can be moved with
   metadata alone, no GPU pass. Lower declared peak, brighter picture and deeper blacks; higher, darker
   and lifted. "HDR looks brighter than SDR" is only true while the declared peak is not far above what
   the content actually reaches, which the 4000 round shows by looking worse than HDR capture off.
3. The response is a soft curve, not a division: 16x the declared peak produced 0.71x the light. So the
   right value cannot be computed from the ratio, it has to be read off a ladder of measurements.
4. Two bounds are not guesses. The content cannot be brighter than 100 cd/m² times the screen's EDR
   headroom, which is 500 cd/m² on this machine, section 10.4, so anything declared above that is
   over-declared by construction and the built-in default of 1000 over-declares by 2x here. And the
   content peak measured in section 10.6 is 245-264 cd/m², so declaring below that trades highlight
   separation for overall brightness. The reasonable values live between those two numbers, and the
   shipped default is derived from headroom, `round(100 * maximumPotentialEDR)`, rather than a constant
   copied from a Linux panel. That is `hdr_max_luminance_macos = -1`, and writing `= 500` on this host
   states the same number explicitly.
5. `maxCLL` must never exceed `maxLuminance`, because content brighter than its own mastering display
   cannot exist. The rounds above ran with peak 245 against `maxCLL` 1000, which the resolver now clamps
   away in both directions, configured and environment alike. Whether `maxCLL` is worth anything on its
   own to this client is still an open measurement.
6. The tuning is client-specific. A renderer that follows the spec anchors SDR white at 100 cd/m² and
   would show no global change at all when the declared peak moves, so a low value optimised for VoidLink
   is not automatically right for the next client, while an over-declared peak is wrong for everyone.
   That asymmetry is the argument for a derived, never-over-declared default, and for the environment
   variable keeping precedence over the configuration option while the ladder of section 12.6 is still
   missing: measuring a client should not require editing sunshine.conf and restarting the host.

### 12.5 Session quality observed while HDR was on

VoidLink's overlay during the HDR session: 2048x1536 at 58.67 FPS, HEVC Main 10 HDR, 18.2 Mbps average
with 40.2 Mbps peak, `Frames buffered: 1.0`, host processing 7.6/11.8/8.3 ms, network 8 ms with 3 ms
variance, decode 1.90/6.02/2.94 ms, `Frames dropped by network/pacing jitter: 0.0% / 3.3%`, renderer
`AVSampleBuffer (Queue Pacing)`. The host logged 36.6-44.6 Mbps, `Opus initialized: 48 kHz, 2 channels,
512 kbps (total), LOWDELAY`, and the audio aggregate device granted a 240 frame, 5 ms IO procedure.

Reading it: the only imperfect number is the client's 3.3% of frames dropped by render pacing at a 1.0
frame buffer, which is roughly two frames a second and is what a slow pan looks like. Network loss, host
processing and decode are all nowhere near a frame period, so the judder is client presentation, not the
HDR path and not bandwidth. VoidLink exposes that directly, `framePacingMode` with `Off`, `Legacy` and
`Queue` (`VoidLink/Database/DataManager.h:64`); Queue is what the overlay reported. Late frames are
dropped in Queue mode and displayed late in the others, so for watching rather than playing, the other
modes trade a little latency for no drops. Nothing in this data speaks to the audio-visual mismatch: the
overlay reports no audio figure, VoidLink has no audio offset or sync setting in its source, and Lumen
logs no audio output latency, so that symptom is currently uninstrumented on both ends.

### 12.6 Still open

1. Screenshot against photograph: do two screenshots, 245 and 4000, analyse the originals. If they differ,
   every later round becomes camera free and exact; if they match while the eye sees a difference, the
   scaling is happening at composition and only photographs or a screen recording can see it.
2. The ladder: 150, 245, 350, 500, 1000 with the same paused frame and AE locked, against a reference of
   the same clip played natively on the device, which is the definition of "correct brightness". The
   crossing point is the value to ship.
3. Whether `maxCLL` has an effect of its own, tested with `maxCLL` paired to the peak and with it dropped.
4. Section 11.6 items 3 and 4, the encoded stream's own colour tags and the renegotiation path, are still
   uninspected.
5. ProMotion is confirmed on the client, a 10-120 Hz adaptive panel presenting a 60 FPS stream. Whether
   that interacts with `Queue` pacing is untested, and 24 FPS content captured on the host's 60 Hz display
   arrives as a 2-3-2-3 pattern of repeats, which is judder the panel cannot remove because it is already
   in the stream. Checking the clip's frame rate is the five second version of that test.
6. Source cadence has not been ruled out as the cause of the judder. Content at 24 or 30 FPS captured on
   a 60 Hz display arrives as an uneven pattern of repeats, which reads as stutter while every latency
   number stays green. The discriminator is a native 60 FPS clip and plain desktop scrolling: if those
   are smooth and only 24/30 FPS video judders, the pipeline is not at fault. Dropping or delaying frames
   in bursts is also the one mechanism that could account for the audio complaint in the same breath,
   since a dropped frame moves the picture relative to an audio clock that keeps running.
7. The host was running AI inference with the GPU saturated during these observations, which was never
   ruled out and is the strongest remaining explanation: ScreenCaptureKit capture and VideoToolbox
   encoding share that GPU, and `vt_drain` defaults to 1, one drain per submission, which makes the
   submission loop wait for the encoder. Under contention that stall is not visible in the client's
   "host processing latency" figure, but it does make frames arrive late enough for `Queue` pacing to
   drop them. The test is the same content and the same client settings with the inference stopped, and
   `sudo powermetrics --samplers tasks --show-process-gpu` to see who owns the GPU. If load is the cause,
   `vt_drain = 0` trades latency for absorbing it, which is the right trade for watching video.

