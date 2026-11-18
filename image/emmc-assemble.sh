#!/bin/bash
# Assemble the flashable Mono Gateway eMMC image from a VyOS ISO.
# Runs as root inside the mono-vyos-cross container (build-emmc.sh); the GRUB
# bookkeeping step chroots into the arm64 rootfs through qemu-user binfmt.
#
# Layout (MBR — the whole table lives in sector 0):
#   0-4 KiB       MBR
#   4 KiB-32 MiB  boot firmware (RCW/BL2, FIP, U-Boot env, FMan microcode) —
#                 not part of this image's payload; the flashing procedure
#                 skips it
#   32 MiB        p1 "persistence" (ext4): the VyOS installed-image layout,
#                 exactly as VyOS's own installer writes it, plus
#                 /boot/extlinux/extlinux.conf for U-Boot's
#                 `sysboot mmc 0:1 any ${scriptaddr} /boot/extlinux/extlinux.conf`,
#                 written by the image's own extlinux-sync (mono-gateway-bsp),
#                 as it rewrites it on every image change on the device.
#                 The partition is grown to the whole eMMC on first boot
#                 (mono-grow-persistence.service).
set -euo pipefail

ISO=$1
OUTDIR=$2
WORK=$3
DTB=mono-gateway-dk.dtb
OWNER=${OWNER:-0:0}

cleanup() {
    for m in "$WORK/rootfs/boot" "$WORK/rootfs/proc" "$WORK/rootfs/dev"; do
        mountpoint -q "$m" && umount "$m" || true
    done
}
trap cleanup EXIT

rm -rf "$WORK"; mkdir -p "$WORK/iso" "$WORK/part"
echo "I: extracting $ISO"
xorriso -osirrox on -indev "$ISO" -extract /version.json "$WORK/iso/version.json" \
    -extract /live/filesystem.squashfs "$WORK/iso/filesystem.squashfs" >/dev/null 2>&1
VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$WORK/iso/version.json")
echo "I: VyOS version $VERSION"
unsquashfs -q -n -d "$WORK/rootfs" "$WORK/iso/filesystem.squashfs"

KREL=$(ls "$WORK/rootfs/lib/modules")
[ "$(echo "$KREL" | wc -l)" = 1 ] || { echo "E: expected one kernel in the image, got: $KREL"; exit 1; }

# --- the VyOS installed-image layout (vyos-build raw_image.install_image) ---
P=$WORK/part
V=$P/boot/$VERSION
mkdir -p "$V/rw" "$V/work/work"
cp "$WORK/iso/filesystem.squashfs" "$V/$VERSION.squashfs"
for f in "$WORK"/rootfs/boot/*; do
    [ -f "$f" ] && cp -L "$f" "$V/"
done
# VyOS's own vmlinuz and initrd.img, and the raw Image and device tree U-Boot
# boots, which mono-gateway-bsp's kernel hook put in the image's /boot.
for f in vmlinuz initrd.img Image "$DTB"; do
    [ -f "$V/$f" ] || { echo "E: no $f in the image's /boot (is mono-gateway-bsp in it?)"; exit 1; }
done
echo "/ union" > "$P/persistence.conf"

# --- GRUB bookkeeping, written by the image's own vyos-1x code, so that
# `show system image` and image management see a normal VyOS install. U-Boot
# does not read it; it boots the extlinux.conf below.
echo "I: GRUB configuration (via the image's vyos.system.grub)"
mkdir -p "$P/boot/grub"
mount --bind "$P/boot" "$WORK/rootfs/boot"
mount -t proc proc "$WORK/rootfs/proc"
mount --bind /dev "$WORK/rootfs/dev"
chroot "$WORK/rootfs" /usr/bin/python3 - "$VERSION" <<'PYEOF'
import sys
from vyos.system import grub
from vyos import template
version = sys.argv[1]
boot_settings = {'timeout': '5', 'console_type': 'ttyS', 'console_num': '0',
                 'console_speed': '115200', 'bootmode': 'normal'}
root = ''
template.render(f'{root}/{grub.GRUB_DIR_MAIN}/grub.cfg', grub.TMPL_GRUB_MAIN, {})
grub.common_write(root)
grub.vars_write(f'{root}/{grub.CFG_VYOS_VARS}', boot_settings)
grub.modules_write(f'{root}/{grub.CFG_VYOS_MODULES}', [])
grub.write_cfg_ver(1, root)
template.render(f'{root}/{grub.CFG_VYOS_MENU}', grub.TMPL_GRUB_MENU, {})
template.render(f'{root}/{grub.CFG_VYOS_OPTIONS}', grub.TMPL_GRUB_OPTS, {})
grub.create_structure(root)
grub.version_add(version, root)
grub.set_default(version, root)
grub.set_console_type('ttyS', root)
print(grub.BOOT_OPTS_STEM + version)
PYEOF
# U-Boot's extlinux.conf, by the same code that maintains it on the device.
chroot "$WORK/rootfs" /usr/libexec/mono/extlinux-sync /
cleanup

[ -f "$P/boot/extlinux/extlinux.conf" ] || { echo "E: extlinux-sync wrote no extlinux.conf"; exit 1; }
cat "$P/boot/extlinux/extlinux.conf"

# --- filesystem + disk image ---
used_kib=$(du -sk "$P" | cut -f1)
fs_mib=$(( (used_kib * 5 / 4) / 1024 + 256 ))
echo "I: persistence filesystem ${fs_mib} MiB (payload $((used_kib / 1024)) MiB)"
FS=$WORK/persistence.ext4
mkfs.ext4 -q -F -L persistence -E lazy_itable_init=0,lazy_journal_init=0 -d "$P" "$FS" "${fs_mib}M"

IMG=$OUTDIR/vyos-$VERSION-mono-gateway-dk-emmc.img
start=$((32 * 2048))
sectors=$((fs_mib * 2048))
rm -f "$IMG"
truncate -s $(( (start + sectors) * 512 )) "$IMG"
printf 'label: dos\nunit: sectors\nstart=%d, size=%d, type=83, bootable\n' "$start" "$sectors" | sfdisk -q "$IMG"
dd if="$FS" of="$IMG" bs=1M seek=32 conv=notrunc,sparse status=none
gzip -1 -f -k "$IMG"
chown "$OWNER" "$IMG" "$IMG.gz"
( cd "$OUTDIR" && sha256sum "$(basename "$IMG")" "$(basename "$IMG").gz" > "$(basename "$IMG").sha256" && chown "$OWNER" "$(basename "$IMG").sha256" )
echo "$IMG" > "$OUTDIR/latest-emmc"; chown "$OWNER" "$OUTDIR/latest-emmc"
rm -rf "$WORK"
echo "I: eMMC image: $IMG"
