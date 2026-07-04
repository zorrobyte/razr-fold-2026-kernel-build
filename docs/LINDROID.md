# Lindroid (Linux-on-droid) kernel enablement

**Status: boot-verified working** on the Razr Fold 2026. The from-source kernel boots to home with
audio/BT/Wi-Fi/NFC **and** the full container stack: all 9 configs live, `unshare --user --pid --ipc
--uts --fork` works, EVDI loads (`/sys/module/evdi` v1.0.0, `/dev/dri/card0` + `renderD128`), and the
stock `sched_walt` module does not crash (the `task_struct` ABI is preserved — see below).

This kernel is patched to satisfy the **kernel-side** requirements for
[Lindroid](https://github.com/Linux-on-droid) — running a real Linux distro in an LXC container
alongside Android, sharing this kernel, with a virtual DRM display. Everything here is injected by
`scripts/build.sh` at build time (idempotent; a fresh `bootstrap.sh` resets the tree and the next
build re-applies). Set `LINDROID=0` in the environment to build a plain kernel without it.

> **Scope:** this repo is the *kernel*. The rest of a Lindroid port is AOSP-side
> (`Linux-on-droid/vendor_lindroid`: the LXC container daemon, the HWComposer-emulation HAL, and
> libhybris) and is **not** covered here.

## What the docs require
Per `Linux-on-droid/vendor_lindroid` (kernel section), a device kernel needs:

```
CONFIG_SYSVIPC=y   CONFIG_UTS_NS=y   CONFIG_PID_NS=y   CONFIG_IPC_NS=y
CONFIG_USER_NS=y   CONFIG_NET_NS=y   CONFIG_CGROUP_DEVICE=y
CONFIG_CGROUP_FREEZER=y   CONFIG_DRM_LINDROID_EVDI=y
```

On our GKI base, `UTS_NS`, `NET_NS`, `CGROUP_FREEZER` (plus `NAMESPACES`, `CGROUPS`, `MEMCG`,
`OVERLAY_FS`, `ANDROID_BINDER_IPC`/`BINDERFS`, `DRM`, `VETH`, `BRIDGE`, `FUSE_FS`) are already `=y`.
The rest are enabled here.

## 1. Container configs — as a **base** defconfig fragment (not a device fragment)
`configs/lindroid_gki.fragment` (plain `CONFIG_x=y`) is dropped into
`common/arch/arm64/configs/` and attached to **`//common:kernel_aarch64`** via
`pre_defconfig_fragments`, and `build.sh` patches `common/BUILD.bazel` to set
`check_defconfig = "disabled"` on that target (savedefconfig would otherwise reject the added
options).

**Why the base kernel and not Moto's `moto-canoe.config` device fragment?** These are
ABI-affecting core-kernel options. The clearest example: enabling `CONFIG_USER_NS` turns
`from_kuid_munged()` from a `static inline` (in `uidgid.h`) into a real `EXPORT_SYMBOL` in
`kernel/user_namespace.c`. The device build uses `//common:kernel_aarch64` as its `base_kernel`, and
vendor DDK modules link against the **base** `Module.symvers`. If the option only lives in the device
config, a module compiled with `USER_NS=y` (e.g. `msm_sysstats`, which calls `from_kuid_munged`)
links against a base built `USER_NS=n` and fails modpost:

```
modpost: "from_kuid_munged" [msm_sysstats.ko] undefined!
```

Enabling the options on the base keeps base vmlinux + symvers + device modules consistent. The
`--notrim` build (see main README, finding #3) is required anyway and conveniently disables the KMI
strict-symbol check that would otherwise reject the newly-exported symbols.

Also enabled: `CONFIG_SQUASHFS` (+ XZ/ZSTD) for compressed container rootfs images.

### Namespace symbol exports
Enabling the namespace configs makes GKI modules reference namespace symbols that the ACK source
leaves **un-exported**, breaking modpost. `build.sh` appends the needed `EXPORT_SYMBOL()`s to the base
kernel (idempotent):
- `CONFIG_IPC_NS` → `rust_binder.ko` needs `put_ipc_ns` (`ipc/namespace.c`) and `init_ipc_ns`
  (`ipc/msgutil.c`):
  ```
  modpost: "put_ipc_ns" [drivers/android/rust_binder.ko] undefined!
  ```
- `CONFIG_USER_NS`'s `from_kuid_munged` is already `EXPORT_SYMBOL`'d, so no patch is needed there once
  the option is on the base kernel (see above).

## 2. EVDI virtual-display driver — vendored in-tree
`CONFIG_DRM_LINDROID_EVDI=y` needs the driver. We vendor
[`Linux-on-droid/lindroid-drm-loopback`](https://github.com/Linux-on-droid/lindroid-drm-loopback)
under `lindroid/evdi/` at a pinned commit (see `lindroid/evdi/PINNED_COMMIT.txt`). `build.sh` copies
it to `common/drivers/gpu/drm/lindroid/`, appends `source "drivers/gpu/drm/lindroid/Kconfig"` to the
DRM `Kconfig`, and `obj-$(CONFIG_DRM_LINDROID_EVDI) += lindroid/` to the DRM `Makefile`. Built-in
(`=y`) to sidestep GKI module-list checks and module packaging.

### 6.12 compat patches (kept in the vendored source)
The upstream driver needed two small fixes for kernel 6.12, applied in
`lindroid/evdi/evdi_lindroid_drv.c` and version-guarded so it still builds on older kernels:
- **`DRM_UNLOCKED` removed** (>=6.8, all DRM ioctls are unlocked): shimmed to `0` when undefined.
- **`platform_driver::remove` returns `void`** (>=6.11, was `int`): guarded with
  `KERNEL_VERSION(6, 11, 0)`.

## The GKI ABI wall (and how we get past it)
Enabling the container configs on a device that must keep **prebuilt stock proprietary modules**
(we can't rebuild `vendor_dlkm` — Moto didn't publish those sources) hits a hard wall that standard
Lindroid ports avoid by rebuilding *everything*. Diagnosed over several boot attempts (pstore):

1. **`module_layout` CRC shift.** Container configs change core structs, so the global module-ABI CRC
   changes (`0xe976b219` → `0xe351f8ce`). With `MODVERSIONS=y` every stock module is rejected
   (*"disagrees about version of symbol module_layout"*) → no storage → first-stage-mount panic.
   Disabling `MODVERSIONS` is worse: vermagic loses the `modversions` token → modules ENOEXEC.
   **Fix:** keep `MODVERSIONS=y` and patch `kernel/module/version.c` so `check_version()`'s
   `bad_version` path warns instead of failing — force-load stock modules by name (`build.sh` applies
   this; `same_magic()` still matches vermagic since CRCs are present).

2. **`task_struct` layout shift → `sched_walt` crash.** Force-loading exposes the real problem:
   `CONFIG_SYSVIPC` inserts `sysvsem`/`sysvshm` into `task_struct` **before** `android_vendor_data`,
   shifting every following offset. The stock `sched_walt` module reads `android_vendor_data` at the
   frozen offset → **NULL-deref panic at `task_fits_capacity` @0.6 s**. **Fix
   (`lindroid/patches/task_struct-sysvipc-kabi.patch`):** relocate those 24 bytes out of their inline
   position into the free `ANDROID_KABI_RESERVE(1..3)` slots (which sit *after* `android_vendor_data`),
   so `task_struct` is byte-identical to the frozen `SYSVIPC=off` GKI ABI. Verified with `pahole`:
   `android_vendor_data1` stays at the same offset as a clean `SYSVIPC=off` build. This is GKI's own
   mechanism for adding fields without breaking the KMI.

If a *different* stock module crashes on boot, it reads another struct that a container config shifted
— apply the same `ANDROID_KABI_RESERVE` relocation to that struct's added field(s).

## Verify (on the running kernel, with `su`)
```bash
zcat /proc/config.gz | grep -E 'USER_NS|PID_NS|IPC_NS|SYSVIPC|CGROUP_DEVICE|SQUASHFS=|DRM_LINDROID_EVDI'
unshare --user --pid --ipc --uts --net --mount-proc true && echo "namespaces OK"
ls -l /sys/module/evdi 2>/dev/null            # EVDI driver present
```

## Files
- `configs/lindroid_gki.fragment` — base defconfig fragment (the 9 options + squashfs)
- `lindroid/evdi/` — vendored EVDI driver (pinned) + 6.12 compat patches
- `scripts/build.sh` — section `0)` does the injection (driver + fragment + `BUILD.bazel` patch)
