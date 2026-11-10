#!/usr/bin/env bash
# Usage: bench.sh BEFORE_BINARY [AFTER_BINARY]. Three rounds (order flips in round 2) of every job, before / after / CPython
# reference, pinned to one core, wall seconds and peak KB per run (docs/perf.md carries the medians).
set -euo pipefail
cd "$(dirname "$0")/.."
BEFORE=${1:?FAIL setup: baseline binary required}
AFTER=${2:-.work/bench-after}
CORE=${BENCH_CPU:-15}
python3 tools/bench_fixtures.py
for round in 1 2 3; do
  for job in many stored stored_view deflate text compress; do
    order=(before after)
    if [ "$round" -eq 2 ]; then order=(after before); fi
    for side in "${order[@]}"; do
      if [ "$job" = compress ] && [ "$side" = before ]; then continue; fi  # the first native build had no compress job
      binary=$BEFORE
      if [ "$side" = after ]; then binary=$AFTER; fi
      echo "BEGIN $side $job round $round cpu $CORE"
      scripts/capped.sh /usr/bin/time -f 'wall_s %e peak_kb %M' taskset -c "$CORE" "$binary" "$job"
    done
    if [ "$job" != stored_view ]; then
      echo "BEGIN reference $job round $round cpu $CORE"
      scripts/capped.sh /usr/bin/time -f 'wall_s %e peak_kb %M' taskset -c "$CORE" python3 -I tools/bench_ref.py "$job"
    fi
  done
done
