#!/bin/sh
# Builds edge.com: the release of the app in one file for the WebAssembly
# runtime of beam.com (https://github.com/sntran/BEAM.com), with no native
# program (--target wasm32): a Worker can be at most 64 MiB. "npm run
# build" runs it, also in the build of Cloudflare Workers Builds. Then
# worker.js serves edge.com with the runtime of the npm package beam.com
# (see wrangler.jsonc).
#
#   npm ci && npm run build      (or: sh scripts/edge-com.sh)
#
# Variables:
# - BEAM_COM: the path of a beam.com, in place of the file of the npm
#   package. npx beam.com downloads the file of the version of the package,
#   and checks its SHA-256.
# - CACERTS: a file with the root certificates (PEM) for TLS. The runtime
#   has no certificates of its own, and the VM gets the weather and the
#   plans with HTTPS. Without CACERTS, the script downloads the bundle of
#   Mozilla from curl.se (CACERT_DATE), and checks its SHA-256
#   (CACERT_SHA256).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CACERT_DATE=${CACERT_DATE:-2026-09-25}
CACERT_SHA256=${CACERT_SHA256:-a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505}
cd "$ROOT"

beam() {
    if [ -n "${BEAM_COM:-}" ]; then sh "$BEAM_COM" "$@"; else npx beam.com "$@"; fi
}

sha256() {
    if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

export MIX_ENV=prod

if [ -z "${CACERTS:-}" ]; then
    CACERTS=$ROOT/_build/cacert-$CACERT_DATE.pem
    if [ ! -f "$CACERTS" ] || [ "$(sha256 "$CACERTS")" != "$CACERT_SHA256" ]; then
        mkdir -p "$ROOT/_build"
        curl -sSfL -o "$CACERTS" "https://curl.se/ca/cacert-$CACERT_DATE.pem"
    fi
    if [ "$(sha256 "$CACERTS")" != "$CACERT_SHA256" ]; then
        echo "The SHA-256 of $CACERTS is not $CACERT_SHA256." >&2
        rm -f "$CACERTS"
        exit 1
    fi
fi

beam mix local.hex --force --if-missing
beam mix local.rebar --force --if-missing
beam mix deps.get --only prod
beam mix compile
sh scripts/tailwind.sh
beam mix assets.deploy
# mix release keeps the directories of old versions in lib/. Remove them.
rm -rf _build/prod/rel/diy
RELEASE_ERTS=false beam mix release --overwrite
beam _build/prod/rel/diy -o edge.com --target wasm32 --cacerts "$CACERTS"
# A Worker cannot compile WebAssembly at run time: Wrangler compiles the
# NIF libraries of nifs/ at the build (the NIF of DIY.Picture), and
# worker.js gives them to serve().
rm -rf nifs nifs.js
beam --nif-modules edge.com "$ROOT"
