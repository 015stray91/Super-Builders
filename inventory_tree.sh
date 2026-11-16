#!/usr/bin/env bash
# Dump a compact inventory of an unpacked tree: paths, sizes, checksums of the
# small text files that matter.  Fed to the fuser script this is enough to get
# every path right, without shipping multi-GB images anywhere.
#
#   ./inventory_tree.sh /path/to/unpacked-dir > inventory.txt
#
# Nothing is uploaded and no file is modified.

set -euo pipefail

DIR="${1:-.}"
[ -d "$DIR" ] || { echo "not a directory: $DIR" >&2; exit 1; }

cd "$DIR"

echo "# inventory of $(pwd)"
echo "# generated $(date -u +%FT%TZ)"
echo "# host: $(uname -sr)"
echo

echo "## top level"
find . -maxdepth 1 -mindepth 1 -printf '%y %10s  %p\n' 2>/dev/null | sort -k3
echo

echo "## directories (depth 3), excluding bulky trees"
find . -maxdepth 3 -mindepth 1 -type d \
     -not -path './.git*' \
     -not -path '*/lib/firmware*' \
     -not -path '*/usr/share/*' \
     -printf '%p\n' 2>/dev/null | sort | head -400
echo

echo "## files >= 1M (name + size only; not uploaded)"
find . -type f -size +1M -not -path './.git/*' \
     -printf '%10s  %p\n' 2>/dev/null | sort -k2 | head -200
echo

echo "## total"
echo "  files: $(find . -type f -not -path './.git/*' 2>/dev/null | wc -l)"
echo "  bytes: $(du -sb . 2>/dev/null | cut -f1)"
echo

echo "## small text files that describe the image"
for f in \
    install.img initrd.img ramdisk.img kernel vmlinuz system.sfs \
    isolinux.bin boot.cat \
    efi/boot/android.cfg boot/grub/grub.cfg \
    efi/boot/TRANS.TBL TRANS.TBL \
    efiboot.img anykernel.sh; do
    if [ -f "$f" ]; then
        printf '### %s (%s bytes)\n' "$f" "$(stat -c %s "$f")"
        case "$f" in
            *.cfg|*.sh|*TRANS.TBL) sed 's/^/    /' "$f" | head -80 ;;
            *) echo "    (binary)" ;;
        esac
        echo
    fi
done

echo "## paths the fuser looks for"
for p in \
    squashfs-root squashfs-root/system squashfs-root/system/etc \
    system.sfs system.img \
    system/bin system/etc system/priv-app \
    data/app rootfs rootfs/kali-amd64 \
    modules modules/lib/lib/modules lib/modules \
    efi efi/boot boot boot/grub; do
    [ -e "$p" ] && echo "  FOUND   $p" || echo "  missing $p"
done
