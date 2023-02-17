#!/bin/bash

set -e

# check for root permissions
if [[ "$(id -u)" != 0 ]]; then
  echo "E: Requires root permissions" > /dev/stderr
  exit 1
fi

# get config
if [ -n "$1" ]; then
  CONFIG_FILE="$1"
else
  CONFIG_FILE="etc/terraform.conf"
fi

BASE_DIR="$PWD"
TMP_DIR="$BASE_DIR/tmp"
BUILDS_DIR="$BASE_DIR/builds"
source "$BASE_DIR"/"$CONFIG_FILE"

echo -e "
#----------------------#
# INSTALL DEPENDENCIES #
#----------------------#
"

# Use system live-build if running on Debian
dist="$(lsb_release -i -s)"

if [ $dist == "Debian" ]; then
  apt-get install -y binutils zstd live-build
  dpkg -i ./debs/ubuntu-keyring*.deb
else
  apt-get install -y binutils zstd
  dpkg -i ./debs/*.deb
fi

ln -sfn /usr/share/debootstrap/scripts/gutsy /usr/share/debootstrap/scripts/lunar

build () {
  BUILD_ARCH="$1"

  if [ -d "$TMP_DIR" ]; then
    rm -rf $TMP_DIR
    mkdir -p "$TMP_DIR/$BUILD_ARCH"
  else
    mkdir -p "$TMP_DIR/$BUILD_ARCH"
  fi

  cd "$TMP_DIR/$BUILD_ARCH" || exit

  # remove old configs and copy over new
  rm -rf config auto
  cp -r "$BASE_DIR"/etc/* .
  # Make sure conffile specified as arg has correct name
  cp -f "$BASE_DIR"/"$CONFIG_FILE" terraform.conf

  # Symlink chosen package lists to where live-build will find them
  ln -s "package-lists.$PACKAGE_LISTS_SUFFIX" "config/package-lists"

  echo -e "
#------------------#
# LIVE-BUILD CLEAN #
#------------------#
"
  lb clean

  echo -e "
#-------------------#
# LIVE-BUILD CONFIG #
#-------------------#
"
  lb config

  echo -e "
#------------------#
# LIVE-BUILD BUILD #
#------------------#
"
  lb build

  echo -e "
#---------------------------#
# MOVE OUTPUT TO BUILDS DIR #
#---------------------------#
"

    YYYYMMDD="$(date +%Y%m%d%H%M)"
    OUTPUT_DIR="$BUILDS_DIR/$BUILD_ARCH"
    mkdir -p "$OUTPUT_DIR"
    if [ "$CHANNEL" == dev ]; then
      FNAME="ubuntusway-$VERSION-$CHANNEL-$YYYYMMDD-$OUTPUT_SUFFIX-$ARCH"
    elif [ "$CHANNEL" == stable ]; then
      FNAME="ubuntusway-$VERSION-$OUTPUT_SUFFIX-$ARCH"
    else
      echo -e "Error: invalid channel name!"
    fi
    mv "$TMP_DIR/$BUILD_ARCH/live-image-$BUILD_ARCH.hybrid.iso" "$OUTPUT_DIR/${FNAME}.iso"

    md5sum "$OUTPUT_DIR/${FNAME}.iso" > "$OUTPUT_DIR/${FNAME}.md5.txt"
    sha256sum "$OUTPUT_DIR/${FNAME}.iso" > "$OUTPUT_DIR/${FNAME}.sha256.txt"
}

# remove old builds before creating new ones
rm -rf "$BUILDS_DIR"

build "$ARCH"

