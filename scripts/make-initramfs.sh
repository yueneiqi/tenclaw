#!/bin/bash
# Build a minimal BusyBox initramfs for TenClaw testing.
# Includes virtio kernel modules for block device support.
# Run this in WSL2 or a Linux environment.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="$(mkdir -p "${1:-$SCRIPT_DIR/../build}" && cd "${1:-$SCRIPT_DIR/../build}" && pwd)"
WORKDIR=$(mktemp -d)
trap "rm -rf $WORKDIR" EXIT

resolve_kernel_pkg() {
    local meta dep
    for meta in linux-image-amd64 linux-image-generic; do
        if apt-cache show "$meta" >/dev/null 2>&1; then
            dep=$(apt-cache depends "$meta" 2>/dev/null \
                | sed -n 's/.*Depends: \(linux-image-[0-9][^ ]*\).*/\1/p' \
                | head -n 1)
            if [ -n "$dep" ]; then
                echo "$dep"
                return 0
            fi
        fi
    done
    return 1
}

download_pkg() {
    apt-get download "$1" 2>/dev/null || apt download "$1" 2>/dev/null
}

echo "[1/5] Downloading BusyBox static binary..."
cd "$WORKDIR"
download_pkg busybox-static
dpkg-deb -x busybox-static*.deb extract/
cp extract/bin/busybox "$WORKDIR/busybox"
chmod +x "$WORKDIR/busybox"

echo "[2/5] Creating initramfs layout..."
mkdir -p "$WORKDIR/initramfs"/{bin,dev,proc,sys,etc,tmp,lib/modules}
cp "$WORKDIR/busybox" "$WORKDIR/initramfs/bin/"

echo "[3/5] Extracting virtio kernel modules from Debian package..."
# Download modules from the same package family used for the kernel image.
KPKG=$(resolve_kernel_pkg || true)
if [ -z "$KPKG" ]; then
    echo "ERROR: Failed to resolve a linux-image package." >&2
    exit 1
fi
echo "  Downloading $KPKG (and module dependencies) ..."

cd "$WORKDIR"
download_pkg "$KPKG" || {
    echo "ERROR: Failed to download $KPKG."
    echo "  Try: apt-cache search linux-image-"
    exit 1
}

for dep_pkg in $(apt-cache depends "$KPKG" 2>/dev/null \
    | sed -n 's/.*Depends: \(linux-modules[^ ]*\).*/\1/p'); do
    download_pkg "$dep_pkg" || true
done

mkdir -p kmod_extract
for deb in ./*.deb; do
    [ -f "$deb" ] || continue
    dpkg-deb -x "$deb" kmod_extract/
done

KVER=$(find kmod_extract/lib/modules -mindepth 1 -maxdepth 1 -type d \
    | sed -n '1s#^.*/##p')
if [ -z "$KVER" ]; then
    echo "ERROR: No kernel modules found in downloaded packages." >&2
    exit 1
fi

MODDIR="kmod_extract/lib/modules/$KVER/kernel"
DESTDIR="$WORKDIR/initramfs/lib/modules"

# Modules needed for virtio block/net devices + ext4 filesystem support
VIRTIO_MODS=(
    "drivers/virtio/virtio.ko"
    "drivers/virtio/virtio_ring.ko"
    "drivers/virtio/virtio_mmio.ko"
    "drivers/block/virtio_blk.ko"
    "net/core/failover.ko"
    "drivers/net/net_failover.ko"
    "drivers/net/virtio_net.ko"
    "fs/mbcache.ko"
    "fs/jbd2/jbd2.ko"
    "lib/crc16.ko"
    "crypto/crc32c_generic.ko"
    "lib/libcrc32c.ko"
    "fs/ext4/ext4.ko"
)

for relmod in "${VIRTIO_MODS[@]}"; do
    modname="$(basename $relmod)"
    src="$MODDIR/$relmod"
    found=""
    # Try plain .ko, .ko.xz, .ko.zst
    if [ -f "$src" ]; then
        found="$src"
    elif [ -f "${src}.xz" ]; then
        found="${src}.xz"
    elif [ -f "${src}.zst" ]; then
        found="${src}.zst"
    else
        found=$(find "$MODDIR" -type f \
            \( -name "$modname" -o -name "${modname}.xz" -o -name "${modname}.zst" \) \
            | sed -n '1p')
    fi

    if [ -z "$found" ]; then
        echo "  WARNING: $modname not found in $KPKG"
        continue
    fi

    if [ "$found" = "${found%.xz}" ] && [ "$found" = "${found%.zst}" ]; then
        cp "$found" "$DESTDIR/"
        echo "  Copied: $modname"
    elif [ "$found" != "${found%.xz}" ]; then
        xz -d < "$found" > "$DESTDIR/$modname"
        echo "  Decompressed: $modname (.xz)"
    else
        zstd -d "$found" -o "$DESTDIR/$modname" 2>/dev/null
        echo "  Decompressed: $modname (.zst)"
    fi
done

cat > "$WORKDIR/initramfs/init" << 'EOF'
#!/bin/busybox sh
/bin/busybox mkdir -p /proc /sys /dev /tmp
/bin/busybox mount -t proc none /proc
/bin/busybox mount -t sysfs none /sys
/bin/busybox mount -t devtmpfs none /dev 2>/dev/null

/bin/busybox --install -s /bin

# Load virtio modules — device discovery is handled by ACPI DSDT
MODDIR=/lib/modules
for mod in virtio virtio_ring virtio_mmio virtio_blk failover net_failover virtio_net; do
    if [ -f "$MODDIR/$mod.ko" ]; then
        insmod "$MODDIR/$mod.ko" 2>/dev/null && \
            echo "Loaded: $mod" || echo "Failed: $mod"
    fi
done

# Load ext4 filesystem modules
for mod in crc16 crc32c_generic libcrc32c mbcache jbd2 ext4; do
    if [ -f "$MODDIR/$mod.ko" ]; then
        insmod "$MODDIR/$mod.ko" 2>/dev/null && \
            echo "Loaded: $mod" || echo "Failed: $mod"
    fi
done

# Wait for block device to appear (poll instead of fixed sleep)
for i in $(seq 1 20); do
    [ -e /dev/vda ] && break
    sleep 0.05
done

echo ""
echo "====================================="
echo " TenClaw VM booted successfully!"
echo "====================================="
echo "Kernel: $(uname -r)"
echo "Memory: $(cat /proc/meminfo | head -1)"
echo ""

if [ -e /dev/vda ]; then
    echo "Block device: /dev/vda detected"
    echo "  Size: $(cat /sys/block/vda/size) sectors"

    # Try to switch_root into the real rootfs
    mkdir -p /newroot
    if mount -t ext4 /dev/vda /newroot 2>/dev/null; then
        # Bookworm uses usrmerge: /sbin/init is an absolute symlink
        # to /lib/systemd/systemd. We must check inside the rootfs
        # context, not from initramfs where the symlink would escape.
        INIT=""
        for candidate in /usr/lib/systemd/systemd /lib/systemd/systemd /sbin/init; do
            if [ -x "/newroot${candidate}" ]; then
                INIT="$candidate"
                break
            fi
        done
        if [ -n "$INIT" ]; then
            echo "Switching to rootfs on /dev/vda (init=$INIT) ..."
            umount /proc /sys /dev 2>/dev/null
            exec switch_root /newroot "$INIT"
        else
            echo "No init found on rootfs, staying in initramfs"
            umount /newroot 2>/dev/null
        fi
    else
        echo "Failed to mount /dev/vda as ext4"
    fi
fi
echo ""

# Fallback to interactive shell if no rootfs
/bin/sh

echo "Shutting down..."
poweroff -f
EOF
chmod +x "$WORKDIR/initramfs/init"

echo "[4/5] Packing initramfs..."
cd "$WORKDIR/initramfs"
find . | cpio -o -H newc 2>/dev/null | gzip > "$WORKDIR/initramfs.cpio.gz"

echo "[5/5] Copying output..."
cp "$WORKDIR/initramfs.cpio.gz" "$OUTDIR/initramfs.cpio.gz"
echo "Done: $OUTDIR/initramfs.cpio.gz ($(du -h "$OUTDIR/initramfs.cpio.gz" | cut -f1))"
