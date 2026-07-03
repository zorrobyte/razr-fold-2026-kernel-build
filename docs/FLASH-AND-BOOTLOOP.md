# Flashing & the bootloop root cause (read before flashing anything)

## Root cause of every past bootloop
A from-source kernel has **different per-symbol CRCs** than the shipping kernel
(`CONFIG_MODVERSIONS=y`). The ~600 factory `vendor_dlkm` modules were built against the factory
kernel's CRCs, so a stock-config from-source kernel makes them fail `check_version()` →
first-stage mount fails → panic → bootloop. **This is true even for a pristine, unmodified Moto
build** (proven: pristine Image loops too). Therefore **flashing boot-only while keeping the
factory `vendor_dlkm` cannot work** with a stock `MODVERSIONS=y` kernel. The fix is at flash time,
not (only) build time.

## Three correct options, in order of preference
1. **Matched set + verity off (most robust).** Flash the from-source `boot` **and** the
   `vendor_dlkm.img` from the *same dist* (CRCs agree by construction) **and** disable AVB so the
   custom vendor_dlkm mounts:
   ```
   fastboot flash boot   boot.img
   fastboot --disable-verity --disable-verification flash vbmeta        vbmeta.img
   fastboot --disable-verity --disable-verification flash vbmeta_system vbmeta_system.img
   fastboot reboot fastboot            # userspace fastboot (dynamic partitions)
   fastboot flash vendor_dlkm vendor_dlkm.img
   fastboot reboot
   ```
2. **MODVERSIONS=n kernel + factory vendor_dlkm (simplest).** Build with `CONFIG_MODVERSIONS=n` +
   `TRIM_UNUSED_KSYMS=n` (`--notrim`); factory modules then load on vermagic alone. Flash `boot`
   only, no verity change. Risk: if a factory module's real type signature (not just CRC) differs,
   it loads then crashes — fall back to option 1.
3. Reproduce factory CRCs exactly (not worth it — undisclosed vendor patches make this a rabbit hole).

## HAZARD — do NOT flash a from-source `dtbo` or `vendor_boot` blindly
The from-source build emits a **tiny dtbo (~97 KB)** and a smaller `vendor_boot` than factory
(factory dtbo is ~75 MB, packing all device overlays). Flashing the tiny dtbo strips hardware
overlays → broken hw / loop. **Keep factory `dtbo` and `vendor_boot`** unless you have verified the
from-source ones contain every needed overlay.

## Vermagic must match stock
Build with `KLEAF_USE_KLEAF_LOCALVERSION=true` so the banner is exactly
`6.12.38-android16-5-g1d46253471dd-ab15048002-4k`. Stock vendor_dlkm gates on this string
(`same_magic()`) in addition to CRCs.

## Recovery (proven, ~30 s)
Magisk lives in `init_boot` (untouched by a `boot` flash), so root/banking survive a bad kernel.
```
fastboot flash boot <factory-or-known-good boot.img> && fastboot reboot
# if you disabled verity / swapped vendor_dlkm, also restore:
fastboot flash vbmeta <factory vbmeta.img>; fastboot flash vbmeta_system <factory vbmeta_system.img>
fastboot reboot fastboot && fastboot flash vendor_dlkm <factory vendor_dlkm.img> && fastboot reboot
```
Pull the crash log after recovery:
`adb wait-for-device; adb shell su -c 'cat /sys/fs/pstore/console-ramoops-0'`

## Device specifics
- fastboot serial `ZP2223437N`; active slot has been `_b`.
- Factory images (boot/vendor_boot/vbmeta/vbmeta_system/dtbo/init_boot) come from the RSA
  firmware `BLANC_G_W3WB…` package.
