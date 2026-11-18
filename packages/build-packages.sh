#!/bin/bash
# Build the non-kernel .debs of the Mono Gateway VyOS image, cross-compiled
# against the kernel tree build-kernel.sh left in build/kernel/src:
#
#   ask-modules     cdx.ko + ask_flowtable.ko for this kernel, and the board's
#                   LED drivers ASK carries (leds-lp5812, sfp-led)
#   ask-flowtable   the ASK offload service (daemon, systemd unit, policy)
#   nat-rtsp, jool, vyos-ipt-netflow, accel-ppp-ng
#                   VyOS's own arm64 packages with their kernel modules rebuilt
#                   for this kernel. Userspace is VyOS's binaries unchanged; the
#                   modules come from the very source revision VyOS packaged.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
. "$TOP/pins.sh"


KSRC=$BUILD/kernel/src
OUT=$BUILD/debs
CACHE=$BUILD/src-cache
WORK=$BUILD/pkgwork
UPSTREAM=$BUILD/upstream-debs
VYOS_PATCHES=$VYOS_BUILD/scripts/package-build/linux-kernel/patches
VYOS_REPO=https://packages.vyos.net/repositories/rolling
MONO_SUFFIX=+mono1
JOBS=${JOBS:-$(nproc)}

export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
KMAKE="make -C $KSRC -j$JOBS"

[ -f "$KSRC/Module.symvers" ] || { echo "E: no built kernel in $KSRC; run 'build.sh kernel'"; exit 1; }
[ "$(make -s -C "$KSRC" kernelrelease LOCALVERSION=-${KERNEL_REVISION}-${KERNEL_FLAVOR})" = "$KERNEL_RELEASE" ] \
    || { echo "E: $KSRC is not $KERNEL_RELEASE"; exit 1; }
mkdir -p "$OUT" "$CACHE" "$UPSTREAM"
rm -rf "$WORK"; mkdir -p "$WORK"

# <module.ko>...: strip, sign with this build's key, compress as the kernel's
# own modules are (CONFIG_MODULE_COMPRESS_XZ).
finish_modules() {
    local m
    for m in "$@"; do
        "${CROSS_COMPILE}strip" --strip-debug "$m"
        "$KSRC/scripts/sign-file" sha512 "$KSRC/certs/signing_key.pem" "$KSRC/certs/signing_key.x509" "$m"
        if grep -q '^CONFIG_MODULE_COMPRESS_XZ=y' "$KSRC/.config"; then
            xz -f --check=crc32 --lzma2=dict=1MiB "$m"
        fi
    done
}

kosuffix() { grep -q '^CONFIG_MODULE_COMPRESS_XZ=y' "$KSRC/.config" && echo .ko.xz || echo .ko; }

# git_src <name> <url> <rev>: a clean checkout of <rev> in $WORK/<name>.
git_src() {
    local name=$1 url=$2 rev=$3
    [ -d "$CACHE/$name.git" ] || git clone -q --bare "$url" "$CACHE/$name.git"
    git -C "$CACHE/$name.git" cat-file -e "$rev^{commit}" 2>/dev/null || git -C "$CACHE/$name.git" fetch -q origin '+refs/*:refs/*'
    git clone -q "$CACHE/$name.git" "$WORK/$name"
    git -C "$WORK/$name" checkout -q "$rev"
}

# rekmod <package> <module.ko...>: VyOS's package (the one upstream_deb
# fetched) with its modules replaced by these, its kernel references moved to
# this kernel.
rekmod() {
    local pkg=$1; shift
    local deb name dir oldk ver
    deb=$UPSTREAM/$(basename "$(index_field "$pkg" Filename)")
    name=$(dpkg-deb -f "$deb" Package)
    dir=$WORK/deb-$name
    rm -rf "$dir"; dpkg-deb -R "$deb" "$dir"
    oldk=$(ls "$dir/lib/modules")
    [ "$(echo "$oldk" | wc -l)" = 1 ] || { echo "E: $name: expected one module dir, got: $oldk"; exit 1; }
    rm -rf "$dir/lib/modules/$oldk"
    mkdir -p "$dir/lib/modules/$KERNEL_RELEASE/extra"
    for m in "$@"; do
        cp "$m" "$dir/lib/modules/$KERNEL_RELEASE/extra/"
    done
    ver=$(dpkg-deb -f "$deb" Version)$MONO_SUFFIX
    sed -i -e "s/^Version: .*/Version: $ver/" "$dir/DEBIAN/control"
    for f in control postinst postrm preinst prerm; do
        [ -f "$dir/DEBIAN/$f" ] && sed -i -e "s/$oldk/$KERNEL_RELEASE/g" "$dir/DEBIAN/$f"
    done
    (cd "$dir" && find . -type f ! -path './DEBIAN/*' -printf '%P\0' | sort -z | xargs -0 md5sum > DEBIAN/md5sums)
    rm -f "$OUT/${name}"_*.deb
    dpkg-deb -Zxz --root-owner-group -b "$dir" "$OUT/${name}_${ver}_arm64.deb" >/dev/null
    echo "I: $name $ver ($(ls "$dir/lib/modules/$KERNEL_RELEASE/extra" | tr '\n' ' '))"
}

# VyOS's arm64 package index, fetched fresh for every build: the rolling
# repository carries only current versions. A cached copy stands in only when
# the repository cannot be reached.
IDX=$CACHE/Packages-arm64
if curl -sSfL -o "$IDX.gz.part" "$VYOS_REPO/dists/rolling/main/binary-arm64/Packages.gz" \
        && gunzip -c "$IDX.gz.part" > "$IDX.part"; then
    mv "$IDX.part" "$IDX"
else
    [ -f "$IDX" ] || { echo "E: cannot fetch VyOS's package index"; exit 1; }
    echo "W: cannot fetch VyOS's package index; using the cached one"
fi
rm -f "$IDX.gz.part" "$IDX.part"

# index_field <package> <field>: a field of the package's index entry.
index_field() {
    awk -v p="$1" -v f="$2:" '$1=="Package:" {cur=$2} cur==p && $1==f {print $2; exit}' "$IDX"
}

# vyos_src <name> <field>: commit_id or scm_url of a package vyos-build builds
# with its kernel (linux-kernel/package.toml at VYOS_BUILD_REF).
vyos_src() {
    python3 -c '
import sys, tomllib
toml, name, field = sys.argv[1:]
for p in tomllib.load(open(toml, "rb"))["packages"]:
    if p["name"] == name:
        print(p[field]); break
else:
    sys.exit(f"{name} not in {toml}")
' "$VYOS_BUILD/scripts/package-build/linux-kernel/package.toml" "$1" "$2"
}

# upstream_deb <package> <source id>: fetch VyOS's current package from the
# index, and refuse one not built from the source this build uses (the source
# id must appear in its version or file name). VyOS moving a package past the
# pinned vyos-build is then a clear error, fixed by moving VYOS_BUILD_REF.
upstream_deb() {
    local pkg=$1 id=$2 ver file
    ver=$(index_field "$pkg" Version)
    file=$(index_field "$pkg" Filename)
    [ -n "$file" ] || { echo "E: $pkg is not in VyOS's arm64 package index"; exit 1; }
    case "$ver $(basename "$file")" in
        *"$id"*) ;;
        *) echo "E: VyOS's repository has $pkg $ver; vyos-build ${VYOS_BUILD_REF:0:12} builds it from $id."
           echo "E: Move VYOS_BUILD_REF in pins.sh to the vyos-build commit that matches."
           exit 1 ;;
    esac
    [ -f "$UPSTREAM/$(basename "$file")" ] || {
        curl -sSfL -o "$UPSTREAM/$(basename "$file").part" "$VYOS_REPO/$file" \
            && mv "$UPSTREAM/$(basename "$file").part" "$UPSTREAM/$(basename "$file")"; }
    echo "I: $pkg $ver from VyOS, source $id"
}

echo "I: ask-modules"
ASKMOD=$BUILD/kernel/ask-cdx
d=$WORK/ask-modules
mkdir -p "$d/DEBIAN" "$d/lib/modules/$KERNEL_RELEASE/extra"
cp "$ASKMOD/cdx.ko" "$ASKMOD/ask_flowtable.ko" "$d/lib/modules/$KERNEL_RELEASE/extra/"
# The board's LED drivers, as ASK (meta-ask) and OpenWrt (package/mono/mono-leds)
# build them: the RGBW status LED's LP5812 controller and the SFP cage LEDs.
for m in lp5812-driver:leds-lp5812 sfp-led:sfp-led; do
    rdir=${m%%:*} mod=${m#*:}
    mkdir -p "$WORK/$mod"
    cp "$BUILD/ask/meta-ask/recipes-kernel/$rdir/files/"*.[ch] "$WORK/$mod/"
    printf 'obj-m := %s.o\nccflags-y := -I$(src)\n' "$mod" > "$WORK/$mod/Kbuild"
    $KMAKE M="$WORK/$mod" modules > "$WORK/$mod.log" 2>&1 || { tail -30 "$WORK/$mod.log"; exit 1; }
    finish_modules "$WORK/$mod/$mod.ko"
    cp "$WORK/$mod/$mod$(kosuffix)" "$d/lib/modules/$KERNEL_RELEASE/extra/"
done
# OpenWrt autoloads both (AutoLoad 10 and 60); nothing else would load sfp-led.
mkdir -p "$d/etc/modules-load.d"
printf 'leds-lp5812\nsfp-led\n' > "$d/etc/modules-load.d/mono-leds.conf"
ASK_VER=${ASK_REF#mono-}~$(cut -c1-12 "$BUILD/ask/.ask-commit")
cat > "$d/DEBIAN/control" <<EOF
Package: ask-modules
Version: $ASK_VER
Architecture: arm64
Maintainer: Tomaz Zaman <tomaz@mono.si>
Depends: linux-image-$KERNEL_RELEASE
Section: kernel
Priority: optional
Description: NXP ASK fast-path kernel modules for the Mono Gateway
 cdx brings up the DPAA/FMan offload hardware (load-once); ask_flowtable
 binds nftables flowtables declaring 'flags offload' on CDX-backed ports and
 installs their flows into the hardware. leds-lp5812 and sfp-led drive the
 board's RGBW status LED and SFP cage link/activity LEDs. Built from ASK $ASK_REF.
EOF
echo /etc/modules-load.d/mono-leds.conf > "$d/DEBIAN/conffiles"
printf '#!/bin/sh\nset -e\n[ "$1" = configure ] && depmod -a %s || true\n' "$KERNEL_RELEASE" > "$d/DEBIAN/postinst"
chmod 0755 "$d/DEBIAN/postinst"
rm -f "$OUT"/ask-modules_*.deb
dpkg-deb -Zxz --root-owner-group -b "$d" "$OUT/ask-modules_${ASK_VER}_arm64.deb" >/dev/null

echo "I: ask-flowtable"
d=$WORK/ask-flowtable
rm -rf "$WORK/ft"; cp -a "$BUILD/ask/flowtable" "$WORK/ft"
make -C "$WORK/ft" -j"$JOBS" CC="${CROSS_COMPILE}gcc" all > "$WORK/ft.log" 2>&1 || { tail -30 "$WORK/ft.log"; exit 1; }
install -D -m 0755 "$WORK/ft/src/ask-flowtable" "$d/usr/sbin/ask-flowtable"
"${CROSS_COMPILE}strip" "$d/usr/sbin/ask-flowtable"
install -D -m 0644 "$BUILD/ask/config/offload.conf" "$d/etc/ask/offload.conf"
install -D -m 0644 "$HERE/files/ask-flowtable.service" "$d/lib/systemd/system/ask-flowtable.service"
mkdir -p "$d/DEBIAN"
cat > "$d/DEBIAN/control" <<EOF
Package: ask-flowtable
Version: $ASK_VER
Architecture: arm64
Maintainer: Tomaz Zaman <tomaz@mono.si>
Depends: ask-modules (= $ASK_VER), nftables, iproute2, kmod
Section: net
Priority: optional
Description: NXP ASK hardware flow-offload service for the Mono Gateway
 Declares and maintains the nftables flowtable that drives the ASK CDX
 hardware offload (table inet ask_flowtable), reconciling /etc/ask/offload.conf
 and backend health. Built from ASK $ASK_REF.
EOF
echo /etc/ask/offload.conf > "$d/DEBIAN/conffiles"
cat > "$d/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    deb-systemd-helper enable ask-flowtable.service >/dev/null || true
    if [ -d /run/systemd/system ]; then
        systemctl daemon-reload >/dev/null || true
        systemctl restart ask-flowtable.service >/dev/null || true
    fi
fi
EOF
cat > "$d/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
if [ -d /run/systemd/system ] && [ "$1" = remove ]; then
    systemctl stop ask-flowtable.service >/dev/null || true
fi
EOF
cat > "$d/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = purge ] || [ "$1" = remove ]; then
    deb-systemd-helper purge ask-flowtable.service >/dev/null || true
fi
EOF
chmod 0755 "$d/DEBIAN/postinst" "$d/DEBIAN/prerm" "$d/DEBIAN/postrm"
rm -f "$OUT"/ask-flowtable_*.deb
dpkg-deb -Zxz --root-owner-group -b "$d" "$OUT/ask-flowtable_${ASK_VER}_arm64.deb" >/dev/null

echo "I: mono-gateway-bsp"
d=$WORK/mono-gateway-bsp
cp -a "$HERE/bsp" "$d"
# Modes from the source tree's umask would leak into the package.
find "$d" -type d -exec chmod 0755 {} +
find "$d" -type f -exec chmod 0644 {} +
chmod 0755 "$d"/usr/libexec/mono/* "$d"/etc/kernel/postinst.d/*
mkdir -p "$d/DEBIAN"
BSP_VER=1.0~$(date -u +%Y%m%d%H%M)
cat > "$d/DEBIAN/control" <<EOF
Package: mono-gateway-bsp
Version: $BSP_VER
Architecture: all
Maintainer: Tomaz Zaman <tomaz@mono.si>
Depends: fdisk, e2fsprogs, util-linux, python3, vyos-1x
Section: admin
Priority: optional
Description: Mono Gateway DK board support for VyOS
 U-Boot boot support: the raw kernel Image and device tree in every image's
 /boot, and /boot/extlinux/extlinux.conf kept in step with VyOS's image list,
 so `add system image` upgrades boot. First-boot growth of the persistence
 partition to the size of the eMMC, and the RGBW status LED's steady state
 (white, dim) once VyOS is configured.
EOF
cat > "$d/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    deb-systemd-helper enable mono-grow-persistence.service >/dev/null || true
    deb-systemd-helper enable mono-status-led.service >/dev/null || true
    deb-systemd-helper enable mono-extlinux-sync.service >/dev/null || true
    deb-systemd-helper enable mono-extlinux-sync.path >/dev/null || true
    # Kernels installed before this package missed its postinst.d hook.
    for v in /boot/vmlinuz-*; do
        [ -f "$v" ] && /etc/kernel/postinst.d/zz-mono-uboot "${v#/boot/vmlinuz-}"
    done
fi
EOF
chmod 0755 "$d/DEBIAN/postinst"
rm -f "$OUT"/mono-gateway-bsp_*.deb
dpkg-deb -Zxz --root-owner-group -b "$d" "$OUT/mono-gateway-bsp_${BSP_VER}_all.deb" >/dev/null

KO=$(kosuffix)

# The source revisions are vyos-build's, at VYOS_BUILD_REF.
echo "I: nat-rtsp (kernel modules)"
rev=$(vyos_src nat-rtsp commit_id)
upstream_deb nat-rtsp "$rev"
git_src nat-rtsp "$(vyos_src nat-rtsp scm_url)" "$rev"
$KMAKE M="$WORK/nat-rtsp" modules > "$WORK/nat-rtsp.log" 2>&1 || { tail -30 "$WORK/nat-rtsp.log"; exit 1; }
finish_modules "$WORK"/nat-rtsp/nf_conntrack_rtsp.ko "$WORK"/nat-rtsp/nf_nat_rtsp.ko
rekmod nat-rtsp "$WORK"/nat-rtsp/nf_conntrack_rtsp$KO "$WORK"/nat-rtsp/nf_nat_rtsp$KO

echo "I: jool (kernel modules)"
# vyos-build builds Jool from its release tarball (build-jool.sh).
jv=$(sed -n 's/^PACKAGE_VERSION=//p' "$VYOS_BUILD/scripts/package-build/linux-kernel/build-jool.sh")
upstream_deb jool "${jv}-"
tgz=$CACHE/jool-$jv.tar.gz
[ -f "$tgz" ] || { curl -sSfL -o "$tgz.part" "https://github.com/NICMx/Jool/archive/refs/tags/v$jv.tar.gz" && mv "$tgz.part" "$tgz"; }
mkdir -p "$WORK/jool"; tar -xzf "$tgz" -C "$WORK/jool" --strip-components=1
for m in common nat64 siit; do
    $KMAKE M="$WORK/jool/src/mod/$m" modules >> "$WORK/jool.log" 2>&1 || { tail -30 "$WORK/jool.log"; exit 1; }
done
finish_modules "$WORK"/jool/src/mod/common/jool_common.ko "$WORK"/jool/src/mod/nat64/jool.ko "$WORK"/jool/src/mod/siit/jool_siit.ko
rekmod jool "$WORK"/jool/src/mod/common/jool_common$KO "$WORK"/jool/src/mod/nat64/jool$KO "$WORK"/jool/src/mod/siit/jool_siit$KO

echo "I: vyos-ipt-netflow (kernel module)"
rev=$(vyos_src ipt-netflow commit_id)
upstream_deb vyos-ipt-netflow "$rev"
git_src ipt-netflow "$(vyos_src ipt-netflow scm_url)" "$rev"
for p in "$VYOS_PATCHES"/ipt-netflow/*.patch; do patch -d "$WORK/ipt-netflow" -p1 -s < "$p"; done
(cd "$WORK/ipt-netflow" && ./configure --enable-direction --enable-macaddress --enable-vlan \
    --enable-sampler --enable-aggregation --kdir="$KSRC" --disable-snmp-agent --ipt-ver=1.8.9 --ipt-lib=/usr/lib/aarch64-linux-gnu/xtables \
    > "$WORK/ipt-netflow.log" 2>&1) || { tail -30 "$WORK/ipt-netflow.log"; exit 1; }
make -C "$WORK/ipt-netflow" CC="${CROSS_COMPILE}gcc" ipt_NETFLOW.ko >> "$WORK/ipt-netflow.log" 2>&1 || { tail -30 "$WORK/ipt-netflow.log"; exit 1; }
finish_modules "$WORK"/ipt-netflow/ipt_NETFLOW.ko
rekmod vyos-ipt-netflow "$WORK"/ipt-netflow/ipt_NETFLOW$KO

echo "I: accel-ppp-ng (kernel modules)"
rev=$(vyos_src accel-ppp-ng commit_id)
upstream_deb accel-ppp-ng "$rev"
git_src accel-ppp-ng "$(vyos_src accel-ppp-ng scm_url)" "$rev"
for p in "$VYOS_PATCHES"/accel-ppp-ng/*.patch; do patch -d "$WORK/accel-ppp-ng" -p1 -s < "$p"; done
for m in ipoe vlan_mon; do
    # version.h is what accel-ppp's CMake generates from version.h.in.
    printf '#define ACCEL_PPP_VERSION "%s"\n' "$(git -C "$WORK/accel-ppp-ng" describe --tags --always)" \
        > "$WORK/accel-ppp-ng/drivers/$m/version.h"
    $KMAKE M="$WORK/accel-ppp-ng/drivers/$m" modules >> "$WORK/accel.log" 2>&1 || { tail -30 "$WORK/accel.log"; exit 1; }
done
finish_modules "$WORK"/accel-ppp-ng/drivers/ipoe/ipoe.ko "$WORK"/accel-ppp-ng/drivers/vlan_mon/vlan_mon.ko
rekmod accel-ppp-ng "$WORK"/accel-ppp-ng/drivers/ipoe/ipoe$KO "$WORK"/accel-ppp-ng/drivers/vlan_mon/vlan_mon$KO

sha256sum < "$KSRC/certs/signing_key.x509" | cut -d' ' -f1 > "$OUT/.packages-key"
echo "I: packages done:"
ls -1 "$OUT"
