# VyOS for the Mono Gateway

Builds a flashable [VyOS](https://vyos.io) (rolling) image for the Mono Gateway
Development Kit (NXP LS1046A), with [ASK](https://github.com/we-are-mono/ASK)
as the board support package: its kernel, its hardware flow offload and its
board drivers, as in Mono's OpenWrt.

## What goes into the image

- **Kernel**: ASK's 6.18 kernel (Linux 6.18.63, the NXP DPAA/FMan SDK and the
  ASK patch series) plus the board device tree, the board fixes in
  `kernel/patches/` and VyOS's own kernel patches. The configuration is VyOS's,
  plus `kernel/mono-ls1046a.config` for the board and ASK.
- **ASK**: the `cdx` and `ask_flowtable` modules and the `ask-flowtable`
  service, which offloads forwarded flows to the hardware with no
  configuration.
- **Board**: the status LED and SFP port LED drivers; on first boot the data
  partition grows to fill the eMMC.
- **Upgrades**: VyOS's own `add system image` works. U-Boot boots
  `/boot/extlinux/extlinux.conf`, which is rewritten from VyOS's image list
  whenever images are added, removed or the default changes.
- **VyOS packages with kernel modules** (nat-rtsp, jool, ipt-netflow,
  accel-ppp): VyOS's own packages with only the modules rebuilt for this kernel.

vyos-build is used unmodified, at the commit pinned in `pins.sh`. Mono's
packages reach it through its `packages/` directory and the build flavor in
`image/flavors/`.

## Build

Needs, on an x86-64 Linux host:

- Docker
- a `qemu-aarch64` binfmt handler registered with the `F` flag (Debian:
  `apt install qemu-user-static`)
- git, python3, patch and tar (the kernel tree is prepared on the host)
- about 40 GB of disk in `build/`, and network access: the first run fetches
  the Linux stable and NXP kernel histories (several GB), vyos-build, ASK and
  VyOS's packages

```
./build.sh all        # or one step: kernel | packages | iso | emmc
```

The result lands in `build/images/`: `vyos-<version>-mono-gateway-dk-emmc.img`,
with a `.gz` and a `.sha256`, and the ISO it is made from.

A full build takes about an hour on an x86-64 host, most of it in the ISO step:
vyos-build runs every arm64 program of the image build under qemu. On an
arm64 host the ISO step runs natively, in an arm64 build of VyOS's build
container (`VYOS_BUILD_IMAGE_ARM64` in `pins.sh`, made by
`.github/workflows/vyos-build-image.yml`), in about 8 minutes; the
release workflow builds that way. For
development there is a shortcut:

```
./build.sh dev        # about 2 minutes; about 5 when the kernel changed
```

It rebuilds the packages and installs the ones that changed onto the root
filesystem of the last full build, then repacks it into an ISO and an eMMC
image like a full build's. Run `./build.sh kernel` first after kernel changes.
Development builds are named `<version>-mono-dev` and are never published:
the result is an upgraded root filesystem, close to a fresh build but not
identical, so releases come from full builds.

`pins.sh` pins the inputs: the vyos-build commit and container, the ASK
release and the kernel version. The VyOS packages the ISO installs come from
VyOS's rolling repository as it is on the day of the build, so two builds of
the same commit are not identical. Overrides for one machine (a local ASK
checkout, for example) go in `pins.local.sh`.

## Install

Installing writes the image to the Gateway's eMMC from its recovery system, a
small Linux that runs from RAM. It replaces whatever OS is on the eMMC
(OpenWrt, say) and keeps the boot firmware.

You need:

- the image, built as above
- a computer on the same network as the Gateway, to serve the image
- the Gateway's serial console on that computer (115200 baud, 8N1), for
  example `picocom -b 115200 /dev/ttyUSB0`
- a network cable or SFP module from one of the Gateway's ports to a network
  with a DHCP server

### 1. Serve the image

On the computer, from this repository:

```
cd build/images
python3 -m http.server 8000
```

Note the computer's IP address (`ip -br addr`); below it is `<host>`.

### 2. Stop at the U-Boot prompt

Power the Gateway on, or reboot it from its current OS. Watch the serial
console: after the board's self-test U-Boot counts down
`Hit any key to stop autoboot: 5`. Press any key before it reaches 0. The
prompt changes to `=>`.

### 3. Check the boot settings

At the `=>` prompt:

```
printenv bootcmd slot upgrade_available ramdisk_addr_r
```

It should show a `bootcmd` that contains `sysboot ... extlinux.conf`,
`slot=a`, `upgrade_available=0` (or "not defined") and
`ramdisk_addr_r=0xa0000000`. Fix whatever differs, then save:

```
setenv slot a
setenv upgrade_available 0
setenv ramdisk_addr_r 0xa0000000
saveenv
```

If `bootcmd` does not mention `sysboot` (the board's firmware predates the
extlinux boot), also run these before `saveenv`:

```
setenv scriptaddr 0x80200000
setenv set_slot_a 'setenv bootpart 1; setenv rootpart 2'
setenv set_slot_b 'setenv bootpart 3; setenv rootpart 4'
setenv bootcmd 'run set_slot_${slot}; sysboot mmc 0:${bootpart} any ${scriptaddr} /boot/extlinux/extlinux.conf || run recovery'
```

### 4. Boot the recovery system

```
run recovery
```

After about a minute it shows `recovery login:`. Log in as `root`; there is
no password.

### 5. Connect it to the network

See which port has a link (`LOWER_UP`):

```
ip -br link
```

Ask for an address on that port (`<port>` is its name, such as `eth3`):

```
udhcpc -i <port> -n -q -t 10
```

It prints `lease of <address> obtained`. If it does not, check the cable and
run it again.

### 6. Download the image and check it

```
cd /tmp
wget http://<host>:8000/vyos-<version>-mono-gateway-dk-emmc.img.gz
wget http://<host>:8000/vyos-<version>-mono-gateway-dk-emmc.img.sha256
gunzip vyos-<version>-mono-gateway-dk-emmc.img.gz
sha256sum vyos-<version>-mono-gateway-dk-emmc.img
cat vyos-<version>-mono-gateway-dk-emmc.img.sha256
```

The checksum `sha256sum` prints must match the `.img` line of the `.sha256`
file. If it does not, download it again; do not flash it.

### 7. Write it to the eMMC

The first 32 MiB of the eMMC hold the board's boot firmware, its settings and
the eMMC copy of the recovery system. The image file is empty in that range,
so it is written in two parts, and never as a whole:

```
I=vyos-<version>-mono-gateway-dk-emmc.img
dd if=$I of=/dev/mmcblk0 bs=512 count=8 conv=fsync
dd if=$I of=/dev/mmcblk0 bs=1M skip=32 seek=32 conv=fsync
```

The first command writes the partition table (the first 4 KiB). The second
writes the VyOS partition, from 32 MiB on; it takes a minute or two. Both
end with `records out`.

### 8. Boot VyOS

```
reboot -f
```

Do not press a key this time. U-Boot loads VyOS from the eMMC. The first boot
takes a few minutes: the VyOS partition grows to fill the eMMC. The status
LED turns from green to dim white when VyOS has finished starting.

Log in on the serial console as `vyos`, password `vyos`.

### 9. First steps

Change the password:

```
configure
set system login user vyos authentication plaintext-password <new password>
commit
save
exit
```

A basic router: `<wan>` is the port facing the internet (address and DNS
servers by DHCP; `system name-server <wan>` lets the Gateway itself use those
DNS servers, which upgrades need), `<lan>` the port facing your network. Pick a LAN subnet that differs from the
WAN side; this example uses 192.168.1.0/24, with the Gateway at 192.168.1.1
handing out .100 to .199 and answering DNS:

```
configure
set interfaces ethernet <wan> address dhcp
set system name-server <wan>
set interfaces ethernet <lan> address 192.168.1.1/24
set service dhcp-server listen-interface <lan>
set service dhcp-server shared-network-name LAN subnet 192.168.1.0/24 subnet-id 1
set service dhcp-server shared-network-name LAN subnet 192.168.1.0/24 option default-router 192.168.1.1
set service dhcp-server shared-network-name LAN subnet 192.168.1.0/24 option name-server 192.168.1.1
set service dhcp-server shared-network-name LAN subnet 192.168.1.0/24 range 0 start 192.168.1.100
set service dhcp-server shared-network-name LAN subnet 192.168.1.0/24 range 0 stop 192.168.1.199
set service dns forwarding listen-address 192.168.1.1
set service dns forwarding allow-from 192.168.1.0/24
set nat source rule 100 outbound-interface name <wan>
set nat source rule 100 source address 192.168.1.0/24
set nat source rule 100 translation address masquerade
commit
save
exit
```

`show interfaces` lists the ports. See the
[VyOS documentation](https://docs.vyos.io) for everything else.

Forwarded traffic between the ports is offloaded to the hardware
automatically; `sudo cat /proc/ask_flowtable/status` shows the offloaded
flows (`entries`).

## Upgrade

Releases are published on this repository's
[Releases](https://github.com/we-are-mono/vyos/releases) page. A running
Gateway upgrades itself from there with VyOS's usual commands. Once, point it
at the release feed:

```
configure
set system update-check url https://github.com/we-are-mono/vyos/releases/latest/download/image-version.json
commit
save
exit
```

Then, to upgrade to the newest release:

```
add system image latest
reboot
```

`add system image` also takes the URL of a release's ISO, or a file. It asks
a few questions; the defaults keep your configuration. It warns that the image
has no signature (releases are not signed yet); answer yes to continue.

The new image becomes the default; the previous one stays installed. To go
back, or to clean up:

```
show system image
set system image default-boot <version>
delete system image <version>
```

U-Boot shows the installed images on the serial console for 3 seconds before
it boots the default. If a new image does not come up, reset the Gateway and
pick the previous one there.

Releases are built and published by GitHub Actions (maintainers):
`gh workflow run release.yml -f publish=true`, or the "Build (and release)"
workflow in the Actions tab. `./publish.sh` publishes a local full build the
same way.

## Known gaps

- **Do not run `install image` on the Gateway.** VyOS's installer wipes the
  disk and creates a PC-style layout starting at 1 MiB, over the eMMC boot
  firmware and the recovery system. The board then only boots from QSPI until
  `firmware update` restores the eMMC firmware. Flash the image as above
  instead.
- Wi-Fi is not built.
- The VyOS packages whose kernel modules are rebuilt (nat-rtsp, jool,
  ipt-netflow, accel-ppp) are fetched from VyOS's rolling repository by exact
  version; when VyOS publishes a newer one, `build-packages.sh` needs the new
  version and source revision.

## License

GPL-2.0-or-later (see `LICENSE`). The patches in `kernel/patches/` modify the
Linux kernel and are under its terms, GPL-2.0-only.
