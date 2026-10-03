#!/usr/bin/env bash
# Build the bundled rpiboot from pinned source; requires a C toolchain, curl,
# tar, make, xxd, pkg-config, and Python 3. macOS also requires Xcode tools.
# The rpiboot source and libusb source below are distributed beside our release
# so recipients can modify libusb and rebuild/relink this separate executable.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
runtime=${RUNTIME_DIR:-"$root/src-tauri/resources/runtime"}
cache=${RPIBOOT_CACHE:-"$root/.cache/rpiboot"}
sources=${RPIBOOT_SOURCES_DIR:-"$root/release/v0.3.0/sources"}
revision=12fa1cdbbeab880f7c8e7e797c4ef2831c9f784e
usb_version=1.0.29
buildroot_revision=37b2275c53e30531dbb1840ae498d755b010cc0c
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
fetch "https://codeload.github.com/raspberrypi/buildroot/tar.gz/$buildroot_revision" "$buildroot_archive" 0e5cfabeb76af56ecf6397a498356ad9e2ac7ec4c2652b706b7f1fb059bb4a11
fetch "https://raw.githubusercontent.com/raspberrypi/firmware/dcca4969e53d2a25e688f0f228a09486786d54c0/boot/LICENCE.broadcom" "$cache/LICENCE.broadcom" c7283ff51f863d93a275c66e3b4cb08021a5dd4d8c1e7acc47d872fbe52d3d6b
# These package notices were collected by Buildroot legal-info at the pinned
# revision above; the separate gadget source asset includes the full sources.
gadget_notices="$cache/Pi-USB-Boot_0.3.0_gadget-notices.tar.gz"
fetch "https://github.com/KaanErgun/pi-usbboot/releases/download/v0.3.0/Pi-USB-Boot_0.3.0_gadget-notices.tar.gz" "$gadget_notices" dba5079bcbaa634850344778fa2af4055fd23738b48fc0322e0de3e69f3ff38a
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
cp "$rpi_source/mass-storage-gadget64/README.md" "$runtime/licenses/mass-storage-gadget-README.md"
for payload in msd mass-storage-gadget64; do mkdir -p "$runtime/share/rpiboot/$payload"; done
cp "$rpi_source/msd/bootcode.bin" "$rpi_source/msd/start.elf" "$runtime/share/rpiboot/msd/"
cp -L "$rpi_source/mass-storage-gadget64/boot.img" "$rpi_source/mass-storage-gadget64/bootfiles.bin" "$rpi_source/mass-storage-gadget64/config.txt" "$runtime/share/rpiboot/mass-storage-gadget64/"
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

Legacy Raspberry Pi firmware and the modern mass-storage-gadget are supplied
unchanged from the same upstream usbboot revision. The modern boot.img also
contains third-party GPL software; its source and license information is listed
in the accompanying gadget source manifest and upstream README.
NOTICE
cat > "$runtime/licenses/gadget-SOURCE-PROVENANCE.txt" <<NOTICE
The unmodified mass-storage-gadget64/boot.img is from raspberrypi/usbboot
revision $revision. Its embedded kernel banner identifies Linux 6.18.54-v8,
built 2026-10-02 09:51:24 BST using Buildroot 2024.11.3-29-g37b2275c53.
The embedded /usr/lib/os-release independently identifies that Buildroot version.
Buildroot source: https://github.com/raspberrypi/buildroot/tree/$buildroot_revision
Configuration: configs/raspberrypi64-mass-storage-gadget_defconfig

The upstream configuration tracks the floating kernel branch rpi-6.18.y.
For source collection, kernel revision 8946ad8626ecacee8a8a9cffa433a23f0b118dcd
is the latest upstream branch commit before the embedded build timestamp.
That kernel revision is inferred from publication time, not recorded in the
binary, so this manifest does not assert a bit-for-bit reproducible gadget.
Kernel source: https://github.com/raspberrypi/linux/tree/8946ad8626ecacee8a8a9cffa433a23f0b118dcd

The release's gadget source collection includes Buildroot configuration,
package sources, and legal-info notices. The Buildroot archive alone is not
the corresponding source of all packages included in boot.img.
NOTICE
cp "$runtime/licenses/gadget-SOURCE-PROVENANCE.txt" "$sources/"
printf 'Prepared rpiboot runtime: %s\n' "$runtime"
