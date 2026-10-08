#!/bin/sh
# Builds app.com: the release of the app in one native file of beam.com
# (https://github.com/sntran/BEAM.com), with its WebAssembly part, and
# edge.com: the part of app.com that the Worker reads (the release, with no
# native program, see scripts/edge-com.mjs). "npm run build" runs it, also
# in the build of Cloudflare Workers Builds. Then worker.js serves edge.com
# with the runtime of the npm package beam.com (see wrangler.jsonc).
#
#   npm install && npm run build      (or: sh scripts/app-com.sh)
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
beam mix assets.deploy
# mix release keeps the directories of old versions in lib/. Remove them.
rm -rf _build/prod/rel/diy
RELEASE_ERTS=false beam mix release --overwrite
beam _build/prod/rel/diy -o app.com --cacerts "$CACERTS"
# A Worker can be at most 64 MiB. The native program of app.com (about 25
# MB) is not for the Worker: the upload has only the release.
node scripts/edge-com.mjs app.com edge.com
