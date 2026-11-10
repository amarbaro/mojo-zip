# mojo-zip

<!-- badges -->
[![ci](https://github.com/amarbaro/mojo-zip/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/amarbaro/mojo-zip/actions/workflows/ci.yml) [![latest release](https://img.shields.io/github/v/release/amarbaro/mojo-zip)](https://github.com/amarbaro/mojo-zip/releases/latest) [![license](https://img.shields.io/github/license/amarbaro/mojo-zip)](https://github.com/amarbaro/mojo-zip/blob/main/LICENSE)
<!-- /badges -->

`zipfile` for Mojo, in pure Mojo: read and write ZIP archives (stored and deflated members, zip64, CRC-32, archive and
member comments) with CPython's `zipfile` behaviour. No C library and no FFI: the DEFLATE codec is a port of zlib, so the
bytes it writes are the bytes `zlib` writes at every level.

<!-- install -->
Install: `pixi workspace channel add https://conda.modular.com/max https://prefix.dev/amarbaro/amarbaro`, then `pixi add mojo-zip` (import `zipfile` and `deflate`). From source: `git clone https://github.com/amarbaro/mojo-zip`, then `mojo run -I mojo-zip/src app.mojo`.
Toolchains: Mojo 1.2 stable, and the nightly 1.3.0.dev2026110805 in the weekly [mojo-libs](https://github.com/amarbaro/mojo-libs) matrix.

```mojo
from zipfile import ZipReader, ZipWriter, ZIP_DEFLATED


def main() raises:
    var w = ZipWriter(ZIP_DEFLATED, 6)
    w.writestr("hello.txt", "hello zip, hello zip, hello zip".as_bytes())
    w.mkdir("docs")
    w.close()
    var z = ZipReader.from_bytes(w.to_bytes())
    print(String(unsafe_from_utf8=Span(z.read("hello.txt"))))
    print(len(z), z.infolist()[0].compress_size, z.testzip() == None)
```
<!-- /install -->

## What is in it

| Package | What |
|---|---|
| `zipfile` | `ZipReader` (`open`, `from_bytes`, `namelist`, `infolist`, `getinfo`, `read`, `read_view`, `testzip`), `ZipWriter` (`create`, `writestr`, `mkdir`, `set_comment`, `close`, `to_bytes`), `ZipInfo` |
| `deflate` | `deflate_raw` (zlib 1.3.2 algorithm, levels 0..9), `inflate_raw`, `inflate`, `crc32` |

The API is in [docs/api.md](docs/api.md), the design in [docs/design.md](docs/design.md), the numbers in [docs/perf.md](docs/perf.md).

Errors are `Error` values whose text is `<PythonClass>: <message>` exactly as CPython raises (`BadZipFile`, `KeyError`,
`LargeZipFile`, ...), so code ported from Python keeps its messages.

## Checks

`scripts/check.sh` runs the gate (full output in `.work/native-gate.txt`):

- no `DLHandle`, `external_call` or `dlopen` under `src`;
- 2610 codec rows against Python `zlib`: every level 0..9 byte-identical (one-shot and `compressobj`), inflate of
  zlib-made, truncated and bit-flipped streams;
- 230 golden rows in 11 oracle scenarios, each replayed through CPython `zipfile` (live) and through mojo-zip, dumps byte-identical;
- a negative control: a codec with one Huffman length off must fail.

`scripts/mutants.sh` flips one source line at a time and expects the oracle diff to notice (`tests/mutants.txt`).
`tools/fuzz.py` runs mutated archives through both sides. Design notes: `docs/design.md`; numbers: `docs/perf.md`.

## Known limits

Not covered: encryption, bzip2/lzma/zstd members (read or write: `NotImplementedError` with its own text), append mode,
in-place `remove`, streaming `open(..., 'w')`, `extract*`, `Path`, `metadata_encoding`, `printdir`, `is_zipfile`.
The reader holds the whole archive in memory (no mmap without FFI). 64-bit sizes and offsets saturate at 2^61.

## Licence

Apache-2.0 (`LICENSE`). Behaviour, field layout and error texts are ported from CPython `Lib/zipfile` (Python Software
Foundation License 2.0, `LICENSE-python`). `src/deflate/deflate.mojo` ports the DEFLATE algorithm of zlib 1.3.2
(Copyright (C) 1995-2026 Jean-loup Gailly and Mark Adler, zlib licence, `LICENSE-zlib`).
