# Performance

Box: 7800X3D, one core pinned (`taskset -c 15`), CPython 3.14.9 with system zlib 1.3.2, Mojo 1.2.0, `-O3`.
`scripts/bench.sh BEFORE AFTER`: three rounds (order flipped in round 2), medians of wall seconds / peak RSS. Jobs run on the
fixtures of `tools/bench_fixtures.py` (many.zip: 100,000 tiny stored members; big_stored.zip: 256 MB stored; big_deflate.zip:
64 MB of a repeating pattern; big_text.zip: 64 MB word soup, level 6). `bench/zipbench.mojo` and `tools/bench_ref.py` do the same
job per name.

| job | CPython reference | first native build | final | note |
|---|---|---|---|---|
| `many`: open + read every `file_size` of 100k entries | 0.27 s / 76 MB | 0.07 s / 72 MB | **0.06 s / 54 MB** | 4.5x faster |
| `stored`: `read` of a 256 MB STORED member | 0.33 s / 270 MB | 1.04 s / 920 MB | 0.50 s / 521 MB | file load + one copy; CPython copies once |
| `stored_view`: `read_view` of the same member (zero copy) | none | 0.86 s / 921 MB | **0.31 s / 265 MB** | peak = file size, no member copy |
| `deflate`: 64 MB pattern member | 0.12 s / 142 MB | 0.10 s / 73 MB | **0.10 s / 73 MB** | inflate |
| `text`: 64 MB word-soup member (dynamic Huffman) | 0.19 s / 151 MB | 0.19 s / 105 MB | 0.19 s / 82 MB | inflate equals zlib's speed |
| `compress`: `writestr` 16 MB text, level 6 (compress only) | 465 ms | n/a | 498 ms | 7% slower than C zlib, same 2,496,705 bytes |

What changed between "first" and "final": `ZipReader.open` asks for the file size so the file is read in one allocation (the
stdlib's default read doubles a 256-byte buffer and copies), and the central directory list is reserved from the directory
size so it does not grow by doubling (`many`: 68 -> 54 MB).

Budget check (plan section "Hot path"): `size_of[ZipInfo]()` is 264 bytes; with the list slot and name index about 340 B per
entry at 100k entries (RSS delta), above the 200 B target of the plan. Shrinking it means narrower integer fields and not storing
`orig_filename` when it equals `filename`; it is an API-visible change, so it is left as a follow-up, not done silently.

Not met: the plan asked for `read_view` of a 1 GB STORED member to keep peak RSS near the touched pages through a mapping. Without
FFI there is no mmap, so the reader holds the whole archive: peak = archive size (265 MB for 256 MB, measured), still one copy
less than `read`.
