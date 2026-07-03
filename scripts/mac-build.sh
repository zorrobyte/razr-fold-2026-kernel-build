#!/usr/bin/env bash
# Build the canoe kernel ON AN APPLE SILICON MAC, via Colima + Rosetta 2.
#
# Why this works (and the old qemu attempt didn't): the AOSP kernel toolchain is x86-64-only
# (prebuilts/clang/host/linux-x86 — there is NO arm64 host clang). Apple's Rosetta 2 translates
# those x86-64 Linux binaries reliably (verified: clang 19.1.7 compiles+runs under Rosetta here),
# whereas full-system qemu emulation segfaulted them. We run the build inside an --platform
# linux/amd64 container so uname=x86_64 and Bazel/Kleaf pick the linux-x86 clang, executed by Rosetta.
#
# One-time host setup (Rosetta-backed Colima VM):
#   colima start kbuild --vm-type vz --vz-rosetta --cpu 10 --memory 64 --disk 320 --arch aarch64
#   (verify: `colima ssh -p kbuild -- ls /proc/sys/fs/binfmt_misc/rosetta` exists)
#
# Usage:  scripts/mac-build.sh [perf|consolidate]
# Tree + ccache persist in the docker volume 'kp-canoe' across runs (survives container removal).
set -euo pipefail

VARIANT="${1:-perf}"
HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="kbuild"

command -v colima >/dev/null || { echo "!! install colima (brew install colima docker)"; exit 1; }
colima status "$PROFILE" >/dev/null 2>&1 || {
  echo ">> starting Rosetta VM '$PROFILE' ..."
  colima start "$PROFILE" --vm-type vz --vz-rosetta --cpu 10 --memory 64 --disk 320 --arch aarch64
}
docker context use "colima-$PROFILE" >/dev/null

echo ">> building canoe $VARIANT in an amd64 (Rosetta) container; tree persists in volume 'kp-canoe'"
docker run --rm --platform=linux/amd64 \
  -v kp-canoe:/root/kp-canoe \
  -v "$HARNESS":/harness:ro \
  -w /root \
  ubuntu:24.04 bash -euxc '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
      git curl python3 python-is-python3 unzip zip rsync bc bison flex libssl-dev \
      ca-certificates make gcc g++ libelf-dev cpio kmod openssl >/dev/null
    # repo tool
    if ! command -v repo >/dev/null; then
      curl -s https://storage.googleapis.com/git-repo-downloads/repo -o /usr/local/bin/repo
      chmod +x /usr/local/bin/repo
    fi
    git config --global user.email build@local; git config --global user.name build
    git config --global color.ui false
    # assemble (idempotent)
    /harness/scripts/bootstrap.sh /root/kp-canoe
    # --- ROSETTA WORKAROUND ---------------------------------------------------------------
    # Rosetta 2 cannot run AOSP hermetic MUSL binaries (relinterp -> "AT_BASE not found in aux
    # vector"). Force the GLIBC hermetic tools, which run fine under Rosetta (like the clang we
    # tested). Applied AFTER sync (repo --force-sync restores pristine each run) and re-applied
    # idempotently. Two forcing points: the bazel launcher, and one unconditional musl.bazelrc line.
    KL=/root/kp-canoe/kernel_platform/build/kernel/kleaf
    sed -i "s#linux_musl-x86/bin/py3-cmd#linux-x86/bin/py3-cmd#g" "$KL/bazel.sh"
    : > "$KL/bazelrc/musl.bazelrc"   # drop the unconditional `common --config=musl_platform` (=> host stays glibc)
    echo ">> rosetta: forced glibc hermetic tools (bazel.sh launcher + musl.bazelrc neutralized)"
    # --------------------------------------------------------------------------------------
    /harness/scripts/build.sh '"$VARIANT"' /root/kp-canoe
  '
echo
echo ">> dist is inside the volume: docker run --rm -v kp-canoe:/k --platform=linux/amd64 ubuntu \\"
echo "     ls -la /k/kernel_platform/out/msm-kernel-canoe-$VARIANT/dist"
echo ">> to copy the Image/vendor_dlkm out to the Mac, see the tail of this script's docs."
