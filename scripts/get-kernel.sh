#!/bin/bash
# Extract a Debian vmlinuz for TenClaw testing.
# Run this in WSL2 or a Debian-based Linux environment.
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

echo "[1/3] Resolving actual kernel package from meta-package..."
cd "$WORKDIR"
REAL_PKG=$(resolve_kernel_pkg || true)
if [ -z "$REAL_PKG" ]; then
    echo "Error: could not resolve kernel package name." >&2
    exit 1
fi
echo "    -> $REAL_PKG"

echo "[2/3] Downloading & extracting vmlinuz..."
apt-get download "$REAL_PKG" 2>/dev/null || \
    apt download "$REAL_PKG" 2>/dev/null
dpkg-deb -x linux-image-*.deb extract/
VMLINUX=$(find extract/boot -maxdepth 1 -type f -name 'vmlinuz-*' | head -n 1)
if [ -z "$VMLINUX" ]; then
    echo "Error: no vmlinuz found in $REAL_PKG package." >&2
    exit 1
fi
cp "$VMLINUX" vmlinuz

echo "[3/3] Copying output..."
cp vmlinuz "$OUTDIR/vmlinuz"
echo "Done: $OUTDIR/vmlinuz ($(du -h "$OUTDIR/vmlinuz" | cut -f1))"
