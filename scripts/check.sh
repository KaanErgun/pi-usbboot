#!/usr/bin/env bash
# Fast, headless gate: typecheck -> lint -> test. Bundling (.app/.dmg/AppImage) is
# slow and platform-specific, so it lives in `npm run bundle:mac` / `bundle:linux`.
set -euo pipefail
cd "$(dirname "$0")/.."
npx tsc -p . --noEmit
cargo fmt --manifest-path src-tauri/Cargo.toml --check
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path src-tauri/Cargo.toml
