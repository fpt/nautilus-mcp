#!/bin/bash
set -e

# Generate UniFFI bindings for Swift

# Resolve the repo root from this script's own location so the paths below hold
# no matter what directory the script is invoked from.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "🦀 Building Rust library..."
cd "$ROOT/crates"
cargo build --release

echo "🔧 Generating UniFFI Swift bindings..."
cd lib

LIBRARY_PATH="../target/release/libnautilus_core.dylib"
OUT_DIR="$ROOT/vendor/uniffi-swift"

mkdir -p "$OUT_DIR"

# Generate Swift sources
cargo run --bin uniffi-bindgen-swift -- --swift-sources "$LIBRARY_PATH" "$OUT_DIR"

# Generate headers
cargo run --bin uniffi-bindgen-swift -- --headers "$LIBRARY_PATH" "$OUT_DIR"

# Generate modulemap
cargo run --bin uniffi-bindgen-swift -- --modulemap "$LIBRARY_PATH" "$OUT_DIR"

echo "✅ UniFFI bindings generated!"

# Copy the generated outputs into the tracked Swift tree. `vendor/uniffi-swift/`
# is gitignored, so the build must NOT depend on it — the FFI header is committed
# self-contained under NautilusBridgeFFI, and the Swift bindings under NautilusBridge.
# Doing the copies here (rather than as a manual "next step") keeps a clean clone
# buildable and stops the committed bindings from silently going stale after a
# .udl change — which is exactly what broke the McpServerConfig.url field.
cd "$ROOT"
echo "📋 Copying generated bindings into the tracked Swift tree..."
cp vendor/uniffi-swift/nautilus_core.swift   swift/Sources/NautilusBridge/nautilus_core.swift
cp vendor/uniffi-swift/nautilus_coreFFI.h    swift/Sources/NautilusBridgeFFI/nautilus_coreFFI.h
cp vendor/uniffi-swift/nautilus_coreFFI.h    swift/Sources/NautilusBridge/include/nautilus_coreFFI.h

echo "✅ Bindings copied. Review & commit:"
echo "     swift/Sources/NautilusBridge/nautilus_core.swift"
echo "     swift/Sources/NautilusBridgeFFI/nautilus_coreFFI.h"
echo "     swift/Sources/NautilusBridge/include/nautilus_coreFFI.h"
