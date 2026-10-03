#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/check-runtime.sh
if [ -n "${APPLE_SIGNING_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$APPLE_SIGNING_IDENTITY" \
        src-tauri/resources/runtime/bin/rpiboot
fi
# The nested official Imager retains its original Raspberry Pi signature.
npx tauri build --target universal-apple-darwin --bundles app,dmg
