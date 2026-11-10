#!/usr/bin/env bash
# CI entry point (GitHub runner or local): install, then every gate. MOJO=path overrides the toolchain.
# Ends with "PASS n/m" (or "FAIL k/m"): the README checks badge parses that line.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${MOJO:-}" ]; then
  command -v uv >/dev/null || { echo "FAIL setup: uv not installed"; exit 1; }
  uv sync -q || { echo "FAIL setup: uv sync"; exit 1; }
  MOJO=.venv/bin/mojo
fi
"$MOJO" --version
[ -x .venv/bin/python ] && export ORACLE_PY=${ORACLE_PY:-.venv/bin/python}
mkdir -p .work/t
for t in tests/api:.work/t/api examples/quickstart:.work/t/quickstart; do
  "$MOJO" build -O3 -I src ${MOJO_FLAGS:-} "${t%%:*}.mojo" -o "${t##*:}" 2>.work/build.err || { echo "FAIL build: ${t%%:*}.mojo"; cat .work/build.err; echo "FAIL 5/5"; exit 1; }
done
m=5; ok=0
gate() { local name=$1; shift; if "$@"; then ok=$((ok+1)); echo "ok $name"; else echo "FAIL $name"; echo "FAIL $((m-ok))/$m"; exit 1; fi; }
gate check env MOJO="$MOJO" scripts/check.sh
gate mutants env MOJO="$MOJO" scripts/mutants.sh
gate api sh -c '.work/t/api && ${ORACLE_PY:-python3} -I tools/pyread.py'
gate quickstart sh -c '.work/t/quickstart > /dev/null'
gate docs env MOJO="$MOJO" scripts/docs.sh
echo "PASS $ok/$m"
echo "PASS ci"
