#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# AnyRealm - NUKI/NURFS  --  DESKTOP edition (x86_64 installer image)
#
# AnyRealm is the project. NUKI/NURFS is the architecture it is built on.
# This script produces the desktop edition of it:
#
#   AnyRealm  NUKI  Native Unified Kernel Image
#             NURFS Native Unified Root File System
#             desktop edition  --  x86_64, bootable install ISO for a PC
#
# The mobile edition is the same architecture on arm64: AR-NUKI-genevn for the
# Moto G Stylus 5G 2023, built by build-ksu-next.yml.
#
# Concretely, this artefact is:
#
#   NUKI  Native Unified Kernel Image   -- one kernel built whole from
#                                          kernel-zenith 6.12, SUSFS + ZeroMount
#                                          + KernelSU-Next compiled in
#   NURFS Native Unified Root File System -- DarkMatter's rootfs with the Kali
#                                          NetHunter Pro user space merged into
#                                          it, one rootfs, one user space
#
# There is no chroot, proot, container or libc translator in the result, and no
# separated vendor module set with a KMI to match at boot. bionic and glibc both
# run because they share one kernel and one VFS.
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
#   ./fuse_darkmatter_nh.sh --base-iso DarkMatter.iso --kernel-dir DIR \
#                           --kalifs kali-amd64.tar.xz [--out DIR] \
#                           [--firmware firmware-amd-graphics_*.deb]
#
#   --base-iso  the original DarkMatter ISO (preferred: it is the authority,
#               and a local working tree may hold leftovers from earlier runs)
#   --gh        a loose copy of the ISO tree, used only if no --base-iso is
#               given; extracted/ working files in it are skipped
# ==============================================================================

GH_DIR=""
BASE_ISO=""
SYSTEM_IMG=""
KERNEL_DIR=""
KALIFS=""
NH_APK_SRC=""
# Extra Debian packages to fetch from Kali and unpack into the merged tree.
# Installed with dpkg-deb --extract under apt Dir= redirection, so no chroot is
# involved; see install_pkgs_into_tree().
EXTRA_PKGS=""
# Device firmware, from firmware-nonfree .debs or unpacked directories.
# Repeatable: --firmware amd.deb --firmware realtek.deb.  Each package is
# unpacked into the tree's /lib/firmware (i.e. /system/lib/firmware live), which
# is where the kernel's fw_path points.  See stage_firmware() for why the deb's
# own /usr/lib layout cannot be copied verbatim.
FIRMWARE_SRC=""
# Directory containing this script, so helper files (installer/, the patch
# scripts) resolve regardless of the caller's working directory.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$PWD/out"
# The fusion has one name. It is neither the builder appliance nor a bare
# DarkMatter or NetHunter image: it is the DarkMatter + NetHunter Pro rootfs
# fused into one -- hence dark-hunter.
ISO_NAME="dark-hunter.iso"
MAKE_ISO=1
KEEP_WORK=0
NO_FUSE=0

die()  { echo "error: $*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --gh)         GH_DIR="$2"; shift 2 ;;
        --base-iso)   BASE_ISO="$2"; shift 2 ;;
        --system)     SYSTEM_IMG="$2"; shift 2 ;;
        --kernel-dir) KERNEL_DIR="$2"; shift 2 ;;
        --kalifs)     KALIFS="$2"; shift 2 ;;
        --apk-src)    NH_APK_SRC="$2"; shift 2 ;;
        --pkgs)       EXTRA_PKGS="$2"; shift 2 ;;
        --firmware)   FIRMWARE_SRC="${FIRMWARE_SRC:+$FIRMWARE_SRC,}$2"; shift 2 ;;
        --out)        OUT_DIR="$2"; shift 2 ;;
        --name)       ISO_NAME="$2"; shift 2 ;;
        --no-iso)     MAKE_ISO=0; shift ;;
        --no-fuse)    NO_FUSE=1; shift ;;
        --keep-work)  KEEP_WORK=1; shift ;;
        -h|--help)    sed -n '2,62p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            die "unknown argument: $1" ;;
    esac
done

[ -n "$GH_DIR" ] || [ -n "$BASE_ISO" ] \
    || die "give --base-iso <DarkMatter.iso> (preferred) or --gh <tree>"
[ -n "$GH_DIR" ] && { [ -d "$GH_DIR" ] || die "not a directory: $GH_DIR"; }
[ -n "$BASE_ISO" ] && { [ -f "$BASE_ISO" ] || die "no such ISO: $BASE_ISO"; }
mkdir -p "$OUT_DIR"; OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# A --gh directory is a scratch tree: it may carry leftovers from earlier runs
# (unpacked initrds, extracted ramdisks, a stale kernel).  The ISO is the
# authority, so prefer --base-iso when both are given.
if [ -n "$BASE_ISO" ]; then
    BASE_ISO="$(cd "$(dirname "$BASE_ISO")" && pwd)/$(basename "$BASE_ISO")"
fi

[ -n "$SYSTEM_IMG" ] && [ -e "$SYSTEM_IMG" ] && SYSTEM_IMG="$(cd "$(dirname "$SYSTEM_IMG")" && pwd)/$(basename "$SYSTEM_IMG")"
[ -n "$KERNEL_DIR" ] && [ -d "$KERNEL_DIR" ] && KERNEL_DIR="$(cd "$KERNEL_DIR" && pwd)"
[ -n "$KALIFS" ] && [ -f "$KALIFS" ] && KALIFS="$(cd "$(dirname "$KALIFS")" && pwd)/$(basename "$KALIFS")"

WORK="$OUT_DIR/work"
ISO_ROOT="$OUT_DIR/iso"
MNT="$WORK/mnt"

# sudo, because a previous run on the same volume leaves these root-owned
# (the fused tree is assembled with sudo), and `rm -rf` as the CI user cannot
# unlink inside a root-owned directory.  Cleanup already does this.
sudo rm -rf "$WORK" "$ISO_ROOT" 2>/dev/null || rm -rf "$WORK" "$ISO_ROOT"
mkdir -p "$MNT" "$ISO_ROOT"

cleanup() {
    mountpoint -q "$MNT" 2>/dev/null && sudo umount "$MNT" || true
    mountpoint -q "$WORK/wrapper" 2>/dev/null && sudo umount "$WORK/wrapper" || true
    mountpoint -q "$WORK/mntimg" 2>/dev/null && sudo umount "$WORK/mntimg" || true
    # The sysroot is assembled with sudo, so the work dir is root-owned in
    # places; a plain rm -rf leaves it behind and fails noisily.  A mount left
    # behind here also makes the directory undeletable and quietly eats the
    # disk until the next reboot.
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
# 0b. Free space
#
# Peak usage, all under --out:
#   gh tree copy      ~ the size of gh/ (minus the extracted dirs we skip)
#   unpacked sysroot  ~2-3x the system image, because squashfs-xz has already
#                       removed the redundancy, so it expands rather than shrinks
#   repacked sfs      ~ the size of the system image again
#   final ISO         ~ tree + sfs, written while the staging tree still exists
#
# Running out here means a multi-minute unpack dies at the end, so check first.
# ------------------------------------------------------------------------------
note "Checking free space on $OUT_DIR"
if [ -n "$GH_DIR" ]; then
    gh_sz=$(du -sb --exclude='initrd_extracted' --exclude='ramdisk_extracted' \
                   --exclude='darkmatter_blueprints' --exclude='*.raw' \
                   "$GH_DIR" 2>/dev/null | cut -f1)
else
    # Reading the ISO: the extracted tree is about the size of the ISO itself,
    # and it lands in OUT_DIR, so count it.
    gh_sz=$(stat -c %s "$BASE_ISO")
fi
# System tree.  It is still staged as an image/wrapper on input (that is the
# only form the base ISO ships it in), so it is unpacked once.  What it costs
# afterwards changed with the monolithic layout: a directory is written into
# the ISO at its own size, with no ext4 image and no second squashfs copy.
sys_sz=0; sys_unpacked=0; sys_phrase=""
if [ -n "$SYSTEM_IMG" ] && [ "$NO_FUSE" -eq 0 ]; then
    if [ -f "$SYSTEM_IMG" ]; then
        sys_sz=$(stat -c %s "$SYSTEM_IMG")
        sys_unpacked=$(( sys_sz * 2 ))
        sys_phrase="the wrapper is unpacked to a directory of ~$(numfmt --to=iec $((sys_sz * 2)))"
    elif [ -d "$SYSTEM_IMG" ]; then
        sys_unpacked=$(du -sb "$SYSTEM_IMG" 2>/dev/null | cut -f1)
        sys_sz=$sys_unpacked
        sys_phrase="already a directory, so it is staged and written out once"
    fi
fi
# Kali rootfs: staged under the ISO tree and written into the ISO as one file,
# so it costs its size once.  It no longer rides inside the system tree.
kali_sz=0
if [ -n "${KALIFS:-}" ] && [ -f "$KALIFS" ] && [ "$NO_FUSE" -eq 0 ]; then
    kali_sz=$(stat -c %s "$KALIFS")
fi

# gh copy + unpacked system tree + staged rootfs + the output ISO.
need=$(( gh_sz + sys_unpacked + kali_sz + (sys_unpacked + kali_sz) / 10 ))
avail=$(df -B1 --output=avail "$OUT_DIR" | tail -1 | tr -d ' ')
echo "  boot tree:   $(numfmt --to=iec "$gh_sz")"
if [ "$sys_unpacked" -gt 0 ]; then
    echo "  system:      $(numfmt --to=iec "$sys_sz") -- $sys_phrase"
fi
if [ "$kali_sz" -gt 0 ]; then
    echo "  rootfs:      $(numfmt --to=iec "$kali_sz") (staged once, written once)"
fi
echo "  estimated:   $(numfmt --to=iec "$need")"
echo "  available:   $(numfmt --to=iec "$avail")"
if [ "$avail" -lt "$need" ]; then
    cat >&2 <<EOF

error: not enough free space in $OUT_DIR
       Need about $(numfmt --to=iec "$need"), have $(numfmt --to=iec "$avail").
       This is an estimate for a build with the system image fused in.

       Free space, or put the working area on another disk:

         ./fuse_darkmatter_nh.sh ... --out /path/on/bigger/disk

       To fuse *without* the system image (useful for a quick boot test):

         ./fuse_darkmatter_nh.sh ... --no-fuse
EOF
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. Copy the gh/ boot tree into the ISO staging area
# ------------------------------------------------------------------------------
note "Staging the DarkMatter boot tree"
if [ -n "$BASE_ISO" ]; then
    # xorriso reads the ISO9660 tree directly -- no loop mount, no root.
    command -v xorriso >/dev/null || die "xorriso is required to read --base-iso"
    xorriso -osirrox on -indev "$BASE_ISO" -extract / "$ISO_ROOT" 2>/dev/null
    chmod -R u+w "$ISO_ROOT"
    echo "  extracted from $(basename "$BASE_ISO")"
    echo "  (the ISO is the authority: no leftover working files are carried in)"
elif [ -n "$GH_DIR" ]; then
    # A --gh tree is a scratch area and may hold leftovers from earlier runs
    # (unpacked initrds, extracted ramdisks, a previous kernel).  None of that
    # belongs in the ISO.
    rsync -a \
        --exclude 'initrd_extracted/' \
        --exclude 'ramdisk_extracted/' \
        --exclude 'darkmatter_blueprints/' \
        --exclude 'nh-unpacked/' \
        --exclude '*.raw' \
        "$GH_DIR/" "$ISO_ROOT/"
    echo "  copied from $GH_DIR"
fi

# Everything below reads the *staged* tree, not the source.  That way a
# --base-iso run and a --gh run follow exactly the same path, and nothing is
# read from a scratch directory once staging is done.
TREE="$ISO_ROOT"

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
# The staged tree already has the ISO's own initrd, which is the one that
# matches this boot layout -- keep it.  Only copy one in if the tree has none.
if [ -f "$ISO_ROOT/initrd.img" ]; then
    echo "  initrd.img kept from the base ISO ($(stat -c %s "$ISO_ROOT/initrd.img") bytes)"
else
    for cand in "$KERNEL_DIR/initrd.img" "$KERNEL_DIR/../initrd.img"; do
        [ -n "$cand" ] && [ -f "$cand" ] && {
            cp -f "$cand" "$ISO_ROOT/initrd.img"
            echo "  initrd.img <- $cand"
            break
        }
    done
fi
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
        [ -d "$cand" ] && { rsync -a --exclude 'build/' --exclude 'source/' "$cand/" "$MODS/"; break; }
    done
    # build/ and source/ are the kernel's own build tree copied in by
    # modules_install.  Nothing at boot reads them -- they exist so out-of-tree
    # modules can compile -- and in the last image they were 5.9 GiB of the
    # 18.9 GB total, against 94 MiB of actual .ko files.  Excluded above; this
    # also clears any copy a previous run left behind.
    for d in "$MODS"/*/; do
        [ -d "$d" ] || continue
        rm -rf "$d/build" "$d/source" 2>/dev/null || true
    done
    echo "  $(find "$MODS" -name '*.ko' 2>/dev/null | wc -l) .ko files, $(du -sh "$MODS" 2>/dev/null | cut -f1) staged"
else
    echo "  none"
fi

# ------------------------------------------------------------------------------
# 4. System image + NetHunter fuse
# ------------------------------------------------------------------------------
# The staged tree already has the system image where the ISO put it.
if [ -z "$SYSTEM_IMG" ] && [ -f "$TREE/system.sfs" ]; then
    SYSTEM_IMG="$TREE/system.sfs"
    echo "  using the system image from the staged tree: system.sfs"
fi

if [ "$NO_FUSE" -eq 1 ]; then
    note "Skipping system fuse (--no-fuse)"
elif [ -z "$SYSTEM_IMG" ]; then
    note "No --system image: staging the ISO without the NetHunter system fuse"
    echo "  Pass --system <system.sfs|system.img|system/> to fuse the rootfs in."
else
    note "Fusing NetHunter into $(basename "$SYSTEM_IMG")"

    # The DarkMatter boot chain mounts the system in two layers:
    #
    #   mount -o loop /mnt/$SRC/system.sfs /sfs     <- squashfs wrapper
    #   mount -o loop /sfs/system.img system        <- ext4, the real system
    #
    # So system.sfs is not a directory tree, it is a container holding one
    # file named system.img.  Editing it means unpacking the wrapper, mounting
    # the inner image, changing that, then rebuilding both layers.
    #
    # --system accepts either layer:
    #   system.sfs   wrapper  -> unwrap to the inner system.img
    #   system.img   inner fs -> use directly
    #   system/      directory -> skip straight to "already unpacked"
    WRAPPER=""
    INNER=""
    SYS_IS_DIR=0

    if [ -d "$SYSTEM_IMG" ]; then
        SYS_IS_DIR=1
        # Always work on our own copy.  The Kali merge adds paths to this tree,
        # and writing into a directory the user passed on the command line
        # corrupts their input -- it did, during testing: /kali and a nested
        # system/system appeared in the source tree.
        sudo mkdir -p "$WORK/sysroot"
        sudo rsync -a "$SYSTEM_IMG/" "$WORK/sysroot/"
        SYS="$WORK/sysroot"
        # Do NOT descend on the mere presence of a system/ subdirectory: Kali's
        # tarball has one, and a merged tree can too, so that check picked
        # <sysroot>/system from a polluted input and then failed every marker
        # test.  The marker check below decides, using build.prop/bin/etc.
        echo "  system root: $SYS (copied from $SYSTEM_IMG)"
    elif unsquashfs -s "$SYSTEM_IMG" >/dev/null 2>&1; then
        WRAPPER="$(basename "$SYSTEM_IMG")"
        echo "  $(basename "$SYSTEM_IMG") is a squashfs wrapper"
        # Mount the wrapper rather than unpacking it.  Extracting a real
        # system.sfs puts a 2 GB system.img on disk that is deleted again a
        # minute later; mounting it costs nothing and is the same mechanism the
        # initrd uses, so it also proves the file is mountable.
        mkdir -p "$WORK/wrapper"
        if sudo mount -o loop,ro "$SYSTEM_IMG" "$WORK/wrapper" 2>/dev/null; then
            echo "  mounted the wrapper (no extraction, saves ~2 GB)"
            INNER="$WORK/wrapper/system.img"
            [ -e "$INNER" ] || INNER="$(find "$WORK/wrapper" -maxdepth 1 -name 'system.img' -print -quit)"
        else
            echo "  mount failed -- extracting instead"
            sudo unsquashfs -f -d "$WORK/wrapper" "$SYSTEM_IMG" >/dev/null
            INNER="$(find "$WORK/wrapper" -maxdepth 1 -name 'system.img' -print -quit)"
        fi
        if [ -z "$INNER" ]; then
            # Not the android-x86 shape.  Treat the squashfs contents as the
            # tree directly -- that is what a repack must then reproduce.
            SYS_IS_DIR=1
            SYS="$WORK/wrapper/system"
            [ -d "$SYS" ] || SYS="$WORK/wrapper"
            WRAPPER=""
            echo "  no system.img inside -- treating the squashfs as a plain tree"
        else
            echo "  inner image: $(basename "$INNER") ($(stat -c %s "$INNER") bytes)"
            sudo mount -o loop,ro "$INNER" "$MNT"
            SYS="$WORK/sysroot/system"
            sudo mkdir -p "$WORK/sysroot"
            sudo rsync -a "$MNT/" "$WORK/sysroot/"
            sudo umount "$MNT"
            [ -d "$SYS" ] || SYS="$WORK/sysroot"
            echo "  system root: $SYS (extracted from system.img)"
        fi
    else
        # A bare ext4 system.img, or a sparse one.
        INNER="$SYSTEM_IMG"
        echo "  treating $(basename "$SYSTEM_IMG") as a filesystem image"
        MNTIMG="$WORK/mntimg"
        mkdir -p "$MNTIMG"
        if ! sudo mount -o loop,ro "$SYSTEM_IMG" "$MNTIMG" 2>/dev/null; then
            command -v simg2img >/dev/null || die "cannot mount $SYSTEM_IMG and simg2img is missing"
            echo "  direct mount failed -- converting from sparse"
            simg2img "$SYSTEM_IMG" "$WORK/system.raw"
            sudo mount -o loop,ro "$WORK/system.raw" "$MNTIMG"
        fi
        sudo mkdir -p "$WORK/sysroot"
        sudo rsync -a "$MNTIMG/" "$WORK/sysroot/"
        sudo umount "$MNTIMG"
        SYS="$WORK/sysroot/system"
        [ -d "$SYS" ] || SYS="$WORK/sysroot"
        echo "  system root: $SYS (extracted from image)"
    fi

    # --- modules -> /system/lib/modules ---
    #
    # The base image carries modules for 4.14.90-*-Darkmatter_comet (2451 .ko,
    # 179 MB).  Under our 6.12 kernel every one of them is unusable: the initrd
    # does `modprobe` against /lib/modules/`uname -r`, so it needs a directory
    # named for OUR kernel, and a stray 4.14 tree just wastes space in an image
    # that only has ~90 MB free.  Drop the old tree, install ours.
    if [ -n "$(ls -A "$MODS" 2>/dev/null)" ]; then
        sudo mkdir -p "$SYS/lib/modules"
        if [ -d "$SYS/lib/modules" ]; then
            for d in "$SYS"/lib/modules/*/; do
                [ -d "$d" ] || continue
                case "$(basename "$d")" in
                    6.12*|*"$(cat "$KERNEL_DIR/kernel-version" 2>/dev/null || echo __none__)"*) ;;
                    *)
                        sudo rm -rf "$d"
                        echo "  removed stale $(basename "$d")"
                        ;;
                esac
            done
        fi
        sudo rsync -a "$MODS/" "$SYS/lib/modules/"
        echo "  modules -> /system/lib/modules: $(find "$SYS/lib/modules" -name '*.ko*' | wc -l) files"
        if [ -d "$SYS/lib/modules" ]; then
            kb=$(sudo du -sm "$SYS/lib/modules" 2>/dev/null | cut -f1)
            echo "  module tree: ${kb} MiB"
            # 5.9 GiB of build/ is what bloated the last image; a tree this size
            # means it came back.
            if [ "${kb:-0}" -gt 1024 ]; then
                echo "  warning: module tree is ${kb} MiB -- build/ may have crept back in"
            fi
        fi
        for d in "$SYS"/lib/modules/*/; do
            [ -d "$d" ] && echo "    $(basename "$d")"
        done
    else
        echo "  warning: no modules staged -- the base 4.14 modules will never load"
    fi

    # --- NetHunter payload: nh-unpacked is a Magisk module ---
    NH="$TREE/nh-unpacked"
    [ -d "$NH" ] || NH="$GH_DIR/nh-unpacked"
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
    if [ -n "$NH_APK_SRC" ]; then
        APK_SRC="$NH_APK_SRC"
    elif [ -d "$TREE/apk" ]; then
        APK_SRC="$TREE/apk"
    else
        APK_SRC="$GH_DIR/apk"
    fi
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

    # --- Kali rootfs: merge it into the SAME rootfs ---
    #
    # This is the part that makes it a native unified OS rather than NetHunter
    # Lite.  Lite keeps Kali in a tarball and chroots into /data/local/nhsystem
    # at runtime: two user spaces, a proot-ish boundary, and the phone's CPU
    # and RAM shared between two kernels' worth of assumptions.  Here there is
    # one rootfs.  The Kali tree is merged into the Android system tree at
    # BUILD time, so what ships on the ISO is already a single filesystem and
    # the target just installs a directory.  No chroot, no proot, no container,
    # no first-boot extraction, nothing to mount.
    #
    # The merge is additive and never overwrites Android.  Both trees claim
    # bin, lib, lib64, media and system, and the two meanings are not the same:
    #
    #   Android                    Kali
    #   -------                    ----
    #   /system/bin  toybox, applets   /bin   coreutils, bash, apt
    #   /system/lib  bionic .so        /lib   glibc .so
    #   /system/etc  Android config    /etc   Debian config
    #
    # Overwriting either side breaks it: Android with glibc libc.so is a brick,
    # Kali with bionic libc.so is equally dead.  So Kali's conflicting top-level
    # paths go to /kali/<name>, and Kali's own non-conflicting ones (usr, var,
    # opt, srv, home, root, run, boot) land at the top level where Debian
    # expects them.  A symlink /kali/lib -> /lib is deliberately NOT created:
    # the whole point is that the two libcs stay apart.
    if [ -z "$KALIFS" ]; then
        for cand in "$TREE"/nh-unpacked/rootfs/kali-amd64.tar.* "$GH_DIR"/nh-unpacked/rootfs/kali-amd64.tar.* "$GH_DIR"/rootfs/kali-amd64.tar.*; do
            [ -f "$cand" ] && { KALIFS="$cand"; break; }
        done
    fi

    if [ -n "$KALIFS" ] && [ -f "$KALIFS" ]; then
        # Install Debian packages into a merged tree without chroot.
#
# A chroot is out by design here -- it is the model this build replaces -- so
# apt is pointed at the tree with Dir= flags, fetches .debs, and each one is
# unpacked with dpkg-deb --extract.  That resolves dependencies through apt but
# runs no maintainer scripts, which is the right trade for an image: the scripts
# assume they are install-time in a booted system, and running them against a
# tree that is not booted is what forces people into chroots in the first place.
#
# Anything needing a postinst (font caches, icon caches, ld.so.cache) is finished
# by the first-boot step in the installed image, or harmlessly regenerated on

# --- GPU / device firmware -------------------------------------------------
#
# A kernel module that loads is not the same thing as a GPU that works.  amdgpu
# is `=m` in the x86_64 fragment, so the .ko is present either way; what it asks
# for at probe time is microcode, and without it the driver fails and the boot
# falls back to efifb/simpledrm at 1024x768 with no acceleration.
#
# The firmware cannot come from the vendor's Windows .exe.  An ASUS/AMD driver
# package carries amdkmdag.sys and DLLs; its .bin files are display tuning
# tables (h9_easu_*), not microcode.  Linux's microcode ships in the
# firmware-nonfree packages, and Debian's is usually newer than Ubuntu's --
# 20261019-1 at time of writing, 90 MB of amdgpu blobs.
#
# Two details decide whether this works:
#
#   1. Debian now installs firmware under /usr/lib/firmware (usrmerge).  The
#      kernel's fw_path is /lib/firmware, so copying the deb layout verbatim
#      produces a tree the kernel never looks in.
#   2. In THIS tree /lib is Android's bionic directory.  Firmware goes to
#      $SYS/lib/firmware -- which is /system/lib/firmware live -- and nowhere
#      near /usr/lib.
#
# The package also carries ~129 relative symlinks (yellow_carp_ta -> psp_13_0_5_ta
# and so on).  Mendocino has no psp_13_0_1_* of its own; it is yellow_carp, and
# the symlinks are how that maps onto shared microcode.  rsync -a keeps them,
# and the broken-link check below is what catches a partial copy leaving one
# dangling.
stage_firmware() {
    local src="$1" treeroot="$2"
    [ -n "$src" ] || return 0
    local T="$treeroot"

    local d="$src"
    if [ -f "$src" ] && case "$src" in *.deb) true;; *) false;; esac; then
        d="$WORK/fw-unpack"
        sudo rm -rf "$d"; mkdir -p "$d"
        dpkg-deb -x "$src" "$d" || { echo "  firmware: cannot unpack $src"; return 1; }
    fi
    [ -d "$d" ] || { echo "  firmware: $src is not a directory or .deb"; return 1; }

    # Locate the firmware root: a package root, an extracted /usr/lib/firmware,
    # or the firmware directory itself.
    #
    # The test has to be structural, not a list of known driver names.  An
    # earlier version looked for amdgpu/ and so silently rejected every package
    # except firmware-amd-graphics; then a list of GPU/WiFi names rejected
    # firmware-misc-nonfree, which carries intel/, moxa/, cxgb3/ and a dozen
    # other trees and is a perfectly valid thing to stage.
    #
    # So: take the first candidate that actually contains something, and let
    # the kernel ignore trees it has no driver for.  Unused firmware is a few
    # MB on a 12 GB ISO; a missing blob is a dead device.
    local fwroot=""
    for c in "$d/usr/lib/firmware" "$d/lib/firmware" "$d"; do
        [ -d "$c" ] || continue
        if [ -n "$(find "$c" -mindepth 1 -maxdepth 1 -type d | head -1)" ] || \
           [ -n "$(find "$c" -mindepth 1 -maxdepth 1 -type f -name '*.bin' | head -1)" ]; then
            fwroot="$c"; break
        fi
    done
    [ -n "$fwroot" ] || { echo "  firmware: nothing to stage under $src"; return 1; }

    sudo mkdir -p "$T/lib/firmware"
    sudo rsync -a "$fwroot/" "$T/lib/firmware/" \
        || { echo "  firmware: rsync failed"; return 1; }

    local n total broken tops
    tops=$(find "$T/lib/firmware" -mindepth 1 -maxdepth 1 -type d | wc -l)
    n=$(find "$T/lib/firmware" -type f | wc -l)
    total=$(find "$T/lib/firmware" -type l | wc -l)
    broken=0
    while IFS= read -r l; do
        [ -e "$l" ] || broken=$((broken + 1))
    done < <(find "$T/lib/firmware" -type l)

    echo "  firmware -> /system/lib/firmware: $tops top-level trees, $n files, $total symlinks, $broken broken"
    [ "$broken" -eq 0 ] || echo "  warning: $broken dangling symlink(s); those blobs will fail to load"
    return 0
}


# demand.
install_pkgs_into_tree() {
    local treeroot="$1" pkgs="$2"
    [ -n "$pkgs" ] || return 0
    [ -n "$KALIFS" ] || { echo "  --pkgs needs --kalifs: no package source without the Kali rootfs"; return 1; }

    local T="$treeroot"
    local key="$T/usr/share/keyrings/kali-archive-keyring.gpg"
    [ -e "$key" ] || { echo "  warning: no Kali keyring in the tree, skipping $pkgs"; return 0; }

    local list=/tmp/kali-pkgs.list
    printf 'deb [signed-by=%s] http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware\n' \
        "$key" | sudo tee "$list" >/dev/null

    # Point apt entirely at the tree: state, status db, lists and cache.  Without
    # Dir::State this writes into the host's /var/lib/apt and disagrees with the
    # status db it is being told to use.
    local A=(-o "Dir=$T" -o "Dir::State=$T/var/lib/apt"
             -o "Dir::State::status=$T/var/lib/dpkg/status"
             -o "Dir::Cache=$T/var/cache/apt"
             -o "Dir::Etc::sourcelist=$list" -o "Dir::Etc::sourceparts=/dev/null"
             -o "Dir::Etc::trusted=/dev/null" -o "Dir::Etc::trustedparts=/dev/null"
             -o "APT::Architecture=amd64")

    sudo mkdir -p "$T/var/lib/apt/lists/partial" "$T/var/cache/apt/archives/partial"
    if ! sudo apt-get "${A[@]}" update >/dev/null 2>&1; then
        echo "  warning: could not update package lists; skipping $pkgs"
        return 0
    fi

    # --download-only first, so a resolution failure costs nothing and the count
    # is known before anything is written into the tree.
    if ! sudo apt-get "${A[@]}" -y --no-install-recommends --download-only \
            install $pkgs >/dev/null 2>&1; then
        echo "  warning: could not resolve: $pkgs"
        return 0
    fi

    local n=0 fail=0 d
    for d in "$T"/var/cache/apt/archives/*.deb; do
        [ -e "$d" ] || continue
        if sudo dpkg-deb --extract "$d" "$T" 2>/dev/null; then
            n=$((n + 1))
        else
            fail=$((fail + 1))
        fi
    done
    echo "  packages: $n unpacked into the tree, $fail failed"
    # Leave the archives: they are small, and a failed unpack is easier to look at
    # than to reproduce.
    return 0
}

        note "Merging the Kali rootfs into the system tree"

        KSTAGE="$WORK/kali-stage"
        sudo rm -rf "$KSTAGE"; mkdir -p "$KSTAGE"

        # Extract to a staging dir first so the layout can be inspected before
        # anything touches the Android tree.  .tar.xz is the real format -- a
        # .tar.gz name with xz inside fails on the first block, so pick the
        # decompressor from the actual extension and try tar's autodetect last.
        case "$KALIFS" in
            *.tar.xz|*.txz) sudo tar -xJf "$KALIFS" -C "$KSTAGE" ;;
            *.tar.gz|*.tgz) sudo tar -xzf "$KALIFS" -C "$KSTAGE" ;;
            *.tar.zst)      sudo tar --zstd -xf "$KALIFS" -C "$KSTAGE" ;;
            *.tar)          sudo tar -xf  "$KALIFS" -C "$KSTAGE" ;;
            *)              sudo tar -xf  "$KALIFS" -C "$KSTAGE" ;;
        esac

        # Tarballs come rooted three ways: kali-amd64/ (Kali's packaging), a
        # different single directory name, or a bare top level.  Pick whichever
        # actually holds the root rather than assuming, and say which was used
        # -- guessing wrong here silently merges an empty tree.
        KSRC=""
        for cand in "$KSTAGE/kali-amd64" "$KSTAGE"; do
            if [ -d "$cand/etc" ] || [ -d "$cand/usr" ] || [ -d "$cand/bin" ]; then
                KSRC="$cand"; break
            fi
        done
        if [ -z "$KSRC" ]; then
            # One directory deep, whatever it is called.
            for cand in "$KSTAGE"/*/; do
                [ -d "${cand}etc" ] || [ -d "${cand}usr" ] || continue
                KSRC="${cand%/}"; break
            done
        fi
        [ -n "$KSRC" ] \
            || die "$(basename "$KALIFS") does not look like a rootfs (no etc/, usr/ or bin/ at any of the likely levels)"
        echo "  root of the tarball: ${KSRC#$KSTAGE/}"
        echo "  staged $(sudo du -sh "$KSRC" | cut -f1)"

        # Recursive merge into DarkMatter's own rootfs.
        #
        # This is the NetHunter Lite trick -- let the two trees share one
        # filesystem instead of boxing Kali away -- applied to the full Pro
        # rootfs so the result is a real Linux userland and not a chroot.
        #
        # Merging directory-by-directory is what makes it work.  At the top
        # level the names collide almost everywhere (bin, lib, etc, usr), but
        # the *files* mostly do not:
        #
        #   Android /system/bin   toybox, sh, logcat
        #   Kali    /bin          bash, nmap, apt, python3      <- no collision
        #   Android /system/lib   libc.so      (bionic)
        #   Kali    /lib/x86_64-linux-gnu/libc.so.6 (glibc)     <- no collision
        #
        # So merge every directory and only step in where a single path is
        # really claimed twice.  A colliding Kali file keeps its whole path
        # under /kali-keep/, so nothing is ever silently dropped and nothing
        # ever overwrites Android -- the one outcome that cannot be undone on a
        # flashed system is a bionic libc replaced by glibc.
        KEEP="$SYS/kali-keep"
        sudo mkdir -p "$KEEP"

        # Record Android's existing paths FIRST.  Checking afterwards is
        # useless: once rsync has run, every Kali path exists, so everything
        # looks like a collision and nothing is reported as merged.
        # sudo on the find, not the pipeline: the system tree was extracted as
        # root, so an unprivileged walk dies on the first 0700 directory and
        # `set -e` turns that into a failed fuse *after* an 11 GB stage.
        ( cd "$SYS" && sudo find . -path ./kali-keep -prune -o -print ) \
            | sed 's|^\./||' | sort > "$WORK/android.before"

        # 1. Everything that does not collide goes straight into the tree.
        #    --ignore-existing never replaces a path that already exists, which
        #    is the whole safety property; it still descends into directories
        #    that exist on both sides (verified: src/lib/k.so lands in dst/lib
        #    while dst/lib/a.so keeps its own contents).
        sudo rsync -a --ignore-existing \
            --exclude '/dev/' --exclude '/proc/' --exclude '/sys/' \
            --exclude '/run/' --exclude '/tmp/' --exclude '/lost+found/' \
            --exclude '/.dockerenv' --exclude '/etc/mtab' \
            "$KSRC/" "$SYS/"

        # 2. Find what rsync refused, and keep it verbatim under /kali-keep.
        #    A Kali path is a collision iff Android already had that exact path
        #    before the merge.  Only files are stashed -- a shared directory is
        #    not a conflict, it is the merge point.
        ( cd "$KSRC" && sudo find . -path ./dev -prune -o -path ./proc -prune \
              -o -path ./sys -prune -o -path ./run -prune -o -path ./tmp -prune \
              -o -path ./lost+found -prune -o -type f -print ) \
            | sed 's|^\./||' | sort > "$WORK/kali.files"
        n_total=$(wc -l < "$WORK/kali.files")
        n_collide=0
        while IFS= read -r rel; do
            grep -qxF "$rel" "$WORK/android.before" || continue
            sudo mkdir -p "$KEEP/$(dirname "$rel")"
            sudo cp -a "$KSRC/$rel" "$KEEP/$rel"
            n_collide=$(( n_collide + 1 ))
        done < "$WORK/kali.files"
        echo "  Kali files:     $n_total total"
        echo "  merged in place: $(( n_total - n_collide ))"
        echo "  kept under /kali-keep: $n_collide (Android already owned that path)"

        # 3. Report the collisions that actually matter -- a replaced libc or
        #    linker would break Android, so surface those by name rather than
        #    leaving the operator to discover it at boot.
        sudo find "$KEEP" -type f \( -name 'libc.so*' -o -name 'ld-*.so*' \
             -o -name 'libstdc++*' -o -name 'libgcc_s*' \) 2>/dev/null \
            | sed "s|^$KEEP|  |" | sed 's|^  /|  /kali-keep/|' | head -5

        # 4. Kali's own view of the tree.  Without this, /etc/apt, /usr/bin and
        #    friends resolve into Android's paths -- which is exactly the split
        #    that makes a merged rootfs unreliable.  A profile.d entry puts the
        #    Kali copies first and points PATH at them, so a Kali shell sees a
        #    Debian layout while Android's own processes are unaffected.
        if [ -d "$SYS/etc" ]; then
            sudo mkdir -p "$SYS/etc/profile.d"
            sudo tee "$SYS/etc/profile.d/10-kali-nethunter.sh" >/dev/null <<'KPROF'
# Kali NetHunter Pro is merged into this same rootfs.  Paths Android also
# claimed were preserved under /kali-keep, so a Kali shell prefers them.
for d in /kali-keep/bin /kali-keep/sbin /kali-keep/usr/bin /kali-keep/usr/sbin; do
    [ -d "$d" ] && PATH="$d:$PATH"
done
export PATH
[ -d /kali-keep/usr/share/man ] && MANPATH="/kali-keep/usr/share/man:${MANPATH:-}"
export MANPATH
KPROF
            echo "  /etc/profile.d/10-kali-nethunter.sh written"
        fi

        # --- make the merged user space actually executable ------------------
        #
        # On a Debian/Kali rootfs /lib64/ld-linux-x86-64.so.2 is the ELF
        # interpreter every dynamically linked binary names.  Kali ships the real
        # file at /usr/lib64/ and relies on usrmerge to create the /lib64 symlink
        # at boot.
        #
        # That can never happen here: Android owns /lib64 as a real directory full
        # of bionic libraries, so usrmerge cannot replace it with a symlink, and
        # --ignore-existing means Kali's copy could not overwrite it either.  The
        # result is a tree where glibc binaries are present and none of them can
        # start:
        #
        #   chroot . /usr/bin/dolphin  ->  No such file or directory
        #
        # which reads as a missing app rather than a missing loader.  Create the
        # one symlink usrmerge would have created.  It is a single file inside
        # Android's /lib64, so nothing bionic owns is touched.
        for ld in /usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 \
                  /usr/lib64/ld-linux-x86-64.so.2; do
            if [ -e "$SYS$ld" ] && [ ! -e "$SYS/lib64/ld-linux-x86-64.so.2" ]; then
                sudo ln -sfn "../${ld#/}" "$SYS/lib64/ld-linux-x86-64.so.2"
                echo "  /lib64/ld-linux-x86-64.so.2 -> ../${ld#/} (usrmerge would have made this)"
                break
            fi
        done
        # Extra packages, after the loader is in place: resolving them needs a
        # working apt and a tree whose interpreter exists.
        if [ -n "$EXTRA_PKGS" ]; then
            note "Installing extra packages into the merged tree: $EXTRA_PKGS"
            install_pkgs_into_tree "$SYS" "$EXTRA_PKGS" || true
        fi

        # Device firmware.  NOT inside the --pkgs block: firmware is its own
        # concern and the ISO build passes --firmware without --pkgs.  Nested
        # there, every image so far shipped an amdgpu driver with no microcode
        # and a Wi-Fi driver with no blob, and said nothing.
        #
        # It still runs after packages, so a firmware-nonfree deb installed via
        # --pkgs is picked up when --firmware was not given explicitly.
        if [ -n "$FIRMWARE_SRC" ]; then
            note "Staging device firmware"
            _fw_fail=0
            _fw_ok=0
            _ifs="$IFS"; IFS=','
            for _fw in $FIRMWARE_SRC; do
                IFS="$_ifs"
                [ -n "$_fw" ] || { IFS=','; continue; }
                if stage_firmware "$_fw" "$SYS"; then
                    _fw_ok=$((_fw_ok + 1))
                else
                    echo "  firmware: FAILED to stage $_fw"
                    _fw_fail=$((_fw_fail + 1))
                fi
                IFS=','
            done
            IFS="$_ifs"
            unset _ifs _fw
            FK="$SYS/lib/firmware"
            echo "  firmware staged from $_fw_ok package(s); $FK has $(sudo find "$FK" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l) top-level entries"
            # A GPU with no microcode falls back to efifb at 1024x768; a Wi-Fi
            # card with no blob never appears.  Neither is a silent success.
            if [ "$_fw_fail" -gt 0 ]; then
                die "$_fw_fail firmware package(s) failed to stage -- the image would boot without working devices"
            fi
            unset _fw_fail _fw_ok
        fi

        rm -f "$WORK/kali.files" "$WORK/android.before"
        sudo rm -rf "$KSTAGE"
    elif [ -d "$GH_DIR/nh-unpacked/rootfs/kali-amd64" ]; then
        note "Merging the Kali rootfs (from nh-unpacked) into the system tree"
        KSRC="$GH_DIR/nh-unpacked/rootfs/kali-amd64"
        sudo mkdir -p "$SYS/kali"
        for d in usr var opt srv home root run boot tmp; do
            [ -e "$KSRC/$d" ] || continue
            sudo cp -a "$KSRC/$d" "$SYS/$d" 2>/dev/null || sudo rsync -a "$KSRC/$d/" "$SYS/$d/"
        done
        for d in bin sbin lib lib64 lib32 media system vendor etc app priv-app framework fonts xbin; do
            [ -e "$KSRC/$d" ] || continue
            [ -e "$SYS/$d" ] && sudo cp -a "$KSRC/$d" "$SYS/kali/$d" || sudo cp -a "$KSRC/$d" "$SYS/$d"
        done
        echo "  kali tree merged from $KSRC"
    else
        echo "  warning: no Kali rootfs found (pass --kalifs)"
    fi

    # --- NetHunter module scripts ---------------------------------------------
    #
    # There is deliberately NO first-boot rootfs extraction and NO
    # nethunter.rc chroot hook here.  Earlier revisions of this script shipped
    # the Kali tarball inside /system and expanded it into
    # /data/local/nhsystem at first boot, which is exactly the NetHunter Lite
    # model -- a second user space behind a chroot.  The Kali tree is merged
    # into this rootfs above instead, so by the time the ISO is built there is
    # one filesystem and nothing left to unpack.  The hook is actively removed
    # so an older tree cannot reintroduce it.
    sudo rm -f "$SYS/etc/init/nethunter.rc" "$SYS/etc/nethunter/nh-firstboot.sh"
    if [ -f "$SYS/etc/nethunter/nh-firstboot.sh" ]; then
        die "could not remove the old first-boot chroot hook"
    fi

    # Keep the module's own boot scripts, which are plain shell run from
    # /system/etc/nethunter -- they set properties and start services in the
    # one user space and do not chroot anything.
    if [ -d "$SYS/etc/nethunter" ]; then
        chmod_probe=$(sudo find "$SYS/etc/nethunter" -maxdepth 1 -name '*.sh' | wc -l)
        echo "  /system/etc/nethunter: $chmod_probe module script(s), no chroot hook"
    fi

    # --- repack ---------------------------------------------------------------
    #
    # Two layers, and the order matters:
    #
    #   system.img   ext4, contains the /system tree
    #   system.sfs   squashfs wrapper containing exactly one file: system.img
    #
    # Monolithic layout: the ISO carries a plain `system/` directory.
    #
    # This is not a shortcut, it is the shape android-x86 installs natively.
    # From the base ISO's own initrd:
    #
    #   elif [ -d /mnt/$SRC/system ]; then
    #       remount_rw
    #       mount --bind /mnt/$SRC/system system
    #
    # and its installer:
    #
    #   if [ "$fs" = "vfat" -o "$fs" = "fuseblk" ]; then
    #       sysimg="mnt/$SRC/system.*"        # image, for FAT only
    #   else
    #       sysimg="android/system"           # a directory, for ext4
    #   fi
    #
    # On ext4 -- which is what a normal Linux install on the Vivobook's NVMe
    # uses -- the installer cpio's that directory tree straight onto the target
    # partition.  No image, no loop mount, no filesystem inside a filesystem.
    #
    # The system.sfs/system.img pair only exists for FAT and for the live boot.
    # It is also what forced the 4 GiB single-file fight, and what made the
    # payload cost twice its size while handing /system a fixed 90 MB of free
    # space.  A plain tree has neither problem: it is exactly as large as its
    # contents, and it is the same thing the user gets from any distro ISO.
    note "Writing the monolithic system tree"

    # SYS is set by the unpacking block above and points at the tree in every
    # input form (wrapper, bare image, directory).  Use it rather than assuming
    # $WORK/sysroot: on a directory input that path does not exist.
    ROOT="$SYS"
    # Descend only when SYS is a *container* (an extracted android root that
    # holds system/ inside it).  If it already looks like a system root, the
    # presence of a system/ subdirectory is not a reason to descend -- Kali's
    # tarball has a top-level system/ and this used to land us in
    # <sysroot>/system/system, which then failed the payload check.
    is_sysroot=0
    for marker in build.prop bin framework lib; do
        [ -e "$ROOT/$marker" ] && { is_sysroot=1; break; }
    done
    if [ "$is_sysroot" -eq 0 ] && [ -d "$ROOT/system" ]; then
        ROOT="$ROOT/system"
    fi

    used_kb=$(sudo du -sk "$ROOT" | cut -f1)
    # Say where the weight is.  A surprise here usually means modules with
    # debug info or a duplicate payload, and it is much cheaper to see it than
    # to work it out from the final image size.
    echo "  largest directories in the payload:"
    # sort writes into head, and if head exits first sort takes SIGPIPE; under
    # set -o pipefail that kills the whole script with no message.  Collect
    # first, then print.
    top=$(sudo du -sk "$ROOT"/* 2>/dev/null | sort -rn | sed -n '1,6p' || true)
    if [ -n "$top" ]; then
        printf '%s\n' "$top" | awk '{printf "    %8s  %s\n", $1/1024 "M", $2}'
    fi
    echo "  payload: $(numfmt --to=iec $((used_kb*1024)))"

    # Replace the two-layer image with a directory.  Removing the old
    # system.sfs matters: the initrd tries system.sfs first, so leaving it in
    # place would boot the stale image and silently ignore everything below.
    rm -rf "$ISO_ROOT/system" "$ISO_ROOT/system.sfs"
    mv_to="$ISO_ROOT/system"
    # Only move when the tree really is our own scratch copy.  --system also
    # accepts a directory the user passed in, and moving that would delete it
    # from under them; copy in that case.
    case "$ROOT" in
        "$WORK"/*) sudo mv "$ROOT" "$mv_to" ;;
        *)         sudo cp -a "$ROOT" "$mv_to" ;;
    esac
    sudo chown -R "$(id -u):$(id -g)" "$mv_to"
    # The installer does `chown 0.0 *` itself, but the tree must ship with
    # root-owned paths and sane modes or a live boot gets a mismatched system.
    echo "  system/: $(find "$mv_to" | wc -l) paths, $(du -sh "$mv_to" | cut -f1)"
    # Only the markers every Android system tree has.  priv-app, framework and
    # lib64 are common but not universal, and a false failure here is worse
    # than a soft warning: it blocks a perfectly good tree.
    for must in bin etc build.prop; do
        [ -e "$mv_to/$must" ] || die "system/$must is missing -- this is not an Android system tree"
    done
    for nice in framework lib lib64 priv-app vendor; do
        [ -e "$mv_to/$nice" ] || echo "  note: system/$nice absent"
    done
    # Android needs lib, lib64 and vendor reachable at the top level too; the
    # base image keeps vendor inside system/, so nothing extra to place there.
    [ -d "$mv_to/vendor" ] && echo "  system/vendor/ present"

    sudo rm -rf "$WORK/sysroot"
fi

# ------------------------------------------------------------------------------
# 4c. SELinux: one policy, two libcs
# ------------------------------------------------------------------------------
# The kernel already runs bionic and glibc processes side by side -- it does not
# care which libc a binary was linked against.  What decides whether the merged
# rootfs is *usable* is labeling and domain, not libc support.
#
# Where the policy actually lives, verified against the base ISO:
#
#   ramdisk.img  ->  sepolicy (175 KB), file_contexts.bin, selinux_version
#   system.img   ->  nothing.  No /sepolicy, no file_contexts, no selinux dir.
#
# selinux_version says Android-x86/android_x86_64/x86_64:7.1.1/NMF26O, and the
# policy contains su_exec and su_tmpfs but no permissive or unconfined domain.
# So the loaded policy is a real 7.1 Android policy, and it is loaded from the
# ramdisk -- writing policy files into /system would do nothing at all on this
# image, which is why this step verifies rather than assumes.
#
# Consequences that matter for a merged rootfs:
#
#   1. Android 7.1 policy has no CIL.  It is a binary policy (secilc output is
#      not consulted by a 7.1 init), so there is no supported way to add a
#      Kali domain by dropping a file next to it.  Pretending otherwise would
#      ship a file nothing reads.
#   2. The policy predates the merged tree, so every Kali path is unlabeled.
#      Under enforcing that means denials, and under permissive it means the
#      kernel logs them and continues -- which is exactly what is needed to
#      bring up a merged system for the first time.
#   3. su_exec already exists.  KernelSU-Next's su is the one domain in this
#      policy designed to cross the Android/other boundary, so Kali processes
#      are started from it rather than being given a new type that cannot be
#      compiled in.
#
# Therefore: keep the image permissive while the merged tree is being proven,
# and record precisely what to do when flipping to enforcing.
if [ -d "$SYS" ] && [ "$NO_FUSE" -eq 0 ]; then
    note "SELinux for the merged rootfs"

    # Report what policy is actually present, from the ramdisk where it lives.
    POL_FOUND=""
    for cand in "$ISO_ROOT/ramdisk.img" "$ISO_ROOT/sepolicy"; do
        [ -f "$cand" ] || continue
        case "$cand" in
            */ramdisk.img)
                if zcat "$cand" 2>/dev/null | cpio -t --quiet 2>/dev/null | grep -qx 'sepolicy'; then
                    POL_FOUND="$cand (inside the ramdisk)"
                fi ;;
            *) POL_FOUND="$cand" ;;
        esac
        [ -n "$POL_FOUND" ] && break
    done
    if [ -n "$POL_FOUND" ]; then
        echo "  policy: $POL_FOUND"
        echo "  note: a 7.1 binary policy -- it cannot take a CIL module, so the"
        echo "        merged Kali tree runs under the domains already defined"
    else
        echo "  warning: no SELinux policy found; the kernel will run unconfined"
    fi

    # Make permissive explicit and reversible.  Not a silent disable: this is
    # written as a property so it is visible in one place and one edit away
    # from enforcing.
    if [ -f "$SYS/build.prop" ]; then
        if ! grep -q '^ro.boot.selinux=' "$SYS/build.prop" 2>/dev/null; then
            echo 'ro.boot.selinux=permissive' | sudo tee -a "$SYS/build.prop" >/dev/null
        fi
        echo "  build.prop: ro.boot.selinux=permissive"
    fi

    # Record the enforcing roadmap where an operator will find it, not in a
    # commit message nobody reads at 2am with a dead laptop.
    sudo mkdir -p "$SYS/etc/nethunter"
    sudo tee "$SYS/etc/nethunter/SELINUX.md" >/dev/null <<'SEMD'
# SELinux on the unified rootfs

The kernel runs bionic and glibc processes equally well; SELinux is the layer
that has to be told both are legitimate.

## Where the policy lives

`ramdisk.img` holds `sepolicy`, `file_contexts.bin` and `selinux_version`
(Android-x86 7.1.1). `/system` holds none of them. Editing /system policy files
has no effect on this image.

## Current state

`ro.boot.selinux=permissive` is set in `/system/build.prop`. Denials are logged
to dmesg and nothing is blocked, which is what lets a merged tree come up.

## Going to enforcing

1. Boot permissive and collect denials:
   `dmesg | grep avc`
2. Every denial against a Kali path (`/system/kali-keep/...`) is a missing
   label. Android 7.1 policy has no CIL support, so the labels must be added to
   the platform policy with the AOSP sepolicy toolchain for this policy
   version -- not by dropping a file into /system.
3. `su_exec` and `su_tmpfs` already exist. KernelSU-Next's su is the existing
   domain meant to cross the Android boundary; run Kali processes from it
   instead of inventing a type the policy cannot contain.
4. Only then set `ro.boot.selinux=enforcing`.

Do not disable SELinux to make the merge "work", and do not flatten labels to
system_file. Both boot, and both throw away the separation that stops one
compromised process owning the other userland.
SEMD
    echo "  /etc/nethunter/SELINUX.md written"
fi

# ------------------------------------------------------------------------------
# 4b. The installer: keep the user in charge of the layout
# ------------------------------------------------------------------------------
# install.img copies a fixed list of paths from the CD to the target, including
# $sysimg, which on ext4 is "android/system" -- a directory.  Because the Kali
# tree is merged into that directory at build time, the stock installer already
# carries the whole unified OS, so the copying needs no change at all.
#
# What does need a change is partitioning.  The interactive path is already
# free-form -- it hands the disk to cgdisk or cfdisk and gets out of the way,
# which is how a Linux installer should behave and is left alone.  The *auto*
# path is not: it hardcodes
#
#     sgdisk --new=1::+260M --typecode=1:EF00 --largest-new=2
#
# so the one number the user cannot choose is the one UEFI cares about.  On a
# 256 GB NVMe a 260 MiB ESP is a rounding error and cannot hold a rescue kernel
# or a second OS; on a 32 GB eMMC the same 260 MiB is a real fraction of the
# disk.  Either way the answer differs per machine, which means it should not
# be a constant.
#
# Note what is NOT changed: GPT itself.  UEFI firmware must accept MBR tables
# as well, so a fixed GPT-only policy would be wrong too.  The requirement is
# narrower -- a partition of type EF00 (GPT) or 0xEF (MBR) holding FAT with
# /EFI/BOOT/BOOTX64.EFI.  The installer keeps using GPT because that is what
# its sgdisk path does, but the size, the root filesystem and everything else
# stay the user's decision.
if [ -d "$ISO_ROOT" ] && [ "$NO_FUSE" -eq 0 ]; then
    if [ -f "$ISO_ROOT/install.img" ]; then
        note "Installer: making the ESP size a choice"

        INST_WORK="$WORK/install-work"
        rm -rf "$INST_WORK"; mkdir -p "$INST_WORK"
        if compgen -G "$ISO_ROOT/install.img" >/dev/null && \
           ( cd "$INST_WORK" && zcat "$ISO_ROOT/install.img" 2>/dev/null | cpio -idm --quiet 2>/dev/null ); then
            ONE_INSTALL="$(find "$INST_WORK" -maxdepth 3 -name '1-install' -print -quit 2>/dev/null)"
            if [ -n "$ONE_INSTALL" ] && [ -f "$HERE/installer/patch-1-install.py" ]; then
                if python3 "$HERE/installer/patch-1-install.py" "$ONE_INSTALL"; then
                    # Rebuild with mode and ownership preserved.  cpio -o takes
                    # the modes from the files, so the umask has to be 0 or the
                    # installer's own 0775 directories come back 0755; and the
                    # archive must be root-owned or install.img's files land
                    # owned by whoever built the ISO.  The staging directory
                    # itself is chmod 0775 to match the stock archive, whose
                    # root entry is 0775 (verified against the original: 38
                    # entries, identical file list, uid/gid 0:0).
                    (
                        cd "$INST_WORK" || exit 1
                        chmod 0775 .
                        umask 000
                        find . -print0 | sort -z | cpio --null -o -H newc --owner=0:0 --quiet 2>/dev/null | gzip -9 -n > "$WORK/install.img.new"
                    )
                    if [ -s "$WORK/install.img.new" ]; then
                        mv "$WORK/install.img.new" "$ISO_ROOT/install.img"
                        echo "  install.img rebuilt ($(stat -c %s "$ISO_ROOT/install.img") bytes)"
                        echo "  auto-install now asks for a 100M..N GiB ESP; root takes the rest"
                    else
                        echo "  warning: install.img rebuild produced nothing; leaving the stock one"
                        echo "           (it will still install, with a fixed 260M ESP)"
                    fi
                else
                    echo "  warning: installer did not match the expected text; left unpatched"
                fi
            else
                echo "  note: no 1-install in install.img, or patch script missing -- installer unchanged"
            fi
        else
            echo "  warning: could not unpack install.img; installer unchanged"
        fi
        rm -rf "$INST_WORK"
    else
        echo "  note: no install.img -- live boot only, nothing to patch"
    fi
fi

if [ -d "$ISO_ROOT/nhpro" ]; then
    echo "  warning: /nhpro still present from an older run -- removing"
    rm -rf "$ISO_ROOT/nhpro"
fi

# ------------------------------------------------------------------------------
# 4d. Display: greetd + phosh, not SurfaceFlinger
# ------------------------------------------------------------------------------
# SurfaceFlinger is Android's compositor and it is the *wrong* display manager
# for the desktop half of this OS.  NetHunter Pro brings its own stack, taken
# straight from its debos recipe:
#
#   include/packages-base.yaml     droidian-phosh
#   scripts/setup-system.sh        systemctl enable greetd      (or phosh)
#
# So the session is greetd -> phosh on phoc, a Wayland compositor, with
# squeekboard as the on-screen keyboard (the skel overlay ships its layouts).
# Starting SurfaceFlinger instead would give an Android surface with no Debian
# session in it, which is the exact failure mode of "it boots but there is no
# desktop".
#
# phosh/phoc/greetd are Debian packages and arrive with the merged rootfs, so
# this step enables and configures them rather than installing anything.
if [ -d "$SYS" ] && [ "$NO_FUSE" -eq 0 ] && [ -d "$SYS/kali-keep" -o -d "$SYS/usr" ]; then
    note "Display stack: greetd + phosh (NetHunter Pro's own)"

    # Detect rather than assume: the merged tree is where these landed, and the
    # paths differ depending on whether phosh was in the collided set.
    PHOSH_SESSION=""
    for c in "$SYS/usr/bin/phosh-session" "$SYS/kali-keep/usr/bin/phosh-session" \
             "$SYS/usr/bin/phosh" "$SYS/kali-keep/usr/bin/phosh"; do
        [ -x "$c" ] || [ -e "$c" ] && { PHOSH_SESSION="$c"; break; }
    done
    GREETD=""
    for c in "$SYS/usr/sbin/greetd" "$SYS/kali-keep/usr/sbin/greetd" \
             "$SYS/usr/bin/greetd" "$SYS/kali-keep/usr/bin/greetd"; do
        [ -e "$c" ] && { GREETD="$c"; break; }
    done

    if [ -n "$PHOSH_SESSION" ]; then
        echo "  phosh session: ${PHOSH_SESSION#$SYS}"
    else
        echo "  warning: no phosh-session in the merged tree -- the desktop will not start"
        echo "           (it comes from the droidian-phosh metapackage in the rootfs)"
    fi
    if [ -n "$GREETD" ]; then
        echo "  greetd: ${GREETD#$SYS}"
    else
        echo "  warning: greetd absent; phosh will have to be started by hand"
    fi

    # greetd's config must point at phosh, and it must be the greeter that runs
    # phosh rather than a tty login.  Written into /etc/greetd, which is where
    # both Debian and the NH-Pro recipe put it.
    sudo mkdir -p "$SYS/etc/greetd"
    sudo tee "$SYS/etc/greetd/config.toml" >/dev/null <<'GREETD'
# NetHunter Pro desktop session.
#
# greetd starts phosh on phoc (Wayland).  SurfaceFlinger is not involved: it is
# Android's compositor, and this session is the Debian userland of the same
# machine.  The two coexist because they are two processes, not two display
# servers fighting over one -- Android's own SurfaceFlinger can keep running for
# the Android side.
[terminal]
vt = 1

[default_session]
# phosh-session execs phoc; keep it as the session command so phosh's own
# environment and dbus activation behave the way the packages expect.
command = "phosh-session"
user = "kali"
GREETD
    echo "  /etc/greetd/config.toml: phosh-session on vt 1"

    # phoc needs the DRM device and the input devices.  On a merged rootfs the
    # Debian session runs as a normal user, so state the groups rather than
    # leaving it to a seat manager that is not installed.
    sudo tee "$SYS/etc/nethunter/DISPLAY.md" >/dev/null <<'DMD'
# Display stack

Session: greetd -> phosh-session -> phoc (Wayland). Config in
`/etc/greetd/config.toml`. This is NetHunter Pro's own stack, from its
`droidian-phosh` package set and `scripts/setup-system.sh` which enables
greetd, falling back to phosh.

## Why not SurfaceFlinger

SurfaceFlinger is Android's compositor. The desktop half of this image is a
Debian userland, so it needs a Wayland compositor; phoc is the one phosh is
built for. Both can run as processes on the same kernel -- they are not two
display managers competing for one seat.

## If there is no desktop

1. `systemctl status greetd` -- the service must be enabled.
2. `ls /usr/bin/phosh-session` -- comes from droidian-phosh in the rootfs.
3. `ls -l /etc/greetd/config.toml` -- command must be `phosh-session`.
4. The user must be in `video` and `input` to open the DRM device.
5. `journalctl -u greetd` and `dmesg | grep -i drm` for a missing GPU driver.

## Keyboard

squeekboard, with the layouts the NH-Pro skel overlay ships under
`/usr/share/squeekboard/keyboards`.
DMD
    echo "  /etc/nethunter/DISPLAY.md written"

    # Enable the unit the way the recipe does, without running systemd here.
    for unit in "$SYS/etc/systemd/system/multi-user.target.wants"; do
        sudo mkdir -p "$unit"
        for svc in greetd phosh bluetooth ssh; do
            for link in "$SYS/usr/lib/systemd/system/$svc.service" \
                        "$SYS/lib/systemd/system/$svc.service"; do
                [ -e "$link" ] || continue
                sudo ln -sf "/${link#$SYS/}" "$unit/$svc.service"
                break
            done
        done
    done
    echo "  enabled: $(sudo ls "$SYS/etc/systemd/system/multi-user.target.wants" 2>/dev/null | tr '\n' ' ')"
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

    # -R (Rock Ridge), NOT -r.
    #
    # This is the difference between a working system tree and a brick.  -r is
    # "-rational-rock", which strips ownership and forces every file 444->
    # actually 0555 for directories/0555-or-0444 for files, and drops setuid.
    # Measured on a round trip through xorriso:
    #
    #   original 755 / 644 / 4755 / 600
    #   with -r  555 / 444 / 0555 / 444     <- setuid gone, all writable bits gone
    #   with -R  755 / 644 / 4755 / 600     <- preserved
    #
    # Android's /system is full of 0755 executables and 0644 config, and the
    # installer copies the tree verbatim, so -r would install a system where
    # nothing is executable.  -R keeps POSIX modes, uids and symlinks.
    #
    # -iso-level 3 allows files over 4 GiB.  The tree no longer needs it, but
    # the Kali rootfs still rides along as one large file and level 3 costs
    # nothing -- both El Torito entries are still written.
    # Volume label matches the artefact: DARK_HUNTER, so a mounted or looped
    # image identifies itself as this fusion rather than as a generic AnyRealm
    # build.
    args=(-as mkisofs -R -iso-level 3 -V "DARK_HUNTER" -o "$OUT_ISO")
    if [ -n "$BOOT_BIOS" ]; then
        args+=(-b isolinux/isolinux.bin -c isolinux/boot.cat
               -no-emul-boot -boot-load-size 4 -boot-info-table)
    else
        echo "  warning: no isolinux.bin -- BIOS boot unavailable"
    fi
    if [ -n "$BOOT_EFI" ]; then
        args+=(-eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot)

        # El Torito alone does not boot this laptop from USB.
        #
        # El Torito is a CD/DVD mechanism: the firmware reads a boot catalog in
        # the ISO's first sectors.  Written to a USB stick, a UEFI machine does
        # not look at that catalog at all -- it enumerates partitions, finds one
        # with the ESP type, and runs /EFI/BOOT/BOOTX64.EFI from it.
        #
        # The base DarkMatter ISO has no partition table whatsoever (MBR
        # signature is 0000, not 55aa), so on the Vivobook it boots when written
        # to a DVD and is invisible as a USB stick.  That is the difference
        # between "the ISO works" and "the ISO works on my machine".
        #
        # append_partition writes efi.img a second time as a real GPT/MBR
        # partition of type 0xEF (EFI System), and isohybrid-gpt-basdat adds the
        # protective MBR + GPT so firmware treats the stick as a disk.  Both are
        # needed: the partition without the table is just bytes in the file.
        #
        # isohybrid-gpt-basdat writes GPT only when it also has an MBR template
        # to base the protective MBR on; without one it produces a bare MBR
        # table and the GPT header stays empty.  Firmware that prefers GPT then
        # falls back to MBR, which usually works but is not what the UEFI spec
        # describes as removable-media boot.  Supply the template so both
        # tables are real.
        ISO_MBR_TEMPLATE=""
        for t in /usr/lib/ISOLINUX/isohdpfx.bin /usr/lib/syslinux/mbr/isohdpfx.bin \
                 /usr/share/syslinux/isohdpfx.bin; do
            [ -f "$t" ] && { ISO_MBR_TEMPLATE="$t"; break; }
        done
        if [ -n "$ISO_MBR_TEMPLATE" ]; then
            args+=(-isohybrid-mbr "$ISO_MBR_TEMPLATE")
        else
            echo "  warning: no isohdpfx.bin; writing MBR-only (no GPT) -- install isolinux"
        fi
        args+=(-append_partition 2 0xef "$ISO_ROOT/boot/grub/efi.img"
               -isohybrid-gpt-basdat)
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

    # Verify the thing the Vivobook actually needs: a partition table with an
    # ESP, so the ISO also boots from a USB stick and not only from a DVD.
    if [ -n "$BOOT_EFI" ]; then
        if python3 - "$OUT_ISO" <<'PYCHK'
import sys
d = open(sys.argv[1], 'rb').read(2048)
assert d[510:512] == b'\x55\xaa', "no DOS partition table (UEFI will not see this USB stick)"
esp = [e for e in (d[446 + i*16:446 + (i+1)*16] for i in range(4)) if e[4] == 0xef]
assert esp, "no EFI System partition (MBR type 0xef)"
PYCHK
        then
            echo "        hybrid: MBR + ESP present (boots from USB, not just DVD)"
        else
            echo "  WARNING: ISO has no ESP partition table -- it will boot as a DVD"
            echo "           but a UEFI laptop may not see it on a USB stick."
        fi
    fi
else
    note "Staged tree only (--no-iso)"
    ls -la "$ISO_ROOT" | sed 's/^/  /'
fi
