#!/bin/bash
# Prepare the Mono Gateway DK kernel tree for VyOS:
#   stable + NXP SDK overlay + ASK series, for ASK_LINE  <- ASK's own
#       tools/kernel_series.py at ASK_REF (base-<line>, series-<line>)
#   + board device tree (ASK dts/)
#   + board fixes (kernel/patches)
#   + VyOS kernel patches
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
. "$TOP/pins.sh"


TREE=$BUILD/kernel-series
ASKDIR=$BUILD/ask
mkdir -p "$BUILD"

# ASK_REPO is a local checkout or a URL; a URL is mirrored into the build tree.
if [ -d "$ASK_REPO/.git" ] || [ -f "$ASK_REPO/HEAD" ]; then
    ASKGIT=$ASK_REPO
else
    ASKGIT=$BUILD/src-cache/ASK.git
    [ -d "$ASKGIT" ] || git clone -q --mirror "$ASK_REPO" "$ASKGIT"
    git -C "$ASKGIT" cat-file -e "$ASK_REF^{commit}" 2>/dev/null || git -C "$ASKGIT" fetch -q --tags origin
fi
ask_commit=$(git -C "$ASKGIT" rev-parse "$ASK_REF^{commit}")
echo "I: exporting ASK $ASK_REF ($ask_commit) -> $ASKDIR"
rm -rf "$ASKDIR"; mkdir -p "$ASKDIR"
git -C "$ASKGIT" archive "$ASK_REF" | tar -x -C "$ASKDIR"
echo "$ask_commit" > "$ASKDIR/.ask-commit"

grep -qx "$ASK_LINE" <(grep -v '^#' "$ASKDIR/RELEASED_LINES") \
    || { echo "E: ASK $ASK_REF is not released for the $ASK_LINE line (RELEASED_LINES)"; exit 1; }
recipe_ver=$(sed -n 's/^LINUX_VERSION = "\(.*\)"/\1/p' "$ASKDIR/meta-ask/recipes-kernel/linux/linux-ask_$ASK_LINE.bb")
[ "$recipe_ver" = "$KERNEL_VERSION" ] \
    || { echo "E: ASK's $ASK_LINE line is Linux $recipe_ver, pins.sh says $KERNEL_VERSION"; exit 1; }

# The tree is rebuilt only when an input changed: a fresh base commit would
# otherwise force a full kernel rebuild every time.
stamp=$( { echo "$ask_commit $ASK_LINE"; cat "$HERE"/patches/*.patch "$HERE"/patches-vyos/*.patch 2>/dev/null;
           for p in $VYOS_KERNEL_PATCHES; do cat "$VYOS_BUILD/scripts/package-build/linux-kernel/patches/kernel/$p"; done;
           cat "$ASKDIR/dts/mono-gateway-dk.dts"; } | sha256sum | cut -d' ' -f1)
if [ "$(cat "$TREE/.git/mono-stamp" 2>/dev/null)" = "$stamp" ] && git -C "$TREE" rev-parse -q --verify mono >/dev/null; then
    echo "I: tree up to date at $TREE ($(git -C "$TREE" rev-parse --short mono))"
    exit 0
fi

# ASK's tool reads its download-cache mirrors from meta-ask/site.conf, which a
# local checkout may have (it is not in the release); without it, it fetches
# the stable kernel and the NXP SDK from their upstream git servers, whole
# histories (several GB) for two commits. Fetch just those two commits,
# shallow, first: the tool skips a commit the work repository already has.
if [ -f "$ASK_REPO/meta-ask/site.conf" ]; then
    cp "$ASK_REPO/meta-ask/site.conf" "$ASKDIR/meta-ask/"
else
    kernel_rev=$(sed -n 's/^KERNEL_SRCREV = "\(.*\)"/\1/p' "$ASKDIR/meta-ask/recipes-kernel/linux/linux-ask_$ASK_LINE.bb")
    sdk_rev=$(sed -n 's/^NXP_SDK_SRCREV = "\(.*\)"/\1/p' "$ASKDIR/pins/$ASK_LINE/nxp-sdk-srcrev.inc")
    [ -d "$TREE/.git" ] || git init -q "$TREE"
    for pair in "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git $kernel_rev" \
                "https://github.com/nxp-qoriq/linux.git $sdk_rev"; do
        set -- $pair
        git -C "$TREE" cat-file -e "$2^{commit}" 2>/dev/null && continue
        echo "I: fetching $2 (shallow) from $1"
        git -C "$TREE" fetch -q --depth 1 --no-tags "$1" "$2"
    done
fi
echo "I: ASK $ASK_LINE series (tools/kernel_series.py prepare)"
python3 -I "$ASKDIR/tools/kernel_series.py" prepare --line "$ASK_LINE" --work "$TREE"

tgit() { git -C "$TREE" -c user.name='Tomaz Zaman' -c user.email=tomaz@mono.si "$@"; }
tgit checkout -q -B mono "series-$ASK_LINE"

echo "I: board device tree"
cp "$ASKDIR/dts/mono-gateway-dk.dts" "$TREE/arch/arm64/boot/dts/freescale/"
tgit add arch/arm64/boot/dts/freescale/mono-gateway-dk.dts
tgit commit -q -m "arm64: dts: freescale: add the Mono Gateway DK (ASK dts/)"
for p in "$HERE"/patches/*.patch; do
    echo "I: board patch $(basename "$p")"
    tgit am -q --keep-cr "$p" 2>/dev/null || { tgit am --abort 2>/dev/null || true; patch -d "$TREE" -p1 --no-backup-if-mismatch -s < "$p"; }
done

echo "I: VyOS kernel patches"
for p in $VYOS_KERNEL_PATCHES; do
    f="$HERE/patches-vyos/$p"
    [ -f "$f" ] || f="$VYOS_BUILD/scripts/package-build/linux-kernel/patches/kernel/$p"
    echo "I:   $p ($f)"
    patch -d "$TREE" -p1 --no-backup-if-mismatch -s < "$f"
done

tgit add -A >/dev/null
tgit commit -q -m "mono: board fixes, VyOS patches" || true
echo "$stamp" > "$TREE/.git/mono-stamp"
echo "I: tree ready at $TREE ($(git -C "$TREE" rev-parse --short HEAD))"
