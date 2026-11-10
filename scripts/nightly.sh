#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
MOJO=${MOJO_NIGHTLY:?FAIL setup: set MOJO_NIGHTLY to a nightly mojo binary}
mkdir -p .work
"$MOJO" --version
scripts/capped.sh "$MOJO" precompile -I src src/pystruct -o .work/pystruct-nightly.mojoc
for t in tests/test_golden.mojo tests/test_roundtrip.mojo tests/api.mojo examples/quickstart.mojo; do
  scripts/capped.sh "$MOJO" run -I src -I tests "$t" || { echo "FAIL nightly: $t"; exit 1; }
done
echo 'PASS nightly'
