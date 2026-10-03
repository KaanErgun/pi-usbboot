#!/usr/bin/env bash
# Stage official, unmodified Raspberry Pi Imager binaries for application bundling.
# Reproduce sources/notices with prepare-imager-sources.py and, for Linux,
# prepare-imager-linux-sources.py as well.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
runtime_root="$repo_root/src-tauri/resources/runtime"
cache="$repo_root/release/v0.3.0/imager-downloads"
platform=${1:-$(uname -s)}
case "$platform" in
  Darwin|macos)
    version=2.0.11.1
    filename="rpi-imager-v${version}.dmg"
    digest=2b4c5324c5ff04aa3bfb216795ae9e01cb54400752727353e13fb21e66c528a9
    ;;
  Linux|linux)
    [[ $(uname -m) == x86_64 ]] || { printf 'The bundled Linux Imager requires x86_64.\n' >&2; exit 1; }
    # v2.0.11.1 has no official AppImage; this is the latest stable portable GUI.
    version=2.0.11
    filename="Raspberry_Pi_Imager-v${version}-desktop-x86_64.AppImage"
    digest=d7338d88440c04f8114d2a5cb526e5ba604250b78b267c3bb2f58b1df04cbda7
    ;;
  *) printf 'Usage: %s [macos|linux]\n' "$0" >&2; exit 2 ;;
esac

mkdir -p "$cache" "$runtime_root"
stage=$(mktemp -d "$runtime_root/.imager-stage.XXXXXX")
mounted=0
cleanup() {
  if [[ "$mounted" == 1 ]]; then
    hdiutil detach "$stage/mount" >/dev/null || true
  fi
  rm -rf "$stage"
}
trap cleanup EXIT

verify_digest() {
  python3 - "$1" "$digest" <<'PY'
import hashlib
import sys

result = hashlib.sha256()
with open(sys.argv[1], "rb") as source:
    for block in iter(lambda: source.read(1024 * 1024), b""):
        result.update(block)
actual = result.hexdigest()
if actual != sys.argv[2]:
    raise SystemExit("Official Imager download failed SHA-256 verification.")
PY
}

asset="$cache/$filename"
if [[ ! -f "$asset" ]]; then
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
    "https://github.com/raspberrypi/rpi-imager/releases/download/v$version/$filename" \
    --output "$stage/download"
  verify_digest "$stage/download"
  mv "$stage/download" "$asset"
fi
verify_digest "$asset"

case "$platform" in
  Darwin|macos)
    mkdir "$stage/mount" "$stage/new"
    hdiutil attach -readonly -nobrowse -mountpoint "$stage/mount" "$asset" >/dev/null
    mounted=1
    app_name='Raspberry Pi Imager.app'
    ditto "$stage/mount/$app_name" "$stage/new/$app_name"
    # Keep Raspberry Pi Ltd's original identity; do not re-sign this nested app.
    codesign --verify --deep --strict "$stage/new/$app_name"
    architectures=$(lipo -archs "$stage/new/$app_name/Contents/MacOS/rpi-imager")
    [[ "$architectures" == *arm64* && "$architectures" == *x86_64* ]] || {
      printf 'Official Imager is not a universal macOS application.\n' >&2
      exit 1
    }
    hdiutil detach "$stage/mount" >/dev/null
    mounted=0
    ;;
  Linux|linux)
    chmod +x "$asset"
    (cd "$stage" && "$asset" --appimage-extract >extract.log)
    mv "$stage/squashfs-root" "$stage/new"
    [[ -x "$stage/new/AppRun" ]] || { printf 'Official Imager AppRun is missing.\n' >&2; exit 1; }
    ;;
esac

# Replace only this script's generated directory after complete verification.
rm -rf "$runtime_root/imager"
mv "$stage/new" "$runtime_root/imager"
# License notices belong in every fresh runtime, before the outer app is signed.
notices="$cache/Pi-USB-Boot_0.3.0_imager-notices.tar.gz"
digest=49ce3d61dc8d10b8f47389ed148db2054b69fd550221794dd3d8c75dc043bf40
if [[ ! -f "$notices" ]]; then
  curl --fail --location --retry 3 \
    'https://github.com/KaanErgun/pi-usbboot/releases/download/v0.3.0/Pi-USB-Boot_0.3.0_imager-notices.tar.gz' \
    --output "$notices"
fi
verify_digest "$notices"
mkdir -p "$runtime_root/licenses"
tar -xzf "$notices" -C "$runtime_root/licenses"
if [[ "$platform" == Linux || "$platform" == linux ]]; then
  "$repo_root/scripts/wrap-linux-imager.sh"
fi
printf 'Staged Raspberry Pi Imager %s (%s) in resources/runtime/imager.\n' "$version" "$platform"
