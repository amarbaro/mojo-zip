#!/usr/bin/env bash
# The gate: no FFI under src, codec corpus vs zlib (levels 0..9, inflate classes), every oracle scenario vs CPython
# zipfile (each twice), and a negative control (a codec with one Huffman length off must fail). Full output goes to
# .work/native-gate.txt. MOJO overrides the toolchain, ORACLE_PY the Python.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work/native .work/t
exec > >(tee .work/native-gate.txt) 2>&1
MOJO=${MOJO:-.venv/bin/mojo}
PY=${ORACLE_PY:-python3}
fail() { echo "FAIL $1: $2"; exit 1; }
step() { echo "== $1"; }

step "no FFI in src"
if grep -rE "DLHandle|external_call|dlopen" src; then fail ffi "src must hold no DLHandle, external_call or dlopen"; fi
echo "src is FFI free"

step "build"
for t in tests/codec:.work/native/codec tests/cases:.work/cases; do
  "$MOJO" build -O3 -I src ${MOJO_FLAGS:-} "${t%%:*}.mojo" -o "${t##*:}" 2> .work/build.err || { cat .work/build.err; fail build "${t%%:*}.mojo"; }
done

step "codec corpus against zlib"
$PY -I tools/codec_corpus.py .work/native
rm -rf .work/native/out; mkdir -p .work/native/out
scripts/capped.sh .work/native/codec .work/native || fail codec "runner exited non-zero"
$PY -I tools/codec_corpus.py .work/native --verify || fail codec "differs from zlib"

step "oracle scenarios against CPython zipfile"
$PY -I tools/gen_vectors.py > /dev/null
git diff --quiet -- tests/golden/vectors.txt || fail vectors "tests/golden/vectors.txt is stale: commit the regenerated file"
CASES=.work/cases ORACLE_PY=$PY scripts/oracle_diff.sh || fail oracle "scenario diff"

step "negative control: one Huffman length off"
rm -rf .work/neg; mkdir -p .work/neg/dir/out; cp -r src .work/neg/src
$PY -I - <<'PYEOF'
p = ".work/neg/src/deflate/deflate.mojo"
s = open(p).read()
a = "while n <= 143:\n            t.unsafe_offset(_SLT + 2 * n + 1)[] = 8"
assert a in s, "negative control pattern missing"
open(p, "w").write(s.replace(a, a[:-1] + "9", 1))
PYEOF
ln -s "$PWD/.work/native/in" .work/neg/dir/in; ln -s "$PWD/.work/native/raw" .work/neg/dir/raw; cp .work/native/manifest.txt .work/neg/dir/
"$MOJO" build -O3 -I .work/neg/src tests/codec.mojo -o .work/neg/codec 2> .work/build.err || { cat .work/build.err; fail negative "mutant does not compile"; }
scripts/capped.sh .work/neg/codec .work/neg/dir > /dev/null 2>&1 || true
if $PY -I tools/codec_corpus.py .work/neg/dir --verify > .work/neg/verify.txt 2>&1; then fail negative "the mutated codec passed the gate"; fi
echo "mutated codec rejected: $(tail -1 .work/neg/verify.txt)"

echo "PASS all"
