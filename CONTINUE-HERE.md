# CONTINUE HERE — agent runbook (read this first, follow it literally)

> ## ✅ STATUS (2026-07-03): THE BUILD WORKS.
> `scripts/mac-build.sh perf` produces a complete from-source canoe PERF dist (Image +
> **matched vendor_dlkm.img** + dtb/dtbo/boot/vendor_boot) on an Apple Silicon Mac via Rosetta.
> Artifacts copied to **`~/Desktop/razr-lindroid/out-canoe-perf-macbuilt/`**. Vermagic is
> `6.12.38-android16-5-maybe-dirty-4k` (fine for Strategy-B flash — boot + vendor_dlkm share it).
> **Remaining work = FLASH IT (Step 3) when the Razr is on USB, then verify boot.** First kernel
> compile is ~5.5 h under Rosetta then cached (~20 min after); an occasional transient clang
> segfault (e.g. `af_vsock_tap.o`) just needs a re-run.

You are continuing a Motorola **Razr Fold 2026** kernel build. This file is a step-by-step runbook.
**Do not re-investigate or re-derive anything below — it is already proven.** Just execute the steps,
check the expected output, and follow the branch that matches what you see. When in doubt, prefer the
explicit command here over inventing your own.

---
## 0. Fixed facts (do not question these)
- **Device:** Motorola Razr Fold 2026, codename **blanc**, SoC **SM8845 / canoe**, Android build
  `W3WB36.36-48-5`. fastboot serial **`ZP2223437N`**. Active slot has been **`_b`**. Root = Magisk,
  and **Magisk lives in `init_boot`** — so flashing `boot` never removes root (safe to experiment).
- **The exact build tag on every Moto repo:** `MMI-W3WB36.36-48-5`. Everything is pinned to it.
- **Why past builds bootlooped (root cause, PROVEN):** Moto's GKI `common` is **1,116 commits ahead**
  of pristine AOSP GKI. The shipped kernel is Moto's *patched* common. Building pristine GKI →
  different module CRCs → factory `vendor_dlkm` modules rejected → mount fail → bootloop. This repo's
  manifest already fixes that (uses Moto `kernel-common`). See `docs/SOURCES.md`.
- **Because you cannot byte-reproduce the factory kernel**, you must flash the from-source kernel
  **together with the `vendor_dlkm.img` from the same build** and **disable verity**. Keeping the
  factory `vendor_dlkm` will bootloop. This is the single most important rule.

## DO NOT (these are the mistakes that already cost weeks)
- ❌ Do NOT flash `boot` only while keeping factory `vendor_dlkm` (CRC mismatch → loop).
- ❌ Do NOT build/flash pristine AOSP GKI `common` (use Moto's `kernel-common`, already in the manifest).
- ❌ Do NOT flash a from-source `dtbo` or `vendor_boot`. The from-source `dtbo` is tiny (~97 KB) vs
  factory ~75 MB and will strip hardware overlays → loop. **Keep factory `dtbo` and `vendor_boot`.**
- ❌ Do NOT "fix" a module-CRC mismatch by hacking `check_version()` — it loads then crashes. Disable
  verity + flash the matched `vendor_dlkm` instead.

---
## 1. Is a build already running / done? Check FIRST.
```bash
# is the Rosetta VM up?
colima status kbuild
# is a build container currently running?
docker ps --filter ancestor=ubuntu:24.04 --format '{{.ID}} {{.Status}} {{.Command}}'
# is the tree synced + is there a dist?
docker run --rm --platform=linux/amd64 -v kp-canoe:/k alpine \
  sh -c 'ls /k/kernel_platform/out/msm-kernel-canoe-perf/dist/ 2>/dev/null || echo NO_DIST_YET'
```
- **If a build container is running** → a build is in progress; wait, then re-check. (Its live log is
  written to the launching session's scratchpad — if you can't find it, just watch `docker ps` and the
  dist dir; the tree persists in the `kp-canoe` volume regardless.)
- **If you see `Image` + `vendor_dlkm.img` in the dist** → go to **Step 3 (flash)**.
- **If `NO_DIST_YET` and no container running** → go to **Step 2 (build)**.

## 2. Build the pristine PERF kernel
On the **Mac** (Apple Silicon, via Rosetta 2 — VERIFIED working):
```bash
cd ~/Desktop/razr-fold-2026-kernel-build
scripts/mac-build.sh perf        # assembles tree + builds in an amd64/Rosetta container
```
On a **native x86-64 Linux box / WSL2** (faster, zero-risk):
```bash
cd <this repo>
scripts/bootstrap.sh             # repo init AOSP GKI @ ACK tag + Moto overlay @ MMI-W3WB tag, sync ~60GB
scripts/build.sh perf            # -> out/msm-kernel-canoe-perf/dist/
```
**Success = ** `dist/Image` exists and its banner is exactly
`6.12.38-android16-5-g1d46253471dd-ab15048002-4k` (build.sh prints this).

### If the build ERRORS, match the message:
- **`repo sync` fails on a project path** → a subsystem-devicetree path may be wrong. Open
  `manifests/moto-canoe.xml`, find the failing repo, and try moving it under
  `soc-repo/arch/arm64/boot/dts/vendor/qcom/<name>` (Moto relocated the *main* devicetree there; some
  subsystem DTs may follow). Re-run `scripts/bootstrap.sh`. Details: `docs/SOURCES.md` "Open items #1".
- **Build error naming `mm-drivers` / `mmrm-driver` / `datarmnet`** → these siblings are referenced but
  Moto did NOT publish them; the canoe product normally doesn't build them. If a target insists,
  disable that target/module in the product config rather than inventing the repo. `docs/SOURCES.md` #2.
- **`build_kernel_product.sh: not found`** → the Moto `build/kernel` override didn't sync; re-run
  `scripts/bootstrap.sh` and confirm `docker ... -v kp-canoe:/k ... ls /k/kernel_platform/build/kernel/build_kernel_product.sh`.
- **A clang crash under Rosetta** (rare) → re-run once (Rosetta caches translations); if it persists on
  the same file, build on the WSL2 x86 PC instead (native, no translation).

### Copy the artifacts out of the docker volume to the Mac:
```bash
mkdir -p ~/Desktop/razr-lindroid/out-fresh
docker run --rm --platform=linux/amd64 -v kp-canoe:/k -v ~/Desktop/razr-lindroid/out-fresh:/o alpine \
  sh -c 'cp /k/kernel_platform/out/msm-kernel-canoe-perf/dist/Image /o/ ; \
         cp /k/kernel_platform/out/msm-kernel-canoe-perf/dist/vendor_dlkm.img /o/ 2>/dev/null; \
         cp /k/kernel_platform/out/msm-kernel-canoe-perf/dist/*.img /o/ 2>/dev/null; ls -la /o'
```
You need at least: a **boot.img** (repack the dist `Image` into the stock boot.img — see
`~/Desktop/razr-lindroid/recovery/STOCK-KERNEL-SANITY.md` for the exact repack recipe) and the
matching **`vendor_dlkm.img`**.

## 3. Flash (ONLY with the device physically here; confirm with the user first)
This is destructive-ish but recoverable in ~30 s (Magisk survives in init_boot). **Confirm the user
wants to flash and that the Razr `ZP2223437N` is on USB before doing anything.**

Use the matched-set + verity-off recipe. Full detail in `docs/FLASH-AND-BOOTLOOP.md`. Short form:
```bash
export PATH="$HOME/Library/Android/sdk/platform-tools:$PATH"
adb reboot bootloader; fastboot devices          # expect ZP2223437N
fastboot flash boot   <fresh boot.img>
fastboot --disable-verity --disable-verification flash vbmeta        <factory vbmeta.img>
fastboot --disable-verity --disable-verification flash vbmeta_system <factory vbmeta_system.img>
fastboot reboot fastboot                         # userspace fastboot (dynamic partitions)
fastboot flash vendor_dlkm <fresh vendor_dlkm.img>
fastboot reboot
# KEEP factory dtbo + vendor_boot — do not flash the from-source ones.
```
Factory vbmeta/vbmeta_system and a known-good stock boot backup are in
`~/Desktop/razr-lindroid/out/` and `~/Desktop/razr-lindroid/recovery/`.

### If it boots:
```bash
adb shell getprop sys.boot_completed            # 1
adb shell su -c 'dmesg | grep -iE "disagrees|module.*version|vendor_dlkm"'   # should be clean
```
That's the milestone: **a from-source kernel boots.** Then Phase 2 = re-add the Lindroid mods (LXC
namespaces + EVDI) by repointing the manifest's `common`/`soc-repo` to the `zorrobyte` forks with
those patches, and rebuild `consolidate`. Context for Lindroid: `~/Desktop/razr-lindroid/`.

### If it bootloops (recover, ~30 s):
```bash
fastboot flash boot ~/Desktop/razr-lindroid/recovery/boot-stock-backup.img
fastboot flash vbmeta        ~/Desktop/razr-lindroid/out/vbmeta-FACTORY.img
fastboot flash vbmeta_system ~/Desktop/razr-lindroid/out/vbmeta_system-FACTORY.img
fastboot reboot fastboot && fastboot flash vendor_dlkm ~/Desktop/razr-lindroid/recovery/vendor_dlkm_STOCKbak.img
fastboot reboot
# then pull the crash log to diagnose:
adb wait-for-device; adb shell su -c 'cat /sys/fs/pstore/console-ramoops-0' > /tmp/crash.txt
```

---
## Map of this repo
- `manifests/moto-canoe.xml` — the tree (tag-pinned Moto overlay + AOSP base). Edit here to change sources.
- `scripts/bootstrap.sh` — assemble tree. `scripts/build.sh` — build. `scripts/mac-build.sh` — build on Mac via Rosetta.
- `docs/SOURCES.md` — verified repo→path map, root cause, open items.
- `docs/FLASH-AND-BOOTLOOP.md` — flash recipe, the dtbo hazard, recovery.
- Prior effort + all factory images / backups: `~/Desktop/razr-lindroid/` (out/, recovery/).
