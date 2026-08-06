# PaperTape `.Tape` format versions

This document describes the on-disk **write dialects** for `.Tape` files (v1–v8), how they differ, and **approximate file size** impact.

Readers accept any known version (v4 ternary … v8 base-256).

For app usage and build instructions, see [README.md](README.md). App version: **1.12.1**.

---

## Pipeline (shared)

```
original bytes → [compress] → [Base85] → [dense pack if v4–v8] → column tokens → .Tape text
```

- **v1–v3**: 1 byte → 1 column (8 bits/col).
- **v4**: base-6561 (~12.68 bits/col).
- **v5**: 2 bytes → 1 column (**16** bits).
- **v6**: 3 bytes → 1 column (**24** bits).
- **v7**: 4 bytes → 1 column (**32** bits).
- **v8**: 8 bytes → 1 column (**64** bits).

Integrity (CRC-32 + XOR + SUM8) uses the packed column value: v1–v3 1 B; v4/v5 LE UInt16; v6 3 B; v7 4 B; **v8 8 channel bytes**.

---

## Version summary

| | v1–v3 | v4 | v5 | v6 | **v7** (default) | v8 base-256 — experimental maximum density |
|--|-------|----|----|----|------------------|---------------------------------------------|
| `# columns:` | annotated/compact/ascii | ternary | quaternary | octal | **hexadecimal** | base256 |
| Channel states | 2 | 3 | 4 | 8 | 16 | **256** |
| Bits/col | 8 | ~12.68 | 16 | 24 | 32 | **64** |
| Bytes/col | 1 | ~0.63 | 2 | 3 | 4 | **8** |
| Token | 9 glyphs | 9 glyphs | 9 glyphs | 9 glyphs | 9 glyphs | **17 hex+`o`** |
| Integrity | 1 B | UInt16 | UInt16 | 3 B | 4 B | **8 B** |

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

**v7 (ASCII hexadecimal, 1 byte each)**

| Level | Glyph | Level | Glyph |
|------:|:-----:|------:|:-----:|
| 0 | `.` | 8 | `b` |
| 1 | `,` | 9 | `c` |
| 2 | `:` | 10 | `d` |
| 3 | `+` | 11 | `e` |
| 4 | `=` | 12 | `f` |
| 5 | `x` | 13 | `g` |
| 6 | `%` | 14 | `@` |
| 7 | `a` | 15 | `*` full |

Feed / sprocket: `o`. Column value \(V = \sum_{i=0}^{7} d_i \cdot 16^i\) with \(d_i \in \{0…15\}\) → \(16^8 = 2^{32}\) states.

---

## v8 packing — experimental maximum density

Each channel is a full byte (0…255). Eight channels → \(256^8 = 2^{64}\) states → **exactly 8 payload bytes per column**.

**v8 base-256 — experimental maximum density.** Not the default write format (that is **v7 hexadecimal**). At 256 levels, holes are continuous **grayscale** intensities rather than a few discrete punch depths. The strip still uses the classic 8-channel + feed layout; on-disk tokens use **two hex digits per channel** because a single ASCII glyph cannot encode 256 values.

Example token: `a3f201o00ffc80011` (ch1=0xA3 … ch3=0x01, feed `o`, ch4…ch8).

Headers:

```
# packing: b256
# packing-base: 18446744073709551616
# channel-states: 256
# columns: base256
# punched-size: <binary byte count before pack>
# base256-columns: <column count>
# pack-chunk: 0
# glyphs: hex-pairs 00-ff per channel, o=sprocket (256 levels=grayscale byte)
# note: base-256 — each channel is a grayscale byte (0–255); 8 bytes/column
```

Streams and archives use `packing=b256`. Density: **⌈N/8⌉** columns for N punched bytes.

---

## v7 packing

Every four consecutive payload bytes become one column (big-endian quad → `UInt32`). Short remainder high-aligns (low bytes zero). Packing is **O(n)**.

Headers:

```
# packing: hex
# packing-base: 4294967296
# channel-states: 16
# columns: hexadecimal
# punched-size: <binary byte count before pack>
# hexadecimal-columns: <column count>
# pack-chunk: 0
# glyphs: *=15 @=14 g=13 … .=0 o=sprocket (16 depths)
```

Streams and folder archives use the same quad packing (`packing=hex`). Density: **exactly 32 bits per column** → **⌈N/4⌉** columns for N punched bytes.

---

## v6 packing

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
| **v7** | ~**10** B (ASCII 9-char + `\n`) | **32** |
| **v8** | ~**18** B (16 hex + `o` + `\n`) | **64** |

v3–v7 share ~10 B/col text cost; **v8** tokens are longer (~18 B) but still win on large N because of 8× fewer columns.

### Relative body size (raw payload, large N)

| | vs binary columns | vs v3 body (large N) |
|--|-------------------|----------------------|
| **v3** | 1.0× | 100% |
| **v5** | 0.5× | ~50% |
| **v6** | ~0.33× | ~33% |
| **v7** | 0.25× | ~25% |
| **v8** | **0.125×** | **~20–25%** (longer tokens offset some savings) |

**Rules of thumb**

1. **v1 → v3**: often **~65–70% smaller**.
2. **v3 → v8**: about **⅛** the columns; body often **~⅕–¼** of v3 despite longer tokens.
3. **With Auto compression**, format savings apply to the remaining punched length.

---

## Choosing a version

| Choose | When |
|--------|------|
| **v7 hexadecimal** | **Default**; 16 discrete depths (32 bits/col); multilevel-punch look |
| **v8 base-256 — experimental maximum density** | Densest (64 bits/col); grayscale “byte grid” aesthetic |
| **v6 octal** | Eight depths (24 bits/col) |
| **v5 quaternary** | Four depths (16 bits/col) |
| **v4 ternary** | Three depths (~12.68 bits/col) |
| **v3 ASCII** | Binary 1:1 columns |
| **v2 / v1** | Unicode visual / annotated debugging |

### Note on “7-bit-safe”

v3–v8 make the **punched column lines** pure ASCII. Header names and archive paths may still be UTF-8.

In the app: **Format** picker lists **v1…v8** in version order (default write is **v7 hexadecimal**; v8 is experimental maximum density).

### Suggested filenames

```
<source-stem>-v<N>.Tape
```

Examples: `letter-v8.Tape`, `backup-v3.Tape`. A trailing `-v1`…`-v8` is replaced on re-save.

---

## Minimal skeletons

### v7 (default)

```
# PaperTape File v7
# name: example.txt
# size: N
# punched-size: M
# compression: none
# transfer: identity
# block-size: 64
# integrity: crc32+xor+sum8
# columns: hexadecimal
# channels: 8
# bit-order: channel-1-lsb
# layout: ch1 ch2 ch3 feed ch4 ch5 ch6 ch7 ch8
# glyphs: .,:+=x%abcdefg@*  o=sprocket (16 depths)
# packing: hex
# packing-base: 4294967296
# channel-states: 16
# hexadecimal-columns: K
# pack-chunk: 0
# ---
# @block 0 off=0 len=… crc32=… xor=… sum8=…
.:+o=xa%*
…
```

### v8 base-256 — experimental maximum density

```
# PaperTape File v8
# name: example.txt
# size: N
# punched-size: M
# compression: none
# transfer: identity
# block-size: 64
# integrity: crc32+xor+sum8
# columns: base256
# channels: 8
# bit-order: channel-1-lsb
# layout: ch1 ch2 ch3 feed ch4 ch5 ch6 ch7 ch8
# glyphs: hex-pairs 00-ff per channel, o=sprocket (256 levels=grayscale byte)
# packing: b256
# packing-base: 18446744073709551616
# channel-states: 256
# base256-columns: K
# pack-chunk: 0
# note: base-256 — each channel is a grayscale byte (0–255); 8 bytes/column
# ---
# @block 0 off=0 len=… crc32=… xor=… sum8=…
a3f201o00ffc80011
…
```

### v6

Same idea with `v6`, `# columns: octal`, packing `oct`, glyphs `* % x = + : , . o`.

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

- [README.md](README.md) — features, usage, build (app **1.12.1**)
- [CHANGELOG.md](CHANGELOG.md) — release history
- `Examples/*.Tape` — sample files (`message-v8.Tape`, `message-v7.Tape`, etc.)


Suggested filename: `payload-v5.Tape`.
