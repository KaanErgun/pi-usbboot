#!/usr/bin/env bash
# Fast, headless gate: typecheck -> lint -> test. Bundling (.app/.dmg/AppImage) is
# slow and platform-specific, so it lives in `npm run bundle:mac` / `bundle:linux`.
set -euo pipefail
cd "$(dirname "$0")/.."
npx tsc -p . --noEmit
python3 scripts/test-boot-image.py
node --test scripts/test-transfer-status.mjs
cargo fmt --manifest-path src-tauri/Cargo.toml --check
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path src-tauri/Cargo.toml
