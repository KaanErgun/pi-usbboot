#!/usr/bin/env bash
# Wrap Tauri's complete AppDir in a per-user installer. No FUSE or downloads.
set -euo pipefail
[ "$#" = 2 ] || { echo "Usage: $0 APPDIR OUTPUT.run" >&2; exit 2; }
appdir=$(cd "$1" && pwd)
output=$2
[ -x "$appdir/AppRun" ] || { echo 'AppRun is missing' >&2; exit 1; }
payload=$(mktemp)
trap 'rm -f "$payload"' EXIT
tar -czf "$payload" -C "$appdir" .
digest=$(sha256sum "$payload" | cut -d ' ' -f1)
cat > "$output" <<'HEADER'
#!/bin/sh
# Pi USB Boot: self-contained per-user desktop installer.
set -eu
umask 077
HEADER
printf "payload_sha='%s'\n" "$digest" >> "$output"
cat >> "$output" <<'HEADER'
data_dir=${XDG_DATA_HOME:-"$HOME/.local/share"}
base="$data_dir/pi-usbboot"
target="$base/$payload_sha"
mkdir -p "$base"
if [ ! -f "$target/.pi-usbboot-complete" ]; then
    stage=$(mktemp -d "$base/.install-XXXXXX")
    trap 'rm -rf "$stage"' EXIT HUP INT TERM
    line=$(awk '/^__PI_USB_BOOT_PAYLOAD__$/ { print NR + 1; exit }' "$0")
    tail -n +"$line" "$0" > "$stage/payload.tar.gz"
    actual=$(sha256sum "$stage/payload.tar.gz" | cut -d ' ' -f1)
    [ "$actual" = "$payload_sha" ] || { echo 'Download is incomplete. Download the installer again.' >&2; exit 1; }
    mkdir "$stage/app"
    tar -xzf "$stage/payload.tar.gz" -C "$stage/app" --no-same-owner
    [ -x "$stage/app/AppRun" ] || { echo 'The application package is incomplete.' >&2; exit 1; }
    printf '%s\n' "$payload_sha" > "$stage/app/.pi-usbboot-complete"
    # A concurrent installer may already have completed this exact version.
    if [ ! -d "$target" ]; then mv "$stage/app" "$target"; fi
    rm -rf "$stage"
    trap - EXIT HUP INT TERM
fi
mkdir -p "$data_dir/applications"
escaped=$(printf '%s' "$target/AppRun" | sed 's/\\/\\\\/g; s/"/\\"/g; s/`/\\`/g; s/\$/\\$/g; s/%/%%/g')
cat > "$data_dir/applications/pi-usbboot.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Pi USB Boot
Comment=USB boot and image writing for supported Raspberry Pi boards
Exec="$escaped"
Icon=drive-removable-media
Terminal=false
Categories=Utility;Development;
DESKTOP
exec "$target/AppRun" "$@"
exit 0
__PI_USB_BOOT_PAYLOAD__
HEADER
cat "$payload" >> "$output"
chmod 755 "$output"
printf 'Built %s\n' "$output"
