# Kernel ↔ Android: what the numbers actually mean

This file exists because the same kernel version appears under more than one
Android release, and this repo's documentation had drifted into treating some of
those as synonyms. They are not — and one of the corrections below contradicts an
earlier version of this very file.

## Two independent numbers

A GKI target is identified by **two** things:

- the **Android release** the KMI belongs to,
- the **kernel version** — which is *not* implied by the Android release.

`kernel/common` carries both as separate branches:

```
android11-5.4     -> 5.4.x
android12-5.4     -> 5.4.302
android12-5.10    -> 5.10.270
android13-5.10    -> 5.10.270    <-- same kernel, different KMI
android13-5.15    -> 5.15.x
android14-5.15    -> 5.15.x
android14-6.1     -> 6.1.x
android15-6.6     -> 6.6.x
android16-6.12    -> 6.12.x
```

`android12-5.10` and `android13-5.10` are **not** the same target with a
cosmetic rename. They are two branches of the same upstream 5.10.270, with
different KMI symbol lists. A boot image built against one does not satisfy the
other's vendor modules.

## GKI generations — corrected

The generation describes **how vendor modules are separated from the core
kernel**. It is checkable from the branch contents rather than from memory, and
the check gives a boundary that is *not* where this repo previously placed it.

| generation | contract | branches |
|---|---|---|
| **pre-GKI** | no KMI at all. Vendor and core built as one tree. | `android11-4.19` and earlier, plus every vendor's own 5.4/5.10 tree |
| **GKI 1.0** (legacy) | hybrid: one kernel image, modules coupled to it; per-device KMI list, but no separated module symbol contract | `android11-5.4`, `android12-5.4`, `android12-5.10` |
| **GKI 2.0** | core kernel + separately built vendor modules against a frozen KMI | `android13-5.10` onward |

Note the first row: `android11-5.4` **does** have an `android/abi_gki_aarch64`
list (verified, HTTP 200) — it is the branch GKI 1.0 launched on. GKI genuinely
starts at 5.4 in Google's own tree. What is pre-GKI is `android11-4.19`, which
has no `android/` directory at all (404), and — the case that matters in
practice — **a vendor's own 5.4 tree**, which is monolithic regardless of what
Google's branch of the same version does. Two different things share the number
5.4, which is the whole source of the confusion.

The distinguishing files, fetched from `kernel/common`:

| branch | `android/abi_gki_aarch64` | `abi_gki_modules_exports` / `_protected` |
|---|---|---|
| `android12-5.4` | yes | **no** |
| `android12-5.10` | yes | **no** |
| `android13-5.10` | yes | **yes** |

`abi_gki_modules_exports` and `abi_gki_modules_protected` exist only from
`android13-5.10`, and `android/gki_system_dlkm_modules` (the `system_dlkm`
partition's module list) likewise appears only at `android13-5.10` — 404 on both
`android12-5.4` and `android12-5.10`. And `android/gki_aarch64_modules` (the
module allowlist) appears at `android12-5.4` — absent at `android11-5.4`.

That combination is why this gets argued about. **Android 12 is where the 2.0
design was laid down; Android 13 is where the contract completes.** Both
descriptions are defensible, and the difference is worth stating precisely:

| marker | `android11-5.4` | `android12-5.10` | `android13-5.10` |
|---|---|---|---|
| `android/abi_gki_aarch64` (KMI list) | yes | yes | yes |
| `android/gki_aarch64_modules` (module allowlist) | **no** | **yes** | yes |
| `android/gki_system_dlkm_modules` (module partition) | no | **no** | **yes** |
| `abi_gki_modules_exports` / `_protected` | no | **no** | **yes** |
| `vendor_boot` + header v4 (two-stage ramdisk) | v3 (A11) | **v4 (A12)** | v4 + `init_boot` |

Read that table as: Android 12 introduced the module *allowlist* and the
two-stage ramdisk, so the architecture exists and is in active use there — that
is what "2.0 was already established on A12" refers to, and it is correct.
What Android 12 does **not** have is the separated module *symbol contract*
(`system_dlkm`, `_protected`); that lands in Android 13. Hence 12 is the legacy
hybrid and 13 is the completed 2.0.

The practical consequence for a 5.10 Moto: it ships the Android 12 module
allowlist with per-device KMI lists and no separated module contract, so it
builds as one image plus coupled modules. That is GKI 1.0 in build terms even
though the 2.0 architecture was already the direction of travel.

- **Both statements about 5.4 are true, of different trees.** Google's
  `android12-5.4` is GKI 1.0 (5.4.302) with a KMI; a vendor's 5.4 tree is
  pre-GKI and monolithic. Say which you mean.
- **`android12-5.10` is GKI 1.0**, not 2.0 — it has per-device KMI lists but no
  separated module symbol contract.
- **`android13-5.10` is GKI 2.0** — same 5.10.270 kernel as `android12-5.10`,
  different generation and different KMI.

A concrete illustration that this is not hair-splitting: `android12-5.10`
carries `android/abi_gki_aarch64_moto`, a Motorola KMI list. `android13-5.10`
does not (404). Motorola's 5.10 devices are GKI 1.0 and live under the Android 12
KMI even when the device ships Android 13 or 14.

## The "5.10-9" shorthand — what the trailing number is

This is the single most useful correction in this file, because the trailing
number is a real field and it explains why "5.10" alone is ambiguous.

Google's trees carry `build.config.common`, which contains:

```
KMI_GENERATION=<n>
BRANCH=android<NN>-<ver>
```

and `scripts/setlocalversion` appends it to the release string:

```sh
printf '%s' "-$android_release-$kmi_generation"
```

so a built kernel identifies itself as `5.10.270-android12-9`. **The trailing
number is `KMI_GENERATION`.** It is not a sub-level, not a patch level, and not
a build number. That is why `5.10-9` and `5.10-4` are the same kernel with
different KMIs, and why neither is "newer" than the other.

Verified values, read from `build.config.common` on each branch:

| shorthand | branch | kernel | `KMI_GENERATION` | generation |
|---|---|---|---|---|
| `5.4-2`  | `android11-5.4`  | 5.4.x    | 2  | GKI 1.0 (the launch branch) |
| `5.4-9`  | `android12-5.4`  | 5.4.302  | 9  | GKI 1.0 |
| `5.10-9` | `android12-5.10` | 5.10.270 | **9** | **GKI 1.0 (legacy hybrid)** |
| `5.10-4` | `android13-5.10` | 5.10.270 | 4  | GKI 2.0 |
| `5.15-8` | `android13-5.15` | 5.15.x   | 8  | GKI 2.0 |
| `5.15-11`| `android14-5.15` | 5.15.x   | 11 | GKI 2.0 |
| `6.1-11` | `android14-6.1`  | 6.1.x    | 11 | GKI 2.0 |
| `6.6-8`  | `android15-6.6`  | 6.6.x    | 8  | GKI 2.0 |
| `6.12-7` | `android16-6.12` | 6.12.96  | 7  | GKI 2.0 |

Three consequences:

1. **`5.10-9` is real and it is the Moto.** It is `android12-5.10`,
   `KMI_GENERATION=9`, GKI 1.0 — the legacy hybrid. Not a newer kernel, not a
   miscount.
2. **There is no `5.10-11`.** The GKI 2.0 branch of 5.10 is `android13-5.10`
   at `-4`. `-11` belongs to 5.15 and 6.1 under `android14`. If a document here
   said `5.10-11`, it was wrong twice over — wrong generation number *and*
   implying a 5.10 branch that does not exist.
3. **The numbers do not increase with kernel version.** `-9` (5.4/5.10) is
   higher than `-4` (5.10) and `-7` (6.12). Do not sort by them.

Because the shorthand invites exactly this misreading, everything in this repo
writes the branch name (`android12-5.10`) and never the bare numeric form. The
mapping above exists so that when a shorthand turns up in a forum post or a
vendor's release notes, it can be resolved rather than guessed at.

## How this repo resolves a target

The GKI builders derive the patch directory from **both** numbers:

```
VERSION_DIR="${ANDROID_VER}-${KERNEL_VER}"
```

through `build-helpers/resolve-version-dir.sh`, which fails loudly if that
directory does not exist. An older `case` fallback keyed on kernel version alone
silently mapped *any* 5.10 device onto `android12-5.10`. For a GKI 1.0 Motorola
device that happened to be the right answer, but it was right by accident and
would be wrong for a GKI 2.0 5.10 device. The resolver now refuses to guess.

Only `android12-5.10/` exists in this repo. The other rows in the README have
workflows that will stop at the resolver with a list of what does exist.

## The Motorola G Stylus 5G 2023 (genevn)

`device-profiles.json`:

```
android_version: android14          <-- the ROM it runs now, not its KMI
shipped_android: android12          <-- what it launched on
kernel_version:  5.10
kmi_generation:  gki-1.0
kmi_branch:      android12-5.10
soc:             sm6450
boot_ramdisk:    boot          <-- first-stage ramdisk
vendor_boot:     true          <-- second-stage ramdisk lives here
kernel_branch:   main
kernel_source:   AR-NUKI-genevn
```

**The tree is `AR-NUKI-genevn`** (`https://github.com/015stray91/AR-NUKI-genevn.git`,
branch `main`, 5.10.240). It is a full kernel tree — `arch/arm64`, `drivers`,
`kernel` all present — and already carries `fs/susfs.c`, `fs/zeromount.c` and
`include/linux/susfs.h` in-tree, which is why the build falls back to in-tree
config flags instead of applying source patches.

`kernel-zenith` is the **other** tree: it is x86_64, 6.12, and exists only for
the DarkMatter ISO. The two must not be crossed. The profile previously pointed
`genevn-g` at `kernel-msm-1`, which was wrong — that repo holds only
`README.md`, `CROSS_REFERENCES.md` and `fs/koto/`.

### The tree is self-sufficient, and its build.config glue is deliberately gone

AR-NUKI-genevn is not a mirror of any upstream branch. It carries its own
`KernelSU-Next/`, its own `nuki-colonel.config`, and its own config chain. The
`build.config.*` scaffolding at the top level is **legacy and partly broken on
purpose**: several of those files still `. ${ROOT_DIR}/build.config.common`, and
`build.config.common` is not in the tree.

That is not an oversight to "fix". Those scripts kept re-deriving the config and
overwriting local modifications, so they were removed and the build stopped
using them entirely. `build-ksu-next.yml` runs:

```sh
python3 scripts/kconfig/merge_nuki.py \
  arch/arm64/configs/ksu-nh.defconfig \
  <vendor_config> <debug_config> <nurfs_fragment> -o out/.config
```

`merge_nuki.py` is in-tree, takes the files positionally, and is the only thing
that produces `.config`. **Do not restore `build.config.common` or re-point the
build at `build.config.anyrealm.kernel`** — doing so reintroduces the overwrite
problem the removal was meant to solve. Treat the `build.config.*` files as
reference documentation of what the upstream GKI build used to do, nothing more.

Note on the release it launched on: this device started on **Android 12**, not
13. Documentation that says 13 is wrong; the 2023 model and the 2024 model share
the SM6450 SoC, which is where the confusion comes from.

Three things follow, and two of them were previously documented wrongly here.

1. **`android_version: android14` does not mean the kernel is GKI 2.0.** The
   SoC is SM6450 on a 5.10 vendor tree, which is the GKI 1.0 branch family —
   the same `abi_gki_aarch64_moto` list as `android12-5.10`. The Android release
   in the profile describes the ROM the device shipped, not the KMI generation.
   The tree itself has no `build.config.common`, i.e. no `KMI_GENERATION`, so it
   is a vendor tree rather than a Google GKI branch at all.
2. **It is a Motorola vendor tree, not a GKI tree.** Built by
   `genevn-nuki.yml` → `build-ksu-next.yml`, which clones `kernel_source` and
   uses the profile's own defconfigs. It never derives `VERSION_DIR`, so the
   resolver does not touch it and the path keeps working.
3. **`kernel-msm-1` is not a buildable kernel tree**, and the profile no longer
   points at it. Its branches carry `README.md`, `CROSS_REFERENCES.md` and
   `fs/koto/` — it is the *source* repo in the Colonel chain (see its own
   `CROSS_REFERENCES.md`), pulled by the orchestrator.

Patches come from `android12-5.10/KernelSU-Next/patches/`, verified to apply
clean to 5.10.270.

## Two-stage boot: boot.img and vendor_boot.img

On this device the first-stage ramdisk is in `boot` and the second stage is in
`vendor_boot`. AnyKernel3 on this tree flashes the **kernel image only** —
`anykernel.sh` sets `do.devicecheck=1` and the build copies `Image.lz4` in with
no `vendor_ramdisk/` directory, so `ak3-core.sh`'s vendor_boot path stays unused
and `vendor_boot` is left stock. That is the correct default: the vendor
ramdisk holds device blobs and module fragments that are signed and matched to
the vendor tree, and a kernel-only change does not need to touch them.

If a change ever does need to alter the vendor ramdisk, it must ship a
`vendor_ramdisk/` directory (or `vendor_patch/`) into AnyKernel, not a second
boot image. Flashing a rebuilt `boot.img` alone cannot update it.

## Android is a Linux mobile distribution

Unrelated to the above but a framing that caused design errors here: Android is
not a different kind of system from other Linux mobile distros. It is the first
and most widely deployed one. What differs is component naming and a restricted
user-facing surface — not the kernel contract. `execve` does not care which libc
the ELF interpreter names, and VFS does not distinguish a bionic process from a
glibc one.
