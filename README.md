# razr-fold-2026-kernel-build

Clean, reproducible build harness for the **Motorola Razr Fold 2026** kernel — built **from
Motorola's published OSS**, assembled correctly via `repo` manifest (no hand-cloning).

> ### 👉 Continuing this work? Read **[CONTINUE-HERE.md](CONTINUE-HERE.md)** first.
> It's a literal step-by-step runbook (build → flash → verify) that needs no prior context and no
> guesswork — including the exact mistakes NOT to repeat and how to recover a bootloop in ~30 s.

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

**Root cause — now VERIFIED (see [Verified findings & debugging](#verified-findings--debugging-2026-07-04) below).**
Earlier theory (that Moto's 1,116-commits-ahead `common` made the whole kernel's code/CRCs differ)
turned out to be wrong. The from-source kernel built from the tag `MMI-W3WB36.36-48-5` is
**ABI-identical to the shipped kernel except ONE config-driven symbol** (`vendor_data_pad`). All 660
stock modules load on it once that one config is right. The bootloops had two concrete causes: (1)
overriding `GKI_TASK_STRUCT_VENDOR_SIZE_MAX` away from its **default 512**, and (2) flashing the
**from-source `vendor_dlkm`**, which is missing proprietary modules. Keep the config default and flash
only the kernel over the **stock** `vendor_dlkm`. This manifest pulls `common` from Moto's
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

## Usage

### Native x86-64 Linux (WSL2 Ubuntu, or any Linux box) — fastest
```bash
# deps: git curl python3 python-is-python3 unzip zip rsync bc bison flex libssl-dev libelf-dev make gcc g++
#       + `repo` (https://storage.googleapis.com/git-repo-downloads/repo)
scripts/bootstrap.sh            # assemble the tree at ~/kp-canoe/kernel_platform  (~60GB sync)
scripts/build.sh perf           # PRISTINE canoe PERF kernel  -> out/msm-kernel-canoe-perf/dist/
```

### Apple Silicon Mac (via Colima + Rosetta 2) — verified working
The AOSP kernel toolchain is x86-64-only (no arm64 host clang), but **Rosetta 2 translates it
reliably** (confirmed: clang 19.x compiles+runs under Rosetta on M4 Max). The old "clang segfaults"
was *qemu* full-system emulation, not Rosetta. Build inside an amd64 container so Bazel picks the
linux-x86 clang, run by Rosetta:
```bash
scripts/mac-build.sh perf       # starts a Rosetta Colima VM if needed, builds in an amd64 container
```
Slower than native x86 (~1.5–3×) but very usable on an M-series with plenty of RAM/disk.
The pristine PERF build **must boot before any modification.** See `docs/FLASH-AND-BOOTLOOP.md`
for the flashing rules that actually matter (they are why prior builds looped) and the recovery
path.

## Pristine → modified
`manifests/moto-canoe.xml` pins Moto **upstream** for a clean-room baseline. To layer changes
(e.g. the Lindroid LXC/EVDI work), repoint the relevant projects to your `zorrobyte` forks in a
second local manifest and rebuild `consolidate`. Do the baseline first.

## Verified findings & debugging (2026-07-04)

The pristine PERF build is **ABI-identical to the shipped kernel except one config-driven symbol**.
Every past bootloop reduces to the two causes below — both now understood end-to-end.

### 1. `vendor_data_pad` — keep `GKI_TASK_STRUCT_VENDOR_SIZE_MAX` at its default (512)
The *only* exported-symbol CRC that differs between a from-source build and the shipped kernel is
`vendor_data_pad` — the dynamic task_struct vendor area, declared
`u64 vendor_data_pad[CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX / sizeof(u64)]` in `init/init_task.c`.
**Do not override this config.** The stock kernel *reports* `MAX=1024` but its array is actually
`u64[64]` (it sizes to the runtime `android_arch_task_struct_size=512` on the cmdline), giving CRC
`0xf54e5881`. The launch source at the **default 512** reproduces `0xf54e5881` exactly; forcing
`1024` yields `0xa4519653` and breaks 5 stock modules (`sched-walt`, `cpu_mpam`, `hung_task_enh`,
`minidump`, `qca_cld3_peach_v2`):
```
sched_walt: disagrees about version of symbol vendor_data_pad
init: Failed to load kernel modules
Kernel panic - not syncing: Attempted to kill init!
```
Gate before flashing (must print `0xf54e5881`):
```
grep -w vendor_data_pad out/msm-kernel-canoe-perf/dist/Module.symvers
```
This kernel uses **gendwarfksyms** (`CONFIG_GENDWARFKSYMS=y`, GENKSYMS off), so the CRC = the DWARF
concrete array size, not a source-string hash. To reverse-engineer which config value yields a target
CRC, build the in-tree `scripts/gendwarfksyms` standalone (needs `libdw-dev`; link `-lelf -ldw -lz`,
`-Iscripts/include`) and hash `u64 vendor_data_pad[N]` compiled with the **prebuilt clang** (not gcc —
their DWARF differs): `N=64 → 0xf54e5881`, `N=128 → 0xa4519653`.

### 2. Do NOT flash the from-source `vendor_dlkm` — keep the STOCK one
The from-source `vendor_dlkm` is **incomplete**: it lacks ~126 proprietary/prebuilt modules that
don't exist in OSS (`msm_drm` display, `msm_kgsl` GPU, touch `synaptics/goodix`, `cnss2`/wifi,
bt, `wcd*`/`lpass_*` audio, `mmi_*`/`utags`). Flashing it *deletes* the drivers needed to boot.
Instead flash **only `boot`** and keep the **stock** `vendor_dlkm` / `system_dlkm` / `vendor_boot` /
`dtbo`. Once finding #1 is correct, the from-source kernel is ABI-compatible with all 660 stock
modules. Extract the stock `vendor_dlkm` from the factory `super` with `simg2img` + `lpunpack`.
**vermagic/scmversion does NOT need to match** — with MODVERSIONS the version string isn't enforced
(stock ships a `g1d46…` kernel with `-maybe-dirty` modules); CRCs are what matter. So the
`--config=stamp` scmversion trick is unnecessary.

### Recovering a panicking kernel's console log (pstore / ramoops)
pstore lives in reserved RAM that **survives a warm reboot** — a `panic=-1` bootloop *is* a warm
reboot, so the dead kernel's console is still in RAM. **Do not battery-pull / hard-power-off** (that
clears it). Then boot a known-good kernel and read it (device is Magisk-rooted, so `su` works):
```
fastboot flash boot <stock boot.img> && fastboot reboot     # boot a kernel that works
adb shell su -c 'cat /sys/fs/pstore/console-ramoops-0'      # previous boot's full console + panic trace
adb shell su -c 'cat /sys/fs/pstore/dmesg-ramoops-0'        # + the crashed boot's dmesg
```
Text may have minor bit-flips but is readable; only the most-recent crashed boot is retained; if the
kernel dies *before* ramoops init you'll get an earlier boot instead. **This is how the
`vendor_data_pad` panic above was found** — with no other way to see why the kernel died.

### Shipped source is not public
The shipped kernel's `common` commit `g1d46253471dd` was never mirrored to GitHub (the API returns
`422 No commit found`); the published tag `MMI-W3WB36.36-48-5` = `950637f7a` is a *different* commit.
We don't need it — default-512 on the tag reproduces the shipped ABI — but the GPL
source-correspondence gap is filed at **MotorolaMobilityLLC/kernel-msm#849**.

## Docs
- `docs/FLASH-AND-BOOTLOOP.md` — the proven root cause of every past bootloop + the correct flash
  recipe (matched vendor_dlkm + verity off, or a MODVERSIONS=n kernel), and recovery.
- `docs/SOURCES.md` — the full verified repo→path map with evidence.
