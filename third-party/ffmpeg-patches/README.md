# FFmpeg patches we carry

Lumen links FFmpeg as a static prebuilt bundle that `LizardByte/build-deps` publishes on GitHub
releases, and `cmake/dependencies/ffmpeg.cmake` downloads the archive whose tag matches the
`third-party/build-deps` submodule. Anything that changes FFmpeg behaviour therefore belongs to the
dependency layer rather than to Lumen's source tree. This directory is the staging area for those
changes: the files here are the copy source for a `build-deps` fork, and keeping them here means the
change stays reviewable instead of living on one development machine.

## videotoolbox/01-frame-drain.patch

Adds a `frame_drain` encoder option to `libavcodec/videotoolboxenc.c`: drain completed frames every
N submissions, `0` disables it, `1` (the default in this patch) makes the encoder synchronous.

Why it is needed: the generic FFmpeg encode layer calls the encoder callback once per submitted
frame, and `vtenc_q_pop(wait = 0)` inside that callback takes at most one completed sample without
waiting. A completion that arrives after the exchange therefore costs one frame of latency
permanently, because every later call exchanges one submit for one packet and can never catch up, so
the wrapper queue depth grows monotonically for the rest of the session. On the development machine
that showed up as a queue frozen at 4 frames: 60 fps content carried 66.7 ms of host latency while
the same hardware produced one frame in flight and about 11 ms when driven directly. With the drain
in place the same content measures 9.0 ms of host latency at the same 60.00 fps, still on HEVC 10-bit.

`scripts/vtprobe.m` measures the whole trade-off, which is why the option is a cadence instead of a
boolean. At 3840x2160 HEVC 10-bit: no drain gives 66.7 ms at 60.00 fps, draining every submit gives
18.1 ms at 50.4 fps, every two submits 33.4 ms at 57.0 fps, every three 48.9 ms at 59.3 fps.

The Lumen side is `vt_drain`, passed as `frame_drain` to the three VideoToolbox encoders. Leftover
dictionary entries after `avcodec_open2()` are checked, so an unpatched FFmpeg logs one warning
instead of silently losing the improvement.

### Carrying the patch in a build-deps fork

Verified locally: the patch applies to FFmpeg `release/9.0` with line offsets only, which is the line
`build-deps` master pins, and to `release/8.1`, the 8.1 series (lavc 62.28.x) that the published
bundle in use here was built from.

1. In the fork put the file at `patches/FFmpeg/FFmpeg/videotoolbox/01-frame-drain.patch`.
2. Add `cmake/ffmpeg/videotoolbox.cmake` that globs that directory and applies each file with
   `APPLY_GIT_PATCH`, mirroring `cmake/ffmpeg/ffmpeg.cmake`, which today only globs
   `patches/FFmpeg/FFmpeg/cbs/*.patch` and is gated on `BUILD_FFMPEG_ALL_PATCHES OR
   BUILD_FFMPEG_CBS_PATCHES`. Introduce `BUILD_FFMPEG_VIDEOTOOLBOX_PATCHES` and honour
   `BUILD_FFMPEG_ALL_PATCHES` so a plain build keeps getting every patch.
3. Rebuild and publish `Darwin-arm64-ffmpeg.tar.gz` on a new tag, **keeping every external encoder
   the upstream bundle enables** (x264, x265, SVT-AV1). A minimal local FFmpeg rebuild that drops
   them, as the proof of concept did, silently removes `encoder = software`.
4. Point the Lumen submodule at the fork and bump it to the tagged commit; nothing else in Lumen
   changes.

Development-only shortcut, not a shipping form: build FFmpeg with the patch and configure Lumen with
`-DFFMPEG_PREPARED_BINARIES=<path-to-bundle>`, which `cmake/dependencies/ffmpeg.cmake` honours. That
is how the 9.0 ms measurement was deployed, and it is also how a regression can be re-measured
without touching the dependency pipeline.

### Verification after the packaged bundle switches

1. `encoder = software` still opens, proving x264/x265/SVT-AV1 survived the rebuild.
2. With the default `vt_drain`, `Video: encoder output latency` reads `0.00 frames` and
   `Frame processing latency` sits near 9 ms on 2560x1920 10-bit content, which needs
   `min_log_level = debug` and moving content in the streamed display.
3. The log contains no `frame_drain` warning, proving the packaged FFmpeg accepts the option.
4. A build against unpatched FFmpeg still streams, shows the warning once, and returns to the old
   latency: the patch is an improvement, never a requirement.
