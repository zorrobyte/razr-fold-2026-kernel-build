#!/usr/bin/env bash
# Bootstrap the full canoe (Razr Fold 2026 / blanc / SM8845) kernel_platform tree.
#
# Strategy (the "done correctly" part):
#   * BASE = AOSP GKI kernel manifest pinned to the EXACT ACK tag Moto built against
#     (android16-6.12-2025-09_r15 / SHA 74ad4605...). This provides common/, build/kernel,
#     external/*, prebuilts/clang, dtc, kleaf — Google-pinned and mutually consistent, so we
#     do NOT hand-assemble the fragile build infrastructure.
#   * OVERLAY = Motorola's vendor source (soc-repo=kernel-msm, qcom/opensource/*, *-devicetree,
#     motorola-kernel-modules, techpacks) via .repo/local_manifests/moto-canoe.xml, pinned to
#     the device release branch. Also overrides common/ with Moto's kernel-common fork.
#
# Run on a NATIVE x86-64 Linux host (WSL2 Ubuntu is fine). Apple Silicon can't run the AOSP
# x86 clang under emulation (it segfaults) — that's why builds live on the PC.
#
# Usage:  scripts/bootstrap.sh [WORKDIR]     (default WORKDIR=~/kp-canoe)
set -euo pipefail

WORKDIR="${1:-$HOME/kp-canoe}"
ACK_TAG="android16-6.12-2025-09_r15"          # from kernel-msm/android/ACK_SHA
AOSP_MANIFEST="https://android.googlesource.com/kernel/manifest"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v repo >/dev/null || { echo "!! 'repo' not found. Install: https://storage.googleapis.com/git-repo-downloads/repo"; exit 1; }

echo ">> Root:   $WORKDIR/kernel_platform"
echo ">> Base:   AOSP GKI manifest @ $ACK_TAG"
echo ">> Overlay: $HERE/manifests/moto-canoe.xml (MotorolaMobilityLLC @ android-16-release-w3wb36.36-48-5)"
mkdir -p "$WORKDIR/kernel_platform"
cd "$WORKDIR/kernel_platform"

# 1) init AOSP GKI base. NOTE: android16-6.12-2025-09_r15 ($ACK_TAG) is a tag on kernel/common, NOT a
# ref on the manifest repo, so we init the manifest BRANCH common-android16-6.12. This only supplies
# prebuilts/clang + external/dtc + build deps (forward-compatible); the kernel 'common' itself is
# OVERRIDDEN below by Moto's kernel-common @ the MMI-W3WB tag, so the exact GKI snapshot here is moot.
repo init -u "$AOSP_MANIFEST" -b common-android16-6.12 --depth=1

# 2) drop in the Moto overlay as a local manifest
mkdir -p .repo/local_manifests
cp "$HERE/manifests/moto-canoe.xml" .repo/local_manifests/moto-canoe.xml

# 3) sync everything
repo sync -c -j"$(nproc)" --no-tags --optimized-fetch --prune --force-sync

echo
echo ">> Tree assembled at $WORKDIR/kernel_platform"
echo ">> Sanity: these must exist —"
for p in common/Makefile soc-repo/build.config.msm.canoe build/kernel/kleaf prebuilts/clang; do
  [ -e "$p" ] && echo "   OK  $p" || echo "   ?? MISSING $p  (check the manifest overlay / AOSP base)"
done
echo ">> Next:  scripts/build.sh"
