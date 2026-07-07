# Replicating GPU-accelerated Lindroid on Motorola Razr Fold 2026 (blanc)

First-ever GPU-accelerated Lindroid (Linux-in-LXC with KDE Plasma) on this SoC:
**SM8845 (canoe), Adreno 829, Android 16 / LineageOS 23.2**. This document is the
1:1 recovery guide â€” every change needed to rebuild the working state from scratch.

Adreno 829 has **no open driver** (Turnip/freedreno don't support A8xx, no Mesa
driver), so the GPU is reachable only via Qualcomm's bionic blob through
**libhybris**. That path had never worked on A16 until the fixes below.

## Repos / branches / key commits

| Repo | Branch | What |
|---|---|---|
| `zorrobyte/libhybris` | `blanc-a16` | glibc/container libhybris. **`39a9693` = the `__cfi_slowpath` GPU-crux fix** |
| `zorrobyte/vendor_lindroid` | `blanc-a16` | `334cd41` = **dispd** (native Android EVDIâ†’composer consumer) |
| `zorrobyte/razr-fold-2026-kernel-build` | `main` | kernel + evdi-lindroid driver. `50bbb5c` = evdi_gem mmap-pin fix |
| LineageOS device/vendor tree | â€” | `lineage_blanc-bp4a-userdebug` (build combo) |

## THE GPU crux fix (this is the one that unlocked everything)

**Symptom:** `eglInitialize` SIGSEGV deep in the hybris-loaded Adreno/QTI stack;
kwin died with `KCrash crashRecursionCounter=2`. Two earlier theories (SnapAlloc
`FETCH_ISnapAlloc` dlsym; TLS) were WRONG â€” both resolve fine.

**Root cause:** Qualcomm vendor graphics libs (gralloc/snapalloc/adreno) are built
with **CFI (Control Flow Integrity)**. On every indirect call they invoke
`__cfi_slowpath`, exported by the real bionic `libdl.so`, which reads the CFI
shadow. That shadow is never initialized in the hybris/glibc process, so the read
(`ldrh w8,[x9,x8]`) faults. libhybris hooked `dlsym`/`dlopen`/`dladdr` but **not
`__cfi_slowpath`**, so it fell through to the real apex libdl â†’ crash.

**Fix (`zorrobyte/libhybris` `39a9693`, `hybris/common/hooks.c`):** add no-op hooks
for `__cfi_slowpath`/`__cfi_slowpath_diag` (CFI is hardening, not functional):
```c
static void _hybris_hook___cfi_slowpath(unsigned long long, void *) {}
static void _hybris_hook___cfi_slowpath_diag(unsigned long long, void *, void *) {}
// in hooks_common[], after HOOK_INDIRECT(dladdr):
    HOOK_INDIRECT(__cfi_slowpath),
    HOOK_INDIRECT(__cfi_slowpath_diag),
```
Result: `eglInitialize` returns `Android META-EGL 1.5`; kwin creates a live GLES2
context on the Adreno GPU and no longer crashes.

## libhybris build + deploy loop (container-native, aarch64 glibc)

The container has gcc/g++/make/autoconf/automake/libtoolize. Configured tree on
the device at `/root/build/libhybris/hybris/` (configure opts recorded in its
`config.status`: `--enable-wayland --with-android-headers=/root/android-headers
--enable-experimental --enable-glvnd --enable-lindroid-drm --enable-arch=arm64
--enable-adreno-quirks` â€¦). To land a libhybris change:
```
edit /root/build/libhybris/hybris/common/hooks.c   # or common/q/*.cpp for the linker
cd /root/build/libhybris/hybris && make             # gralloc/ target errors later â€” harmless
cp -a /usr/lib/aarch64-linux-gnu/libhybris-common.so.1.0.0{,.bak}
cp -f common/.libs/libhybris-common.so.1.0.0 /usr/lib/aarch64-linux-gnu/libhybris-common.so.1.0.0
```
Diagnose with `/root/egltest2.c` (`gcc egltest2.c -o egltest2 -lEGL -lgbm`; run with
`EGL_PLATFORM=lindroid-drm GBM_BACKEND=hybris __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_libhybris.json`).
libhybris-common.so on-device has full debug info â†’ gdb-debuggable (no rebuild to inspect).

## kwin fix â€” the other historical wall

`kwin_wayland` failed with `Could not load Qt platform plugin
"wayland-org.kde.kwin.qpa"` for weeks. Root cause: `/usr/bin/kwin_wayland` is a
wrapper that `exec`s `kwin_wayland.bin`, so `applicationFilePath()` ends in `.bin`
and kwin's QPA self-check (`endsWith("kwin_wayland")`) refuses to load. **Fix: set
`KWIN_FORCE_OWN_QPA=1`.** `/usr/bin/kwin_wayland` (container):
```bash
#!/bin/bash
unset QT_QPA_PLATFORM
export HYBRIS_PATCH_TLS=1
export KWIN_FORCE_OWN_QPA=1
exec /usr/bin/kwin_wayland.bin "$@"
```

## Greeter config â€” `/etc/sddm.conf.d/plasma-wayland.conf` (container)
```
[General]
DisplayServer=wayland
GreeterEnvironment=QT_QPA_PLATFORM=wayland,QT_WAYLAND_SHELL_INTEGRATION=xdg-shell,KWIN_COMPOSE=O2ES,KWIN_FORCE_OWN_QPA=1,KWIN_DRM_DEVICES=/dev/dri/by-path/platform-evdi-lindroid.0-card,GBM_BACKEND=hybris,__GLX_VENDOR_LIBRARY_NAME=libhybris,__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_libhybris.json,EGL_PLATFORM=lindroid-drm,HYBRIS_PATCH_TLS=1
[Wayland]
CompositorCommand=kwin_wayland --no-global-shortcuts --no-lockscreen --inputmethod maliit-keyboard --locale1
```

## dispd â€” native Android EVDIâ†’composer consumer (replaces create-disp/libhwc2)

`vendor/lindroid/dispd/` in `zorrobyte/vendor_lindroid` blanc-a16. Runs as a native
bionic Android process â†’ zero libhybris on the frame hand-off path. Owns gralloc
allocation (`AHardwareBuffer`), drives the EVDI poll loop, and calls
`vendor.lindroid.composer` directly. **Drops DRM master** after opening the evdi
card so the container's kwin holds KMS master.
```
m lindroid_dispd                                   # combo lineage_blanc-bp4a-userdebug
adb push out/.../system_ext/bin/lindroid_dispd /data/local/tmp/
# container-side create-disp.service is masked (dispd replaces it)
```

## Runtime bring-up sequence (order matters)
1. User starts the container from the LindroidUI app (composer service registers).
2. Foreground the app's DisplayActivity (stable composer surface).
3. Start dispd AFTER the composer is live: `/data/local/tmp/lindroid_dispd --card /dev/dri/card1 --display 0`
   (it re-binds the composer; on every container bounce dispd must be restarted â€” the composer
   is re-created and dispd's binding goes stale).
4. Start the greeter: `systemctl restart sddm` in the container.
   kwin loads its QPA, takes the seat, grabs KMS master, inits Adreno EGL (via the CFI-fixed
   libhybris), and composites to the evdi output.

## Kernel (evdi-lindroid)
- `CONFIG_DRM_LINDROID_EVDI=y` (built into the kernel, `arch/arm64/configs/lindroid_gki.fragment`).
- Prior fix: `FOP_UNSIGNED_OFFSET` on the evdi drm fops (kernel 6.12 open() EINVAL).
- `50bbb5c`: `evdi_gem` pins backing pages on the initial mmap (dumb-buffer SIGBUS fix; needed
  only for CPU/software rendering, not the GPU path).

## Status (2026-07-06)
- **DONE:** GPU EGL init works; kwin renders via Adreno GPU; kwin scans out `fb` to the
  active evdi CRTC (`crtc-0 enable=1 active=1`); dispd allocates the GBM swapchain. All fixes
  pushed to GitHub.
- **REMAINING â€” display not yet visible:** evdi isn't emitting the `swap_to` event to dispd
  after kwin's page-flip, so nothing presents to the app surface (black). Suspect the
  `bound_generation` gate in `evdi_modeset.c` (many dispd reconnects) or the flush path. Needs
  evdi debug logging + kernel reflash to pin down.
- **REMAINING:** container networking (fwmark routing to Android's active uplink â€” blocked while
  the phone has no uplink), GApps on host Android, LindroidUI app polish + dispd-lifecycle
  orchestration so the manual dispd restart isn't needed.
