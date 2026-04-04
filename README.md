## ISO Builder

This ISO builder is fork of the good work from the elementary crew.  Many thanks to the devs there https://github.com/elementary/os

## Building Locally

As Ubuntu Sway is built with the Debian version of live-build, not the Ubuntu patched version, it's easiest to build an Ubuntu Sway .iso in a Debian VM or container. This prevents messing up your host system too.

The following example uses Docker and assumes you have Docker correctly installed and set up:

Clone this project & cd into it:

    git clone https://github.com/Ubuntu-Sway/iso-builder && cd iso-builder

Configure the channel in the `options` (dev, stable).

To build image for `amd64` architecure:

    docker run --privileged -i -v /proc:/proc \
        -v ${PWD}:/working_dir \
        -w /working_dir \
        debian:trixie \
        ./build --arch amd64 --release stable
        
See `build --help` for available options.

Build Raspberry Pi image:

        docker run --privileged -i -v /proc:/proc \
        -v ${PWD}:/working_dir \
        -w /working_dir \
        ubuntu:24.04 \
        ./build-rpi


When done, your image will be in the `builds` folder. The Raspberry Pi images will be placed in `artifacts` folder.
