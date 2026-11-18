#!/bin/bash
# Development ISO: the last full build with the changed .debs layered on top
# (see dev-assemble.sh). Minutes instead of a full vyos-build run.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
. "$TOP/pins.sh"

BASE=$(cat "$BUILD/images/latest-full-iso" 2>/dev/null || true)
[ -f "$BASE" ] && [ -f "$BASE.debs" ] \
    || { echo "E: no full build to layer on; run './build.sh iso' once"; exit 1; }
[ "$(cat "$BUILD/debs/.kernel-key" 2>/dev/null)" = "$(cat "$BUILD/debs/.packages-key" 2>/dev/null)" ] \
    || { echo "E: the packages were not built against this kernel build; run './build.sh packages'"; exit 1; }
grep -q 'flags: .*F' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null || [ "$(uname -m)" = aarch64 ] \
    || { echo "E: qemu-aarch64 binfmt with the F flag is required (apt install qemu-user-static)"; exit 1; }

# A -dev suffix keeps these out of releases (publish.sh refuses them).
VERSION=${VERSION:-$(date -u +%Y.%m.%d-%H%M)-mono-dev}
echo "I: development build $VERSION on $(basename "$BASE")"
docker run --rm --privileged --user 0 -v "$TOP:$TOP" -w "$TOP" \
    -e OWNER="$(id -u):$(id -g)" "${TOOLS_IMAGE:?run through build.sh}" \
    "$HERE/dev-assemble.sh" "$BASE" "$BASE.debs" "$BUILD/debs" "$VERSION" "$BUILD/images" "$BUILD/dev-work" \
    "$VYOS_BUILD/data/live-build-config/rootfs/excludes"
