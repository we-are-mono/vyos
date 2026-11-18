#!/bin/bash
# VyOS for the Mono Gateway DK: top-level driver.
#
#   ./build.sh kernel     patched tree + kernel .debs + ASK modules
#   ./build.sh packages   ASK and board .debs, kernel-tied VyOS packages
#   ./build.sh iso        VyOS ISO (vyos-build, arm64)
#   ./build.sh emmc       flashable eMMC image from the ISO
#   ./build.sh all        everything, in order
#   ./build.sh dev        development image in minutes: packages, then the
#                         last full ISO with the changed .debs layered on top
#                         (image/dev-assemble.sh), then the eMMC image
set -euo pipefail

TOP=$(cd "$(dirname "$0")" && pwd)
. "$TOP/pins.sh"
# The cross-build container, tagged by what it is built from, so an edited
# Dockerfile (or another user) gets its own image.
CROSS_IMAGE=mono-vyos-cross:$( { cat "$TOP/docker/Dockerfile.cross"; id -u; id -g; } | sha256sum | cut -c1-12)
export CROSS_IMAGE

cross_image() {
    docker image inspect "$CROSS_IMAGE" >/dev/null 2>&1 || \
        docker build -t "$CROSS_IMAGE" --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
            -f "$TOP/docker/Dockerfile.cross" "$TOP/docker"
}

cross() {
    cross_image
    docker run --rm -v "$TOP:$TOP" -w "$TOP" ${JOBS:+-e JOBS="$JOBS"} "$CROSS_IMAGE" "$@"
}

# vyos-build at VYOS_BUILD_REF. Every step reads it: the kernel its config and
# patches, the packages VyOS's patches, the ISO step the builder itself.
vyos_build() {
    mkdir -p "$BUILD"
    [ -d "$VYOS_BUILD/.git" ] || git clone -q "$VYOS_BUILD_REPO" "$VYOS_BUILD"
    git -C "$VYOS_BUILD" cat-file -e "$VYOS_BUILD_REF^{commit}" 2>/dev/null \
        || git -C "$VYOS_BUILD" fetch -q origin
    git -C "$VYOS_BUILD" checkout -q --detach "$VYOS_BUILD_REF"
    echo "I: vyos-build $(git -C "$VYOS_BUILD" rev-parse --short HEAD)"
}

step_kernel()   { "$TOP/kernel/prepare-tree.sh"; cross "$TOP/kernel/build-kernel.sh"; }
step_packages() { cross "$TOP/packages/build-packages.sh"; }
step_iso()      { "$TOP/image/build-iso.sh"; }
step_emmc()     { cross_image; "$TOP/image/build-emmc.sh"; }
step_dev()      { cross_image; "$TOP/image/build-dev.sh"; }

case "${1:-all}" in
    kernel|packages|iso|all|dev) vyos_build ;;
esac
case "${1:-all}" in
    kernel)   step_kernel ;;
    packages) step_packages ;;
    iso)      step_iso ;;
    emmc)     step_emmc ;;
    all)      step_kernel; step_packages; step_iso; step_emmc ;;
    dev)      step_packages; step_dev; step_emmc ;;
    *) echo "usage: $0 {kernel|packages|iso|emmc|all|dev}"; exit 1 ;;
esac
