# razr-fold-2026-kernel-build

Clean, reproducible build harness for the **Motorola Razr Fold 2026** kernel — built **from
Motorola's published OSS**, assembled correctly via `repo` manifest (no hand-cloning).

| | |
|---|---|
| Device | Motorola Razr Fold 2026, codename **blanc** |
| SoC | Snapdragon **SM8845 / canoe** (8-Elite class) |
| Android build | `motorola/blanc_g/blanc:16/W3WB36.36-48-5` |
| Kernel | GKI **6.12.38-android16-5** |
| Moto OSS branch | `android-16-release-w3wb36.36-48-5` (28 repos, org `MotorolaMobilityLLC`) |
| GKI ACK pin | `android16-6.12-2025-09_r15` (SHA `74ad4605221549423a507537bdd3503ee11d38e2`) |
| Source request | MotorolaMobilityLLC/kernel-msm#836 (published) |

## Why this repo exists (start-over rationale)
Earlier attempts assembled `kernel_platform/` by hand-cloning ~30 repos, mixing in the OnePlus
SM8845 tree to fill gaps, and never had a provably-correct layout — every flashed result
bootlooped. This harness fixes the *assembly*: everything is pinned to the **immutable build tag
`MMI-W3WB36.36-48-5`** (the exact W3WB36.36-48-5 build point) and overlaid at **evidence-verified
paths**. Deterministic, re-runnable, diffable.

**The likely root cause it fixes:** Moto's GKI `common` is **1,116 commits ahead** of pristine
AOSP GKI — the shipped kernel is Moto's *patched* common, not stock GKI. A prior "pristine" build
compiled stock `//common:kernel_aarch64` and only *looked* correct because it hardcoded the stock
`SCMVERSION` stamp; the real code (and thus every exported-symbol CRC) differed, so factory
`vendor_dlkm` modules were rejected → bootloop. This manifest pulls `common` from Moto's
`kernel-common` at the tag. See `docs/SOURCES.md`.

## Layout strategy
- **Base** = AOSP GKI kernel manifest at `android16-6.12-2025-09_r15`. Provides `common/`,
  `build/kernel`, `external/*`, `prebuilts/clang`, `dtc`, `kleaf` — Google-pinned and mutually
  consistent, so the fragile Bazel/Kleaf build infra is never hand-assembled. (Moto's own
  `kernel_platform-external-*` forks sit on a *different* device's release branch and are just
  mirrors of these — so we use Google's canonical, matching set.)
- **Overlay** (`manifests/moto-canoe.xml`) = Moto's vendor source at the release branch:
  `soc-repo` (kernel-msm), `qcom/opensource/*`, `*-devicetree`, `motorola-kernel-modules`,
  techpacks — and overrides `common/` with Moto's `kernel-common` fork.

## Usage (on a NATIVE x86-64 Linux host — WSL2 Ubuntu)
> Apple Silicon can't run the AOSP x86-64 clang under emulation (it segfaults). Build on the PC.
```bash
# deps: git curl python3 python-is-python3 unzip zip rsync bc bison flex libssl-dev libelf-dev make gcc g++
#       + `repo` (https://storage.googleapis.com/git-repo-downloads/repo)
scripts/bootstrap.sh            # assemble the tree at ~/kp-canoe/kernel_platform  (~60GB sync)
scripts/build.sh perf           # PRISTINE canoe PERF kernel  -> out/msm-kernel-canoe-perf/dist/
```
The pristine PERF build **must boot before any modification.** See `docs/FLASH-AND-BOOTLOOP.md`
for the flashing rules that actually matter (they are why prior builds looped) and the recovery
path.

## Pristine → modified
`manifests/moto-canoe.xml` pins Moto **upstream** for a clean-room baseline. To layer changes
(e.g. the Lindroid LXC/EVDI work), repoint the relevant projects to your `zorrobyte` forks in a
second local manifest and rebuild `consolidate`. Do the baseline first.

## Docs
- `docs/FLASH-AND-BOOTLOOP.md` — the proven root cause of every past bootloop + the correct flash
  recipe (matched vendor_dlkm + verity off, or a MODVERSIONS=n kernel), and recovery.
- `docs/SOURCES.md` — the full verified repo→path map with evidence.
