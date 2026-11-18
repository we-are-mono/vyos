#!/bin/bash
# Layered development image: the last full build's root filesystem with the
# .debs that changed since installed on top, repacked as an ISO that the eMMC
# step and VyOS's `add system image` take like a full one.
#
# Runs as root in the cross-build container (build-dev.sh). Only the changed
# packages' maintainer scripts run emulated (through the host's qemu-user
# binfmt handler); unpacking, repacking and the ISO are native. For
# development only: an upgraded root filesystem is close to, but not the same
# as, a fresh vyos-build image, so releases come from full builds.
#
#   dev-assemble.sh <base.iso> <base.debs> <debs dir> <version> <out dir> <work dir> <excludes>
#
# <excludes> is vyos-build's squashfs exclude list (docs, man pages, logs,
# backups...), applied as vyos-build applies it.
set -euo pipefail

BASE_ISO=$1 BASE_DEBS=$2 DEBS=$3 VERSION=$4 OUT=$5 WORK=$6 EXCLUDES=$7
OWNER=${OWNER:-0:0}
R=$WORK/rootfs

cleanup() {
    for m in dev/pts dev sys proc; do
        mountpoint -q "$R/$m" && umount "$R/$m" || true
    done
}
trap cleanup EXIT

rm -rf "$WORK"; mkdir -p "$WORK/iso"
xorriso -osirrox on -indev "$BASE_ISO" -extract /live/filesystem.squashfs "$WORK/iso/filesystem.squashfs" \
    -extract /version.json "$WORK/iso/version.json" >/dev/null 2>&1
BASE_VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$WORK/iso/version.json")
echo "I: base $BASE_VERSION"
unsquashfs -q -n -d "$R" "$WORK/iso/filesystem.squashfs"
rm -f "$WORK/iso/filesystem.squashfs"

# The packages whose .deb differs from the one the base was built with.
changed=()
for deb in "$DEBS"/*.deb; do
    case "$(basename "$deb")" in linux-headers-*|linux-libc-dev_*) continue ;; esac
    name=$(dpkg-deb -f "$deb" Package)
    sum=$(sha256sum "$deb" | cut -d' ' -f1)
    grep -qx "$name $sum" "$BASE_DEBS" || changed+=("$deb")
done
echo "I: changed since the base: ${#changed[@]} package(s)"

if [ ${#changed[@]} -gt 0 ]; then
    mount -t proc proc "$R/proc"
    mount -t sysfs sys "$R/sys"
    mount --bind /dev "$R/dev"
    mkdir -p "$R/tmp/mono-debs"
    cp "${changed[@]}" "$R/tmp/mono-debs/"
    # No services start in the chroot.
    printf '#!/bin/sh\nexit 101\n' > "$R/usr/sbin/policy-rc.d"; chmod 0755 "$R/usr/sbin/policy-rc.d"
    # kdump-tools' kernel hook cannot build its initrd in a chroot ("failed to
    # determine device for /"); the full build ships none either.
    kdump=$R/etc/kernel/postinst.d/kdump-tools
    [ -x "$kdump" ] && chmod -x "$kdump"
    for deb in "$R"/tmp/mono-debs/*.deb; do echo "I:   $(basename "$deb")"; done
    chroot "$R" sh -c 'DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/mono-debs/*.deb' > "$WORK/dpkg.log" 2>&1 \
        || { tail -30 "$WORK/dpkg.log"; echo "E: dpkg -i failed (log: $WORK/dpkg.log)"; exit 1; }
    [ -f "$kdump" ] && chmod +x "$kdump"
    rm -rf "$R/tmp/mono-debs" "$R/usr/sbin/policy-rc.d"
    cleanup
fi

# The version, everywhere vyos-build writes it.
python3 - "$R" "$WORK/iso/version.json" "$BASE_VERSION" "$VERSION" <<'PYEOF'
import datetime, json, sys, uuid
root, iso_json, old, new = sys.argv[1:]
data = json.load(open(iso_json))
data.update(version=new, built_on=datetime.datetime.now(datetime.timezone.utc).strftime('%a %d %b %Y %H:%M UTC'),
            build_uuid=str(uuid.uuid4()), build_comment=f'development build layered on {old}')
for path in (iso_json, f'{root}/usr/share/vyos/version.json'):
    json.dump(data, open(path, 'w'))
open(f'{root}/opt/vyatta/etc/version', 'w').write(f'Version: {new}\n')
p = f'{root}/etc/os-release'
open(p, 'w').write(open(p).read().replace(old, new))
PYEOF

KREL=$(ls "$R/lib/modules")
[ "$(echo "$KREL" | wc -l)" = 1 ] || { echo "E: expected one kernel, got: $KREL"; exit 1; }
I=$WORK/isoroot
mkdir -p "$I/live"
cp "$WORK/iso/version.json" "$I/"
cp -L "$R/boot/vmlinuz" "$I/live/vmlinuz-$KREL"
cp -L "$R/boot/initrd.img" "$I/live/initrd.img-$KREL"
ln -s "vmlinuz-$KREL" "$I/live/vmlinuz"
ln -s "initrd.img-$KREL" "$I/live/initrd.img"
echo "I: squashfs (native)"
mksquashfs "$R" "$I/live/filesystem.squashfs" -comp xz -b 256K -always-use-fragments \
    -wildcards -ef "$EXCLUDES" -noappend -no-progress -quiet
(cd "$I" && find . -type f ! -name sha256sum.txt -print0 | sort -z | xargs -0 sha256sum > sha256sum.txt)

ISO=$OUT/vyos-$VERSION-mono-gateway-dk-arm64.iso
xorriso -as mkisofs -quiet -R -J -V VyOS -o "$ISO" "$I"
chown "$OWNER" "$ISO"
echo "$ISO" > "$OUT/latest-iso"; chown "$OWNER" "$OUT/latest-iso"
rm -rf "$WORK"
echo "I: ISO: $ISO"
