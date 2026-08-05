# PaperTape `.Tape` format versions

This document describes the on-disk **write dialects** for `.Tape` files (v1–v6), how they differ, and **approximate file size** impact.

Readers in current PaperTape accept any version they understand (Unicode and ASCII glyphs are both recognized when parsing; v4 ternary; v5 quaternary; v6 octal).

For app usage and build instructions, see [README.md](README.md). App version: **1.10.3**.

---

## Pipeline (shared)

```
original bytes → [compress] → [Base85] → [dense pack if v4/v5/v6] → column tokens → .Tape text
```

- **v1–v3**: one binary byte → one column (8 bits/column).
- **v4**: binary payload packed into base-6561 digits (~12.68 bits/column).
- **v5**: binary payload packed as 2 bytes → 1 column (**16 bits/column**).
- **v6**: binary payload packed as 3 bytes → 1 column (**24 bits/column**).

Compression codecs and integrity math (CRC-32 + XOR + SUM8) apply in all dialects. Multi-state integrity uses the packed column value (v4/v5: LE `UInt16`; v6: LE 3-byte 24-bit value).

---

## Version summary

| | **v1** | **v2** | **v3** | **v4 ternary** | **v5 quat** | **v6 octal** (default) |
|--|--------|--------|--------|----------------|-------------|-------------------------|
| Header | `v1` | `v2` | `v3` | `v4` | `v5` | `v6` |
| `# columns:` | `annotated` | `compact` | `ascii` | `ternary` | `quaternary` | `octal` |
| Channel states | 2 | 2 | 2 | **3** | **4** | **8** |
| Glyphs | `●·○` | `●·○` | `* . o` | `* + . o` | `* = + . o` | `* % x = + : , . o` |
| Example | `··●○·●·●·` | same | `...o*.*.*` | `..+o*+.*+` | `.=+o*=+.*` | `.,:o+=x%*` |
| Packing | 1 B/col | 1 B/col | 1 B/col | ~12.68 b/col | **16 b/col** | **24 b/col** |
| Annotations | yes | — | — | — | — | — |
| Preview footer | yes | — | — | — | — | — |
| Integrity | 1 B | 1 B | 1 B | UInt16 | UInt16 | 3 B |

**Token layout** (always 9 characters; ch1 = least-significant digit or bit):

```
ch1  ch2  ch3  feed  ch4  ch5  ch6  ch7  ch8
```

### Glyph tables

**v1 / v2 (Unicode, multi-byte UTF-8)**

| Role | Character | Typical UTF-8 size |
|------|-----------|--------------------|
| Hole (bit = 1) | `●` | 3 bytes |
| Blank (bit = 0) | `·` | 2 bytes |
| Sprocket / feed | `○` | 3 bytes |

**v3 (ASCII binary, 1 byte each)**

| Role | Character | UTF-8 size |
|------|-----------|------------|
| Hole | `*` | 1 byte |
| Blank | `.` | 1 byte |
| Sprocket | `o` | 1 byte |

**v4 (ASCII ternary, 1 byte each)**

| Role | Character | Trit | UTF-8 size |
|------|-----------|------|------------|
| Full | `*` | 2 | 1 byte |
| Mid | `+` | 1 | 1 byte |
| Blank | `.` | 0 | 1 byte |
| Sprocket | `o` | — | 1 byte |

Column value: \(V = \sum_{i=0}^{7} d_i \cdot 3^i\) with \(d_i \in \{0,1,2\}\), so \(V \in [0, 6560]\) and there are \(3^8 = 6561\) states per column.

**v5 (ASCII quaternary, 1 byte each)**

| Role | Character | Level | UTF-8 size |
|------|-----------|-------|------------|
| Full | `*` | 3 | 1 byte |
| Medium | `=` | 2 | 1 byte |
| Shallow | `+` | 1 | 1 byte |
| Blank | `.` | 0 | 1 byte |
| Sprocket | `o` | — | 1 byte |

Column value: \(V = \sum_{i=0}^{7} d_i \cdot 4^i\) with \(d_i \in \{0,1,2,3\}\), so \(V \in [0, 65535]\) and there are \(4^8 = 65536 = 2^{16}\) states per column.

**v6 (ASCII octal, 1 byte each)**

| Role | Character | Level | UTF-8 size |
|------|-----------|-------|------------|
| Full | `*` | 7 | 1 byte |
| | `%` | 6 | 1 byte |
| | `x` | 5 | 1 byte |
| | `=` | 4 | 1 byte |
| | `+` | 3 | 1 byte |
| | `:` | 2 | 1 byte |
| | `,` | 1 | 1 byte |
| Blank | `.` | 0 | 1 byte |
| Sprocket | `o` | — | 1 byte |

Column value: \(V = \sum_{i=0}^{7} d_i \cdot 8^i\) with \(d_i \in \{0…7\}\), so \(V \in [0, 16\,777\,215]\) and there are \(8^8 = 16\,777\,216 = 2^{24}\) states per column.

**Important:** `#` is reserved for comments and `@block` markers — it is **not** a hole glyph (v6 uses `%` for level 6).

---

## v6 packing (default write, densest)

Every three consecutive payload bytes become one column (big-endian triple → 24-bit value). Remainder 1 or 2 bytes pad into a final column (high-aligned). Packing is **O(n)** with no big-integer conversion.

Headers:

```
# packing: oct
# packing-base: 16777216
# channel-states: 8
# columns: octal
# punched-size: <binary byte count before pack>
# octal-columns: <column count>
# pack-chunk: 0
# glyphs: *=7 %=6 x=5 ==4 +=3 :=2 ,=1 .=0 o=sprocket
```

Streams and folder archives use the same triple packing (`packing=oct` on `# @file` when applicable). Density: **exactly 24 bits per column** → **⌈N/3⌉** columns for N punched bytes.

---

## v5 packing

Every two consecutive payload bytes become one column (big-endian pair → `UInt16` value). An odd final byte becomes a single high-byte column. Packing is **O(n)** with no big-integer conversion.

Headers:

```
# packing: quat
# packing-base: 65536
# channel-states: 4
# columns: quaternary
# punched-size: <binary byte count before pack>
# quaternary-columns: <column count>
# pack-chunk: 0
# glyphs: *=full ==med +=shallow .=blank o=sprocket
```

Streams and folder archives use the same pair-wise packing (`packing=quat` on `# @file` when applicable). Density: **exactly 16 bits per column** → **⌈N/2⌉** columns for N punched bytes.

---

## v4 packing

### Full packing (`# packing: full`)

1. Take the punched binary payload (after compress / Base85) as a **big-endian integer**.
2. Convert to base **6561** digits (least-significant digit first).
3. Each digit is one ternary column.

Information density approaches \(\log_2 6561 \approx 12.684\) bits per column (~**58% more** data per column than binary 8-bit punch).

Headers:

```
# packing: full
# packing-base: 6561
# channel-states: 3
# punched-size: <binary byte count before ternary pack>
# ternary-columns: <column count>
# pack-chunk: 0
```

`pack-chunk: 0` means the **whole payload** is one integer (densest). Used when the punched payload is modest (≤ ~24 KiB).

Larger payloads set `# pack-chunk: 4096` and full-pack each 4 KiB chunk with a fixed digit width. That stays near peak density (~12.68 bits/col) while packing in **linear time** — whole-file integer conversion is O(n²) and would freeze the app on multi-100 KB files.

### Stream packing (`# packing: block3`)

For multi-GB / streaming writes, full big-integer conversion is impractical. Streams use **block3**: every 3 bytes → 2 columns (exactly 12 bits/column, ~5% less dense than full, O(1) memory).

```
# packing: block3
```

Folder archives: whole-file members use `packing=full` on each `# @file` line; streamed members use `packing=block3`.

---

## What is *not* versioned away

These appear in all dialects when applicable:

- Header metadata (`name`, `size`, `punched-size`, `compression`, `transfer`, `block-size`, `integrity`, `mode`, …)
- `# @block N off=… len=… crc32=… xor=… sum8=…` every 64 columns (default)
- Folder archives: `# @file` / `# @endfile` members
- Stream / archive trailers as comment lines

Parsing ignores trailing `# …` comments on column lines, so **v1 annotations are optional for readers**.

---

## Approximate file size

Sizes below are for the **`.Tape` text file** when the strip holds **raw** punched bytes (no payload compression, no Base85). Real files also grow or shrink if you enable **Compress** or **Base85** on the *payload* before packing—that is independent of format version.

### Per-column body cost (token + newline)

| Format | ≈ bytes per column line | Bits of payload / column |
|--------|-------------------------|---------------------------|
| **v1** | ~**33** B (Unicode + annotation) | 8 |
| **v2** | ~**24** B (Unicode token) | 8 |
| **v3** | ~**10** B (ASCII 9-char + `\n`) | 8 |
| **v4** | ~**10** B (ASCII 9-char + `\n`) | **~12.68** |
| **v5** | ~**10** B (ASCII 9-char + `\n`) | **16** |
| **v6** | ~**10** B (ASCII 9-char + `\n`) | **24** |

v3–v6 share the same **per-column text cost**; denser packing needs **fewer columns** (v4 ~0.63×, v5 **0.5×**, v6 **~0.33×** vs binary).

### Relative body size (raw payload, large N)

| | vs binary columns | vs v3 file size (same payload) |
|--|-------------------|--------------------------------|
| **v3** | 1.0× columns | 100% |
| **v4 full** | ~**0.63×** columns | ~**63%** of v3 |
| **v4 block3** | ~**0.67×** columns | ~**67%** of v3 |
| **v5 quat** | **0.5×** columns | ~**50%** of v3 |
| **v6 oct** | **~0.33×** columns | ~**33%** of v3 |

### Full-file rough sizes (header + `@block` + body)

Illustrative estimates for **uncompressed payload** punched raw:

| Payload | ≈ raw | ≈ v3 | ≈ v4 | ≈ v5 | ≈ v6 | v6 / v3 |
|---------|-------|------|------|------|------|---------|
| Short (~19 B) | 19 B | ~0.7 KB | ~0.5 KB | ~0.4 KB | ~0.3 KB | ~40% |
| 1 KiB text | 1 KiB | ~12 KB | ~7.5 KB | ~6 KB | ~4 KB | ~33% |
| 64 KiB mixed | 64 KiB | ~0.7 MB | ~0.44 MB | ~0.35 MB | ~0.23 MB | ~33% |

**Rules of thumb**

1. **v1 → v3**: ASCII + drop notes/preview → often **~65–70% smaller**.
2. **v3 → v4**: fewer columns via ternary → often **~35–40% smaller** than v3.
3. **v3 → v5**: half the columns → often **~half** the v3 body.
4. **v3 → v6**: one-third the columns → often **~one-third** the v3 body.
5. **With Auto compression**, payload columns shrink first; format savings still apply on the remaining punched length.

---

## Choosing a version

| Choose | When |
|--------|------|
| **v6 octal** | **Default**; densest (24 bits/col); eight calibrated depths |
| **v5 quaternary** | Four-state channels (16 bits/col) |
| **v4 ternary** | Three-state channels + base-6561 (~12.68 bits/col) |
| **v3 ASCII** | Binary 1:1 columns; simple ASCII `* . o` |
| **v2 visual** | Unicode “paper” look in the file, without annotation clutter |
| **v1 annotated** | Human debugging; character/hex notes + terminal-paper preview footer |

### Note on “7-bit-safe”

v3–v6 make the **punched column lines** pure ASCII. That does **not** guarantee the whole file is 7-bit: `# name:`, `# note:`, and archive `# @file path="…"` values are still UTF-8 and may include non-ASCII characters from real filenames.

In the app: **Format** picker (**v6 octal** / **v5 quaternary** / **v4 ternary** / **v3 ASCII** / **v2 visual** / **v1 annotated**).

### Suggested filenames

Encode / Save panels suggest a name that includes the write dialect:

```
<source-stem>-v<N>.Tape
```

Examples: `letter-v6.Tape`, `backup-v3.Tape`, `MyFolder-v4.Tape`.

A trailing `-v1`…`-v6` on the stem is replaced when re-saving under a different format. The on-disk `# PaperTape File vN` header is authoritative for readers; the filename suffix is a convenience only.

---

## Minimal skeletons

### v6 (default)

```
# PaperTape File v6
# name: example.txt
# size: N
# punched-size: M
# compression: none
# transfer: identity
# block-size: 64
# integrity: crc32+xor+sum8
# columns: octal
# channels: 8
# bit-order: channel-1-lsb
# layout: ch1 ch2 ch3 feed ch4 ch5 ch6 ch7 ch8
# glyphs: *=7 %=6 x=5 ==4 +=3 :=2 ,=1 .=0 o=sprocket
# packing: oct
# packing-base: 16777216
# channel-states: 8
# octal-columns: K
# pack-chunk: 0
# ---
# @block 0 off=0 len=… crc32=… xor=… sum8=…
.,:o+=x%*
…
```

### v5

Same idea with `v5`, `# columns: quaternary`, packing `quat`, glyphs `* = + . o`.

### v4

Same idea with `v4`, `# columns: ternary`, packing `full` / `block3`, glyphs `* + . o`.

### v3

Same idea with `v3`, `# columns: ascii`, binary `* . o` tokens, no packing headers.

### v2 visual

Same as v3 with `v2`, `# columns: compact`, Unicode glyphs.

### v1

Same as v2 with `v1`, `# columns: annotated`, annotated column lines, and a trailing terminal paper preview section.

---

## Related

- [README.md](README.md) — features, usage, build (app **1.10.3**)
- [CHANGELOG.md](CHANGELOG.md) — release history
- `Examples/*.Tape` — sample files (`message-v6.Tape`, `message-v5.Tape`, etc.)


Suggested filename: `payload-v5.Tape`.
