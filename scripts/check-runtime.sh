#!/usr/bin/env bash
# Fail the release build instead of silently shipping a partial runtime.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
runtime="$root/src-tauri/resources/runtime"
for file in bin/rpiboot share/rpiboot/msd/bootcode.bin share/rpiboot/msd/start.elf \
    share/rpiboot/mass-storage-gadget64/boot.img \
    share/rpiboot/mass-storage-gadget64/bootfiles.bin \
    share/rpiboot/mass-storage-gadget64/config.txt; do
    [ -s "$runtime/$file" ] || { echo "Missing bundled file: $file. Run npm run prepare:runtime." >&2; exit 1; }
done
[ -x "$runtime/bin/rpiboot" ] || { echo 'Bundled rpiboot is not executable.' >&2; exit 1; }
"$runtime/bin/rpiboot" -V
for member in 2711/bootcode4.bin 2712/bootcode5.bin; do
    tar -tf "$runtime/share/rpiboot/mass-storage-gadget64/bootfiles.bin" "$member" >/dev/null
done
case "$(uname -s)" in
    Darwin)
        imager="$runtime/imager/Raspberry Pi Imager.app"
        [ -x "$imager/Contents/MacOS/rpi-imager" ] || { echo 'Bundled Imager is missing.' >&2; exit 1; }
        ;;
    Linux)
        [ -x "$runtime/imager/AppRun" ] || { echo 'Bundled Imager is missing.' >&2; exit 1; }
        ;;
esac
echo 'Bundled runtime is complete.'
