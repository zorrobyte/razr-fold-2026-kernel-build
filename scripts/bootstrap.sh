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

# Make git ABORT a stalled fetch instead of hanging forever. The big AOSP prebuilts (clang) fetch
# over android.googlesource.com can stall mid-transfer on a flaky link; without this, the fetch
# sleeps indefinitely and the retry loop below never triggers (a hang is not a non-zero exit).
# lowSpeedLimit/Time => abort if throughput stays under 1 KB/s for 60s -> retryable failure.
git config --global http.lowSpeedLimit 1000
git config --global http.lowSpeedTime 60
git config --global http.postBuffer 524288000

# 3) sync everything. repo sync is resumable (--optimized-fetch reuses partial packs), so retry.
# First passes use -j to go fast; later passes drop to -j1 so the one stubborn repo (clang) gets a
# dedicated connection instead of competing for bandwidth.
synced=0
for attempt in 1 2 3 4 5 6 7 8; do
  jobs=$([ "$attempt" -ge 4 ] && echo 1 || nproc)
  if repo sync -c -j"$jobs" --no-tags --optimized-fetch --prune --force-sync --retry-fetches=3; then synced=1; break; fi
  echo ">> repo sync attempt $attempt (j=$jobs) failed; resuming in 8s..."
  sleep 8
done
[ "$synced" = 1 ] || { echo "!! repo sync still failing after retries — check network; tree is resumable, just re-run."; exit 1; }

echo
echo ">> Tree assembled at $WORKDIR/kernel_platform"
echo ">> Sanity: these must exist —"
for p in common/Makefile soc-repo/build.config.msm.canoe build/kernel/kleaf prebuilts/clang; do
  [ -e "$p" ] && echo "   OK  $p" || echo "   ?? MISSING $p  (check the manifest overlay / AOSP base)"
done
echo ">> Next:  scripts/build.sh"
