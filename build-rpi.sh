#!/bin/bash

set -e

# Install dependencies in host system
echo -e "
#----------------------#
# INSTALL DEPENDENCIES #
#----------------------#
"

apt-get update
apt-get install -y --no-install-recommends \
debian-keyring ca-certificates debootstrap git \
qemu-user-static qemu-utils qemu-system-arm binfmt-support \
parted kpartx rsync dosfstools xz-utils whois

# Make sure cross-running ARM ELF executables is enabled
update-binfmts --enable

rootdir=$(pwd)
basedir=$(pwd)/artifacts/ubuntusway-rpi

export packages="ubuntu-sway-minimal ubuntu-sway-desktop-raspi ubuntu-sway-standard"
export architecture="arm64"
export codename="noble"
export channel="dev"

version=24.04
YYYYMMDD="$(date +%Y%m%d)"
imagename=ubuntusway-$version-$channel-rpi-$YYYYMMDD

# Remove old builds before creating new one
echo -e "
#----------------------#
# REMOVE OLD BUILDS    #
#----------------------#
"

if [ -d $rootdir/artifacts ]; then
	rm -rf $rootdir/artifacts
fi

# Bootstrap an ubuntu minimal system
echo -e "
#----------------------#
# BOOTSTRAP BASE SYSTEM #
#----------------------#
"

mkdir -p "${basedir}"
cd "${basedir}"

# Enable Noble build in debootstrap
ln -sfn /usr/share/debootstrap/scripts/gutsy /usr/share/debootstrap/scripts/noble

debootstrap \
    --arch $architecture \
    --components=main,restricted,universe,multiverse \
    --foreign \
    --include=cloud-guest-utils \
    $codename ubuntusway-$architecture http://ports.ubuntu.com/ubuntu-ports

# Add the QEMU emulator for running ARM executables
cp /usr/bin/qemu-arm-static ubuntusway-$architecture/usr/bin/

# Run the second stage of the bootstrap in QEMU
LANG=C.UTF-8 chroot ubuntusway-$architecture /debootstrap/debootstrap --second-stage

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
LABEL=writable     /               ext4  discard,noatime,x-systemd.growfs     0  1
LABEL=system-boot  /boot/firmware  vfat  defaults                             0  1
EOF

export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive
# Config to stop flash-kernel trying to detect the hardware in chroot
export FK_MACHINE=none

mount -t proc proc ubuntusway-$architecture/proc
mount -o bind /dev/ ubuntusway-$architecture/dev/
mount -o bind /dev/pts ubuntusway-$architecture/dev/pts

# Make a desktop stage that installs all of the metapackages
echo -e "
#--------------------------#
# INSTALL DESKTOP PACKAGES #
#--------------------------#
"

cat << EOF > ubuntusway-$architecture/desktop
#!/bin/bash
apt-get update
apt-get -y upgrade
apt-get -y install $packages
rm -f /desktop
EOF

chmod +x ubuntusway-$architecture/desktop
LANG=C.UTF-8 chroot ubuntusway-$architecture /desktop

# Install Raspberry Pi specific packages
echo -e "
#----------------------------------------#
# INSTALL RASPBERRY PI SPECIFIC PACKAGES #
#----------------------------------------#
"

cat << EOF > ubuntusway-$architecture/hardware
#!/bin/bash
apt-get -y install linux-image-raspi linux-firmware-raspi \
pi-bluetooth upower \
calamares-settings-ubuntu-sway-raspi
apt-get -y install --no-install-recommends raspi-config
systemctl disable raspi-config
rm -f hardware
EOF

chmod +x ubuntusway-$architecture/hardware
LANG=C.UTF-8 chroot ubuntusway-$architecture /hardware

# Copy in any file overrides
cp -rv "${rootdir}"/etc/config/includes.chroot/etc/apt/ ubuntusway-$architecture/etc/
cp -rv "${rootdir}"/etc/config/includes.chroot/etc/netplan/ ubuntusway-$architecture/etc/
cp -rv "${rootdir}"/etc/config/includes.chroot/usr ubuntusway-$architecture/
cp -rv "${rootdir}"/rpi/greetd/* ubuntusway-${architecture}/etc/greetd/

echo -e "
#----------------------#
# RUNNING HOOKS        #
#----------------------#
"

mkdir ubuntusway-$architecture/hooks
cp -v "${rootdir}"/etc/config/hooks/live/*.chroot ubuntusway-$architecture/hooks

hook_files="ubuntusway-$architecture/hooks/*"
for f in $hook_files
do
    base=$(basename "${f}")
    LANG=C.UTF-8 chroot ubuntusway-$architecture "/hooks/${base}"
done

rm -r "ubuntusway-$architecture/hooks"

# Create OEM user
echo -e "
#----------------------#
# CREATING OEM USER    #
#----------------------#
"

cat <<EOF >> ubuntusway-$architecture/user
#!/bin/bash
DATE=$(date +%m%H%M%S)
PASSWD=$(mkpasswd -m sha-512 oem "${DATE}")
addgroup --gid 29999 oem
adduser --gecos "OEM Configuration (temporary user)" --add_extra_groups --disabled-password --gid 29999 --uid 29999 oem
usermod -a -G adm,sudo -p "${PASSWD}" oem
rm -f user
EOF

chmod +x ubuntusway-$architecture/user
LANG=C.UTF-8 chroot ubuntusway-$architecture /user

# Creating swapfile service
echo -e "
#----------------------#
# CREATING SWAPFILE    #
#----------------------#
"

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
update-initramfs -u
rm -f enable_zswap
EOF

chmod +x ubuntusway-$architecture/enable_zswap
LANG=C.UTF-8 chroot ubuntusway-$architecture /enable_zswap

# Cleanup chroot before creating .img
echo -e "
#----------------------#
# CLEANING CHROOT      #
#----------------------#
"

cat <<EOF >> ubuntusway-$architecture/cleanup
#!/bin/bash

apt-get -y autoremove
apt-get -y autoclean
apt-get -y clean

rm -rf {*.bak,*.old}
rm -rf wget-log
rm -rf /boot/{*.bak,*.old}
rm -rf /etc/ssh/ssh_host_*_key*
rm -rf /etc/apt/*.save
rm -rf /etc/apt/apt.conf.d/90cache
rm -rf /etc/apt/sources.list.d/*.save
rm -rf /root/.wget-hsts
rm -rf /tmp/*
rm -rf /var/log/apt/*
rm -rf /var/log/alternatives.log
rm -rf /var/log/bootstrap.log
rm -rf /var/log/dpkg.log
rm -rf /var/log/fontconfig.log
rm -rf /var/cache/fontconfig/CACHEDIR.TAG
rm -rf /var/crash/*
rm -rf /var/lib/apt/lists/*
rm -rf /var/lib/dpkg/*-old

[ -L /var/lib/dbus/machine-id ] || rm -f /var/lib/dbus/machine-id
echo '' > /etc/machine-id

rm -f cleanup
EOF

chmod +x ubuntusway-$architecture/cleanup
LANG=C.UTF-8 chroot ubuntusway-$architecture /cleanup

echo -e "
#----------------------#
# CREATING IMAGE FILE  #
#----------------------#
"

# Calculate image size accounting for boot parition + 5%
boot_size="256"
root_size="$(du -cs --block-size=MB ubuntusway-$architecture | tail -n1 | cut -d'M' -f1)"
pad_size="$(( (root_size / 10) / 2 ))"
raw_size="$((boot_size + root_size + pad_size))"

# Create the disk and partition it
fallocate -l "${raw_size}"M "${basedir}/${imagename}.img"

parted "${imagename}.img" -s -- mklabel msdos
parted "${imagename}.img" -s -a optimal -- mkpart primary fat32 1 "${boot_size}MB"
parted "${imagename}.img" -s -a optimal -- mkpart primary ext4 "${boot_size}MB" 100%
parted "${imagename}.img" -s set 1 boot on

# Set the partition variables
loopdevice=$(losetup -f --show "${basedir}/${imagename}.img")
device=$(kpartx -va "$loopdevice" | sed -E 's/.*(loop[0-9])p.*/\1/g' | head -1)
device="/dev/mapper/${device}"
bootp=${device}p1
rootp=${device}p2

# Create file systems
mkfs.vfat -n system-boot -S 512 -s 16 -v "$bootp"
mkfs.ext4 -L writable -m 0 "$rootp"

# Create the dirs for the partitions and mount them
mkdir -p "${basedir}/bootp" "${basedir}/root"
mount -t vfat "$bootp" "${basedir}/bootp"
mount "$rootp" "${basedir}/root"

mkdir -p ubuntusway-$architecture/boot/firmware
mount -o bind "${basedir}/bootp/" ubuntusway-$architecture/boot/firmware

# Copy Raspberry Pi specific files
cp -rv "${rootdir}"/rpi/rootfs/system-boot/* ubuntusway-${architecture}/boot/firmware/

NEW_KERNEL=$(find ubuntusway-$architecture/boot/vmlinuz-* | tail -n1 | awk -F/ '{print $NF}' | cut -d'-' -f2-4)
    if [ -z "${NEW_KERNEL}" ]; then
        echo "ERROR! Could not detect the new kernel version"
        exit 1
    fi
echo "Kernel: ${NEW_KERNEL}"

# Copy kernels and firmware to boot partition
cat << EOF > ubuntusway-$architecture/hardware
#!/bin/bash
cp -av /boot/vmlinuz-${NEW_KERNEL} /boot/firmware/vmlinuz
cp -av /boot/initrd.img-${NEW_KERNEL} /boot/firmware/initrd.img
# Copy device-tree blobs to fat32 partition
cp -v /lib/firmware/${NEW_KERNEL}/device-tree/broadcom/* /boot/firmware/
cp -rv /lib/firmware/${NEW_KERNEL}/device-tree/overlays /boot/firmware/
cp -v /lib/linux-firmware-raspi/* /boot/firmware/
rm -f hardware
EOF

chmod +x ubuntusway-$architecture/hardware
LANG=C.UTF-8 chroot ubuntusway-$architecture /hardware

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

echo -e "
#----------------------#
# BUILD DONE           #
#----------------------#
"
