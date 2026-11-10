# Design

## Why native (no C)

The first plan used libz through `mojo-gzip` (`OwnedDLHandle`, a runtime dlopen of `libz.so.1`) and `mojo-mmap` (`external_call`).
Both are FFI: a clone build needs the system libz, a static link is not possible, and the library cannot run where `dlopen` is
unavailable. This lane replaces them: `src/deflate` is pure Mojo and `src/` holds no `DLHandle`, `external_call` or `dlopen`
(a gate step greps for them). The price is stated in `docs/perf.md`: no mmap, so the reader keeps the archive in memory.

## src/deflate

| File | What |
|---|---|
| `crc32.mojo` | slicing-by-8 over one comptime table in static memory; equals `zlib.crc32` |
| `inflate.mojo` | RFC 1951 decoder: 64-bit bit buffer, 10-bit first-level tables, canonical walk for longer codes, zlib's error texts, `max_out` limit, status (`END`, `LIMIT`, `INPUT`, `BAD`) |
| `deflate.mojo` | port of zlib 1.3.2 `deflate.c` + `trees.c` |

**Why a port and not a new encoder.** Byte identity with `zlib.compress` needs the same decisions everywhere: hash chains
(`INSERT_STRING`, `longest_match` including the compare window beyond the lookahead, `good`/`nice`/`chain`/`lazy` per level),
`deflate_fast` and `deflate_slow`, `TOO_FAR`, the 16383-symbol block split, Huffman tree building (`build_tree`, `gen_bitlen`
overflow repair, `gen_codes`), the static/dynamic/stored choice, and `fill_window` sliding with `high_water` zeroing (matches
can compare bytes past the lookahead, so the window contents must match too). The Mojo code keeps zlib's names and structure; the
only changes are data layout: trees are `[Freq/Code, Dad/Len]` word pairs in one `List[UInt16]` (zlib's `ct_data` unions
preserved), symbols live in two parallel arrays (zlib's `LIT_MEM` layout), no gzip/zlib wrappers, no strategies other than
default, no dictionaries or flush modes other than `Z_NO_FLUSH`/`Z_FINISH`.

**Level 0 is not a pure function of the input.** zlib's `deflate_stored` sizes stored blocks by `avail_out`, so the bytes depend
on how much output room the caller offers. CPython offers 32 KiB, then 64 KiB, 256 KiB, 1 MiB, 4 MiB ... (its blocks output
buffer). `deflate_raw` models `avail_out`/`next_out` and drives the same schedule: `stream=False` is `zlib.compress(..., wbits=-15)`
(one `Z_FINISH` call), `stream=True` is `compressobj(...)` fed the whole data (`Z_NO_FLUSH`) then `flush()`, which is what
`zipfile` does. Both are in the gate for every input size and level.

**zlib version.** The reference is the zlib 1.3.2 that CPython 3.14.9 runs here (`zlib.ZLIB_RUNTIME_VERSION`). Other zlib
releases changed block-split and stored-block details (1.2.12, 1.3.1); if the system zlib moves, rerun the gate: byte identity
is what it measures, and a mismatch names the first differing byte.

## src/zipfile

`ZipReader` and `ZipWriter` follow CPython 3.14.9 `Lib/zipfile/__init__.py` function by function (`_EndRecData`, `_EndRecData64`,
`_RealGetContents`, `_decodeExtra`, `ZipFile.open`, `ZipExtFile._read1`, `_open_to_write`, `_write_end_record`). Decisions:

- Error text is `<PythonClass>: <message>`; `inflate` errors are `error: zlib` and `UnicodeDecodeError` carries its kind only
  (the plan's contract). `repr` of names uses Python's own `isprintable` table (`tools/gen_printable.py`, Unicode 16.0).
- `read` ports `ZipExtFile.read(-1)` as a closed form: the CRC is checked when `compress_left` or `_left` reach zero or the
  decompressor reports eof; a file shorter than `compress_size` is `EOFError`; deflate is inflated with CPython's own call limit
  (2^31-1 bytes) and then cut to `file_size`, so corruption after `file_size` bytes still raises, as in CPython.
- Compression types: 0 and 8 only. CPython also reads 12, 14, 93 (bz2, lzma, zstd): those raise `NotImplementedError:
  compression type N (name)` with our text (tests/api.mojo, outside the oracle diff). Every other type raises
  `That compression method is not supported`, from `_check_compression`; the plan's `compression type %d (%s)` texts are
  unreachable in 3.14 (verified against the source and by oracle rows `ctype.*`).
- Writer: the whole member is compressed, then header + data are appended (CPython writes the header, the data, then seeks back
  and rewrites the header; the final bytes are the same). `zip64_limit` and `filecount_limit` are fields so tests can lower
  them the way CPython's own tests patch the module constants.
- The name index is an open-addressing table of `Int32` entry numbers (last duplicate wins, like `NameToInfo`), not a `Dict`:
  no second copy of the names.
- Known limits (also in the README): 64-bit sizes and offsets saturate at 2^61; the file is read whole (no mmap); encryption,
  append mode, `extract*`, streaming writes are not implemented.

## Gate

`scripts/check.sh` (output in `.work/native-gate.txt`): FFI grep; codec corpus vs zlib (`tools/codec_corpus.py`, runner
`tests/codec.mojo`, 2610 rows); oracle scenarios (`tools/gen_vectors.py` -> `tests/golden/vectors.txt`, replayed by
`tools/oracle.py` and `tests/cases.mojo`, diffed twice each); negative control (one static-tree length changed must fail).
`scripts/mutants.sh` (`tests/mutants.txt`) and `tools/fuzz.py` extend it. Verifiers are committed, nothing is throwaway.
