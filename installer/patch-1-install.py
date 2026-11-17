#!/usr/bin/env python3
"""Patch the DarkMatter installer so UEFI layout is a choice, not a constant.

Why this exists
---------------
The stock installer already lets the user partition the disk interactively
(cgdisk/cfdisk) -- that is standard Linux behaviour and it should stay.  What
it hardcodes is the *auto* path:

    sgdisk --new=1::+260M --typecode=1:EF00 --largest-new=2 --typecode=2:8300

260 MiB for the ESP and "everything else" for root.  On a 256 GB NVMe that is
wasteful and, more importantly, it means the one thing the user cannot choose
is the thing the UEFI firmware cares about.  A 260 MiB ESP cannot hold a second
kernel plus a rescue image, and it cannot be shared with another OS later.

What is actually fixed by firmware, and what is not
---------------------------------------------------
GPT is not "required" -- UEFI firmware must accept MBR tables too, and the
installer can convert GPT to MBR for legacy GRUB.  What *is* required for a
UEFI boot is an EFI System Partition: a partition of type EF00 (GPT) or 0xEF
(MBR) holding a FAT filesystem with /EFI/BOOT/BOOTX64.EFI.  Which disk you
install to, how big root is, whether you encrypt, whether there is a separate
/home -- all of that is the user's business.

So this patch keeps the interactive path as-is (it is already free-form), and
changes the automatic path to:

  * ask for the ESP size (with a sane default and a floor),
  * put root on the remainder,
  * keep the same type codes and the same mkdosfs, so nothing downstream in
    1-install has to change.

It rewrites the function body by text replacement and refuses to write if the
expected text is not found, so a future installer change fails loudly instead
of producing a silently-unpatched script.
"""

import re
import sys

# The exact auto_partition() body from the stock Android-x86 7.1.1 installer.
ORIGINAL = r'''	if [ -z "$efi" ]; then
		echo -e "o\nn\np\n1\n\n\nw\n" | fdisk /dev/$1
		p=1
	else
		sgdisk --zap-all /dev/$1
		sgdisk --new=1::+260M --typecode=1:EF00 --largest-new=2 --typecode=2:8300 /dev/$1
		p=2
	fi > /dev/tty6
'''

PATCHED = r'''	if [ -z "$efi" ]; then
		echo -e "o\nn\np\n1\n\n\nw\n" | fdisk /dev/$1
		p=1
	else
		# GPT is the layout we default to, but the sizes are the user's call.
		#
		# 260 MiB is the stock value and is too small for anything but one
		# kernel.  Ask, with a floor of 100M (below that Windows setup and some
		# firmware refuse the ESP) and a default of 512M, which leaves room for
		# a rescue kernel, a second OS later, and grub's own fonts/themes.
		ESP_SIZE="$AUTO_ESP_SIZE"
		if [ -z "$ESP_SIZE" ]; then
			ESP_SIZE=$(dialog --title " EFI System Partition " \
				--inputbox "\nSize of the EFI System Partition (ESP) in MiB.\n\n100M is the firmware minimum; 512M is a comfortable default\nand leaves room for a rescue kernel or a second OS.\nRoot gets the rest of the disk.\n" \
				12 60 "512" 3>&1 1>&2 2>&3)
			[ -z "$ESP_SIZE" ] && rebooting
		fi
		# Strip a trailing M/m; sgdisk wants a bare number with the +N M form.
		ESP_SIZE=$(echo "$ESP_SIZE" | tr -d 'Mm ')
		case "$ESP_SIZE" in
			''|*[!0-9]*) echo "Invalid ESP size '$ESP_SIZE'; using 512M" >&2
			              ESP_SIZE=512 ;;
		esac
		[ "$ESP_SIZE" -lt 100 ] && { echo "ESP below 100M is not bootable; using 100M" >&2
		                             ESP_SIZE=100; }

		sgdisk --zap-all /dev/$1
		sgdisk --new=1::+${ESP_SIZE}M --typecode=1:EF00 \
		       --largest-new=2 --typecode=2:8300 /dev/$1
		p=2
	fi > /dev/tty6
'''


def patch(text: str) -> str:
    if PATCHED.strip() in text:
        return text  # already patched, idempotent
    if ORIGINAL not in text:
        raise SystemExit(
            "1-install: auto_partition() does not match the expected stock text; "
            "refusing to patch. Inspect it rather than guessing -- an unpatched "
            "installer silently keeps the 260M ESP."
        )
    return text.replace(ORIGINAL, PATCHED, 1)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    path = sys.argv[1]
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as fh:
        original = fh.read()
    out = patch(original)
    if out == original:
        print("1-install: already patched")
        return 0
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write(out)
    print("1-install: auto_partition now asks for the ESP size")
    return 0


if __name__ == "__main__":
    sys.exit(main())
