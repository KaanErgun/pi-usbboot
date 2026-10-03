#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/wrap-linux-imager.sh
target=$(cargo metadata --manifest-path src-tauri/Cargo.toml --no-deps --format-version 1 |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')
version=$(node -p 'require("./package.json").version')
# Tauri may reuse AppImage's Debian staging tree. Remove only generated staging
# so libraries removed from resources cannot survive into a later package.
rm -rf "$target/release/bundle/appimage_deb" \
    "$target/release/bundle/appimage/Pi USB Boot.AppDir"
npx tauri build --bundles deb,appimage "$@"
mkdir -p "release/v$version"
./scripts/build-linux-installer.sh \
    "$target/release/bundle/appimage/Pi USB Boot.AppDir" \
    "release/v$version/Pi-USB-Boot_${version}_amd64.run"
cp "$target/release/bundle/deb/Pi USB Boot_${version}_amd64.deb" \
    "release/v$version/Pi-USB-Boot_${version}_amd64.deb"
