#!/bin/bash
# Builds a fully static avifenc (libavif + aom encoder) for embedding in the
# app bundle at Contents/MacOS/avifenc. Output: Vendor/avifenc/avifenc plus
# Vendor/avifenc/avifenc.sha256, which the Xcode postBuildScript verifies
# before embedding the binary in a signed app.
#
# The binary is NOT tracked in git; fresh clones must run this script once
# (Release builds fail loudly when it is missing). Re-run to upgrade libavif:
# bump LIBAVIF_TAG *and* LIBAVIF_COMMIT below.
#
# Requires: cmake, git, ninja (brew install cmake ninja)
set -euo pipefail

LIBAVIF_TAG="v1.3.0"
# Tags are mutable upstream; pin the exact commit the tag pointed to when
# this was last audited so rebuilds are reproducible and provable.
LIBAVIF_COMMIT="1aadfad932c98c069a1204261b1856f81f3bc199"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/Vendor/avifenc"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/libavif-build.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

git clone --depth 1 --branch "$LIBAVIF_TAG" https://github.com/AOMediaCodec/libavif "$WORK_DIR"

ACTUAL_COMMIT="$(git -C "$WORK_DIR" rev-parse HEAD)"
if [[ "$ACTUAL_COMMIT" != "$LIBAVIF_COMMIT" ]]; then
    echo "ERROR: ${LIBAVIF_TAG} now points at ${ACTUAL_COMMIT}, expected ${LIBAVIF_COMMIT}."
    echo "The upstream tag moved. Audit the diff, then update LIBAVIF_COMMIT."
    exit 1
fi

# Build for both architectures so Intel Macs don't pass the executable check
# and then fail at Process.run with an arm64-only binary.
cmake -S "$WORK_DIR" -B "$WORK_DIR/build" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DAVIF_CODEC_AOM=LOCAL \
    -DAVIF_LIBYUV=LOCAL \
    -DAVIF_LIBSHARPYUV=LOCAL \
    -DAVIF_JPEG=LOCAL \
    -DAVIF_ZLIBPNG=LOCAL \
    -DAVIF_BUILD_APPS=ON \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0

cmake --build "$WORK_DIR/build" --target avifenc -j "$(sysctl -n hw.ncpu)"

mkdir -p "$OUT_DIR"
cp "$WORK_DIR/build/avifenc" "$OUT_DIR/avifenc"
chmod +x "$OUT_DIR/avifenc"

# Record the checksum next to the binary; the embed step refuses to ship a
# binary that doesn't match it.
(cd "$OUT_DIR" && shasum -a 256 avifenc > avifenc.sha256)

echo "--- architectures: ---"
lipo -info "$OUT_DIR/avifenc" || file "$OUT_DIR/avifenc"
echo "--- dylib dependencies (should be system-only): ---"
otool -L "$OUT_DIR/avifenc"
"$OUT_DIR/avifenc" --version
echo "Built: $OUT_DIR/avifenc"
cat "$OUT_DIR/avifenc.sha256"
