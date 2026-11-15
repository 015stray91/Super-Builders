#!/bin/bash
#
# Build a NetHunter Pro x86_64 kernel for the ASUS Vivobook Go (E1404FA)
# with KernelSU-Next + SUSFS + ZeroMount, including NetHunter Pro's
# initrd/ramdisk and optional GIMPLE-level obfuscation.
#
# Usage:
#   ./build-nh-pro.sh                 # build Image only
#   ./build-nh-pro.sh --obfuscate     # + goat substitution pass
#   ./build-nh-pro.sh --pack          # + repack boot artefacts
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${HERE}/.."

# --- pinned sources ---------------------------------------------------------
KERNEL_REPO="https://github.com/015stray91/kernel-zenith.git"
KERNEL_BRANCH="6.12_KSU"
KERNEL_PIN="$(tr -d '[:space:]' \
  < "${HERE}/6.12_KSU/x86_- indirect syscall bypass+syscall_hardeningpin.txt")"

KSU_PIN="$(tr -d '[:space:]' < "${HERE}/KernelSU-Next/kernelsu-next_x86_64pin.txt")"
KSU_REPO="https://github.com/KernelSU-Next/KernelSU-Next.git"

# NetHunter Pro amd64 payload lives on the android-x86 branch
NH_REF="6.12_android-x86"
NH_REPO="https://github.com/015stray91/kernel-zenith.git"
NH_DIR="kali-nethunter-kernel-builder-main"

WORK="${WORK:-/tmp/nh-build}"
SRC="${WORK}/kernel"
OUT="${WORK}/out"

ARCH="x86_64"
JOBS="$(nproc)"
OBFUSCATE=0
PACK=0

for a in "$@"; do
  case "$a" in
    --obfuscate) OBFUSCATE=1 ;;
    --pack)      PACK=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# --- 1. kernel source -------------------------------------------------------
say "Fetching kernel ${KERNEL_BRANCH} @ ${KERNEL_PIN:0:12}"
if [ ! -d "${SRC}/.git" ]; then
  mkdir -p "${WORK}"
  git clone --filter=blob:none --no-checkout "${KERNEL_REPO}" "${SRC}"
fi
git -C "${SRC}" fetch -q --depth 1 origin "${KERNEL_BRANCH}"
git -C "${SRC}" checkout -q "${KERNEL_PIN}"

# --- 2. KernelSU-Next at the pin -------------------------------------------
say "Installing KernelSU-Next @ ${KSU_PIN:0:12}"
if [ ! -d "${WORK}/ksu/.git" ]; then
  git clone -q "${KSU_REPO}" "${WORK}/ksu"
fi
git -C "${WORK}/ksu" fetch -q origin "${KSU_PIN}" || true
git -C "${WORK}/ksu" checkout -q "${KSU_PIN}"

# The tree expects drivers/kernelsu -> ../KernelSU/kernel
rm -rf "${SRC}/KernelSU"
cp -a "${WORK}/ksu" "${SRC}/KernelSU"
rm -rf "${SRC}/drivers/kernelsu"
ln -sfn ../KernelSU/kernel "${SRC}/drivers/kernelsu"

# --- 3. patches -------------------------------------------------------------
say "Applying SUSFS / ZeroMount / KSU patches"

apply_patch() {  # apply_patch <dir> <patch>
  local dir="$1" p="$2"
  [ -f "$p" ] || { echo "missing patch: $p" >&2; exit 1; }
  printf '  %-52s ' "$(basename "$p")"
  if ( cd "$dir" && patch -p1 --forward -F3 --no-backup-if-mismatch <"$p" ) \
       >/tmp/p.log 2>&1; then
    echo applied
  elif grep -qi "previously applied\|Reversed" /tmp/p.log; then
    echo "already applied"
  else
    echo FAILED; grep -E "FAILED|can't find file" /tmp/p.log | head -5; exit 1
  fi
}

# Kernel-side (fs/, include/, mm/, security/) — from the tree root.
for p in \
  "${HERE}/KernelSU-Next/50_add_susfs_in_gki-android16-6.12.patch" \
  "${HERE}/KernelSU-Next/51_enhanced_susfs-android16-6.12.patch" \
  "${HERE}/KernelSU-Next/60_zeromount-android16-6.12.patch" ; do
  apply_patch "${SRC}" "$p"
done

# KernelSU-side (kernel/...) — from inside the KernelSU source dir.
apply_patch "${SRC}/KernelSU" \
  "${HERE}/KernelSU-Next/70_ksu_next_susfs_x86_64_consolidated.patch"

# --- 4. config --------------------------------------------------------------
say "Configuring (x86_64 + SUSFS + ZeroMount + NetHunter Pro drivers)"
mkdir -p "${OUT}"
make -C "${SRC}" O="${OUT}" ARCH="${ARCH}" x86_64_defconfig >/dev/null
"${SRC}/scripts/kconfig/merge_config.sh" -m -O "${OUT}" \
  "${OUT}/.config" \
  "${HERE}/config-darkmatter-nhpro-x86_64.fragment" >/dev/null
make -C "${SRC}" O="${OUT}" ARCH="${ARCH}" olddefconfig >/dev/null

for o in CONFIG_KSU CONFIG_KSU_SUSFS CONFIG_ZEROMOUNT CONFIG_X86_64; do
  grep -q "^${o}=y" "${OUT}/.config" || { echo "${o} not enabled" >&2; exit 1; }
done

# --- 5. obfuscation ---------------------------------------------------------
KCFLAGS_EXTRA=""
if [ "${OBFUSCATE}" = 1 ]; then
  GOAT="${GOAT_PLUGIN:-${WORK}/goat-src/build/hellscape.so}"
  [ -f "${GOAT}" ] || { echo "goat plugin not built: ${GOAT}" >&2; exit 1; }
  say "Obfuscating with goat (substitution pass)"
  # Only -sub is safe on kernel code; -fla and -bcf crash on computed gotos.
  KCFLAGS_EXTRA="-fplugin=${GOAT} -fplugin-arg-hellscape-seed=deadbeef -fplugin-arg-hellscape-sub"
fi

# --- 6. build ---------------------------------------------------------------
say "Building kernel (${JOBS} jobs)"
make -C "${SRC}" O="${OUT}" ARCH="${ARCH}" -j"${JOBS}" \
  ${KCFLAGS_EXTRA:+KCFLAGS="${KCFLAGS_EXTRA}"} \
  bzImage modules

say "Kernel image"
ls -la "${OUT}/arch/x86/boot/bzImage"

# --- 7. stage NetHunter Pro payload ----------------------------------------
say "Fetching NetHunter Pro amd64 payload"
NH="${WORK}/nh"
mkdir -p "${NH}"
if [ ! -f "${NH}/initrd.img" ]; then
  for f in initrd.img ramdisk.img config-pro; do
    curl -fsSL -o "${NH}/${f}" \
      "https://raw.githubusercontent.com/${NH_REPO#https://github.com/}/${NH_REF}/${NH_DIR}/${f}"
  done
fi
ls -lh "${NH}"

if [ "${PACK}" = 1 ]; then
  say "Staging boot artefacts"
  BOOT="${WORK}/boot"
  rm -rf "${BOOT}"; mkdir -p "${BOOT}"
  cp "${OUT}/arch/x86/boot/bzImage"        "${BOOT}/vmlinuz"
  cp "${NH}/initrd.img"                    "${BOOT}/initrd.img"
  cp "${NH}/ramdisk.img"                   "${BOOT}/ramdisk.img"
  cp "${OUT}/System.map"                   "${BOOT}/System.map"
  cp "${OUT}/.config"                      "${BOOT}/config"
  if [ -d "${OUT}/modules" ] || [ -n "$(ls -A "${OUT}" 2>/dev/null)" ]; then
    make -C "${SRC}" O="${OUT}" ARCH="${ARCH}" \
      INSTALL_MOD_PATH="${BOOT}/modules" modules_install >/dev/null
  fi
  echo
  ls -lhR "${BOOT}" | head -30
fi

say "Done. Source: ${SRC}  Output: ${OUT}"
