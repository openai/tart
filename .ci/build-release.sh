#!/bin/sh

set -eu

ARCH="$1"
SCRATCH_PATH=".build/$ARCH"
OUTPUT_PATH=".build/prebuilt/$ARCH"

swift build \
  --build-system swiftbuild \
  --scratch-path "$SCRATCH_PATH" \
  --arch "$ARCH" \
  --configuration release \
  --product tart

BIN_PATH=$(swift build \
  --build-system swiftbuild \
  --scratch-path "$SCRATCH_PATH" \
  --arch "$ARCH" \
  --configuration release \
  --show-bin-path)

mkdir -p "$OUTPUT_PATH"
cp "$BIN_PATH/tart" "$OUTPUT_PATH/tart"
