#!/usr/bin/env bash
# Each line of tests/mutants.txt is FILE|FROM|TO: one source change the gate must catch.
# A surviving mutant means a blind gate.
set -euo pipefail
cd "$(dirname "$0")/.."
MOJO=${MOJO:-.venv/bin/mojo}; killed=0; n=0; bad=0; cur=""
trap '[ -n "$cur" ] && [ -f .work/orig.mojo ] && cp .work/orig.mojo "$cur"' EXIT INT TERM
while IFS='|' read -r f from to; do
  [ -n "$f" ] || continue; n=$((n+1)); cp "$f" .work/orig.mojo; cur=$f
  grep -qF -- "$from" "$f" || { echo "FAIL mutant $n: pattern not found in $f: $from"; exit 1; }
  python3 -c 'import sys;p,a,b=sys.argv[1:];s=open(p).read();open(p,"w").write(s.replace(a,b,1))' "$f" "$from" "$to"
  # a mutant that does not compile proves nothing (2026-11-07: typo mutants `UUIDX` counted as kills)
  if ! scripts/capped.sh "$MOJO" build -I src -I tests ${MOJO_FLAGS:-} tests/cases.mojo -o .work/mutant 2>/dev/null; then
    echo "INVALID mutant $n (does not compile): $f: $from -> $to"; bad=$((bad+1))
  elif ! CHECK_DIR=.work/mcheck CASES=.work/mutant scripts/oracle_diff.sh >/dev/null 2>&1; then
    killed=$((killed+1)); echo "KILLED mutant $n (oracle diff): $f: $from -> $to"
  elif [[ $f == src/deflate/* ]] && scripts/capped.sh "$MOJO" build -O3 -I src tests/codec.mojo -o .work/mutant-codec 2>/dev/null \
       && rm -rf .work/native/out && mkdir -p .work/native/out && scripts/capped.sh .work/mutant-codec .work/native >/dev/null 2>&1 \
       && ! python3 -I tools/codec_corpus.py .work/native --verify >/dev/null 2>&1; then
    killed=$((killed+1)); echo "KILLED mutant $n (codec corpus): $f: $from -> $to"
  else echo "SURVIVED mutant $n: $f: $from -> $to"; fi
  cp .work/orig.mojo "$f"; cur=""
done < tests/mutants.txt
echo "mutants: $killed/$n killed, $bad invalid"
[ "$n" -gt 0 ] && [ "$killed" -eq "$n" ] || { echo "FAIL mutants"; exit 1; }
