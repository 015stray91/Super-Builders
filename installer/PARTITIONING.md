# Partitioning: what firmware fixes, and what the user decides

## The short version

The installer must not impose a partition layout. What it *may* fix is the one
thing UEFI firmware actually requires: an EFI System Partition.

## What is genuinely fixed

UEFI firmware boots by finding a FAT-formatted partition of type `EF00` (GPT) or
`0xEF` (MBR) and executing `/EFI/BOOT/BOOTX64.EFI` from it. That is the whole
requirement.

Note what that excludes:

- **GPT is not required.** The UEFI spec requires firmware to accept MBR
  partition tables as well. A GPT-only policy would be as wrong as an MBR-only
  one. The stock installer already knows this — it offers to convert GPT to MBR
  before installing legacy GRUB — and that behaviour is left alone.
- **No size is fixed.** 100 MiB is the practical floor below which some
  firmware and Windows setup refuse the ESP. Above that it is a tradeoff, not a
  constant.
- **No root layout is fixed.** Separate `/home`, LUKS, LVM, btrfs subvolumes,
  a shared ESP with another OS — all user decisions.

## What the stock installer did

Two paths, and they behaved very differently:

| path | behaviour |
|------|-----------|
| interactive | hands the disk to `cgdisk`/`cfdisk` and gets out of the way — correct, unchanged |
| `AUTO_INSTALL` | `sgdisk --new=1::+260M --typecode=1:EF00 --largest-new=2` |

So the automatic path hardcoded 260 MiB for the ESP on every machine. On the
256 GB NVMe in the Vivobook that is a rounding error and cannot hold a rescue
kernel or a second OS; on a 32 GB eMMC the same number is a real fraction of the
disk. The one number the user could not choose was the one that matters to
firmware.

## What the patch changes

`installer/patch-1-install.py` rewrites only the `auto_partition()` ESP branch:

- prompts for the ESP size, default 512 MiB, floor 100 MiB,
- sanitises the input (non-numeric → 512, below 100 → 100),
- puts root on the remainder with the same type codes,
- leaves the interactive path and the BIOS path untouched.

It refuses to write if the expected stock text is not found, so a future
installer change fails loudly instead of silently keeping 260 MiB. It is
idempotent — a second run reports "already patched".

`AUTO_ESP_SIZE` overrides the prompt for unattended installs.

## Verifying the rebuilt install.img

`install.img` is a gzip cpio of the installer ramdisk. Rebuilding it naively
loses the tree's modes and ownership, so the fuser rebuilds it with
`umask 000` and `cpio --owner=0:0`, and `chmod 0775 .` to match the stock
archive's root entry.

Measured against the original (all 38 entries):

| | original | rebuilt |
|---|---|---|
| entries | 38 | 38 |
| file list | — | identical |
| root mode | 0775 | 0775 |
| dirs `bin lib sbin scripts` | 0775 | 0775 |
| `scripts/1-install` | 0664 | 0664 |
| uid/gid | 1000:1000 | 0:0 (normalised, as the fuser intends) |

An installer ramdisk whose files are not root-owned or whose `1-install` is not
executable is not obviously broken — the boot proceeds and fails later, at the
copy step.
