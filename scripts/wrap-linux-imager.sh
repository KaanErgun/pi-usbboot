#!/usr/bin/env bash
# Keep the already self-contained Qt program out of GTK dependency rewriting.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
runtime="$root/src-tauri/resources/runtime"
[ -x "$runtime/imager/AppRun" ] || { echo 'Prepare Imager first.' >&2; exit 1; }
mkdir -p "$runtime/imager-bundle"
tar -czf "$runtime/imager-bundle/payload.tar.gz" -C "$runtime/imager" .
digest=$(sha256sum "$runtime/imager-bundle/payload.tar.gz" | cut -d ' ' -f1)
cat > "$runtime/imager-bundle/AppRun" <<'HEADER'
#!/bin/sh
# Extract only the verified local payload; this launcher performs no download.
set -eu
umask 077
HEADER
printf "payload_sha='%s'\n" "$digest" >> "$runtime/imager-bundle/AppRun"
cat >> "$runtime/imager-bundle/AppRun" <<'HEADER'
bundle=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
base="${XDG_CACHE_HOME:-$HOME/.cache}/pi-usbboot/imager"
target="$base/$payload_sha"
mkdir -p "$base"
if [ ! -f "$target/.pi-usbboot-complete" ]; then
    actual=$(sha256sum "$bundle/payload.tar.gz" | cut -d ' ' -f1)
    [ "$actual" = "$payload_sha" ] || { echo 'The bundled Imager is incomplete. Reinstall Pi USB Boot.' >&2; exit 1; }
    stage=$(mktemp -d "$base/.extract-XXXXXX")
    trap 'rm -rf "$stage"' EXIT HUP INT TERM
    mkdir "$stage/app"
    tar -xzf "$bundle/payload.tar.gz" -C "$stage/app" --no-same-owner
    [ -x "$stage/app/AppRun" ] || { echo 'The bundled Imager is incomplete.' >&2; exit 1; }
    printf '%s\n' "$payload_sha" > "$stage/app/.pi-usbboot-complete"
    if [ ! -d "$target" ]; then mv "$stage/app" "$target"; fi
    rm -rf "$stage"
    trap - EXIT HUP INT TERM
fi
unset APPDIR APPIMAGE ARGV0 LD_LIBRARY_PATH LD_PRELOAD QT_PLUGIN_PATH
unset QT_QPA_PLATFORM_PLUGIN_PATH QML2_IMPORT_PATH QML_IMPORT_PATH GIO_MODULE_DIR
exec "$target/AppRun" "$@"
HEADER
chmod 755 "$runtime/imager-bundle/AppRun"
echo 'Prepared isolated, FUSE-free Imager payload.'
