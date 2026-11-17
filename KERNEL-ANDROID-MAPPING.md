# Kernel ↔ Android: what the numbers actually mean

This file exists because the same kernel version appears under more than one
Android version, and the documentation in this repo had drifted into treating
some of those as synonyms. They are not.

## Two independent numbers

A GKI build is identified by **two** things:

- the **Android release** whose KMI (Kernel Module Interface) it belongs to,
- the **kernel version** — which is *not* implied by the Android release.

Google's `kernel/common` carries both, as separate branches:

```
android12-5.4     -> 5.4.302
android12-5.10    -> 5.10.270
android13-5.10    -> 5.10.270     <-- same kernel, different KMI
android13-5.15    -> 5.15.x
android14-5.15    -> 5.15.x
android14-6.1     -> 6.1.x
android15-6.6     -> 6.6.x
android16-6.12    -> 6.12.x
```

`android12-5.10` and `android13-5.10` are **not** the same target with a
cosmetic rename. They are two branches of the same upstream 5.10.270, carrying
different KMI symbol lists and different Android-side glue. A boot image built
against one does not satisfy the other's vendor modules.

So "Android 13 with kernel 5.10" is a real, distinct target — and that is the
case this repo's documentation used to collapse into "Android 12 + 5.10".

## GKI generations (the "1.0 / 2.0" naming)

The generation is a property of **how modules are separated from the core
kernel**, not of the kernel version alone:

| generation | what it means | kernels |
|---|---|---|
| pre-GKI | no KMI; vendor and core built together | ≤ 5.4 era integrators' trees |
| GKI 1.0 | one kernel binary, modules still coupled to it | 5.4 onward under the 1.0 contract |
| GKI 2.0 | core kernel + separately-built vendor modules against a frozen KMI | 5.10 onward |

Two consequences worth being precise about, because the docs got both wrong:

1. **5.4 is not "pre-GKI".** `android12-5.4` is a genuine GKI branch (5.4.302)
   with a KMI. What *is* true is that it is the oldest branch still built here,
   and that KernelSU-Next/WKSU do not support it for unrelated reasons
   (`TWA_RESUME` does not exist before 5.7). The label "Pre-GKI" on that row was
   wrong; the *constraint* it was trying to express was right.
2. **The KMI generation does not follow the kernel version number.** 5.10 is
   GKI 2.0; 5.4 is GKI 1.0. Do not write "5.10-11" or similar — sub-level and
   generation are different axes and concatenating them produces labels that
   mean nothing.

## Android is a Linux mobile distribution

Unrelated to the above but a framing that caused real design errors here:
Android is not a different kind of system from other Linux mobile distros. It is
the first and most widely deployed one. What differs is component naming and a
restricted user-facing surface — not the kernel contract. `execve` does not care
which libc the ELF interpreter names, and VFS does not distinguish a bionic
process from a glibc one. That is why the merged DarkMatter/Kali rootfs works on
one kernel rather than needing a translation layer.

## How this repo resolves a target

`build-*` workflows derive the patch directory from **both** numbers:

```
VERSION_DIR="${ANDROID_VER}-${KERNEL_VER}"      # e.g. android13-5.10
```

A patch directory per *(Android, kernel)* pair is therefore correct, and adding
`android13-5.10/` alongside `android12-5.10/` is the right shape — not
duplication. What was wrong was that only `android12-5.10/` existed while seven
workflows derived directories that were never created, and nothing checked.

The samsung/device workflows additionally had a `case` fallback keyed on the
kernel version alone:

```sh
5.10) VERSION_DIR="android12-5.10" ;;
```

which silently maps *any* 5.10 device — including an Android 14 one — onto the
Android 12 KMI patch set. That is the bug to fix: fall back only when the
derived directory is missing **and** say so, and never let the fallback cross
Android versions.

## The Moto G Stylus 5G 2023 (genevn)

`device-profiles.json` records it as:

```
android_version: android14
kernel_version:  5.10
sub_level:       42
os_patch_level:  2024-03
kernel_branch:   android-14-release-u1tgns34.42-86-2-32
```

This is a **vendor tree from Motorola**, not a GKI tree, even though it is 5.10.
It is built by `genevn-nuki.yml` → `build-ksu-next.yml`, which clones
`kernel_source` from the profile and uses the profile's own defconfigs. It does
**not** use `VERSION_DIR`, so it is unaffected by the android12/android13-5.10
patch-directory question. Its patches come from
`android12-5.10/KernelSU-Next/patches/`, which apply cleanly to 5.10.270 — that
part was verified, and it is what was fixed for that device.
