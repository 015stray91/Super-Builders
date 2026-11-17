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
#   ./fuse_darkmatter_nh.sh --base-iso DarkMatter.iso --kernel-dir DIR \
#                           --kalifs kali-amd64.tar.xz [--out DIR]
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
        --base-iso)   BASE_ISO="$2"; shift 2 ;;
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

rm -rf "$WORK" "$ISO_ROOT"
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
        [ -d "$cand" ] && { rsync -a "$cand/" "$MODS/"; break; }
    done
    echo "  $(find "$MODS" -name '*.ko' 2>/dev/null | wc -l) .ko files"
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
        SYS="$SYSTEM_IMG"
        # A plain directory may or may not have the android top-level "system".
        [ -d "$SYS/system" ] && SYS="$SYS/system"
        echo "  system root: $SYS (directory)"
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

    # --- Kali rootfs ---
    if [ -z "$KALIFS" ]; then
        for cand in "$TREE"/nh-unpacked/rootfs/kali-amd64.tar.* "$GH_DIR"/nh-unpacked/rootfs/kali-amd64.tar.* "$GH_DIR"/rootfs/kali-amd64.tar.*; do
            [ -f "$cand" ] && { KALIFS="$cand"; break; }
        done
    fi
    if [ -n "$KALIFS" ] && [ -f "$KALIFS" ]; then
        # The Kali rootfs does NOT belong inside /system.
        #
        # It is 2.2 GB compressed and ~8 GB expanded, and putting it in the
        # system image charged it twice (once in the tree, once in the built
        # image), ate the image's free space, and pushed system.sfs past the
        # 4 GiB single-file limit.  None of that buys anything: it is not part
        # of the Android system, it is the other half of the OS.
        #
        # Ship it at the top level of the ISO instead, as a single file the
        # installer copies to the target and the first boot expands to a real
        # directory on the NVMe.  Real files, real paths, no loop device.
        sudo mkdir -p "$ISO_ROOT/nhpro"
        # Keep the real extension: the Kali rootfs is .tar.xz, and naming it
        # .tar.gz then extracting with `tar -zxf` fails on the first block.
        case "$KALIFS" in
            *.tar.xz|*.txz)   KALI_NAME=kalifs-amd64.tar.xz ;;
            *.tar.gz|*.tgz)   KALI_NAME=kalifs-amd64.tar.gz ;;
            *.tar.zst)        KALI_NAME=kalifs-amd64.tar.zst ;;
            *.tar)            KALI_NAME=kalifs-amd64.tar ;;
            *)                KALI_NAME="kalifs-amd64.$(basename "$KALIFS")" ;;
        esac
        sudo cp -f "$KALIFS" "$ISO_ROOT/nhpro/$KALI_NAME"
        echo "  rootfs -> /nhpro/$KALI_NAME ($(du -h "$KALIFS" | cut -f1))"
    elif [ -d "$GH_DIR/nh-unpacked/rootfs/kali-amd64" ]; then
        sudo mkdir -p "$ISO_ROOT/nhpro"
        sudo tar -czf "$ISO_ROOT/nhpro/kalifs-amd64.tar.gz" \
             -C "$GH_DIR/nh-unpacked/rootfs" kali-amd64
        KALI_NAME=kalifs-amd64.tar.gz
        echo "  rootfs archived from nh-unpacked/rootfs/kali-amd64"
    else
        echo "  warning: no Kali rootfs found (pass --kalifs)"
    fi

    # --- first-boot extraction + module script ---
    # Both dirs must exist before tee runs; the Kali block above only creates
    # /system/etc/nethunter when it actually found a rootfs.
    sudo mkdir -p "$SYS/etc/init" "$SYS/etc/nethunter"
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
    # The rootfs ships at the top of the ISO and the installer copies it to
    # /nhpro on the target; on a live boot it is read straight off the CD.
    for f in /nhpro/kalifs-amd64.tar.* /system/etc/nethunter/kalifs-amd64.tar.*; do
        [ -f "$f" ] || continue
        echo "extracting $(basename "$f")"
        # Android ships toybox tar, which handles gzip but not always xz, and
        # the Kali rootfs is .tar.xz.  Try a direct extract first, then fall
        # back to decompressing to a pipe.
        if tar -xf "$f" -C /data/local/nhsystem/ 2>/dev/null; then
            break
        fi
        case "$f" in
            *.xz)  busybox xz -dc "$f" | tar -x -C /data/local/nhsystem/ && break ;;
            *.gz)  busybox gzip -dc "$f" | tar -x -C /data/local/nhsystem/ && break ;;
            *.zst) busybox zstd -dc "$f" | tar -x -C /data/local/nhsystem/ && break ;;
        esac
        echo "  could not extract $f"
    done
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
    [ -d "$ROOT/system" ] && ROOT="$ROOT/system"

    used_kb=$(sudo du -sk "$ROOT" | cut -f1)
    # Say where the weight is.  A surprise here usually means modules with
    # debug info or a duplicate payload, and it is much cheaper to see it than
    # to work it out from the final image size.
    echo "  largest directories in the payload:"
    sudo du -sk "$ROOT"/* 2>/dev/null | sort -rn | head -6 \
        | awk '{printf "    %8s  %s\n", $1/1024 "M", $2}'
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
    for must in bin build.prop etc framework lib priv-app; do
        [ -e "$mv_to/$must" ] || die "system/$must is missing -- this is not an Android system tree"
    done
    # Android needs lib, lib64 and vendor reachable at the top level too; the
    # base image keeps vendor inside system/, so nothing extra to place there.
    [ -d "$mv_to/vendor" ] && echo "  system/vendor/ present"

    sudo rm -rf "$WORK/sysroot"
fi

# ------------------------------------------------------------------------------
# 4b. Teach the installer to carry the Kali rootfs
# ------------------------------------------------------------------------------
# install.img is a gzipped cpio of the android-x86 installer.  Its 1-install
# script copies a fixed list of paths from the CD onto the target:
#
#   files="mnt/$SRC/kernel mnt/$SRC/gearlock ... $sysimg"
#   ( cd /; find $files | cpio -H newc -o ) | ( cpio -iud )
#
# $sysimg is "android/system" on ext4 -- a directory -- so the monolithic tree
# we just wrote installs natively with no change.  Only /nhpro is unknown to
# it, and a file it does not list is a file that never reaches the disk.  Add
# it to that list so the rootfs is installed in the same pass as the system,
# and so the space check counts it.
if [ -f "$ISO_ROOT/install.img" ] && [ -d "$ISO_ROOT/nhpro" ]; then
    note "Patching the installer to carry /nhpro"
    IPATCH="$WORK/install-patch"
    # sudo: the tree below is unpacked root-owned (the archive is root:root),
    # so an unprivileged rm leaves it behind and the next run reuses a
    # half-patched copy.
    sudo rm -rf "$IPATCH"; mkdir -p "$IPATCH"
    # umask 000 and root ownership matter even here: the installer runs as
    # root and executes these scripts, and a rebuild under the normal umask
    # drops the execute bits (verified: 775 dirs came back 755, and a file
    # list diff that looked clean still had 0775 -> 0755 everywhere).
    ( cd "$IPATCH" && umask 000 && zcat "$ISO_ROOT/install.img" | sudo cpio -idmu --quiet )
    SCRIPT="$IPATCH/scripts/1-install"
    [ -f "$SCRIPT" ] || die "install.img has no scripts/1-install -- unexpected layout"

    if grep -q '\$SRC/nhpro' "$SCRIPT"; then
        echo "  already patched"
    else
        # Anchor on the unchanged file-list line rather than a line number, and
        # fail loudly if the base ISO ever moves it.
        grep -q 'files="mnt/\$SRC/kernel' "$SCRIPT" \
            || die "cannot find the installer file list; refusing to guess"

        # 1. Add /nhpro to the copy list.  Done in python, not sed: the pattern
        # needs a quote and two backslashes inside a shell string, and getting
        # that wrong silently patches nothing.
        sudo python3 - "$SCRIPT" <<'PATCH'
import re, sys
p = sys.argv[1]
s = open(p).read()
s2 = re.sub(r'(files="mnt/\$SRC/kernel[^"]*)"', r'\1 mnt/$SRC/nhpro"', s, count=1)
if s2 == s:
    sys.exit("the installer file list did not match")
open(p, "w").write(s2)
PATCH

        # 2. The Install menu's own idea of required space is 4-8 GB, which is
        # fine for Android alone and far too small with an expanded Kali tree
        # next to it.  Say so where the user picks a partition.
        sudo sed -i 's#Recommended minimum free space - 4GB  |  Optimum free space >= 8GB#Recommended minimum free space - 16GB  |  Optimum free space >= 32GB (Android system + Kali NetHunter Pro rootfs)#' "$SCRIPT" 2>/dev/null || true

        grep -q '\$SRC/nhpro' "$SCRIPT" \
            || die "the installer patch did not take -- /nhpro would not be installed"
        echo "  /nhpro added to the installer's copy list"
    fi

    # Repack it the way it arrived: gzipped newc cpio, root-owned, at the same
    # path the initrd extracts it from.
    # --owner=0:0 so the archive says root:root regardless of how it was
    # unpacked; the original install.img is root-owned and the initrd extracts
    # it as root before running anything.
    ( cd "$IPATCH" && find . -print0 \
        | sudo cpio --null -o -H newc --quiet --owner=0:0 ) \
        | gzip -9 > "$WORK/install.img.new"
    rm -f "$ISO_ROOT/install.img"
    cp -f "$WORK/install.img.new" "$ISO_ROOT/install.img"
    sudo rm -rf "$IPATCH"; rm -f "$WORK/install.img.new"

    # Prove it round-trips before it goes in the ISO.
    zcat "$ISO_ROOT/install.img" | cpio -t --quiet 2>/dev/null | grep -qx 'scripts/1-install' \
        || die "rebuilt install.img is not readable"
    echo "  install.img rebuilt ($(stat -c %s "$ISO_ROOT/install.img") bytes)"
else
    [ -d "$ISO_ROOT/nhpro" ] || echo "  note: no /nhpro -- installer needs no patch"
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
    args=(-as mkisofs -R -iso-level 3 -V "DARKMATTER_NH_KSU" -o "$OUT_ISO")
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
