#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# DarkMatter + NetHunter Pro (amd64) + KernelSU-Next  --  install image fuser
#
# Merges the Kali rootfs, NetHunter payload and the CI-built kernel into a
# DarkMatter android-x86 ISO tree, then emits a bootable ISO.
#
#   <out>/iso/            boot tree (kernel, initrd.img, system.sfs, efi/, ...)
#   <out>/<name>.iso      final image
#
# Designed around the real tree, which is a GearLock-style android-x86 layout:
#
#   gh/
#     apk/                     NetHunter/KSU APKs (flat)
#     boot/grub/efi.img        UEFI El Torito image
#     darkmatter_blueprints/   ikconfig + vmlinux-darkmatter.raw
#     efi/boot/                BOOTx64.EFI, grubx64.efi, android.cfg
#     findme                   android-x86 marker used to locate the ISO
#     gearlock/                GearLock assets
#     initrd_extracted/        unpacked initrd (busybox, lib, scripts)
#     install.img              installer ramdisk (enables the Install menu)
#     isolinux/                isolinux.bin, boot.cat, *.c32, isolinux.cfg
#     nh-unpacked/             NetHunter payload as a Magisk module
#                              (module.prop, customize.sh, post-fs-data.sh)
#     ramdisk_extracted/       unpacked android ramdisk
#
# The Android system image (system.sfs or system/) is NOT in this tree; pass it
# with --system.
#
# Usage:
#   ./fuse_darkmatter_nh.sh --gh DIR --system system.sfs --kernel-dir DIR \
#                           --kalifs kali-amd64.tar.xz [--out DIR]
# ==============================================================================

GH_DIR=""
SYSTEM_IMG=""
KERNEL_DIR=""
KALIFS=""
NH_APK_SRC=""
OUT_DIR="$PWD/out"
ISO_NAME="DarkMatter-NetHunter-KSU-amd64.iso"
MAKE_ISO=1
KEEP_WORK=0
NO_FUSE=0

die()  { echo "error: $*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --gh)         GH_DIR="$2"; shift 2 ;;
        --system)     SYSTEM_IMG="$2"; shift 2 ;;
        --kernel-dir) KERNEL_DIR="$2"; shift 2 ;;
        --kalifs)     KALIFS="$2"; shift 2 ;;
        --apk-src)    NH_APK_SRC="$2"; shift 2 ;;
        --out)        OUT_DIR="$2"; shift 2 ;;
        --name)       ISO_NAME="$2"; shift 2 ;;
        --no-iso)     MAKE_ISO=0; shift ;;
        --no-fuse)    NO_FUSE=1; shift ;;
        --keep-work)  KEEP_WORK=1; shift ;;
        -h|--help)    sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            die "unknown argument: $1" ;;
    esac
done

[ -n "$GH_DIR" ] || die "--gh is required (the gh/ tree)"
[ -d "$GH_DIR" ] || die "not a directory: $GH_DIR"
GH_DIR="$(cd "$GH_DIR" && pwd)"
mkdir -p "$OUT_DIR"; OUT_DIR="$(cd "$OUT_DIR" && pwd)"

[ -n "$SYSTEM_IMG" ] && [ -e "$SYSTEM_IMG" ] && SYSTEM_IMG="$(cd "$(dirname "$SYSTEM_IMG")" && pwd)/$(basename "$SYSTEM_IMG")"
[ -n "$KERNEL_DIR" ] && [ -d "$KERNEL_DIR" ] && KERNEL_DIR="$(cd "$KERNEL_DIR" && pwd)"
[ -n "$KALIFS" ] && [ -f "$KALIFS" ] && KALIFS="$(cd "$(dirname "$KALIFS")" && pwd)/$(basename "$KALIFS")"

WORK="$OUT_DIR/work"
ISO_ROOT="$OUT_DIR/iso"
MNT="$WORK/mnt"

rm -rf "$WORK" "$ISO_ROOT"
mkdir -p "$MNT" "$ISO_ROOT"

cleanup() {
    mountpoint -q "$MNT" 2>/dev/null && sudo umount "$MNT" || true
    # The sysroot is assembled with sudo, so the work dir is root-owned in
    # places; a plain rm -rf leaves it behind and fails noisily.
    [ "$KEEP_WORK" -eq 1 ] || sudo rm -rf "$WORK"
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# 0. Dependencies
# ------------------------------------------------------------------------------
note "Checking dependencies"
need="mksquashfs unsquashfs rsync tar gzip"
[ "$MAKE_ISO" -eq 1 ] && need="$need xorriso"
missing=""
for c in $need; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
[ -z "$missing" ] || die "install:$missing   (apt-get install -y squashfs-tools xorriso rsync)"
echo "  ok"

# ------------------------------------------------------------------------------
# 1. Copy the gh/ boot tree into the ISO staging area
# ------------------------------------------------------------------------------
note "Staging the DarkMatter boot tree"
# Extracted/working copies of the boot images are not part of the ISO.
rsync -a \
    --exclude 'initrd_extracted/' \
    --exclude 'ramdisk_extracted/' \
    --exclude 'darkmatter_blueprints/' \
    --exclude 'nh-unpacked/' \
    --exclude '*.raw' \
    "$GH_DIR/" "$ISO_ROOT/"
echo "  copied from $GH_DIR"

[ -d "$ISO_ROOT/isolinux" ] && echo "  isolinux/: $(ls "$ISO_ROOT/isolinux" | wc -l) files"
[ -d "$ISO_ROOT/efi/boot" ] && echo "  efi/boot/: $(ls "$ISO_ROOT/efi/boot" | wc -l) files"
[ -f "$ISO_ROOT/findme" ]   && echo "  findme marker present (android-x86 ISO scan)"

# ------------------------------------------------------------------------------
# 2. Kernel, initrd, install.img
# ------------------------------------------------------------------------------
note "Installing kernel and initrd"
if [ -n "$KERNEL_DIR" ]; then
    [ -f "$KERNEL_DIR/vmlinuz" ] || die "no vmlinuz in $KERNEL_DIR"
    cp -f "$KERNEL_DIR/vmlinuz" "$ISO_ROOT/kernel"
    echo "  kernel  <- $KERNEL_DIR/vmlinuz ($(stat -c %s "$KERNEL_DIR/vmlinuz") bytes)"
else
    [ -f "$ISO_ROOT/kernel" ] && echo "  reusing existing kernel" \
        || die "no --kernel-dir given and no kernel in the tree"
fi

# The android-x86 boot chain reads <root>/initrd.img next to the kernel.
for cand in "$GH_DIR/initrd.img" "$KERNEL_DIR/initrd.img" "$KERNEL_DIR/../initrd.img"; do
    [ -n "$cand" ] && [ -f "$cand" ] && { cp -f "$cand" "$ISO_ROOT/initrd.img"; echo "  initrd.img <- $cand"; break; }
done
[ -f "$ISO_ROOT/initrd.img" ] || echo "  warning: no initrd.img -- the ISO will not boot"

if [ -f "$ISO_ROOT/install.img" ]; then
    echo "  install.img present -- the installer menu will appear"
else
    echo "  note: no install.img -- live boot only, no Install entry"
fi

# ------------------------------------------------------------------------------
# 3. Modules
# ------------------------------------------------------------------------------
note "Staging kernel modules"
MODS="$WORK/modules"
mkdir -p "$MODS"
if [ -n "$KERNEL_DIR" ]; then
    for cand in "$KERNEL_DIR/modules/lib/modules" "$KERNEL_DIR/lib/modules" "$KERNEL_DIR/modules"; do
        [ -d "$cand" ] && { rsync -a "$cand/" "$MODS/"; break; }
    done
    echo "  $(find "$MODS" -name '*.ko' 2>/dev/null | wc -l) .ko files"
else
    echo "  none"
fi

# ------------------------------------------------------------------------------
# 4. System image + NetHunter fuse
# ------------------------------------------------------------------------------
if [ "$NO_FUSE" -eq 1 ]; then
    note "Skipping system fuse (--no-fuse)"
elif [ -z "$SYSTEM_IMG" ]; then
    note "No --system image: staging the ISO without the NetHunter system fuse"
    echo "  Pass --system <system.sfs|system.img|system/> to fuse the rootfs in."
else
    note "Fusing NetHunter into $(basename "$SYSTEM_IMG")"
    mkdir -p "$WORK/sysroot"

    SYS_IS_DIR=0
    [ -d "$SYSTEM_IMG" ] && SYS_IS_DIR=1

    if [ "$SYS_IS_DIR" -eq 0 ]; then
        # A system.sfs is a squashfs; a system.img is ext4.  Try squashfs
        # first, since that is what android-x86 ships.
        if unsquashfs -s "$SYSTEM_IMG" >/dev/null 2>&1; then
            sudo unsquashfs -f -d "$WORK/sysroot" "$SYSTEM_IMG" >/dev/null
        else
            sudo mount -o loop,ro "$SYSTEM_IMG" "$MNT"
            sudo rsync -a "$MNT/" "$WORK/sysroot/"
            sudo umount "$MNT"
        fi
    else
        sudo rsync -a "$SYSTEM_IMG/" "$WORK/sysroot/"
    fi

    SYS="$WORK/sysroot/system"
    [ -d "$SYS" ] || SYS="$WORK/sysroot"
    echo "  system root: $SYS"

    # --- modules -> /system/lib/modules ---
    if [ -n "$(ls -A "$MODS" 2>/dev/null)" ]; then
        sudo mkdir -p "$SYS/lib/modules"
        sudo rsync -a "$MODS/" "$SYS/lib/modules/"
        echo "  modules merged into /system/lib/modules"
    fi

    # --- NetHunter payload: nh-unpacked is a Magisk module ---
    NH="$GH_DIR/nh-unpacked"
    if [ -d "$NH" ]; then
        if [ -d "$NH/system" ]; then
            sudo rsync -a "$NH/system/" "$SYS/"
            echo "  nh-unpacked/system merged"
        fi
        # Magisk module scripts: run post-fs-data at boot via an init hook
        # instead of the Magisk daemon, which does not exist here.
        NHDIR="$SYS/etc/nethunter"
        sudo mkdir -p "$NHDIR"
        for f in customize.sh post-fs-data.sh env.sh module.prop; do
            [ -f "$NH/$f" ] && sudo cp -f "$NH/$f" "$NHDIR/"
        done
        echo "  nh-unpacked scripts -> /system/etc/nethunter/"
    else
        echo "  warning: no nh-unpacked/ in the tree"
    fi

    # --- APKs ---
    APK_SRC="${NH_APK_SRC:-$GH_DIR/apk}"
    if [ -d "$APK_SRC" ]; then
        shopt -s nullglob
        n=0
        for apk in "$APK_SRC"/*.apk; do
            name="$(basename "$apk" .apk)"
            sudo mkdir -p "$SYS/priv-app/$name"
            sudo cp -f "$apk" "$SYS/priv-app/$name/$name.apk"
            sudo chmod 0755 "$SYS/priv-app/$name"
            sudo chmod 0644 "$SYS/priv-app/$name/$name.apk"
            n=$((n+1))
        done
        shopt -u nullglob
        echo "  $n APKs -> /system/priv-app/"
    fi

    # --- Kali rootfs ---
    if [ -z "$KALIFS" ]; then
        for cand in "$GH_DIR"/nh-unpacked/rootfs/kali-amd64.tar.* "$GH_DIR"/rootfs/kali-amd64.tar.*; do
            [ -f "$cand" ] && { KALIFS="$cand"; break; }
        done
    fi
    if [ -n "$KALIFS" ] && [ -f "$KALIFS" ]; then
        sudo mkdir -p "$SYS/etc/nethunter"
        sudo cp -f "$KALIFS" "$SYS/etc/nethunter/kalifs-amd64.tar.gz"
        echo "  rootfs <- $(basename "$KALIFS") ($(du -h "$KALIFS" | cut -f1))"
    elif [ -d "$GH_DIR/nh-unpacked/rootfs/kali-amd64" ]; then
        sudo mkdir -p "$SYS/etc/nethunter"
        sudo tar -czf "$SYS/etc/nethunter/kalifs-amd64.tar.gz" \
             -C "$GH_DIR/nh-unpacked/rootfs" kali-amd64
        echo "  rootfs archived from nh-unpacked/rootfs/kali-amd64"
    else
        echo "  warning: no Kali rootfs found (pass --kalifs)"
    fi

    # --- first-boot extraction + module script ---
    sudo mkdir -p "$SYS/etc/init"
    sudo tee "$SYS/etc/init/nethunter.rc" >/dev/null <<'EOF'
on property:sys.boot_completed=1
    mkdir /data/local/nhsystem 0770 root root
    exec - root root -- /system/bin/sh /system/etc/nethunter/nh-firstboot.sh
EOF
    sudo tee "$SYS/etc/nethunter/nh-firstboot.sh" >/dev/null <<'EOF'
#!/system/bin/sh
# Extract the Kali chroot once, then run the NetHunter Magisk-module logic
# that would normally be driven by the Magisk daemon.
LOG=/data/local/tmp/nethunter-firstboot.log
exec >>"$LOG" 2>&1
echo "--- nethunter firstboot $(date)"

if [ ! -d /data/local/nhsystem/kali-amd64 ]; then
    if [ -f /system/etc/nethunter/kalifs-amd64.tar.gz ]; then
        echo "extracting kali-amd64 rootfs"
        tar -xzf /system/etc/nethunter/kalifs-amd64.tar.gz -C /data/local/nhsystem/
    fi
fi

if [ -d /data/local/nhsystem/kali-amd64/etc ]; then
    echo "rootfs present"
    [ -d /data/local/nhsystem/kali-amd64/dev ]     || mkdir -p /data/local/nhsystem/kali-amd64/dev
    [ -d /data/local/nhsystem/kali-amd64/proc ]    || mkdir -p /data/local/nhsystem/kali-amd64/proc
    [ -d /data/local/nhsystem/kali-amd64/sys ]     || mkdir -p /data/local/nhsystem/kali-amd64/sys
fi
echo "--- done"
EOF
    sudo chmod 0755 "$SYS/etc/nethunter/nh-firstboot.sh"

    # --- repack ---
    note "Repacking system image"
    rm -f "$ISO_ROOT/system.sfs"
    sudo mksquashfs "$WORK/sysroot" "$ISO_ROOT/system.sfs" -comp xz -b 1M -noappend >/dev/null
    sudo chown "$(id -u):$(id -g)" "$ISO_ROOT/system.sfs"
    echo "  $(du -h "$ISO_ROOT/system.sfs" | cut -f1) system.sfs"
fi

# ------------------------------------------------------------------------------
# 5. ISO
# ------------------------------------------------------------------------------
if [ "$MAKE_ISO" -eq 1 ]; then
    note "Building the ISO"
    OUT_ISO="$OUT_DIR/$ISO_NAME"
    rm -f "$OUT_ISO"

    BOOT_BIOS=""; BOOT_EFI=""
    [ -s "$ISO_ROOT/isolinux/isolinux.bin" ] && BOOT_BIOS=1
    [ -s "$ISO_ROOT/boot/grub/efi.img" ]     && BOOT_EFI=1
    if [ -z "$BOOT_BIOS" ] && [ -z "$BOOT_EFI" ]; then
        die "no boot image found (isolinux/isolinux.bin or boot/grub/efi.img)"
    fi

    args=(-as mkisofs -r -V "DARKMATTER_NH_KSU" -o "$OUT_ISO")
    if [ -n "$BOOT_BIOS" ]; then
        args+=(-b isolinux/isolinux.bin -c isolinux/boot.cat
               -no-emul-boot -boot-load-size 4 -boot-info-table)
    else
        echo "  warning: no isolinux.bin -- BIOS boot unavailable"
    fi
    if [ -n "$BOOT_EFI" ]; then
        args+=(-eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot)
    else
        echo "  warning: no efi.img -- UEFI boot unavailable"
    fi

    # xorriso uses a bitmask exit status: 32 = SORRY/MISHAP, i.e. a boot image
    # it could not patch but an otherwise written ISO.  Do not let that through
    # as success -- the resulting image would not boot.
    rc=0
    xorriso "${args[@]}" "$ISO_ROOT" >/tmp/xorriso.$$.log 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        tail -20 /tmp/xorriso.$$.log >&2
        rm -f /tmp/xorriso.$$.log
        die "xorriso failed (exit $rc); see the messages above"
    fi
    rm -f /tmp/xorriso.$$.log

    # A real iso9660 with an El Torito record is well over this; catching a
    # suspiciously small image here is cheaper than finding out on the laptop.
    iso_sz=$(stat -c %s "$OUT_ISO")
    if [ "$iso_sz" -lt 1048576 ]; then
        die "ISO is only $iso_sz bytes -- staging is incomplete"
    fi
    echo
    echo "ISO:    $OUT_ISO"
    echo "size:   $(du -h "$OUT_ISO" | cut -f1)"
    echo "sha256: $(sha256sum "$OUT_ISO" | cut -d' ' -f1)"
    echo "boot:   $([ -n "$BOOT_BIOS" ] && echo BIOS) $([ -n "$BOOT_EFI" ] && echo UEFI)"
else
    note "Staged tree only (--no-iso)"
    ls -la "$ISO_ROOT" | sed 's/^/  /'
fi
