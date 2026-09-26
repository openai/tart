#!/bin/sh

set -eu

ARCH="$1"
SCRATCH_PATH=".build/$ARCH"
OUTPUT_PATH=".build/prebuilt/$ARCH"
SWIFT_COMPATIBILITY_LIBRARY="$(dirname "$(xcrun --find swiftc)")/../lib/swift-6.2/macosx/libswiftCompatibilitySpan.dylib"

swift build \
  --build-system swiftbuild \
  --scratch-path "$SCRATCH_PATH" \
  --arch "$ARCH" \
  --configuration release \
  -Xlinker -weak_library \
  -Xlinker "$SWIFT_COMPATIBILITY_LIBRARY" \
  --product tart

BIN_PATH=$(swift build \
  --build-system swiftbuild \
  --scratch-path "$SCRATCH_PATH" \
  --arch "$ARCH" \
  --configuration release \
  --show-bin-path)

mkdir -p "$OUTPUT_PATH"
cp "$BIN_PATH/tart" "$OUTPUT_PATH/tart"
