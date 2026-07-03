#!/usr/bin/env bash
# Build the canoe (Razr Fold 2026 / blanc) kernel from the assembled tree.
#
# Two paths — pick with the first arg:
#   pristine    : unmodified Moto canoe PERF kernel (baseline that must boot before ANY mod)
#   consolidate : dev variant, KMI enforcement off (use while iterating on mods)
#
# Output dist: out/msm-kernel-canoe-<variant>/dist/  (Image, *.dtb, *.dtbo, vendor_dlkm.img,
#              and the rebuilt modules incl. sched_walt.ko).
set -euo pipefail

WORKDIR="${2:-$HOME/kp-canoe}"
VARIANT="${1:-perf}"     # perf (pristine) | consolidate (dev)
cd "$WORKDIR/kernel_platform/soc-repo"

# build_with_bazel.py passes unknown flags through to Bazel (parse_known_args).
# KLEAF_USE_KLEAF_LOCALVERSION=true reproduces Moto's stock vermagic stamp
# (6.12.38-android16-5-g1d46253471dd-...), which stock vendor_dlkm modules gate on.
echo ">> Building canoe $VARIANT from $(pwd)"
KLEAF_USE_KLEAF_LOCALVERSION=true python3 build_with_bazel.py -t canoe "$VARIANT" --skip abl

DIST="$WORKDIR/kernel_platform/out/msm-kernel-canoe-$VARIANT/dist"
echo
echo ">> dist: $DIST"
ls -la "$DIST"/Image "$DIST"/*.img 2>/dev/null || true
echo
echo ">> vermagic (must equal stock 6.12.38-android16-5-g1d46253471dd-ab15048002-4k):"
strings "$DIST/Image" 2>/dev/null | grep -m1 '6\.12\.38-android16' || echo "   (Image not found)"
