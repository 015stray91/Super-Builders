#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# DarkMatter + NetHunter Pro (amd64) + KernelSU-Next  --  install image fuser
#
# Takes the DarkMatter Android-x86 base and the NetHunter payloads, merges the
# Kali rootfs into the Android system image, and emits:
#
#   <out>/iso/            bootable ISO tree (kernel, initrd.img, system.sfs, ...)
#   <out>/install.img     installer ramdisk (optional, enables the Install menu)
#   <out>/DarkMatter-NetHunter-KSU-amd64.iso
#
# Unlike the first version this script does NOT build the kernel: it consumes
# the artifact the CI build already produced (vmlinuz + modules).  Building
# here as well meant the fused image could ship a kernel that never went through
# the pinned SUSFS/ZeroMount patch set.
#
# Usage:
#   ./fuse_darkmatter_nh.sh --base DIR --nh DIR --kernel-dir DIR [options]
#
#   --base DIR        unpacked DarkMatter ISO tree (contains squashfs-root/)
#   --nh DIR          unpacked NetHunter installer (contains system/, data/app)
#   --kernel-dir DIR  CI artifact dir: vmlinuz + modules/lib/modules/...
#   --kalifs FILE     Kali rootfs tarball; defaults to <nh>/rootfs/kali-amd64.tar.*
#                     or a kali-amd64/ directory under <nh>/rootfs
#   --out DIR         output directory (default: ./out)
#   --no-iso          stage the tree but skip the xorriso step
#   --keep-work       do not delete the work directory
#
# Everything is parameterised: the old script hardcoded a path under
# /media/<user>/<uuid>/, so it only ever ran on one machine.
# ==============================================================================

BASE_DIR=""
NH_DIR=""
KERNEL_DIR=""
KALIFS=""
OUT_DIR="$PWD/out"
MAKE_ISO=1
KEEP_WORK=0

die() { echo "error: $*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --base)       BASE_DIR="$2"; shift 2 ;;
        --nh)         NH_DIR="$2"; shift 2 ;;
        --kernel-dir) KERNEL_DIR="$2"; shift 2 ;;
        --kalifs)     KALIFS="$2"; shift 2 ;;
        --out)        OUT_DIR="$2"; shift 2 ;;
        --no-iso)     MAKE_ISO=0; shift ;;
        --keep-work)  KEEP_WORK=1; shift ;;
        -h|--help)    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            die "unknown argument: $1" ;;
    esac
done

[ -n "$BASE_DIR" ] || die "--base is required"
[ -d "$BASE_DIR" ] || die "base dir not found: $BASE_DIR"

BASE_DIR="$(cd "$BASE_DIR" && pwd)"
[ -n "$NH_DIR" ]     && NH_DIR="$(cd "$NH_DIR" 2>/dev/null && pwd || true)"
[ -n "$KERNEL_DIR" ] && KERNEL_DIR="$(cd "$KERNEL_DIR" 2>/dev/null && pwd || true)"

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

WORK="$OUT_DIR/work"
ISO_ROOT="$OUT_DIR/iso"
MODS_STAGE="$WORK/modules"
MNT="$WORK/mnt"

rm -rf "$WORK"
mkdir -p "$MODS_STAGE" "$MNT" "$ISO_ROOT"

cleanup() {
    # Never leave a loop mount behind: a stale mount here makes the next run
    # fail with a confusing "squashfs-root is busy".
    if mountpoint -q "$MNT" 2>/dev/null; then
        sudo umount "$MNT" || true
    fi
    [ "$KEEP_WORK" -eq 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# 0. Dependencies
# ------------------------------------------------------------------------------
note "Checking dependencies"
missing=0
for cmd in mksquashfs unsquashfs rsync tar gzip; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "  missing: $cmd"; missing=1; }
done
if [ "$MAKE_ISO" -eq 1 ]; then
    command -v xorriso >/dev/null 2>&1 || { echo "  missing: xorriso"; missing=1; }
fi
if [ "$missing" -ne 0 ]; then
    die "install them: sudo apt-get install -y squashfs-tools xorriso rsync"
fi
echo "  ok"

# ------------------------------------------------------------------------------
# 1. Locate the DarkMatter system image
# ------------------------------------------------------------------------------
note "Locating the DarkMatter system image"

# Android-x86 bases ship either an uncompressed squashfs-root/ tree or a
# system.sfs that has to be unpacked first.  Support both.
SYS_SFS=""
SQUASH_ROOT=""
for cand in "$BASE_DIR/system.sfs" "$BASE_DIR/system.img.sfs"; do
    [ -f "$cand" ] && { SYS_SFS="$cand"; break; }
done
for cand in "$BASE_DIR/squashfs-root" "$BASE_DIR/root"; do
    [ -d "$cand" ] && { SQUASH_ROOT="$cand"; break; }
done

if [ -z "$SQUASH_ROOT" ]; then
    [ -n "$SYS_SFS" ] || die "no system.sfs or squashfs-root/ under $BASE_DIR"
    SQUASH_ROOT="$WORK/squashfs-root"
    note "Unpacking $(basename "$SYS_SFS")"
    sudo unsquashfs -d "$SQUASH_ROOT" "$SYS_SFS" >/dev/null
fi
echo "  system tree: $SQUASH_ROOT"

# The Android system image is either a directory (system/) or a mounted img.
SYSTEM_PATH=""
for cand in "$SQUASH_ROOT/system" "$SQUASH_ROOT/system.img"; do
    [ -e "$cand" ] && { SYSTEM_PATH="$cand"; break; }
done
[ -n "$SYSTEM_PATH" ] || die "no system/ or system.img inside $SQUASH_ROOT"

# ------------------------------------------------------------------------------
# 2. Kernel + modules (from the CI artifact -- never rebuilt here)
# ------------------------------------------------------------------------------
note "Installing kernel and modules"
if [ -n "$KERNEL_DIR" ]; then
    [ -f "$KERNEL_DIR/vmlinuz" ] || die "no vmlinuz in $KERNEL_DIR"
    cp -v "$KERNEL_DIR/vmlinuz" "$ISO_ROOT/kernel"

    # Modules may be a full tree (modules/lib/modules/<ver>) or bare modules/.
    src=""
    for cand in "$KERNEL_DIR/modules/lib/modules" "$KERNEL_DIR/lib/modules"; do
        [ -d "$cand" ] && { src="$cand"; break; }
    done
    if [ -n "$src" ]; then
        cp -a "$src/." "$MODS_STAGE/"
        echo "  modules: $(find "$MODS_STAGE" -name '*.ko' | wc -l) .ko files"
    else
        echo "  warning: no modules/ in $KERNEL_DIR -- wireless/HID modules will be missing"
    fi
else
    for cand in "$BASE_DIR/kernel" "$BASE_DIR/vmlinuz"; do
        [ -f "$cand" ] && { cp -v "$cand" "$ISO_ROOT/kernel"; break; }
    done
    [ -f "$ISO_ROOT/kernel" ] || die "no kernel supplied and none in $BASE_DIR"
    echo "  warning: no --kernel-dir given; reusing the base kernel"
fi

# initrd: the NetHunter Pro payload if present, else the base one.
for cand in "$NH_DIR/initrd.img" "$BASE_DIR/initrd.img"; do
    [ -n "$cand" ] && [ -f "$cand" ] && { cp -v "$cand" "$ISO_ROOT/initrd.img"; break; }
done

# ------------------------------------------------------------------------------
# 3. Merge the NetHunter system files
# ------------------------------------------------------------------------------
note "Merging NetHunter system files"
if [ -z "$NH_DIR" ]; then
    echo "  warning: no --nh given; skipping the NetHunter system merge"
else
    [ -d "$NH_DIR" ] || die "NetHunter dir not found"

    if mountpoint -q "$MNT" 2>/dev/null; then sudo umount "$MNT"; fi
    sudo mount -o loop "$SYSTEM_PATH" "$MNT" 2>/dev/null || {
        # A directory-shaped system/ is rsynced directly.
        [ -d "$SYSTEM_PATH" ] || die "cannot mount $SYSTEM_PATH"
    }

    if mountpoint -q "$MNT" 2>/dev/null; then
        TARGET="$MNT/system"
        mkdir -p "$TARGET"
    else
        TARGET="$SYSTEM_PATH"
    fi

    # rsync, not `cp -rn`: cp skips anything that already exists, which silently
    # drops NetHunter binaries that share a name with an Android one.  rsync
    # updates them in place.
    if [ -d "$NH_DIR/system" ]; then
        sudo rsync -a "$NH_DIR/system/" "$TARGET/"
        echo "  system/ merged"
    fi

    # NetHunter APKs -> priv-app
    if [ -d "$NH_DIR/data/app" ]; then
        shopt -s nullglob
        for apk in "$NH_DIR/data/app"/*.apk; do
            name="$(basename "$apk" .apk)"
            sudo mkdir -p "$TARGET/priv-app/$name"
            sudo cp -f "$apk" "$TARGET/priv-app/$name/$name.apk"
            sudo chmod 0755 "$TARGET/priv-app/$name"
            sudo chmod 0644 "$TARGET/priv-app/$name/$name.apk"
        done
        shopt -u nullglob
        echo "  APKs staged into priv-app"
    fi

    # Kernel modules -> system/lib/modules
    if [ -n "$(ls -A "$MODS_STAGE" 2>/dev/null)" ]; then
        sudo mkdir -p "$TARGET/lib/modules"
        sudo rsync -a "$MODS_STAGE/" "$TARGET/lib/modules/"
        echo "  modules merged"
    fi

    if mountpoint -q "$MNT" 2>/dev/null; then
        sudo umount "$MNT"
    fi
fi

# ------------------------------------------------------------------------------
# 4. Kali rootfs -> first-boot extraction
# ------------------------------------------------------------------------------
note "Staging the Kali rootfs"
[ -z "$KALIFS" ] && [ -n "$NH_DIR" ] && {
    for cand in "$NH_DIR"/rootfs/kali-amd64.tar.gz "$NH_DIR"/rootfs/kali-amd64.tar.xz; do
        [ -f "$cand" ] && { KALIFS="$cand"; break; }
    done
}

NH_ETC="$SQUASH_ROOT/system/etc/nethunter"
if [ -n "$KALIFS" ] && [ -f "$KALIFS" ]; then
    sudo mkdir -p "$NH_ETC"
    sudo cp -f "$KALIFS" "$NH_ETC/kalifs-amd64.tar.gz"
    echo "  rootfs -> /system/etc/nethunter/kalifs-amd64.tar.gz"
elif [ -n "$NH_DIR" ] && [ -d "$NH_DIR/rootfs/kali-amd64" ]; then
    sudo mkdir -p "$NH_ETC"
    sudo tar -czf "$NH_ETC/kalifs-amd64.tar.gz" -C "$NH_DIR/rootfs" kali-amd64
    echo "  rootfs archived from $NH_DIR/rootfs/kali-amd64"
else
    echo "  warning: no Kali rootfs found; the chroot will be empty on first boot"
fi

if [ -f "$NH_ETC/kalifs-amd64.tar.gz" ]; then
    # Extract on first boot only, and only if it is not already there.
    sudo mkdir -p "$SQUASH_ROOT/system/etc/init"
    sudo tee "$SQUASH_ROOT/system/etc/init/nethunter.rc" >/dev/null <<'EOF'
on property:sys.boot_completed=1
    exec - root root -- /system/bin/sh -c "if [ ! -d /data/local/nhsystem/kali-amd64 ] && [ -f /system/etc/nethunter/kalifs-amd64.tar.gz ]; then mkdir -p /data/local/nhsystem && tar -xzf /system/etc/nethunter/kalifs-amd64.tar.gz -C /data/local/nhsystem/; fi"
EOF
    sudo chmod 0644 "$SQUASH_ROOT/system/etc/init/nethunter.rc"
fi

# ------------------------------------------------------------------------------
# 5. Repack system.sfs
# ------------------------------------------------------------------------------
note "Repacking system.sfs"
cp -f "$SQUASH_ROOT/system/../kernel" "$ISO_ROOT/kernel" 2>/dev/null || true
rm -f "$ISO_ROOT/system.sfs"
sudo mksquashfs "$SQUASH_ROOT" "$ISO_ROOT/system.sfs" -comp xz -b 1M -noappend >/dev/null
sudo chown "$(id -u):$(id -g)" "$ISO_ROOT/system.sfs"
echo "  $(du -h "$ISO_ROOT/system.sfs" | cut -f1) system.sfs"

# ------------------------------------------------------------------------------
# 6. Boot files
# ------------------------------------------------------------------------------
note "Copying boot loaders"
for d in efi boot isolinux; do
    [ -d "$BASE_DIR/$d" ] && cp -a "$BASE_DIR/$d" "$ISO_ROOT/"
done
# android-x86 keeps isolinux.bin at the ISO root, not in isolinux/
for f in isolinux.bin boot.cat; do
    [ -f "$BASE_DIR/$f" ] && cp -a "$BASE_DIR/$f" "$ISO_ROOT/"
done
[ -d "$ISO_ROOT/efi" ] || die "no efi/ in $BASE_DIR -- the ISO would not be UEFI-bootable"

# ------------------------------------------------------------------------------
# 7. ISO
# ------------------------------------------------------------------------------
if [ "$MAKE_ISO" -eq 1 ]; then
    note "Building the ISO"
    OUT_ISO="$OUT_DIR/DarkMatter-NetHunter-KSU-amd64.iso"
    rm -f "$OUT_ISO"

    # A zero-length or missing boot image makes xorriso emit an ISO that
    # silently will not boot, so check before building rather than after.
    BOOT_BIOS=""
    BOOT_EFI=""
    [ -s "$ISO_ROOT/isolinux.bin" ] && BOOT_BIOS=1
    [ -s "$ISO_ROOT/boot/grub/efi.img" ] && BOOT_EFI=1
    if [ -z "$BOOT_BIOS" ] && [ -z "$BOOT_EFI" ]; then
        die "no usable boot image (isolinux.bin / boot/grub/efi.img) in $ISO_ROOT"
    fi
    [ -z "$BOOT_BIOS" ] && echo "  warning: no isolinux.bin -- BIOS/CSM boot will not work"
    [ -z "$BOOT_EFI" ]  && echo "  warning: no boot/grub/efi.img -- UEFI boot will not work"

    xorriso_args=(-as mkisofs -r -V "DARKMATTER_NH_KSU" -o "$OUT_ISO")
    if [ -n "$BOOT_BIOS" ]; then
        xorriso_args+=(-b isolinux.bin -c boot.cat
                       -no-emul-boot -boot-load-size 4 -boot-info-table)
    fi
    if [ -n "$BOOT_EFI" ]; then
        xorriso_args+=(-eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot)
    fi

    xorriso "${xorriso_args[@]}" "$ISO_ROOT"
    echo
    echo "ISO: $OUT_ISO ($(du -h "$OUT_ISO" | cut -f1))"
    echo "sha256: $(sha256sum "$OUT_ISO" | cut -d' ' -f1)"
    echo "boot: $([ -n "$BOOT_BIOS" ] && echo BIOS) $([ -n "$BOOT_EFI" ] && echo UEFI)"
else
    note "Staged tree (no ISO requested)"
    find "$ISO_ROOT" -maxdepth 1 -type f -printf '  %10s  %f\n' | sort -k2
fi
