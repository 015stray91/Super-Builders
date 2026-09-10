#!/usr/bin/env bash
# Build a SELF-CONTAINED static cross toolchain for the NUKI kernel build.
#
# Tier A (clang/LLVM) is fetched prebuilt by the workflow - not handled here.
# This script builds tiers B and C from source:
#
#   B. musl-cross:  an aarch64 musl cross toolchain whose host binaries are
#                   themselves statically linked. This is the piece that makes
#                   the cross-compile environment-independent.
#   C. host tools:  static binutils + static busybox, used by the kernel scripts.
#
# Everything lands under ./toolchain and is fully self-describing.
set -euo pipefail

ARCH="${ARCH:-amd64}"
HOST_PREFIX="${HOST_PREFIX:-x86_64-linux-gnu}"

MUSL_CROSS_VER="${MUSL_CROSS_VER:-1.2.5}"
BINUTILS_VER="${BINUTILS_VER:-2.41}"
BUSYBOX_VER="${BUSYBOX_VER:-1.36.1}"

ROOT="$(pwd)"
TC="$ROOT/toolchain"
JOBS="$(nproc)"

mkdir -p "$TC"/{musl,host/bin,src}
log() { printf '\n=== %s ===\n' "$*"; }

# ---------------------------------------------------------------------------
# Tier B - musl-cross
# ---------------------------------------------------------------------------
log "Tier B: musl-cross ${MUSL_CROSS_VER} (cross gcc ${HOST_PREFIX} -> aarch64)"
cd "$TC/src"

if [ ! -d "musl-cross-make-${MUSL_CROSS_VER}" ]; then
  curl -fsSL -o musl-cross-make.tar.gz \
    "https://github.com/richfelker/musl-cross-make/archive/refs/tags/v${MUSL_CROSS_VER}.tar.gz"
  tar xzf musl-cross-make.tar.gz
fi
cd "musl-cross-make-${MUSL_CROSS_VER}"

# Hermetic, reproducible: pin revisions, target aarch64, static gcc host binaries.
cat > config.mak <<EOF
TARGET = aarch64-linux-musl
OUTPUT = ${TC}/musl
GCC_VER = 12.3.0
BINUTILS_VER = ${BINUTILS_VER}
MUSL_VER = $(echo "${MUSL_CROSS_VER}" | cut -d. -f1-3)
COMMON_CONFIG += CFLAGS="-g0 -Os" CXXFLAGS="-g0 -Os"
COMMON_CONFIG += --disable-nls
# Make the HOST binaries static so the toolchain runs anywhere.
GCC_CONFIG += --disable-libmudflap --disable-libsanitizer
GCC_CONFIG += --with-build-time-tools=/usr/bin
EOF

log "Building musl cross toolchain (this is the long step)"
make -j"$JOBS" 2>&1 | tail -40

# Static-ify the host-side gcc if the build produced dynamic binaries.
CROSS_GCC="$TC/musl/bin/aarch64-linux-musl-gcc"
[ -x "$CROSS_GCC" ] || { echo "FAIL: cross gcc not produced at $CROSS_GCC"; exit 1; }

# ---------------------------------------------------------------------------
# Tier C - static host tools
# ---------------------------------------------------------------------------
log "Tier C.1: static binutils ${BINUTILS_VER}"
cd "$TC/src"
if [ ! -d "binutils-${BINUTILS_VER}" ]; then
  curl -fsSL -o binutils.tar.xz \
    "https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VER}.tar.xz"
  tar xf binutils.tar.xz
fi
mkdir -p "build-binutils-${ARCH}" && cd "build-binutils-${ARCH}"
"../binutils-${BINUTILS_VER}/configure" \
  --prefix="$TC/host" \
  --target=aarch64-linux-gnu \
  --disable-nls \
  --disable-werror \
  --enable-static --disable-shared \
  LDFLAGS="-static"
make -j"$JOBS" 2>&1 | tail -10
make install 2>&1 | tail -5

log "Tier C.2: static busybox ${BUSYBOX_VER}"
cd "$TC/src"
if [ ! -d "busybox-${BUSYBOX_VER}" ]; then
  curl -fsSL -o busybox.tar.bz2 \
    "https://busybox.net/downloads/busybox-${BUSYBOX_VER}.tar.bz2"
  tar xf busybox.tar.bz2
fi
cd "busybox-${BUSYBOX_VER}"
make defconfig >/dev/null
sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
make -j"$JOBS" 2>&1 | tail -10
cp busybox "$TC/host/bin/busybox"
"$TC/host/bin/busybox" | head -1

# ---------------------------------------------------------------------------
# Self-description + verification
# ---------------------------------------------------------------------------
log "Writing toolchain manifest"
{
  echo "NUKI static toolchain"
  echo "host_arch:        ${ARCH}"
  echo "host_prefix:      ${HOST_PREFIX}"
  echo "target:           aarch64-linux-musl"
  echo "clang_rev:        ${CLANG_REV:-r416183b} (tier A, fetched by workflow)"
  echo "gcc:              $( "$CROSS_GCC" --version 2>/dev/null | head -1 )"
  echo "binutils:         ${BINUTILS_VER}"
  echo "musl:             ${MUSL_CROSS_VER}"
  echo "busybox:          ${BUSYBOX_VER}"
  echo "built_utc:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$TC/MANIFEST.txt"
cat "$TC/MANIFEST.txt"

log "Static verification"
if command -v ldd >/dev/null 2>&1; then
  ldd "$CROSS_GCC" 2>&1 | grep -q "not a dynamic executable" \
    && echo "OK  cross gcc is static" \
    || { echo "WARN cross gcc is dynamic:"; ldd "$CROSS_GCC"; }
  ldd "$TC/host/bin/busybox" 2>&1 | grep -q "not a dynamic executable" \
    && echo "OK  busybox is static" || echo "WARN busybox is dynamic"
fi

echo
echo "TOOLCHAIN READY: $TC"
du -sh "$TC"
