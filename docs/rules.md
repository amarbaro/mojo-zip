# Rules (what broke -> the rule)

- A pointer made with `_pu16(local_list)` is dead before the call that uses it: Mojo destroys a local at its last use, and an
  untracked pointer does not keep it alive -> keep scratch lists in a field of `self` (the static-tree init read freed memory and
  produced a different `0b00` for the empty input on every run).
- `Pointer(to=self.ct[0])` is not the list's storage -> take element pointers from `unsafe_ptr()`.
- Hand-rolled "it prints roughly like Python" tables drift: repr of unassigned code points differed in the first fuzz run -> generate
  the table from Python itself (`tools/gen_printable.py`) and rerun it on a Python bump.
- A mutant whose change the next branch repairs is not a gate gap (`static_lenb <= opt_lenb`): prove equivalence, drop it, write a
  real one.
- Fixed Huffman needs 32 distance codes (30 and 31 invalid at use), not 30: with 30 the table is incomplete and `build` returned
  before filling it, so every fixed block mis-decoded.
- Stored blocks after a 64-bit refill: stray look-ahead bits must be cleared before reading bytes straight from the input.
- zlib's `Z_NO_FLUSH` + `flush()` and one-shot `Z_FINISH` give the same bytes except at level 0, where stored-block size depends on
  `avail_out`: test both call shapes at level 0 on sizes around 32 KiB, 64 KiB and 1 MiB.
- Pre-sizing an output from a header field is a memory bomb on a mutated archive -> bound the hint by what the compressed bytes can
  expand to.
- `plan.md` text is a hypothesis until a row proves it: item 15's `compression type %d (%s)` text is unreachable in CPython 3.14
  (`_check_compression` raises first). Prefer oracle rows over plan prose.
