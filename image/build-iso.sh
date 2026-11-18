#!/bin/bash
# Build the Mono Gateway VyOS ISO with vyos-build (live-build), arm64.
#
# VyOS publishes its build container for amd64 only; live-build bootstraps
# and configures the arm64 chroot through the host's qemu-aarch64 binfmt
# handler (registered with the F flag, so it works inside the container).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
. "$TOP/pins.sh"

SRC=$VYOS_BUILD

IMAGE=$VYOS_BUILD_IMAGE
FLAVOR=mono-gateway-dk
VERSION=${VERSION:-$(date -u +%Y.%m.%d-%H%M)-mono}

grep -qx "kernel_version = \"$KERNEL_VERSION\"" "$HERE/flavors/$FLAVOR.toml" \
    || { echo "E: flavors/$FLAVOR.toml kernel_version is not $KERNEL_VERSION (pins.sh)"; exit 1; }

grep -q 'flags: .*F' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null \
    || { echo "E: qemu-aarch64 binfmt with the F flag is required (apt install qemu-user-static)"; exit 1; }
ls "$BUILD"/debs/linux-image-"$KERNEL_RELEASE"_*.deb >/dev/null \
    || { echo "E: no kernel .deb; run 'build.sh kernel'"; exit 1; }
ls "$BUILD"/debs/ask-flowtable_*.deb >/dev/null \
    || { echo "E: no ASK packages; run 'build.sh packages'"; exit 1; }
# The kernel forces module signatures: packages built against another kernel
# build (another key) would ship modules it refuses to load.
[ "$(cat "$BUILD/debs/.kernel-key" 2>/dev/null)" = "$(cat "$BUILD/debs/.packages-key" 2>/dev/null)" ] \
    || { echo "E: the packages were not built against this kernel build; run 'build.sh packages'"; exit 1; }

echo "I: staging local packages into $SRC/packages"
mkdir -p "$SRC/packages"
rm -f "$SRC"/packages/*.deb
cp "$BUILD"/debs/*.deb "$SRC/packages/"
rm -f "$SRC"/packages/linux-headers-*.deb "$SRC"/packages/linux-libc-dev_*.deb

docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull "$IMAGE"

echo "I: building VyOS $VERSION ($FLAVOR, arm64)"
docker run --rm --privileged -v /dev:/dev -v "$TOP:$TOP" -w "$SRC" \
    --sysctl net.ipv6.conf.lo.disable_ipv6=0 \
    -e GOSU_UID="$(id -u)" -e GOSU_GID="$(id -g)" \
    "$IMAGE" \
    sudo env VYOS_BUILD_FLAVORS_DIR="$HERE/flavors" \
        ./build-vyos-image --architecture arm64 --build-by mono-build \
        --version "$VERSION" "$FLAVOR"

ISO=$SRC/build/vyos-$VERSION-$FLAVOR-arm64.iso
[ -f "$ISO" ] || { echo "E: $ISO was not produced"; exit 1; }
mkdir -p "$BUILD/images"
cp "$ISO" "$BUILD/images/"
echo "$BUILD/images/$(basename "$ISO")" > "$BUILD/images/latest-iso"
echo "I: ISO: $BUILD/images/$(basename "$ISO")"
