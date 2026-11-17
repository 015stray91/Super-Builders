# Forward-porting: what CodeLinaro is and is not

Reference tag: `refs/tags/android12-5.10.270_r00` in `clo/la/kernel/msm-5.10`
(`e2d2f4a03413c6dd311f4debc83ccbf3824885a2`, peeled `a5829f70`, dated 2026-10-14).

## It is a full kernel tree, not an arm64 tree

`msm-5.10` is upstream 5.10.270 plus Qualcomm's msm additions. It carries every
architecture directory, including `arch/x86/` and
`arch/x86/configs/x86_64_defconfig`. Nothing about the reference itself is
arm64-only. What is Qualcomm-specific is the SoC support (drivers, DTBs, clock
and interconnect trees), and none of that is used by a build targeting amd64.

So porting *from* this reference is not "porting from arm64". It is porting a
patch set across two different axes, and it is worth keeping them apart:

| Axis | From | To | What actually breaks |
|------|------|----|----------------------|
| kernel version | 5.10 | 6.12 | VFS internals: `iterate_dir` signature, `filldir` vs `filldir64`, `d_path`, `task_mmu` and `proc` layouts, `set_fs` removal |
| Android version | android12 | android16 | GKI enablement and the KernelSU glue around it, not the VFS |
| architecture | arm64 (msm) | amd64 (Android-x86) | nothing in SUSFS/ZeroMount; only device-specific fixes |

The third row being empty is the useful finding, and it is checkable rather
than assumed:

```
$ grep -hoE "\b(vfs_[a-z_]+|kern_path[a-z_]*|iterate_dir|filldir[0-9]*|path_openat|task_mmu|inode_permission)\b" \
    50_*.patch 51_*.patch 60_*.patch 65_*.patch | sort | uniq -c | sort -rn
     24 kern_path
     14 path_openat
     12 task_mmu
      8 iterate_dir
      4 vfs_statx
    ...
```

Every hook is generic VFS. There is no `asm/`, no `CONFIG_ARM64`, no
`aarch64` in the generated `fs/susfs.c` or `fs/zeromount.c`:

```
$ grep -nE "CONFIG_ARM64|CONFIG_X86_64|asm/" fs/susfs.c fs/zeromount.c
(no output)
```

That is why the same four patches (50/51/60/65) exist once per kernel version
and serve every architecture in the tree.

## Verified against the real 5.10.270 source

Applied in order to a pristine `android12-5.10.270_r00` checkout:

| patch | result |
|-------|--------|
| `50_add_susfs_in_gki-android12-5.10.patch` | applies clean |
| `51_enhanced_susfs-android12-5.10.patch` | applies clean (on top of 50) |
| `60_zeromount-android12-5.10.patch` | applies clean |
| `65_zeromount-adb-filter-android12-5.10.patch` | applies clean |

Producing `fs/susfs.c` (52 KB), `fs/zeromount.c` (36 KB) and their headers.

Patches that do **not** belong in this list:

- `10_enable_susfs_for_ksu.patch` — targets the KernelSU source tree, not the
  kernel. Newer KernelSU-Next ships its own `kernel/susfs/` LKM driver
  (`8f573af0`), so this patch is superseded rather than merely stale.
- `70_ksu_safety-kernelsu-next-5.10.patch` — also KernelSU-side; applies
  cleanly to the pinned KSU tree for 5.10, which is what the GKI workflows
  expect.
- `80_nuki_colonel_source_fixes.patch` — genuinely arm64-only: it disables
  `CONFIG_ARM64 && CONFIG_KERNEL_MODE_NEON` branches around
  `LZ4_arm64_decompress_safe` in `crypto/lz4.c` and `crypto/lz4hc.c`. It is a
  NUKI/Motorola device fix, wired into no workflow, and meaningless on amd64.

## Sublevels are not branches

This is the trap that makes 270 look unavailable. Manifests are branched by
month, tags are named by sublevel:

```
android12-5.10-2026-10   -> 5.10.269   (branch head)
android12-5.10.270_r00   -> 5.10.270   (tag, one merge past the head)
```

There is no `common-android12-5.10-2026-10-270` branch and no manifest tag, so
`repo init -b <something naming 270>` cannot work. `sync-gki-source.sh` syncs
the month branch for the requested OS patch level, then checks out
`refs/tags/android12-5.10.<sublevel>_r00` and asserts the resulting `SUBLEVEL`.
If a sublevel has no tag it stays on the branch and warns, instead of shipping
an artifact labelled 270 that is really 269.

Sublevels 260/264/270 are all tags on top of the 2026-07 and 2026-10 branches
respectively; 252/257/269 are branch heads.

## On 32-bit compatibility

`CONFIG_IA32_EMULATION=y` is a *user-space* facility: it lets an x86_64 kernel
execute i386 ELF binaries. It has nothing to do with the portability of kernel
source between arm64 and amd64, and nothing to do with SUSFS. It matters to
this project for a different reason — it is what lets 32-bit bionic and 32-bit
Debian binaries run under the merged rootfs — and it is already enabled in the
6.12 x86_64 defconfig.

The "modularity" that decides whether these patches port is the kernel's VFS
interface, which is architecture-independent by design, plus the KernelSU
module interface. Neither cares which libc a process uses or how wide its
registers are.
