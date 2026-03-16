#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="$PROJECT_ROOT/shadow-core"
SWIFT_DIR="$PROJECT_ROOT/Shadow"
GENERATED_DIR="$SWIFT_DIR/Shadow/Generated"

export PATH="$HOME/.cargo/bin:$PATH"

echo "Building shadow-core (release, aarch64-apple-darwin)..."
cd "$RUST_DIR"
cargo build --release --target aarch64-apple-darwin

echo "Generating Swift bindings..."
mkdir -p "$GENERATED_DIR"
cargo run --bin uniffi-bindgen generate \
    --library target/aarch64-apple-darwin/release/libshadow_core.a \
    --language swift \
    --out-dir "$GENERATED_DIR"

echo "Copying static library..."
cp target/aarch64-apple-darwin/release/libshadow_core.a "$SWIFT_DIR/"

echo "Done. Rust library built and Swift bindings generated."
