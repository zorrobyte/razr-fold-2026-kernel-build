#!/usr/bin/env bash
# Build the canoe (Razr Fold 2026 / blanc) kernel from the assembled tree.
#
# Two steps, matching Moto's own flow:
#   1. build/kernel/build_kernel_product.sh <product> canoe <variant>  — generates
#      soc-repo/moto_product.bzl (mmi_product_name/type + build_target/variant). This file is NOT
#      in the published tree; without it the canoe target can't select the blanc product. The
#      wrapper has NO shebang and hardcodes the relative path 'kernel_platform/soc-repo', so it
#      MUST be run with bash from WORKDIR (the parent of kernel_platform).
#   2. soc-repo/build_with_bazel.py -t canoe <variant>  — the actual kleaf/bazel build.
#
#   variant: perf (pristine baseline that MUST boot first) | consolidate (dev, KMI enforcement off)
# Output dist: out/msm-kernel-canoe-<variant>/dist/  (Image, *.dtb, *.dtbo, vendor_dlkm.img, modules).
set -euo pipefail

VARIANT="${1:-perf}"
WORKDIR="${2:-$HOME/kp-canoe}"
PRODUCT="${PRODUCT:-blanc_g}"      # -> mmi_product_name=blanc, mmi_product_type=g
KP="$WORKDIR/kernel_platform"

# 1a) generate soc-repo/moto_product.bzl  (run from WORKDIR; wrapper paths are relative to it)
cd "$WORKDIR"
echo ">> generating moto_product.bzl via build_kernel_product.sh $PRODUCT canoe $VARIANT"
bash ./kernel_platform/build/kernel/build_kernel_product.sh "$PRODUCT" canoe "$VARIANT"
echo ">> moto_product.bzl:"; cat "$KP/soc-repo/moto_product.bzl" 2>/dev/null | sed 's/^/     /'

# 1b) generate configs/ext_config/moto_{perf,consolidate}_config.bzl from the .config fragments.
# canoe.bzl loads BOTH, so both are required even for a perf build. Args: <arch> <variant> <product>.
echo ">> generating ext_config .bzl via build_defconfig.sh canoe $VARIANT $PRODUCT"
bash ./kernel_platform/build/kernel/build_defconfig.sh canoe "$VARIANT" "$PRODUCT"
# build_defconfig.sh ends with `cd kernel_platform && ln -fs ../motorola`; since our motorola/ is a
# real synced dir, that creates a self-referential motorola/motorola symlink — remove it so Bazel's
# package globbing doesn't hit an infinite symlink loop.
rm -f "$KP/motorola/motorola"

# build_with_bazel.py symlinks build/msm_kernel_extensions.bzl and loads it as //build:...,
# so build/ must be a Bazel package. Nothing in the manifest owns the bare build/ dir, so ensure
# an (empty) BUILD file exists — the loader just needs the package to be present.
[ -f "$KP/build/BUILD.bazel" ] || : > "$KP/build/BUILD.bazel"

# build_with_bazel.py points bazel --output_user_root at soc-repo/bazel-cache (in-tree). The target
# query would then recurse into bazel's own execroot and fail loading external repos' test .bzl files
# (+ "infinite symlink expansion"). Exclude the cache from package scanning via .bazelignore (at the
# workspace root = kernel_platform). Idempotent.
BZI="$KP/.bazelignore"; touch "$BZI"
grep -qxF "soc-repo/bazel-cache" "$BZI" || echo "soc-repo/bazel-cache" >> "$BZI"

# dtc repo: the kleaf_local_repository rule uses soc-repo/BUILD.dtc as the dtc repo's build_file, but
# Moto's soc-repo ships a STALE BUILD.dtc that mismatches the published qcom-dtc source (it references
# version_non_gen.h and fdtoverlaymerge.c, neither of which exist). kernel-external-dtc ships its OWN
# correct BUILD.bazel (version_gen_header genrule; fdtget/fdtput/fdtdump/fdtoverlay — matching the
# actual sources). Use our vendored copy of that as the build_file, and remove the source's BUILD.bazel
# so the repo rule's readdir doesn't collide with the build_file symlink ("File exists").
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cp -f "$HARNESS_DIR/overlays/qcom-dtc-BUILD.bazel" "$KP/soc-repo/BUILD.dtc"
rm -f "$KP/external/qcom-dtc/BUILD.bazel"

# 2) build. KLEAF_USE_KLEAF_LOCALVERSION reproduces Moto's stock vermagic stamp.
cd "$KP/soc-repo"
echo ">> building canoe $VARIANT"
export KLEAF_USE_KLEAF_LOCALVERSION=true
python3 build_with_bazel.py -t canoe "$VARIANT" --skip abl

DIST="$KP/out/msm-kernel-canoe-$VARIANT/dist"
echo; echo ">> dist: $DIST"
ls -la "$DIST"/Image "$DIST"/*.img 2>/dev/null || true
echo; echo ">> vermagic (must equal stock 6.12.38-android16-5-g1d46253471dd-ab15048002-4k):"
strings "$DIST/Image" 2>/dev/null | grep -m1 '6\.12\.38-android16' || echo "   (Image not found)"
