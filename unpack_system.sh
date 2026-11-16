#!/usr/bin/env bash
# Unpack a DarkMatter / android-x86 system image into a plain directory.
#
#   ./unpack_system.sh <system.sfs|system.img|system.raw> [outdir]
#
# Detects what the file actually is rather than trusting the extension:
#   squashfs      -> unsquashfs
#   sparse ext4   -> simg2img, then mount/rsync
#   raw ext4      -> mount/rsync
#   directory     -> copied as-is
#
# Why bother: mksquashfs and rsync both need a directory.  Repacking a
# system.sfs from an unpacked tree is also how you keep the ISO build from
# needing the original (often multi-GB) image around.
#
# NOTE on disk space: an unpacked tree is normally 2-3x the compressed size,
# because squashfs-xz has already squeezed out all the redundancy.

set -euo pipefail

SRC="${1:-}"
OUT="${2:-}"
[ -n "$SRC" ] || { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ -e "$SRC" ] || { echo "error: no such file: $SRC" >&2; exit 1; }

SRC="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"
[ -z "$OUT" ] && OUT="$(dirname "$SRC")/system-unpacked"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

die() { echo "error: $*" >&2; exit 1; }

# --- space check -------------------------------------------------------------
src_sz=$(stat -c %s "$SRC" 2>/dev/null || echo 0)
avail=$(df -B1 --output=avail "$OUT" | tail -1 | tr -d ' ')
# 3x is the usual worst case for squashfs-xz -> files.
need=$(( src_sz * 3 ))
if [ "$avail" -lt "$need" ]; then
    echo "warning: $(numfmt --to=iec "$need") may be needed, only $(numfmt --to=iec "$avail") free on $OUT" >&2
    echo "         continuing; this fails partway if it runs out" >&2
fi

desc="$(file -b "$SRC")"
echo "source: $SRC"
echo "size:   $(numfmt --to=iec "$src_sz")"
echo "type:   $desc"
echo "out:    $OUT"

case "$desc" in
    *Squashfs*|*squashfs*)
        command -v unsquashfs >/dev/null || die "unsquashfs missing (apt-get install squashfs-tools)"
        echo "--- unpacking squashfs"
        sudo unsquashfs -f -d "$OUT" "$SRC" >/dev/null
        ;;

    *ext4*|*ext2*|*ext3*)
        echo "--- ext filesystem"
        MNT="$(mktemp -d)"
        trap 'sudo umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true' EXIT
        sudo mount -o loop,ro "$SRC" "$MNT"
        sudo rsync -a "$MNT/" "$OUT/"
        sudo umount "$MNT"
        ;;

    *Android*sparse*|*sparse*)
        command -v simg2img >/dev/null || die "simg2img missing (apt-get install android-sdk-libsparse-utils)"
        echo "--- converting sparse image to raw"
        RAW="${OUT%/}.raw"
        simg2img "$SRC" "$RAW"
        MNT="$(mktemp -d)"
        trap 'sudo umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true' EXIT
        sudo mount -o loop,ro "$RAW" "$MNT"
        sudo rsync -a "$MNT/" "$OUT/"
        sudo umount "$MNT"
        rm -f "$RAW"
        ;;

    *directory*)
        echo "--- copying directory"
        sudo rsync -a "$SRC/" "$OUT/"
        ;;

    *)
        die "unrecognised image type: $desc
       Check with: file '$SRC'
       If it is a raw android system image, try: simg2img '$SRC' out.raw"
        ;;
esac

# --- report ------------------------------------------------------------------
echo
echo "unpacked: $(du -sh "$OUT" | cut -f1)  ($(find "$OUT" -type f | wc -l) files)"
for p in system system/bin system/etc system/framework system/priv-app; do
    [ -d "$OUT/$p" ] && echo "  has /$p"
done
echo
echo "Now pass this directory as --system:"
echo "  ./fuse_darkmatter_nh.sh --gh <gh-dir> --system '$OUT' ..."
