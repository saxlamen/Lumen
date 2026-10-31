#!/usr/bin/env bash
#
# Build the FFmpeg dependency bundle Lumen should link against: the published build-deps archive with
# third-party/ffmpeg-patches/build-deps/patches/FFmpeg/FFmpeg/videotoolbox/01-frame-drain.patch
# applied to FFmpeg itself.
#
# The published archive is used as the base so that libx264.a, libx265.a, libSvtAv1Enc.a, libcbs.a and
# their headers stay byte identical to what LizardByte publishes; only the FFmpeg libraries are rebuilt.
# cmake/dependencies/ffmpeg.cmake links exactly those archives by name, so a base that is missing one
# breaks the Lumen link instead of degrading.
#
# Provenance is recorded next to the output: the build-deps release tag, the FFmpeg commit pinned by
# that tag's submodule gitlink, and the SHA-256 of the produced archive.
#
# Usage: third-party/ffmpeg-patches/build-bundle.sh
# Overrides: BUILD_DEPS_TAG, FFMPEG_COMMIT, ARCHIVE, WORK, JOBS
set -euo pipefail

BUILD_DEPS_TAG="${BUILD_DEPS_TAG:-v2026.910.121303}"
FFMPEG_COMMIT="${FFMPEG_COMMIT:-bf1b838f2ab88b4f8fd83443325c782ea0e0f7fa}"
ARCHIVE="${ARCHIVE:-Darwin-arm64-ffmpeg.tar.gz}"
WORK="${WORK:-/tmp/lumen-ffmpeg-bundle}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
patch_file="${repo_root}/third-party/ffmpeg-patches/build-deps/patches/FFmpeg/FFmpeg/videotoolbox/01-frame-drain.patch"
[ -f "${patch_file}" ] || {
  echo "missing patch: ${patch_file}" >&2
  exit 1
}

# The configure flags below are the ones recorded inside the published libavutil.a, with the CI build
# directories replaced by this base bundle. Keep them aligned with upstream, otherwise the bundle
# silently loses encoders.
mkdir -p "${WORK}"
cd "${WORK}"

if [ ! -f archive.tar.gz ]; then
  curl -fL -o archive.tar.gz \
    "https://github.com/LizardByte/build-deps/releases/download/${BUILD_DEPS_TAG}/${ARCHIVE}"
fi
rm -rf bundle && mkdir bundle
tar xzf archive.tar.gz -C bundle
base="${WORK}/bundle/ffmpeg"

if [ ! -d src ]; then
  curl -fL -o src.tar.gz "https://github.com/FFmpeg/FFmpeg/archive/${FFMPEG_COMMIT}.tar.gz"
  mkdir src
  tar xzf src.tar.gz -C src --strip-components=1
fi

if grep -q frame_drain src/libavcodec/videotoolboxenc.c; then
  echo "patch already applied in ${WORK}/src"
else
  patch -p1 -d src -i "${patch_file}"
fi

# The published archive ships libx264.a and x264.h but no x264.pc: upstream built x264 into its own
# prefix and pointed PKG_CONFIG_PATH there, so FFmpeg's pkg-config check for libx264 needs a file the
# archive never carried. Synthesize it from the shipped headers.
for pc in "${base}"/lib/pkgconfig/*.pc; do
  sed -i '' -E "s#^prefix=.*#prefix=${base}#" "${pc}"
done

if [ ! -f "${base}/lib/pkgconfig/x264.pc" ]; then
  x264_build="$(grep -E '^#define X264_BUILD ' "${base}/include/x264.h" | awk '{print $3}')"
  x264_build="${x264_build:-0}"
  cat > "${base}/lib/pkgconfig/x264.pc" <<EOF
prefix=${base}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: x264
Description: free H.264/MPEG-4 AVC encoder
Version: ${x264_build}
Cflags: -I\${includedir}
Libs: -L\${libdir} -lx264
Libs.private: -lm -lpthread
EOF
fi

export PKG_CONFIG_PATH="${base}/lib/pkgconfig"

(
  cd src
  ./configure \
    --prefix="${base}" \
    --cc=/usr/bin/clang --cxx=/usr/bin/clang++ --ar=/usr/bin/ar --ranlib=/usr/bin/ranlib \
    --pkg-config=/opt/homebrew/bin/pkg-config \
    --pkg-config-flags=--static \
    --extra-cflags="-I${base}/include" \
    --extra-ldflags="-L${base}/lib" \
    --extra-libs=-lpthread \
    --disable-all \
    --disable-autodetect \
    --disable-iconv \
    --enable-gpl \
    --enable-static \
    --enable-avcodec \
    --enable-avutil \
    --enable-bsfs \
    --enable-swscale \
    --enable-encoder=mpeg2video,h263p \
    --enable-libsvtav1 --enable-encoder=libsvtav1 \
    --enable-libx264 --enable-encoder=libx264 \
    --enable-libx265 --enable-encoder=libx265 \
    --enable-encoder=h264_videotoolbox,hevc_videotoolbox \
    --enable-videotoolbox \
    --arch=arm64 \
    --enable-cross-compile \
    --target-os=darwin
  make -j"${JOBS}"
  make install
)

# Frame draining must be inside the rebuilt encoder, and the software encoders must still be enabled.
# grep reads files here rather than a pipe: grep -q exits early, which under pipefail would make a
# successful match look like a failed pipeline.
strings "${base}/lib/libavcodec.a" > "${WORK}/avcodec.strings"
grep -q frame_drain "${WORK}/avcodec.strings" || {
  echo "frame_drain missing from the rebuilt libavcodec.a" >&2
  exit 1
}
for feature in LIBX264 LIBX265 LIBSVTAV1 VIDEOTOOLBOX; do
  grep -q "^#define CONFIG_${feature} 1" "${base}/include/config.h" || {
    echo "rebuilt bundle lost CONFIG_${feature}" >&2
    exit 1
  }
done

(
  cd bundle
  tar czf "../${ARCHIVE}" ffmpeg
)
sha256sum "${ARCHIVE}" 2>/dev/null | awk '{print $1}' > "${ARCHIVE}.sha256" || \
  shasum -a 256 "${ARCHIVE}" | awk '{print $1}' > "${ARCHIVE}.sha256"

cat > PROVENANCE.txt <<EOF
archive:     ${ARCHIVE}
sha256:      $(cat "${ARCHIVE}.sha256")
base:        https://github.com/LizardByte/build-deps/releases/download/${BUILD_DEPS_TAG}/${ARCHIVE}
ffmpeg:      ${FFMPEG_COMMIT}
patch:       third-party/ffmpeg-patches/build-deps/patches/FFmpeg/FFmpeg/videotoolbox/01-frame-drain.patch
built:       $(sw_vers -productVersion 2>/dev/null || echo unknown) / $(uname -m) / $(/usr/bin/clang --version | head -1)
configured:  as recorded in the published libavutil.a, CI paths replaced by the base bundle
verify:      frame_drain present; x264/x265/SVT-AV1 encoder symbols present
EOF

echo
echo "bundle:  ${base}"
echo "archive: ${WORK}/${ARCHIVE}"
echo "sha256:  $(cat "${ARCHIVE}.sha256")"
