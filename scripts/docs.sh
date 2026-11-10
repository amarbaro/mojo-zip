#!/usr/bin/env bash
# Every Mojo block in README.md and skills/mojo-zip/SKILL.md compiles and runs.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work/docs
for f in README.md skills/mojo-zip/SKILL.md; do
  out=.work/docs/$(basename "$f" .md).mojo
  awk '/^```mojo$/{active=1; next} /^```$/{active=0} active' "$f" > "$out"
  [ -s "$out" ] || { echo "FAIL docs: no Mojo example in $f"; exit 1; }
  scripts/capped.sh "${MOJO:-.venv/bin/mojo}" run -I src "$out" || { echo "FAIL docs: $f example"; exit 1; }
done
printf 'PASS docs\n'
