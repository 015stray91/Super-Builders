#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Dark Matter + Kali NetHunter (amd64) + KernelSU-Next ISO Fuser
# Tailored to /media/slm015/ff289034-a99e-44cf-990f-1912c7a0fe05/nethunter-dark-matter_build
# ==============================================================================

BASE_DIR="/media/slm015/ff289034-a99e-44cf-990f-1912c7a0fe05/nethunter-dark-matter_build"
DM_DIR="${BASE_DIR}/nethunter-darkmatter_iso/dark-matter_base"
NH_DIR="${BASE_DIR}/nethunter-darkmatter_iso/nh-unpacked"

KERNEL_SRC="${BASE_DIR}/kernel_src" # Optional: path to your x86_64 kernel source
OUT_ISO="${BASE_DIR}/DarkMatter-NetHunter-KSU-amd64.iso"

WORK_DIR="${BASE_DIR}/work_fuse"
MOD_OUT="${WORK_DIR}/modules_out"
MNT_SYS="${WORK_DIR}/mnt_sys"
SYS_IMG="${DM_DIR}/squashfs-root/system.img"

mkdir -p "$WORK_DIR" "$MOD_OUT" "$MNT_SYS"

echo "[1/5] Checking dependencies..."
for cmd in make gcc xorriso mksquashfs tar curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Missing required tool: $cmd"
        echo "Install: sudo apt-get install -y build-essential bc bison flex libssl-dev libelf-dev xorriso squashfs-tools curl"
        exit 1
    fi
done

# ==============================================================================
# 2. Build KSU-Next + NetHunter Kernel (x86_64)
# ==============================================================================
if [ -d "$KERNEL_SRC" ]; then
    echo "[2/5] Patching & building kernel in $KERNEL_SRC..."
    cd "$KERNEL_SRC"

    if [ ! -d "KernelSU-Next" ] && [ ! -d "drivers/kernelsu" ]; then
        curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s next
    fi

    # Optional: apply SUSFS / ZeroMount patches if present in BASE_DIR/patches/
    if [ -d "${BASE_DIR}/patches" ]; then
        for p in "${BASE_DIR}/patches"/*.patch; do
            [ -e "$p" ] || continue
            echo "Applying kernel patch: $p"
            git apply "$p" || patch -p1 < "$p"
        done
    fi

    if [ ! -f ".config" ]; then
        if [ -f "${DM_DIR}/darkmatter_blueprints/ikconfig_darkmatter_readable.txt" ]; then
            cp "${DM_DIR}/darkmatter_blueprints/ikconfig_darkmatter_readable.txt" .config
        elif [ -f "${NH_DIR}/kernel_blueprints/config-pro" ]; then
            cp "${NH_DIR}/kernel_blueprints/config-pro" .config
        elif [ -f "arch/x86/configs/darkmatter_defconfig" ]; then
            make ARCH=x86_64 darkmatter_defconfig
        else
            make ARCH=x86_64 x86_64_defconfig
        fi
    fi

    ./scripts/config --enable CONFIG_KSU \
                     --enable CONFIG_KSU_SUSFS \
                     --enable CONFIG_KPROBES \
                     --enable CONFIG_HAVE_KPROBES \
                     --enable CONFIG_KPROBE_EVENTS \
                     --enable CONFIG_MAC80211 \
                     --enable CONFIG_CFG80211_WEXT \
                     --enable CONFIG_USB_HID \
                     --enable CONFIG_HID_GENERIC \
                     --enable CONFIG_USB_GADGET \
                     --enable CONFIG_USB_CONFIGFS \
                     --enable CONFIG_USB_CONFIGFS_F_HID \
                     --enable CONFIG_BRIDGE \
                     --enable CONFIG_TUN

    make ARCH=x86_64 olddefconfig
    make ARCH=x86_64 -j"$(nproc)" bzImage modules
    make ARCH=x86_64 INSTALL_MOD_PATH="$MOD_OUT" modules_install

    cp -v arch/x86/boot/bzImage "${DM_DIR}/kernel"
else
    echo "[2/5] Skipping kernel build ($KERNEL_SRC not found). Using existing ${DM_DIR}/kernel."
fi

# ==============================================================================
# 3. Mount dark-matter_base/squashfs-root/system.img
# ==============================================================================
echo "[3/5] Mounting $SYS_IMG..."
if [ ! -f "$SYS_IMG" ]; then
    echo "Error: $SYS_IMG not found!"
    exit 1
fi

sudo mount -o loop "$SYS_IMG" "$MNT_SYS"
trap 'sudo umount "$MNT_SYS" 2>/dev/null || true' EXIT

# ==============================================================================
# 4. Fuse NetHunter system files, APKs, rootfs & kernel modules
# ==============================================================================
echo "[4/5] Fusing NetHunter amd64 into Dark Matter system.img..."

# Merge kernel modules if built
if [ -d "${MOD_OUT}/lib/modules" ]; then
    sudo mkdir -p "${MNT_SYS}/system/lib/modules"
    sudo cp -r "${MOD_OUT}/lib/modules/"* "${MNT_SYS}/system/lib/modules/"
fi

# Merge nh-unpacked/system (bin, etc, addon.d, media)
if [ -d "${NH_DIR}/system" ]; then
    sudo cp -rn "${NH_DIR}/system/"* "${MNT_SYS}/system/" || true
fi

# Install NetHunter APKs from nh-unpacked/data/app into system/priv-app
if [ -d "${NH_DIR}/data/app" ]; then
    for apk in "${NH_DIR}/data/app"/*.apk; do
        [ -e "$apk" ] || continue
        name="$(basename "$apk" .apk)"
        sudo mkdir -p "${MNT_SYS}/system/priv-app/${name}"
        sudo cp -v "$apk" "${MNT_SYS}/system/priv-app/${name}/${name}.apk"
        sudo chmod 0755 "${MNT_SYS}/system/priv-app/${name}"
        sudo chmod 0644 "${MNT_SYS}/system/priv-app/${name}/${name}.apk"
    done
fi

# Pack kali-amd64 rootfs & add first-boot init script
if [ -d "${NH_DIR}/rootfs/kali-amd64" ]; then
    echo "Archiving kali-amd64 rootfs for first-boot extraction..."
    sudo mkdir -p "${MNT_SYS}/system/etc/nethunter"
    sudo tar -czf "${MNT_SYS}/system/etc/nethunter/kalifs-amd64.tar.gz" -C "${NH_DIR}/rootfs" kali-amd64

    sudo tee "${MNT_SYS}/system/etc/init/nethunter.rc" >/dev/null << 'EOF'
on property:sys.boot_completed=1
    exec - root root -- /system/bin/sh -c "if [ ! -d /data/local/nhsystem/kali-amd64 ] && [ -f /system/etc/nethunter/kalifs-amd64.tar.gz ]; then mkdir -p /data/local/nhsystem && tar -xzf /system/etc/nethunter/kalifs-amd64.tar.gz -C /data/local/nhsystem/; fi"
EOF
    sudo chmod 0644 "${MNT_SYS}/system/etc/init/nethunter.rc"
fi

sudo umount "$MNT_SYS"
trap - EXIT

# Repack system.sfs
echo "Repacking dark-matter_base/system.sfs (this may take a few minutes)..."
rm -f "${DM_DIR}/system.sfs"
mksquashfs "${DM_DIR}/squashfs-root" "${DM_DIR}/system.sfs" -comp xz -b 1M

# ==============================================================================
# 5. Build Bootable ISO
# ==============================================================================
echo "[5/5] Building final ISO: $OUT_ISO..."
xorriso -as mkisofs -r -V "DARKMATTER_NH_KSU" \
    -b isolinux/isolinux.bin -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot \
    -o "$OUT_ISO" "$DM_DIR"

echo "Done! Your fused ISO is ready at: $OUT_ISO"
