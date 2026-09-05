#!/usr/bin/env bash
## @file configure-prebuilt-ffmpeg.sh
## @brief Keep FFmpeg release metadata updated while skipping source dependencies.
## @details Run before recursive submodule initialization on a fresh clone.
## Local Git settings persist across updates without modifying the dependency repository.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

git config submodule.third-party/build-deps.update checkout
git submodule update --init --checkout -- third-party/build-deps

while IFS= read -r key; do
  git -C third-party/build-deps config "${key%.path}.update" none
done < <(git -C third-party/build-deps config --file .gitmodules --name-only --get-regexp '^submodule\..*\.path$')
