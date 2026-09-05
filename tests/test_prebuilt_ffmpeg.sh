#!/usr/bin/env bash
## @file test_prebuilt_ffmpeg.sh
## @brief Verify fresh setup, metadata updates, and skipped source downloads using local repositories.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lumen-ffmpeg-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Test GIT_COMMITTER_NAME=Test
export GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_ALLOW_PROTOCOL=file

git init -q "$TEST_DIR/dependency"
git -C "$TEST_DIR/dependency" config --file .gitmodules submodule.source.path source
git -C "$TEST_DIR/dependency" config --file .gitmodules submodule.source.url "$TEST_DIR/missing-source"
git -C "$TEST_DIR/dependency" add .gitmodules
git -C "$TEST_DIR/dependency" commit -qm initial
SOURCE_COMMIT="$(git -C "$TEST_DIR/dependency" rev-parse HEAD)"
git -C "$TEST_DIR/dependency" update-index --add --cacheinfo "160000,$SOURCE_COMMIT,source"
git -C "$TEST_DIR/dependency" commit -qm metadata

git init -q "$TEST_DIR/project"
git -C "$TEST_DIR/project" submodule add -q "$TEST_DIR/dependency" third-party/build-deps
git init -q "$TEST_DIR/required"
git -C "$TEST_DIR/required" commit --allow-empty -qm initial
# @brief Unreachable documentation fixtures detect accidental recursive downloads.
git -C "$TEST_DIR/required" config --file .gitmodules submodule.docs.path third-party/doxyconfig
git -C "$TEST_DIR/required" config --file .gitmodules submodule.docs.url "$TEST_DIR/missing-docs"
git -C "$TEST_DIR/required" add .gitmodules
git -C "$TEST_DIR/required" update-index --add --cacheinfo "160000,$SOURCE_COMMIT,third-party/doxyconfig"
git -C "$TEST_DIR/required" commit -qm docs
for library in Simple-Web-Server TPCircularBuffer lizardbyte-common libdisplaydevice libvirtualhid tray; do
  git -C "$TEST_DIR/project" submodule add -q "$TEST_DIR/required" "third-party/$library"
done
git init -q "$TEST_DIR/moonlight"
git -C "$TEST_DIR/moonlight" submodule add -q "$TEST_DIR/required" enet
git -C "$TEST_DIR/moonlight" submodule add -q "$TEST_DIR/required" nanors
git -C "$TEST_DIR/moonlight" commit -qm initial
git -C "$TEST_DIR/project" submodule add -q "$TEST_DIR/moonlight" third-party/moonlight-common-c
git -C "$TEST_DIR/project" submodule add -q "$TEST_DIR/required" third-party/doxyconfig
git -C "$TEST_DIR/project" commit -qm initial
git clone -q "$TEST_DIR/project" "$TEST_DIR/fresh clone"
mkdir -p "$TEST_DIR/fresh clone/scripts"
cp "$REPO_DIR/scripts/configure-prebuilt-ffmpeg.sh" "$TEST_DIR/fresh clone/scripts/"
cd "$TEST_DIR/fresh clone"
git config submodule.third-party/build-deps.update none
bash scripts/configure-prebuilt-ffmpeg.sh
test "$(git config submodule.third-party/build-deps.update)" = checkout
test "$(git -C third-party/build-deps config submodule.source.update)" = none
git submodule update --init --recursive -- third-party/build-deps
test ! -e third-party/build-deps/source/.git

git -C "$TEST_DIR/dependency" commit --allow-empty -qm updated-metadata
EXPECTED_COMMIT="$(git -C "$TEST_DIR/dependency" rev-parse HEAD)"
git update-index --cacheinfo "160000,$EXPECTED_COMMIT,third-party/build-deps"
bash scripts/configure-prebuilt-ffmpeg.sh
test "$(git -C third-party/build-deps rev-parse HEAD)" = "$EXPECTED_COMMIT"
bash scripts/configure-prebuilt-ffmpeg.sh
git submodule update --init --recursive -- third-party/build-deps
test ! -e third-party/build-deps/source/.git

# @brief Exercise build.sh setup with real Git; stop at CMake before compilation or deployment.
cp "$REPO_DIR/build.sh" ./build.sh
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/brew" <<'SH'
#!/usr/bin/env bash
echo /unused-test-prefix
SH
cat > "$TEST_DIR/bin/cmake" <<'SH'
#!/usr/bin/env bash
exit 73
SH
chmod +x "$TEST_DIR/bin/brew" "$TEST_DIR/bin/cmake"
BUILD_STATUS=0
PATH="$TEST_DIR/bin:$PATH" bash ./build.sh || BUILD_STATUS=$?
test "$BUILD_STATUS" -eq 73
for library in Simple-Web-Server TPCircularBuffer lizardbyte-common libdisplaydevice libvirtualhid tray moonlight-common-c; do
  test -f "third-party/$library/.git"
  test ! -e "third-party/$library/third-party/doxyconfig/.git"
done
test -f third-party/moonlight-common-c/enet/.git
test -f third-party/moonlight-common-c/nanors/.git
test ! -e third-party/doxyconfig/.git
test ! -e third-party/build-deps/source/.git
echo 'PASS: fresh setup, metadata updates, repeat setup, and build.sh submodule initialization'
