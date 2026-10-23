#!/bin/sh
# This script downloads the Tailwind CLI of config/config.exs to _build,
# with curl. It writes the file at the path of "mix tailwind.install":
# _build/tailwind-<target>-<version>. "mix assets.setup" and
# scripts/edge-com.sh run it before Tailwind.
#
# "mix tailwind.install" uses the HTTP client of Erlang (httpc). httpc
# stops at 10240 bytes of response headers. The redirect of GitHub to the
# release file has more headers than this. Because of this, httpc cannot
# download the file.
#
# When the file is there, the script does nothing. When the system has no
# known target, the script does nothing, and Tailwind downloads the file
# with httpc.
#
# beam.com always gives a Linux target with glibc. For this reason, the
# script does not use the musl targets.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$(sed -n '/^config :tailwind,/,/version:/s/^ *version: "\(.*\)",*$/\1/p' "$ROOT/config/config.exs")
if [ -z "$VERSION" ]; then
    echo "scripts/tailwind.sh: config/config.exs has no Tailwind version." >&2
    exit 1
fi

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64 | Linux-amd64) TARGET=linux-x64 ;;
    Linux-aarch64 | Linux-arm64) TARGET=linux-arm64 ;;
    Darwin-arm64) TARGET=macos-arm64 ;;
    Darwin-x86_64) TARGET=macos-x64 ;;
    *) exit 0 ;;
esac

BIN=$ROOT/_build/tailwind-$TARGET-$VERSION
if [ ! -x "$BIN" ]; then
    mkdir -p "$ROOT/_build"
    curl -sSfL -o "$BIN.part" \
        "https://github.com/tailwindlabs/tailwindcss/releases/download/v$VERSION/tailwindcss-$TARGET"
    chmod +x "$BIN.part"
    mv "$BIN.part" "$BIN"
fi
