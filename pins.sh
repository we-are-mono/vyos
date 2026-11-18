# What the build consumes, pinned. Sourced by every build script, on the host
# and in the build containers. Machine-specific overrides of anything in the
# first part (a local ASK checkout, say) go in pins.local.sh, which git
# ignores; environment variables do not reach the containers.

# vyos-build: the upstream VyOS image builder, used unmodified at this commit.
VYOS_BUILD_REPO=https://github.com/vyos/vyos-build.git
VYOS_BUILD_REF=43fe89d93a53724ab681120f7917b04367e86a57

# The vyos-build container image the ISO is built in, by digest (the `rolling`
# tag moves).
VYOS_BUILD_IMAGE=vyos/vyos-build@sha256:197f5910a0720b13cde212c36226944728e0aefbe1f0699497cf38202f42d184
# The same container built for arm64 from VyOS's Dockerfile at VYOS_BUILD_REF
# (.github/workflows/vyos-build-image.yml), for native builds on arm64 hosts.
VYOS_BUILD_IMAGE_ARM64=ghcr.io/we-are-mono/vyos-build@sha256:d33038ae642f163410378f355bf3a595333a01dc05150d368771fae82ecef961

# ASK release and the kernel line taken from it. ASK carries every line on one
# trunk (patches/kernel/<line>, pins/<line>, meta-ask linux-ask_<line>.bb); a
# release is refused unless its RELEASED_LINES lists ASK_LINE.
# ASK_REPO may be a URL or a local checkout.
ASK_REPO=https://github.com/we-are-mono/ASK.git
ASK_REF=mono-1.4.0
ASK_LINE=6.18

# The kernel is the line's own: LINUX_VERSION in ASK's linux-ask_<line>.bb,
# with the line's NXP SDK overlaid (built by ASK's tools/kernel_series.py).
# prepare-tree.sh refuses a mismatch with the recipe.
KERNEL_VERSION=6.18.63
KERNEL_REVISION=1
KERNEL_FLAVOR=vyos

# VyOS kernel patches carried onto the ASK kernel (a port in
# kernel/patches-vyos/ wins over the original). 0002 and 0005 only build the
# linux-perf package, which this image does not carry.
VYOS_KERNEL_PATCHES="0001-linkstate-ip-device-attribute.patch
0003-Kernel-T8914-add-support-for-2.5G-pluggables-on-BCM5.patch
0004-l2tp-defer-route-at-tunnel-create.patch"

_pins_local=$(dirname "${BASH_SOURCE[0]}")/pins.local.sh
[ -f "$_pins_local" ] && . "$_pins_local"
unset _pins_local

# Derived. The build tree lives inside the repository ($TOP, set by the
# sourcing script): the build containers mount only that.
KERNEL_RELEASE=${KERNEL_VERSION}-${KERNEL_REVISION}-${KERNEL_FLAVOR}
BUILD=$TOP/build
VYOS_BUILD=$BUILD/vyos-build
