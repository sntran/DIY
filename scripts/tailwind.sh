#!/bin/sh
# Downloads the Tailwind CLI of config/config.exs to _build, with curl, at
# the path of "mix tailwind.install": _build/tailwind-<target>-<version>.
# "mix assets.setup" and scripts/edge-com.sh run it before Tailwind.
#
# "mix tailwind.install" uses the HTTP client of Erlang (httpc). httpc
# stops at 10240 bytes of response headers, and the redirect of GitHub to
# the release file has more. Thus httpc cannot download the file.
#
# When the file is there, or when the system has no known target, the
# script does nothing. Then "mix tailwind.install --if-missing" does the
# usual steps.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$(sed -n '/^config :tailwind,/,/version:/s/^ *version: "\(.*\)",*$/\1/p' "$ROOT/config/config.exs")

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64 | Linux-amd64) TARGET=linux-x64 ;;
    Linux-aarch64 | Linux-arm64) TARGET=linux-arm64 ;;
    Darwin-arm64) TARGET=macos-arm64 ;;
    Darwin-x86_64) TARGET=macos-x64 ;;
    *) exit 0 ;;
esac
if [ "${TARGET#linux}" != "$TARGET" ] && ldd --version 2>&1 | grep -qi musl; then
    TARGET=$TARGET-musl
fi

BIN=$ROOT/_build/tailwind-$TARGET-$VERSION
if [ -n "$VERSION" ] && [ ! -x "$BIN" ]; then
    mkdir -p "$ROOT/_build"
    curl -sSfL -o "$BIN.part" \
        "https://github.com/tailwindlabs/tailwindcss/releases/download/v$VERSION/tailwindcss-$TARGET"
    chmod +x "$BIN.part"
    mv "$BIN.part" "$BIN"
fi
