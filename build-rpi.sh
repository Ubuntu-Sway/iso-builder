#!/bin/bash

set -e

# Install dependencies in host system
apt-get update
apt-get install -y --no-install-recommends ubuntu-keyring ca-certificates debootstrap git qemu-user-static qemu-utils qemu-system-arm binfmt-support parted kpartx rsync dosfstools xz-utils

# Make sure cross-running ARM ELF executables is enabled
update-binfmts --enable

rootdir=$(pwd)
basedir=$(pwd)/artifacts/ubuntusway-rpi

# Free space on rootfs in MiB
free_space="500"

export packages="ubuntusway-minimal ubuntusway-desktop ubuntusway-standard"
export architecture="arm64"
export codename="jammy"
export channel="dev"

version=22.04
YYYYMMDD="$(date +%Y%m%d)"
imagename=ubuntusway-$version-$channel-rpi-$YYYYMMDD

mkdir -p "${basedir}"
cd "${basedir}"

# Bootstrap an ubuntu minimal system
debootstrap --foreign --arch $architecture $codename ubuntusway-$architecture http://ports.ubuntu.com/ubuntu-ports

# Add the QEMU emulator for running ARM executables
cp /usr/bin/qemu-arm-static ubuntusway-$architecture/usr/bin/

# Run the second stage of the bootstrap in QEMU
LANG=C chroot ubuntusway-$architecture /debootstrap/debootstrap --second-stage

# Copy Raspberry Pi specific files
cp -r "${rootdir}"/rpi/rootfs/writable/* ubuntusway-${architecture}/

# Add the rest of the ubuntu repos
cat << EOF > ubuntusway-$architecture/etc/apt/sources.list
deb http://ports.ubuntu.com/ubuntu-ports $codename main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports $codename-updates main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports $codename-security main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports $codename-backports main restricted universe multiverse
EOF

# Copy in the ubuntusway PPAs/keys/apt config
for f in "${rootdir}"/etc/config/archives/*.list; do cp -- "$f" "ubuntusway-$architecture/etc/apt/sources.list.d/$(basename -- "$f")"; done
for f in "${rootdir}"/etc/config/archives/*.key; do cp -- "$f" "ubuntusway-$architecture/etc/apt/trusted.gpg.d/$(basename -- "$f").asc"; done
for f in "${rootdir}"/etc/config/archives/*.pref; do cp -- "$f" "ubuntusway-$architecture/etc/apt/preferences.d/$(basename -- "$f")"; done

# Set codename/channel in added repos
sed -i "s/@CHANNEL/$channel/" ubuntusway-$architecture/etc/apt/sources.list.d/*.list*
sed -i "s/@BASECODENAME/$codename/" ubuntusway-$architecture/etc/apt/sources.list.d/*.list*

# Set codename in added preferences
sed -i "s/@BASECODENAME/$codename/" ubuntusway-$architecture/etc/apt/preferences.d/*.pref*

echo "ubuntusway" > ubuntusway-$architecture/etc/hostname

cat << EOF > ubuntusway-${architecture}/etc/hosts
127.0.0.1       ubuntusway    localhost
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

# Configure mount points
cat << EOF > ubuntusway-${architecture}/etc/fstab
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
proc               /proc           proc  nodev,noexec,nosuid 0  0
LABEL=writable     /               ext4  discard,noatime     0  1
LABEL=system-boot  /boot/firmware  vfat  defaults            0  1
EOF

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
# Config to stop flash-kernel trying to detect the hardware in chroot
export FK_MACHINE=none

mount -t proc proc ubuntusway-$architecture/proc
mount -o bind /dev/ ubuntusway-$architecture/dev/
mount -o bind /dev/pts ubuntusway-$architecture/dev/pts

# Make a third stage that installs all of the metapackages
cat << EOF > ubuntusway-$architecture/third-stage
#!/bin/bash
apt-get update
apt-get --yes upgrade
apt-get --yes install $packages
rm -f /third-stage
EOF

chmod +x ubuntusway-$architecture/third-stage
LANG=C chroot ubuntusway-$architecture /third-stage


# Install Raspberry Pi specific packages
cat << EOF > ubuntusway-$architecture/hardware
#!/bin/bash
# Make a dummy folder for the boot partition so packages install properly,
# we'll recreate it on the actual partition later
mkdir -p /boot/firmware
apt-get --yes install linux-image-raspi linux-firmware-raspi linux-modules-extra-raspi \
pi-bluetooth rpi-eeprom libraspberrypi0 libraspberrypi-bin
# Symlink to workaround bug with Bluetooth driver looking in the wrong place for firmware
ln -s /lib/firmware /etc/firmware
rm -rf /boot/firmware
rm -f hardware
EOF

chmod +x ubuntusway-$architecture/hardware
LANG=C chroot ubuntusway-$architecture /hardware

# Copy in any file overrides
cp -r "${rootdir}"/etc/config/includes.chroot/* ubuntusway-$architecture/

mkdir ubuntusway-$architecture/hooks
cp "${rootdir}"/etc/config/hooks/live/*.chroot ubuntusway-$architecture/hooks

hook_files="ubuntusway-$architecture/hooks/*"
for f in $hook_files
do
    base=$(basename "${f}")
    LANG=C chroot ubuntusway-$architecture "/hooks/${base}"
done

rm -r "ubuntusway-$architecture/hooks"

# Add a oneshot service to grow the rootfs on first boot
install -m 755 -o root -g root "${rootdir}/rpi/files/resizerootfs" "ubuntusway-$architecture/usr/sbin/resizerootfs"
install -m 644 -o root -g root "${rootdir}/rpi/files/resizerootfs.service" "ubuntusway-$architecture/etc/systemd/system"
mkdir -p "ubuntusway-$architecture/etc/systemd/system/systemd-remount-fs.service.requires/"
ln -s /etc/systemd/system/resizerootfs.service "ubuntusway-$architecture/etc/systemd/system/systemd-remount-fs.service.requires/resizerootfs.service"


# Support for kernel updates on the Pi 400
cat << EOF >> ubuntusway-$architecture/etc/flash-kernel/db
Machine: Raspberry Pi 400 Rev 1.0
Method: pi
Kernel-Flavors: raspi raspi2
DTB-Id: bcm2711-rpi-4-b.dtb
U-Boot-Script-Name: bootscr.rpi
Required-Packages: u-boot-tools
EOF

# Create default user (WARNING! This is a temporary solution, until postinstall user setup is created)
cat <<EOF >> ubuntusway-$architecture/user
#!/bin/bash
adduser --disabled-password --gecos "" ubuntu
echo "ubuntu:ubuntusway" | chpasswd
usermod -a -G adm,dialout,cdrom,sudo,audio,video,plugdev,games,users,input,netdev ubuntu
rm -f user
EOF

chmod +x ubuntusway-$architecture/user
LANG=C chroot ubuntusway-$architecture /user

# Creating swapfile service

# Adds lz4 and z3fold modules to initramfs.
# - https://ubuntu.com/blog/how-low-can-you-go-running-ubuntu-desktop-on-a-2gb-raspberry-pi-4
echo lz4    >> ubuntusway-$architecture/etc/initramfs-tools/modules
echo z3fold >> ubuntusway-$architecture/etc/initramfs-tools/modules

mkdir -p ubuntusway-$architecture/usr/lib/systemd/system/swap.target.wants

cat <<EOF >> ubuntusway-$architecture/usr/lib/systemd/system/mkswap.service
[Unit]
Description=Create the default swapfile
DefaultDependencies=no
Requires=local-fs.target
After=local-fs.target
Before=swapfile.swap
ConditionPathExists=!/swapfile

[Service]
Type=oneshot
ExecStartPre=fallocate -l 1GiB /swapfile
ExecStartPre=chmod 600 /swapfile
ExecStart=mkswap /swapfile

[Install]
WantedBy=swap.target
EOF

cat <<EOF >> ubuntusway-$architecture/usr/lib/systemd/system/swapfile.swap
[Unit]
Description=The default swapfile

[Swap]
What=/swapfile
EOF

cat <<EOF >> ubuntusway-$architecture/enable_zswap
#!/bin/bash
ln -s /usr/lib/systemd/system/mkswap.service /usr/lib/systemd/system/swap.target.wants/mkswap.service
ln -s /usr/lib/systemd/system/swapfile.swap /usr/lib/systemd/system/swap.target.wants/swapfile.swap
rm -f enable_zswap
EOF

chmod +x ubuntusway-$architecture/enable_zswap
LANG=C chroot ubuntusway-$architecture /enable_zswap

# Calculate the space to create the image.
root_size="$(du -s -B1K ubuntusway-$architecture | cut -f1)"
raw_size="$(($((free_space*1024))+root_size))"

# Create the disk and partition it
echo "Creating image file"

# Sometimes fallocate fails if the filesystem or location doesn't support it, fallback to slower dd in this case
if ! fallocate -l "$(echo ${raw_size}Ki | numfmt --from=iec-i --to=si --format=%.1f)" "${basedir}/${imagename}.img"
then
    dd if=/dev/zero of="${basedir}/${imagename}.img" bs=1024 count=${raw_size}
fi

parted "${imagename}.img" --script -- mklabel msdos
parted "${imagename}.img" --script -- mkpart primary fat32 0 256
parted "${imagename}.img" --script -- mkpart primary ext4 256 -1

# Set the partition variables
loopdevice=$(losetup -f --show "${basedir}/${imagename}.img")
device=$(kpartx -va "$loopdevice" | sed -E 's/.*(loop[0-9])p.*/\1/g' | head -1)
device="/dev/mapper/${device}"
bootp=${device}p1
rootp=${device}p2

# Create file systems
mkfs.vfat -n system-boot "$bootp"
mkfs.ext4 -L writable "$rootp"

# Create the dirs for the partitions and mount them
mkdir -p "${basedir}/bootp" "${basedir}/root"
mount -t vfat "$bootp" "${basedir}/bootp"
mount "$rootp" "${basedir}/root"

mkdir -p ubuntusway-$architecture/boot/firmware
mount -o bind "${basedir}/bootp/" ubuntusway-$architecture/boot/firmware

# Copy Raspberry Pi specific files
cp -r "${rootdir}"/rpi/rootfs/system-boot/* ubuntusway-${architecture}/boot/firmware/

# Copy kernels and firmware to boot partition
cat << EOF > ubuntusway-$architecture/hardware
#!/bin/bash
cp /boot/vmlinuz /boot/firmware/vmlinuz
cp /boot/initrd.img /boot/firmware/initrd.img
# Copy device-tree blobs to fat32 partition
cp -r /lib/firmware/*-raspi/device-tree/broadcom/* /boot/firmware/
cp -r /lib/firmware/*-raspi/device-tree/overlays /boot/firmware/
rm -f hardware
EOF

chmod +x ubuntusway-$architecture/hardware
LANG=C chroot ubuntusway-$architecture /hardware

# Grab some updated firmware from the Raspberry Pi foundation
git clone -b '1.20220331' --single-branch --depth 1 https://github.com/raspberrypi/firmware raspi-firmware
cp raspi-firmware/boot/*.elf "${basedir}/bootp/"
cp raspi-firmware/boot/*.dat "${basedir}/bootp/"
cp raspi-firmware/boot/bootcode.bin "${basedir}/bootp/"

umount ubuntusway-$architecture/dev/pts
umount ubuntusway-$architecture/dev/
umount ubuntusway-$architecture/proc
umount ubuntusway-$architecture/boot/firmware

echo "Rsyncing rootfs into image file"
rsync -HPavz -q "${basedir}/ubuntusway-$architecture/" "${basedir}/root/"

# Unmount partitions
umount "$bootp"
umount "$rootp"
kpartx -dv "$loopdevice"
losetup -d "$loopdevice"

echo "Compressing ${imagename}.img"
xz -T0 -z "${basedir}/${imagename}.img"

cd "${basedir}"

md5sum "${imagename}.img.xz" | tee "${imagename}.md5.txt"
sha256sum "${imagename}.img.xz" | tee "${imagename}.sha256.txt"