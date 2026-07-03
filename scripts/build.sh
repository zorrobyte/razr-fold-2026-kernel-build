#!/usr/bin/env bash
# Build the canoe (Razr Fold 2026 / blanc) kernel from the assembled tree.
#
# Uses Moto's OFFICIAL wrapper build_kernel_product.sh, which:
#   1. generates soc-repo/moto_product.bzl  (mmi_product_name="blanc", mmi_product_type="g")
#      from the product arg  -> this file is NOT in the published tree; the wrapper creates it,
#      and without it the canoe target can't select the blanc product/DTBs.
#   2. invokes the kleaf build for the canoe target.
#
#   variant: perf (pristine baseline that MUST boot first) | consolidate (dev, KMI enforcement off)
#
# Output dist: out/msm-kernel-canoe-<variant>/dist/  (Image, *.dtb, *.dtbo, vendor_dlkm.img,
#              rebuilt modules incl. sched_walt.ko).
set -euo pipefail

VARIANT="${1:-perf}"
WORKDIR="${2:-$HOME/kp-canoe}"
PRODUCT="${PRODUCT:-blanc_g}"     # -> mmi_product_name=blanc, mmi_product_type=g
KP="$WORKDIR/kernel_platform"
cd "$KP"

# Moto's wrapper. Args: <product> <target> <variant>   (product=blanc_g, target=canoe)
# It reproduces Moto's stock vermagic via KLEAF_USE_KLEAF_LOCALVERSION.
echo ">> build_kernel_product.sh $PRODUCT canoe $VARIANT   (root: $KP)"
export KLEAF_USE_KLEAF_LOCALVERSION=true
if [ -x build/kernel/build_kernel_product.sh ]; then
  ./build/kernel/build_kernel_product.sh "$PRODUCT" canoe "$VARIANT"
else
  echo "!! build/kernel/build_kernel_product.sh missing — is the Moto build/kernel override synced? Falling back to raw driver."
  echo "!! (raw driver skips moto_product.bzl generation — generate it manually if the build errors on mmi_product_name)"
  ( cd soc-repo && python3 build_with_bazel.py -t canoe "$VARIANT" --skip abl )
fi

DIST="$KP/out/msm-kernel-canoe-$VARIANT/dist"
echo; echo ">> dist: $DIST"
ls -la "$DIST"/Image "$DIST"/*.img 2>/dev/null || true
echo; echo ">> vermagic (must equal stock 6.12.38-android16-5-g1d46253471dd-ab15048002-4k):"
strings "$DIST/Image" 2>/dev/null | grep -m1 '6\.12\.38-android16' || echo "   (Image not found)"
