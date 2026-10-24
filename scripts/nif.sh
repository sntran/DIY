#!/bin/sh
# Builds priv/resvg.wasm: the NIF of DIY.Picture in WebAssembly, from the
# crate native/resvg. The file is in the repository, so the build of the
# app (scripts/edge-com.sh) does not need Rust. Build it again after a
# change of the crate or of its fonts:
#
#   sh scripts/nif.sh
#
# It needs rustup: native/resvg/rust-toolchain.toml gives the version of
# Rust and the target wasm32-wasip1. rustler 0.38.0 comes from crates.io,
# with native/rustler.patch (docs/NIFS.md of BEAM.com).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CRATE=$ROOT/native/resvg
RUSTLER_SHA256=60ac8495cb6091c1f8bd0c3bb816cd4e6f0a073f396d77eb602cb7f0615212de
cd "$CRATE"

sha256() {
    if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

mkdir -p target
if [ ! -f target/rustler/.patched ]; then
    curl -sSfL -o target/rustler.crate https://crates.io/api/v1/crates/rustler/0.38.0/download
    if [ "$(sha256 target/rustler.crate)" != "$RUSTLER_SHA256" ]; then
        echo "The SHA-256 of rustler 0.38.0 is not $RUSTLER_SHA256." >&2
        exit 1
    fi
    rm -rf target/rustler target/rustler-0.38.0
    tar xzf target/rustler.crate -C target
    mv target/rustler-0.38.0 target/rustler
    cp target/rustler/Cargo.toml.orig target/rustler/Cargo.toml
    (cd target/rustler && patch -s -p1 < "$ROOT/native/rustler.patch")
    touch target/rustler/.patched
fi

# The paths of this computer do not go into the file.
RUSTFLAGS="--remap-path-prefix=$CRATE=/resvg --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo" \
    cargo build --release --target wasm32-wasip1
mkdir -p "$ROOT/priv"
cp target/wasm32-wasip1/release/resvg_nif.wasm "$ROOT/priv/resvg.wasm"
ls -l "$ROOT/priv/resvg.wasm"
