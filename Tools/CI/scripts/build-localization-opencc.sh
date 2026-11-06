#!/usr/bin/env bash
# Purpose: build the pinned OpenCC CLI for clean-checkout localization checks.
# Usage: Tools/CI/scripts/build-localization-opencc.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$root/Tools/BuildRime/VERSIONS.env"
localization_root="$root/.local/localization-opencc"
source_root="$localization_root/source"
build_root="$localization_root/build"
mkdir -p "$localization_root"
if [[ ! -d "$source_root/.git" ]]; then
  git clone --no-checkout https://github.com/BYVoid/OpenCC.git "$source_root"
fi
if [[ "$(git -C "$source_root" rev-parse HEAD 2>/dev/null || true)" != "$OPENCC_COMMIT" ]]; then
  git -C "$source_root" fetch origin "$OPENCC_COMMIT"
  git -C "$source_root" checkout --detach "$OPENCC_COMMIT"
fi
cmake -S "$source_root" -B "$build_root" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DENABLE_GTEST=OFF -DBUILD_TESTING=OFF -DBUILD_DOCUMENTATION=OFF
cmake --build "$build_root" --target opencc --parallel 2
"$build_root/src/tools/opencc" --version
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "OPENCC_BIN=$build_root/src/tools/opencc" >> "$GITHUB_ENV"
fi
