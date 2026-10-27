#!/bin/bash
# Build sjasmplus from a pinned source tag and print the binary path.
# Usage: tools/install-sjasmplus.sh [tag] [destination]
# The default destination is build/sjasmplus-src (gitignored).
set -euo pipefail

version="${1:-v1.21.0}"
dest="${2:-build/sjasmplus-src}"

if [ ! -x "$dest/build/release/sjasmplus" ]; then
    rm -rf "$dest"
    git clone --depth 1 --branch "$version" \
        https://github.com/z00m128/sjasmplus.git "$dest" >&2
    jobs="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
    make -C "$dest" -j"$jobs" >&2
fi

printf '%s\n' "$dest/build/release/sjasmplus"
