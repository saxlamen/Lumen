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

Create the fork at <https://github.com/LizardByte/build-deps/fork>; nothing is published from
`LizardByte/build-deps` by hand, so a fork is the only way to get a bundle that carries a patch.

1. `build-deps/` in this directory mirrors the fork layout, so copy its contents into the fork root.
   That lands `patches/FFmpeg/FFmpeg/videotoolbox/01-frame-drain.patch` and
   `cmake/ffmpeg/videotoolbox.cmake`. The cmake file only applies patches, because there is no extra
   library to build here.
2. Add the two hooks that make the component reachable. `cmake/ffmpeg/_main.cmake` includes one file
   per component and only then includes `ffmpeg.cmake`, which creates the configure and build targets:
   - `CMakeLists.txt`: `option(BUILD_FFMPEG_VIDEOTOOLBOX_PATCHES "Apply FFmpeg VideoToolbox patches" ON)`
     beside the other patch options. `ffmpeg.cmake` applies its own patches under
     `BUILD_FFMPEG_ALL_PATCHES OR BUILD_FFMPEG_CBS_PATCHES`, and every existing option defaults to
     `ON`, so an `OFF` default would quietly skip this patch.
   - `cmake/ffmpeg/_main.cmake`: `if(APPLE) include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/ffmpeg/videotoolbox.cmake) endif()`
     before the `ffmpeg.cmake` include.
3. Push to `master`, or run the `CI` workflow manually. CI builds the `Darwin-arm64` matrix entry and
   publishes `Darwin-arm64-ffmpeg.tar.gz` on a generated release tag using `GITHUB_TOKEN`, which
   works in a fork without extra secrets. **Keep every external encoder the upstream bundle enables**
   (x264, x265, SVT-AV1): a minimal local FFmpeg rebuild that drops them, as the proof of concept
   did, silently removes `encoder = software`.
4. Point the Lumen submodule at the fork (`git config -f .gitmodules submodule.third-party/build-deps.url
   <fork url>`, then `git submodule sync`) and bump it to the tagged commit.
5. One Lumen side change is still required: `cmake/dependencies/ffmpeg.cmake` hard-codes
   `FFMPEG_GITHUB_REPO` as `LizardByte/build-deps` when it builds the download URL, so a submodule
   URL alone does not redirect the archive download. Either derive the repository from the
   submodule's `origin` remote, or skip cmake entirely and hand the bundle to the build with
   `-DFFMPEG_PREPARED_BINARIES=<path>` from the packaging recipe.

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
