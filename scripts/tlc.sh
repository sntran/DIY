#!/bin/sh
# Checks the TLA+ models of specs/ with TLC. A model NAME.tla has one or more
# configurations NAME.*.cfg (and NAME.cfg).
#
# - TLC must find no error in a configuration, but
# - a configuration with the line "\* TLC must find: TEXT" has a known fault.
#   TLC must show TEXT, for example "Invariant NoLostUpdate is violated.".
#   This shows that the property can fail, and that the model has the fault.
#
#   scripts/tlc.sh
#
# It needs Java 11 or later and tla2tools.jar v1.7.4 (see CONTRIBUTING.md).
#
# Variables:
# - TLA2TOOLS_JAR: the path of tla2tools.jar (default: ~/.tla/tla2tools.jar).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
JAR=${TLA2TOOLS_JAR:-$HOME/.tla/tla2tools.jar}
if [ ! -f "$JAR" ]; then
  echo "tla2tools.jar is not at $JAR. See CONTRIBUTING.md." >&2
  exit 1
fi

# TLC writes its states to a temporary directory, not to specs/.
META=$(mktemp -d)
trap 'rm -rf "$META"' EXIT

STATUS=0
cd "$ROOT/specs"
for CFG in *.cfg; do
  MODEL=${CFG%%.*}
  EXPECT=$(sed -n 's/^\\\* TLC must find: //p' "$CFG")
  if [ -z "$EXPECT" ]; then
    EXPECT="Model checking completed. No error has been found."
  fi

  OUTPUT=$(java -Xss64m -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers auto \
    -metadir "$META/$CFG" -config "$CFG" "$MODEL" 2>&1) || true

  if printf '%s\n' "$OUTPUT" | grep -qF "$EXPECT"; then
    echo "ok     $CFG: $EXPECT"
  else
    printf '%s\n' "$OUTPUT"
    echo "FAILED $CFG: TLC did not show \"$EXPECT\"" >&2
    STATUS=1
  fi
done
exit $STATUS
