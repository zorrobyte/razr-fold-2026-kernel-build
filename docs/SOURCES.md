# Source tree — verified repo → path map

All Motorola repos are pinned to the **immutable build tag `MMI-W3WB36.36-48-5`** (the exact
W3WB36.36-48-5 build point), not the release branch (which keeps moving). Every repo below was
confirmed to carry that tag. ROOT_DIR = `kernel_platform/` = the Bazel workspace root `//`.

## Why the tag + the common override matter (root-cause of prior bootloops)
- Moto's `kernel-common` is **1,116 commits ahead** of the pristine AOSP ACK base
  (`74ad4605…` / `android16-6.12-2025-09_r15`). The shipped kernel is Moto's *patched* common,
  not stock GKI. Building stock GKI → different exported-symbol CRCs → the ~600 factory
  `vendor_dlkm` modules fail `check_version()` → first-stage mount fails → bootloop.
- The prior "exact stock vermagic" was **forced** by hardcoding
  `SCMVERSION="-g1d46253471dd-ab15048002"` in `workspace_status.json`. That hash isn't in the
  public tree (Moto re-hashes on publish), so it can never come from a real `git describe` — it
  only satisfied the vendor modules' vermagic *string* check while the actual code/CRCs still
  differed (proven: pristine Image was 4,096 B smaller than factory, different sha256).
- Fix: pull `common` from **Moto's kernel-common** at the tag, and pin the whole tree so it's
  byte-reproducible. Confirm on the old PC tree with:
  `git -C ~/kp-canoe/kernel_platform/common rev-list --count 74ad4605..HEAD` (0 ⇒ it was pristine GKI = the bug).

## Base (from AOSP GKI manifest @ `android16-6.12-2025-09_r15`)
Provides `prebuilts/clang` (toolchain), `external/dtc`, `prebuilts/*`, and standard build deps —
Google-pinned and consistent. We override only what Moto forked (below).

## Overlay (Moto @ tag `MMI-W3WB36.36-48-5`)
| repo | path | evidence |
|---|---|---|
| kernel-common | `common` (overrides AOSP `kernel/common`) | +1116 commits vs ACK; the actual shipped GKI |
| kernel_platform-build-kernel | `build/kernel` (overrides AOSP `kernel/build`) | has `build_kernel_product.sh` + Moto kleaf tweaks |
| kernel-msm | `soc-repo` | `build.config.msm.canoe` sources `${ROOT_DIR}/soc-repo/...`; build driver `soc-repo/build_with_bazel.py` |
| kernel-devicetree | `soc-repo/arch/arm64/boot/dts/vendor` | `msm_kernel_extensions.bzl` loads `//soc-repo/arch/arm64/boot/dts/vendor:...`; repo defines `kernel_dtstree(name="msm_dt")` + `qcom/canoe-blanc-base.dts` |
| vendor-qcom-opensource-{audio,bt,dsp,eva,graphics,securemsm,spu,synx,camera}-kernel | `vendor/qcom/opensource/<name>-kernel` | Bazel `//vendor/qcom/opensource/...` labels in techpack `.bzl`; OnePlus SM8845 mirror |
| vendor-qcom-opensource-wlan-platform | `vendor/qcom/opensource/wlan/platform` | qcacld `.bzl` refs `//vendor/qcom/opensource/wlan/platform:*_cnss2` |
| vendor-qcom-opensource-wlan-qcacld-3.0 | `vendor/qcom/opensource/wlan/qcacld-3.0` | is the qcacld package emitting those labels |
| vendor-qcom-opensource-wlan-qca-wifi-host-cmn | `vendor/qcom/opensource/wlan/qca-wifi-host-cmn` | standard CLO wlan/ layout; OnePlus mirror |
| kernel-{audio,bt,data,display,dsp,eSE,mm,nfc,video,camera}-devicetree | `vendor/qcom/opensource/<x>-devicetree` | OnePlus SM8845 + audio-devicetree Makefile convention (see caveat) |
| kernel-wlan-devicetree | `vendor/qcom/opensource/wlan/wlan-devicetree` | nested under `wlan/`; OnePlus mirror |
| kernel-msm-5.4-techpack-display | `vendor/qcom/opensource/display-drivers` | self-refs `:display_drivers_headers`; OnePlus `display-drivers` (msm/, rotator/, hdcp/) |
| kernel-msm-techpack-dataipa | `vendor/qcom/opensource/dataipa` | `define_modules.bzl` sibling refs; OnePlus mirror |
| motorola-kernel-modules | `motorola/kernel/modules` | `kernel-msm/BUILD.bazel` refs `//motorola/kernel/modules:moto_kconfigs_group`; repo defines exactly that target |

## Build entry point
`scripts/build.sh perf` → runs Moto's `build/kernel/build_kernel_product.sh blanc_g canoe perf`,
which generates `soc-repo/moto_product.bzl` (`mmi_product_name="blanc"`, `mmi_product_type="g"`)
and builds `//soc-repo:canoe_perf_dist` → `out/msm-kernel-canoe-perf/dist/`. `blanc` is a *product
of the canoe target*, selected via `configs/ext_config/moto-canoe-blanc.config` (`CONFIG_BLANC_DTB=y`).

## Open items (verify empirically — repo sync / build will error loudly, not silently)
1. **Subsystem-DT placement** (`kernel-*-devicetree` → `vendor/qcom/opensource/<x>-devicetree`) rests
   on OnePlus (same SoC) + convention; Moto *relocated the main DT* into `soc-repo`, so there's a small
   chance the subsystem DTs are also under `soc-repo/arch/arm64/boot/dts/vendor/qcom/`. If DTBs fail to
   build, try that alternative.
2. **Referenced-but-unpublished siblings:** techpack display/dataipa `.bzl` reference
   `vendor/qcom/opensource/{mm-drivers,mmrm-driver,datarmnet,datarmnet-ext}` — Moto did NOT publish these
   as repos, so the canoe *product* config likely doesn't build those targets (or uses prebuilts). Don't
   add them unless a build error names them.
3. **Optional fidelity overrides:** Moto also tagged `kernel_platform-build-bazel_common_rules` and the
   `kernel_platform-external-{lz4,pigz,toybox,zlib,zopfli,bazelbuild-*,bazel-contrib-*}` repos. We take
   these from AOSP (generic, identical in practice). If a build discrepancy points at them, override with
   the Moto forks at the tag (`external/<name>`, `external/bazelbuild/<name>`, etc.).
