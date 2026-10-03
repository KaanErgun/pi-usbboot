#!/usr/bin/env bash
# Build the bundled rpiboot from pinned source; requires a C toolchain, curl,
# tar, make, xxd, pkg-config, and Python 3. macOS also requires Xcode tools.
# The rpiboot source and libusb source below are distributed beside our release
# so recipients can modify libusb and rebuild/relink this separate executable.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
runtime=${RUNTIME_DIR:-"$root/src-tauri/resources/runtime"}
cache=${RPIBOOT_CACHE:-"$root/.cache/rpiboot"}
sources=${RPIBOOT_SOURCES_DIR:-"$root/release/v0.3.1/sources"}
revision=12fa1cdbbeab880f7c8e7e797c4ef2831c9f784e
usb_version=1.0.29
# Pin the hardware-tested gadget independently of the host binary and legacy MSD.
gadget_revision=fe4a6288878b104ceb232ab4b8a777be6ac98ff3
buildroot_revision=93c97919253c7a2caa12373b06a7d035b95e1b1d
mkdir -p "$cache" "$sources" "$runtime/bin" "$runtime/share/rpiboot" "$runtime/licenses"
fetch() {
  local url=$1 file=$2 sha=$3
  if [ ! -f "$file" ]; then curl --fail --location --retry 3 "$url" -o "$file"; fi
  python3 - "$file" "$sha" <<'PY'
import hashlib, sys
with open(sys.argv[1], 'rb') as f:
    actual = hashlib.file_digest(f, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hashlib.sha256(f.read()).hexdigest()
if actual != sys.argv[2]:
    raise SystemExit('Source archive checksum mismatch: ' + sys.argv[1])
PY
}
usb_archive="$cache/libusb-$usb_version.tar.bz2"
rpi_archive="$cache/usbboot-$revision.tar.gz"
fetch "https://github.com/libusb/libusb/releases/download/v$usb_version/libusb-$usb_version.tar.bz2" "$usb_archive" 5977fc950f8d1395ccea9bd48c06b3f808fd3c2c961b44b0c2e6e29fc3a70a85
fetch "https://codeload.github.com/raspberrypi/usbboot/tar.gz/$revision" "$rpi_archive" 1539610b0850b829b5caa92391412de7478cc8951a1b23cb3ad35c56bd302250
buildroot_archive="$cache/buildroot-$buildroot_revision.tar.gz"
fetch "https://codeload.github.com/raspberrypi/buildroot/tar.gz/$buildroot_revision" "$buildroot_archive" c77157b0a54596292eb7e25116207d70ee31de5d6aa2adbf0187304888e29395
fetch "https://raw.githubusercontent.com/raspberrypi/firmware/dcca4969e53d2a25e688f0f228a09486786d54c0/boot/LICENCE.broadcom" "$cache/LICENCE.broadcom" c7283ff51f863d93a275c66e3b4cb08021a5dd4d8c1e7acc47d872fbe52d3d6b
# These package notices were collected by Buildroot legal-info at the pinned
# revision above; the separate gadget source asset includes the full sources.
gadget_notices="$cache/Pi-USB-Boot_0.3.1_gadget-notices.tar.gz"
fetch "https://github.com/KaanErgun/pi-usbboot/releases/download/v0.3.1/Pi-USB-Boot_0.3.1_gadget-notices.tar.gz" "$gadget_notices" 000250e0fc404c1f6da370eda6a7cee7ac4d3f5569dc4b146a2786fd2c6efdea
tar -xzf "$gadget_notices" -C "$runtime/licenses"
[ -d "$cache/libusb-$usb_version" ] || tar -xf "$usb_archive" -C "$cache"
[ -d "$cache/usbboot-$revision" ] || tar -xf "$rpi_archive" -C "$cache"
[ -d "$cache/buildroot-$buildroot_revision" ] || tar -xf "$buildroot_archive" -C "$cache"
usb_source="$cache/libusb-$usb_version"
rpi_source="$cache/usbboot-$revision"
cp "$usb_archive" "$rpi_archive" "$buildroot_archive" "$sources/"
cp "$0" "$sources/prepare-rpiboot.sh"
cp "$usb_source/COPYING" "$runtime/licenses/libusb-LGPL-2.1.txt"
cp "$usb_source/AUTHORS" "$runtime/licenses/libusb-AUTHORS.txt"
cp "$rpi_source/LICENSE" "$runtime/licenses/rpiboot-Apache-2.0.txt"
cp "$cache/LICENCE.broadcom" "$runtime/licenses/raspberrypi-firmware-LICENCE.broadcom"
cp "$cache/buildroot-$buildroot_revision/COPYING" "$runtime/licenses/Buildroot-COPYING.txt"
gadget_source="$cache/gadget-$gadget_revision"
mkdir -p "$gadget_source"
gadget_url="https://raw.githubusercontent.com/raspberrypi/usbboot/$gadget_revision/mass-storage-gadget64"
fetch "$gadget_url/boot.img" "$gadget_source/boot.img" ba98c962eb41270379681f78c97907890a791f281ff84bd0b98ea0fcf7fc441e
fetch "$gadget_url/bootfiles.bin" "$gadget_source/bootfiles.bin" 344c6a2c6a9109e0d041f58bd1a65f839c4f30d8bbe6a73eabd8e894772805ad
fetch "$gadget_url/config.txt" "$gadget_source/config.txt" f74a9db07cd32f418e25754134840b138486e39cda2a4e536042b86c5c67b687
fetch "$gadget_url/README.md" "$gadget_source/README.md" 27bd79bbe6002581f7d7f23478f42b139ece2c323f39dc689e9864bfe5886791
cp "$gadget_source/README.md" "$runtime/licenses/mass-storage-gadget-README.md"
for payload in msd mass-storage-gadget64; do mkdir -p "$runtime/share/rpiboot/$payload"; done
cp "$rpi_source/msd/bootcode.bin" "$rpi_source/msd/start.elf" "$runtime/share/rpiboot/msd/"
cp "$gadget_source/boot.img" "$gadget_source/bootfiles.bin" "$gadget_source/config.txt" "$runtime/share/rpiboot/mass-storage-gadget64/"
(
  cd "$rpi_source"
  xxd -i msd/bootcode.bin > msd/bootcode.h
  xxd -i msd/start.elf > msd/start.h
)
build_one() {
  local arch=$1 build="$cache/build-$1" cc=${CC:-cc}
  mkdir -p "$build"
  (
    cd "$build"
    if [ "$(uname -s)" = Darwin ]; then
      export CC=clang CFLAGS="-O2 -arch $arch -mmacosx-version-min=11.0" LDFLAGS="-arch $arch -mmacosx-version-min=11.0"
      "$usb_source/configure" --host="$arch-apple-darwin" --disable-shared --enable-static --disable-examples-build --disable-tests-build > configure.log 2>&1
    else
      export CFLAGS=-O2
      "$usb_source/configure" --disable-shared --enable-static --disable-udev --disable-examples-build --disable-tests-build > configure.log 2>&1
    fi
    make -j4 > build.log 2>&1
  )
  local flags=() libs=()
  if [ "$(uname -s)" = Darwin ]; then
    cc=clang
    flags=(-arch "$arch" -mmacosx-version-min=11.0)
    libs=(-lobjc -framework IOKit -framework CoreFoundation -framework Security)
  else
    libs=(-pthread)
  fi
  "$cc" "${flags[@]}" -O2 -I"$usb_source/libusb" \
    "$rpi_source/main.c" "$rpi_source/bootfiles.c" "$rpi_source/decode_duid.c" \
    "$build/libusb/.libs/libusb-1.0.a" "${libs[@]}" \
    '-DBUILD_DATE="2026/10/03"' "-DGIT_VER=\"$revision\"" '-DPKG_VER="pi-usbboot-bundled"' \
    '-DDEFAULT_MSG_DIR="/nonexistent/pi-usbboot/explicit-directory-required/"' \
    -o "$build/rpiboot"
}
case "$(uname -s)" in
  Darwin)
    build_one arm64
    build_one x86_64
    lipo -create "$cache/build-arm64/rpiboot" "$cache/build-x86_64/rpiboot" -output "$runtime/bin/rpiboot"
    otool -L "$runtime/bin/rpiboot"
    ;;
  Linux)
    [ "$(uname -m)" = x86_64 ] || { echo 'Only Linux x86_64 is currently packaged.' >&2; exit 1; }
    build_one x86_64-linux
    cp "$cache/build-x86_64-linux/rpiboot" "$runtime/bin/rpiboot"
    ldd "$runtime/bin/rpiboot"
    ;;
  *) echo 'Unsupported build host' >&2; exit 1 ;;
esac
chmod 755 "$runtime/bin/rpiboot"
"$runtime/bin/rpiboot" -V
cat > "$runtime/licenses/rpiboot-NOTICE.txt" <<NOTICE
Pi USB Boot bundles unmodified Raspberry Pi rpiboot source revision $revision
(Apache-2.0) and libusb $usb_version (LGPL-2.1-or-later), statically linked in
the separate rpiboot executable. Both complete source archives and this build
script accompany the release under sources. Recipients may modify libusb,
rebuild/relink rpiboot, and replace runtime/bin/rpiboot for their own use.
On macOS re-sign the modified executable and containing app ad-hoc as needed.

Legacy Raspberry Pi firmware is supplied unchanged from usbboot $revision.
The modern mass-storage-gadget is pinned separately to unchanged files from
usbboot $gadget_revision. Its boot.img contains third-party GPL software;
source locations and provenance limits are recorded in the accompanying
source manifest and upstream README.
NOTICE
cat > "$runtime/licenses/gadget-SOURCE-PROVENANCE.txt" <<NOTICE
The unmodified mass-storage-gadget64 boot files come from raspberrypi/usbboot
revision $gadget_revision, independently of the bundled rpiboot host binary.
Immutable source: https://github.com/raspberrypi/usbboot/tree/$gadget_revision/mass-storage-gadget64
SHA256:
  boot.img      ba98c962eb41270379681f78c97907890a791f281ff84bd0b98ea0fcf7fc441e
  bootfiles.bin 344c6a2c6a9109e0d041f58bd1a65f839c4f30d8bbe6a73eabd8e894772805ad
  config.txt    f74a9db07cd32f418e25754134840b138486e39cda2a4e536042b86c5c67b687

The embedded kernel is Linux 6.12.49-v8, built 2025-10-02 12:01:23 BST.
Its compiler banner identifies Buildroot 2024.11.3-23-gca9f386ae8.
The root filesystem's /usr/lib/os-release identifies the separate, later
Buildroot 2024.11.3-24-g93c9791925 revision used for the root filesystem.
Buildroot source: https://github.com/raspberrypi/buildroot/tree/$buildroot_revision
Configuration: configs/raspberrypi64-mass-storage-gadget_defconfig

That configuration tracks the floating kernel branch rpi-6.12.y. The source
collection pins 2f4a28199c418599ba0224186e42926b482b523c, the latest upstream
branch commit before the embedded kernel build timestamp. This kernel revision
is inferred from publication time, not recorded in the binary; it is not an
assertion of bit-for-bit gadget reproducibility.
Kernel source: https://github.com/raspberrypi/linux/tree/2f4a28199c418599ba0224186e42926b482b523c

The matching gadget source collection includes this Buildroot configuration,
package sources, and legal-info notices. The Buildroot archive alone is not
the corresponding source of every package in boot.img. Sources and notices for
the different Linux 6.18.54 gadget shipped in 0.3.0 do not describe this image.

NOTICE
cp "$runtime/licenses/gadget-SOURCE-PROVENANCE.txt" "$sources/"
printf 'Prepared rpiboot runtime: %s\n' "$runtime"
