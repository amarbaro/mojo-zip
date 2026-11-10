# mojo-zip API

Two packages: `zipfile` (archive reader and writer) and `deflate` (raw DEFLATE codec and CRC-32). Every name below is
exported by `src/zipfile/__init__.mojo` or `src/deflate/__init__.mojo`. Errors are `Error` values whose text is
`<PythonClass>: <message>`, the class and message CPython's `zipfile` and `zlib` raise; match with `String(err)`.
"Raises" lists the texts the code can produce.

## zipfile

```mojo
from zipfile import ZipReader, ZipWriter, ZipInfo, make_dt
from zipfile import ZIP_STORED, ZIP_DEFLATED, ZIP64_LIMIT, ZIP_FILECOUNT_LIMIT, ZIP_MAX_COMMENT
```

### Constants

| Name | Value | Meaning |
|---|---|---|
| `ZIP_STORED` | 0 | no compression |
| `ZIP_DEFLATED` | 8 | DEFLATE (the zlib port in `deflate`) |
| `ZIP64_LIMIT` | 2^31 - 1 | size and offset above which zip64 records are used |
| `ZIP_FILECOUNT_LIMIT` | 65535 | member count above which zip64 is needed |
| `ZIP_MAX_COMMENT` | 65535 | longest archive comment; longer ones are cut |

### `ZipReader`

Holds the whole archive in memory (`data`), parses the central directory on construction, and keeps a name index
(the last duplicate name wins, as in CPython).

| Call | What | Raises |
|---|---|---|
| `ZipReader(var data: List[UInt8]) raises` | Parse an archive held in memory. | `BadZipFile: File is not a zip file`, `Bad offset for central directory`, `Truncated central directory`, `Bad magic number for central directory`, zip64 record errors, `Corrupt extra field ...`, `Corrupt zip64 extra field. <field> not found.`, `Corrupt unicode path extra field (0x7075)`, `NotImplementedError: zip file version N.N` |
| `ZipReader.from_bytes(var data: List[UInt8]) raises -> ZipReader` | Same as the constructor. | as above |
| `ZipReader.open(path: String) raises -> ZipReader` | Read the file in one allocation, then parse it. | the file error from `open`, plus the constructor's |
| `len(z)` | Number of members (`Sized`). | |
| `z.namelist() -> List[String]` | Member names in archive order. | |
| `z.infolist() -> ref List[ZipInfo]` | The entries, by reference, no copy. | |
| `z.getinfo(name: String) raises -> ZipInfo` | The entry for `name`. | `KeyError: There is no item named '<name>' in the archive` |
| `z.read(name: String) raises -> List[UInt8]` | Inflate and CRC-check one member. | `KeyError`, `ValueError: negative seek value N`, `BadZipFile: Truncated file header`, `Bad magic number for file header`, `File name in directory ... and header ... differ.`, `Overlapped entries: ... (possible zip bomb)`, `Bad CRC-32 for file '<name>'`, `RuntimeError: File '<name>' is encrypted, password required for extraction`, `NotImplementedError: compression type 12 (bzip2)` / `14 (lzma)` / `93 (zstd)` / `That compression method is not supported`, `compressed patched data (flag bit 5)`, `strong encryption (flag bit 6)`, `EOFError`, `error: zlib` |
| `z.read_view(name: String) raises -> Span[UInt8, ...]` | A STORED member as a view into the archive bytes, no copy, CRC checked. The span lives as long as `z`. | the `read` errors, and `NotImplementedError: read_view needs a STORED member` |
| `z.testzip() raises -> Optional[String]` | Name of the first member (archive order) whose read fails with `BadZipFile`, else `None`. | |

Fields: `data`, `infos`, `comment: List[UInt8]` (archive comment), `start_dir: Int`.

### `ZipWriter`

Builds an archive in memory (`ZipWriter(...)`, then `to_bytes`) or writes one file at `close` (`ZipWriter.create`).
Member data is compressed when `writestr` is called.

| Call | What | Raises |
|---|---|---|
| `ZipWriter(compression: Int = ZIP_STORED, compresslevel: Int = -1, allow_zip64: Bool = True)` | In-memory writer; `compression` and `compresslevel` are the defaults for members. | |
| `ZipWriter.create(path: String, compression = ZIP_STORED, compresslevel = -1, allow_zip64 = True) raises -> ZipWriter` | Writer whose archive goes to `path` on `close`. | |
| `w.writestr(name: String, data: Span[UInt8, _], compress_type: Int = -1, compresslevel: Int = -2, date_time = make_dt(0,0,0,0,0,0)) raises` | Add a member as `ZipFile.writestr(name, data)` does. A `compress_type` of -1 uses the writer's default; `date_time` year 0 means `SOURCE_DATE_EPOCH` if set, else 1980-01-01. | `ValueError: Attempt to write to ZIP archive that was already closed`, `ValueError: ZIP does not support timestamps before 1980`, `ValueError: Invalid initialization option` (bad level), `NotImplementedError: compression type 12 (bzip2)` / `14 (lzma)` / `93 (zstd)` / `That compression method is not supported`, `LargeZipFile: Filesize would require ZIP64 extensions` (also `Files count`, `Zipfile size`), `RuntimeError: File size too large, try using force_zip64`, `Compressed size too large, ...` |
| `w.writestr(var info: ZipInfo, data: Span[UInt8, _]) raises` | Add a member using the info's own type, level, attributes and date. | as above |
| `w.mkdir(name: String, mode: Int = 511) raises` | Add a directory entry (`/` appended when missing). | as `writestr` |
| `w.set_comment(comment: Span[UInt8, _])` | Archive comment, cut at `ZIP_MAX_COMMENT`. | |
| `w.close() raises` | Write the central directory and end records; to the file for a `create` writer. A second `close` does nothing. | `LargeZipFile` errors, file errors |
| `w.to_bytes() raises -> List[UInt8]` | A copy of the archive bytes (after `close`). | `ValueError: to_bytes needs an in-memory writer` |

Fields: `compression`, `compresslevel`, `allow_zip64`, `comment`, and the limits `zip64_limit`, `filecount_limit`
(the real constants by default; tests lower them as CPython's tests do).

### `ZipInfo`

One member's record, with CPython's field names and meanings.

`ZipInfo(filename: String = "NoName", date_time: Array[Int, 6] = make_dt()) raises` raises
`ValueError: ZIP does not support timestamps before 1980`. The name is cut at the first NUL.

| Field | Type | Note |
|---|---|---|
| `orig_filename`, `filename` | `String` | name as stored, name with the NUL cut |
| `date_time` | `Array[Int, 6]` | year, month, day, hour, minute, second |
| `compress_type`, `compress_level` | `Int` | `compress_level` -1 is Python's `None` |
| `comment`, `extra` | `List[UInt8]` | member comment, extra field bytes |
| `create_system`, `create_version`, `extract_version`, `reserved`, `flag_bits`, `volume` | `Int` | header fields |
| `internal_attr`, `external_attr`, `header_offset` | `Int` | |
| `CRC` | `UInt32` | |
| `compress_size`, `file_size` | `Int` | 64-bit sizes saturate at 2^61 |

`zi.is_dir() -> Bool`: `filename` ends with `/`.

`encode_name_flags`, `file_header` and `decode_extra` are the codec of the header records; they are used by the
reader and writer and are not part of the API.

### `make_dt`

`make_dt(y = 1980, mo = 1, d = 1, h = 0, mi = 0, s = 0) -> Array[Int, 6]`: a `date_time` value.

## deflate

```mojo
from deflate import crc32, inflate, inflate_raw, InflateResult, deflate_raw
from deflate import INF_END, INF_LIMIT, INF_INPUT, INF_BAD
```

| Call | What | Raises |
|---|---|---|
| `deflate_raw(data: Span[UInt8, _], level: Int = -1, stream: Bool = False) raises -> List[UInt8]` | Raw DEFLATE of `data`, byte-identical with zlib 1.3.2. Level -1 is 6, 0 is stored, 1..9 as zlib. `stream=False` equals `zlib.compress(data, level, wbits=-15)`; `stream=True` equals `zlib.compressobj(level, DEFLATED, -15)` fed all of `data` then flushed (what `zipfile` does). | `ValueError: Invalid initialization option` (`stream=True`), `error: Bad compression level` (`stream=False`) for a level outside -1..9 |
| `inflate(src: Span[UInt8, _], size_hint: Int = 0) raises -> List[UInt8]` | The whole inflated stream; bytes after the end are ignored. | `Error -3 while decompressing data: <zlib text>`, `Error -5 while decompressing data: incomplete or truncated stream` |
| `inflate_raw(src: Span[UInt8, _], max_out: Int = -1, size_hint: Int = 0) -> InflateResult` | Inflate without raising; `max_out >= 0` stops after that many bytes. | never; read `status` |
| `crc32(data: Span[UInt8, _], start: UInt32 = 0) -> UInt32` | CRC-32 as `zlib.crc32(data, start)`. | |

`InflateResult` fields: `out: List[UInt8]` (bytes produced), `status: Int`, `consumed: Int` (input bytes used; a partly
used last byte counts as used), `msg: String` (zlib's text when `status` is `INF_BAD`).

| Status | Value | Meaning |
|---|---|---|
| `INF_END` | 0 | final block finished |
| `INF_LIMIT` | 1 | `max_out` bytes produced, stream not finished |
| `INF_INPUT` | 2 | input ended inside the stream |
| `INF_BAD` | 3 | corrupt stream, `msg` says why |
