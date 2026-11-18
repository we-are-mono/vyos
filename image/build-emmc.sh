#!/bin/bash
# Build the flashable eMMC image from the latest ISO (see emmc-assemble.sh).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
. "$TOP/pins.sh"

ISO=${ISO:-$(cat "$BUILD/images/latest-iso" 2>/dev/null || true)}
[ -f "$ISO" ] || { echo "E: no ISO; run 'build.sh iso'"; exit 1; }

docker run --rm --privileged --user 0 -v "$TOP:$TOP" -w "$TOP" \
    -e OWNER="$(id -u):$(id -g)" "${TOOLS_IMAGE:?run through build.sh}" \
    "$HERE/emmc-assemble.sh" "$ISO" "$BUILD/images" "$BUILD/emmc-work"
