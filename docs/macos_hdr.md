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
| Colour attachments | whole of `src/` | No `kCVImageBuffer*` attachment is ever read or written, so whatever the capture layer tags is dropped on the floor |

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
   anything is captured, and there is nothing HDR to encode. Measured on the development machine:
   the BetterDisplay virtual screen reports `maximumPotentialExtendedDynamicRangeColorComponentValue`
   of exactly 1.0, which means no HDR capability at all, so the current session cannot be HDR
   regardless of what the code does. Options: stream a physically HDR display with mirroring off,
   or give the virtual screen an HDR colour profile in BetterDisplay.
2. **Capture must request HDR.** `captureDynamicRange` (canonical, i.e. tuned for any HDR display,
   rather than the local panel) plus `colorSpaceName` for PQ/BT.2020, with `x420` as the container.
   ScreenCaptureKit then tags the buffers, and the zero-copy path already hands the same
   `CVPixelBuffer` to FFmpeg, which keeps the IOSurface and its attachments.
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
measurement is meaningless.

## 7. Measurements still to run

`/tmp/hdrprobe.swift` (signed as `com.saxlamen.hdrprobe`) already prints the EDR state of every
screen and dumps the colour attachments of captured frames for SDR and for both HDR presets. It
needs Screen Recording permission, which has not been granted yet, so the attachment side is still
unknown. The checklist:

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

## 8. Open questions

These were the questions raised for review; section 9 records what was decided about each one.

1. Canonical or local dynamic range, given that local display tone mapping is reported as
   unreliable on some macOS 15 builds while Nottlespike chose it deliberately for a different
   reason.
2. How to handle the SDR white level: PR 5957 needed a Metal pass to scale PQ by 2.03 because SCK
   puts SDR white at 100 nits. A GPU pass costs latency, which is the one thing this project has
   spent its time buying back. The macOS 26 `RequestSDRRangePreservation` insertion mode may make
   that pass unnecessary, and is worth testing before writing any Metal code.
3. Whether to read real display mastering metadata (nothing public, and PR 5957 synthesised it) and
   whether VideoToolbox's `Auto` HDR10 insertion is good enough, or whether the mastering-display
   and content-light properties should be set explicitly from `get_hdr_metadata()`.
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

