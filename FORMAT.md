# PaperTape `.Tape` format versions

This document describes the on-disk **write dialects** for `.Tape` files (**v1–v9**), how they differ, and **approximate file size** impact.

| | |
|--|--|
| **Readers** | Accept any known version (**v1…v9**) |
| **Default write** | **v7 hexadecimal** |
| **Experimental** | **v8 base-256 — experimental maximum density** |
| **App** | **1.12.2** — see [README.md](README.md) for usage and build |

Format picker order in the app: **v1 → v2 → v3 → v4 → v5 → v6 → v7 → v8 → v9** (version order). Selection default is still **v7**.

---

## Pipeline (shared)

```
original bytes → [compress] → [Base85] → [pack if v4–v9] → column tokens → .Tape text
```

| Version | Packing density |
|---------|-----------------|
| **v1–v3** | 1 byte → 1 column (**8** bits/col) |
| **v4** | base-6561 (~**12.68** bits/col) |
| **v5** | 2 bytes → 1 column (**16** bits) |
| **v6** | 3 bytes → 1 column (**24** bits) |
| **v7** (default) | 4 bytes → 1 column (**32** bits) |
| **v8** (experimental) | 8 bytes → 1 column (**64** bits) |
| **v9** | 9 bits → 1 column (512 states) |

Integrity (CRC-32 + XOR + SUM8) uses the packed column value:

| Versions | Integrity unit |
|----------|----------------|
| v1–v3 | 1 byte (the punched byte) |
| v4 / v5 | LE `UInt16` |
| v6 | 3 bytes |
| v7 | 4 bytes |
| v8 | 8 channel bytes |
| v9 | LE `UInt16` (9-bit symbol) |

---

## Version summary

| | v1 | v2 | v3 | v4 | v5 | v6 | **v7** (default) | v8 experimental | v9 Base512 |
|--|----|----|----|----|----|----|------------------|-----------------| ------------ |
| `# columns:` | annotated | compact | ascii | ternary | quaternary | octal | **hexadecimal** | base256 | base512 |
| Channel states | 2 | 2 | 2 | 3 | 4 | 8 | **16** | 256 | 2 |
| Bits/col | 8 | 8 | 8 | ~12.68 | 16 | 24 | **32** | **64** | 9 |
| Bytes/col | 1 | 1 | 1 | ~0.63 | 2 | 3 | **4** | **8** | 1.125 |
| Token | 9 Unicode | 9 Unicode | 9 ASCII | 9 ASCII | 9 ASCII | 9 ASCII | **9 ASCII** | **17 hex+`o`** | 10 ASCII |
| Integrity | 1 B | 1 B | 1 B | UInt16 | UInt16 | 3 B | **4 B** | **8 B** | 2 B |
| Annotations | Yes | No | No | No | No | No | No | No | No |
| Terminal preview | Yes | No | No | No | No | No | No | No | No |

### Physical / token layout

Channels are laid out left → right as (ch9 only in v9):

```
ch1  ch2  ch3  feed  ch4  ch5  ch6  ch7  ch8  [ch9]
```

- **ch1** = least-significant digit / bit (LSB).
- **feed** is always punched (not payload).
- **v1–v7:** one character per channel + feed → **9-character** tokens.
- **v8:** two hex digits per data channel + feed `o` → **17-character** tokens.
- **v9:** nine binary data glyphs plus feed `o` → **10-character** tokens.

---

## Glyph tables

### v1 / v2 (Unicode, multi-byte UTF-8)

| Role | Character | Typical UTF-8 size |
|------|-----------|--------------------|
| Hole (bit = 1) | `●` | 3 bytes |
| Blank (bit = 0) | `·` | 2 bytes |
| Sprocket / feed | `○` | 3 bytes |

### v3 (ASCII binary)

| Role | Character | UTF-8 size |
|------|-----------|------------|
| Hole | `*` | 1 byte |
| Blank | `.` | 1 byte |
| Sprocket | `o` | 1 byte |

### v4 (ASCII ternary)

| Role | Character | Trit | UTF-8 size |
|------|-----------|------|------------|
| Full | `*` | 2 | 1 byte |
| Mid | `+` | 1 | 1 byte |
| Blank | `.` | 0 | 1 byte |
| Sprocket | `o` | — | 1 byte |

Column value: \(V = \sum_{i=0}^{7} d_i \cdot 3^i\) with \(d_i \in \{0,1,2\}\) → \(3^8 = 6561\) states.

### v5 (ASCII quaternary)

| Role | Character | Level | UTF-8 size |
|------|-----------|-------|------------|
| Full | `*` | 3 | 1 byte |
| Medium | `=` | 2 | 1 byte |
| Shallow | `+` | 1 | 1 byte |
| Blank | `.` | 0 | 1 byte |
| Sprocket | `o` | — | 1 byte |

Column value: \(V = \sum_{i=0}^{7} d_i \cdot 4^i\) → \(4^8 = 2^{16}\) states.

### v6 (ASCII octal)

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

Column value: \(V = \sum_{i=0}^{7} d_i \cdot 8^i\) → \(8^8 = 2^{24}\) states.

**Important:** `#` is reserved for comments and `@block` markers — it is **not** a hole glyph (v6 uses `%` for level 6).

### v7 (ASCII hexadecimal) — default write

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

Feed / sprocket: `o`.  
Glyph string: `. , : + = x % a b c d e f g @ *`  
Column value: \(V = \sum_{i=0}^{7} d_i \cdot 16^i\) with \(d_i \in \{0…15\}\) → \(16^8 = 2^{32}\) states.

### v8 (base-256 tokens) — experimental maximum density

No single-glyph depth table: each channel is a full byte **0…255**, written as **two lowercase hex digits**.

Example token: `a3f201o00ffc80011`

| Segment | Meaning |
|---------|---------|
| `a3` `f2` `01` | ch1…ch3 |
| `o` | feed |
| `00` `ff` `c8` `00` `11` | ch4…ch8 |

On-disk body remains ASCII; the in-app strip draws continuous **grayscale** holes from the channel bytes (less classic “punch depth,” intentionally more “byte grid”).

---

## Packing (v4–v9)

Sections below follow **version order**. Only **v4–v9** use bit/digit packing; **v1–v3** punch one byte per column.

### v4 packing

#### Full packing (`# packing: full`)

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

#### Stream packing (`# packing: block3`)

For multi-GB / streaming writes, full big-integer conversion is impractical. Streams use **block3**: every 3 bytes → 2 columns (exactly 12 bits/column, ~5% less dense than full, O(1) memory).

```
# packing: block3
```

Folder archives: whole-file members use `packing=full` on each `# @file` line; streamed members use `packing=block3`.

### v5 packing

Every two consecutive payload bytes become one column (big-endian pair → `UInt16` value). An odd final byte becomes a single high-byte column. Packing is **O(n)**.

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

Density: **exactly 16 bits per column** → **⌈N/2⌉** columns for N punched bytes.

### v6 packing

Every three consecutive payload bytes become one column (big-endian triple → 24-bit value). Remainder 1 or 2 bytes pad into a final column (high-aligned). Packing is **O(n)**.

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

Density: **exactly 24 bits per column** → **⌈N/3⌉** columns for N punched bytes.

### v7 packing — default write

Every four consecutive payload bytes become one column (big-endian quad → `UInt32`). Short remainder high-aligns (low bytes zero). Packing is **O(n)**.

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

Streams and folder archives use the same quad packing (`packing=hex`).  
Density: **exactly 32 bits per column** → **⌈N/4⌉** columns for N punched bytes.

### v8 packing — experimental maximum density

Each channel is a full byte (0…255). Eight channels → \(256^8 = 2^{64}\) states → **exactly 8 payload bytes per column**.

**v8 base-256 — experimental maximum density.** Not the default write format (that is **v7 hexadecimal**). At 256 levels, holes are continuous **grayscale** intensities rather than a few discrete punch depths. The strip still uses the classic 8-channel + feed layout; on-disk tokens use **two hex digits per channel** because a single ASCII glyph cannot encode 256 values.

Example token: `a3f201o00ffc80011` (ch1=0xA3 … ch3=0x01, feed `o`, ch4…ch8).

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

## What is *not* versioned away

These appear in all dialects when applicable:

- Header metadata (`name`, `size`, `punched-size`, `compression`, `transfer`, `block-size`, `integrity`, `mode`, …)
- `# @block N off=… len=… crc32=… xor=… sum8=…` every 64 columns (default)
- Folder archives: `# @file` / `# @endfile` members
- Stream / archive trailers as comment lines

Parsing ignores trailing `# …` comments on column lines, so **v1 annotations are optional for readers**.

---

### v9 nine-channel binary (Base512)

The header uses `# PaperTape File v9`, `# columns: base512`,
`# packing: b512`, and `# channels: 9`. Each column has nine binary data
positions and one sprocket. A data position is `*` for 1 or `.` for 0.
The fourth character is always the separate sprocket `o`. In file order,
the data positions are channels 1 through 9, with channel 1 the least
significant bit of the symbol. For example, `*..o.....*` represents 257.

Read input bytes MSB first as one continuous bitstream and take nine bits
at a time, with the first bit becoming channel 9 of the symbol. Zero-fill
the low bits of the last symbol when needed. For `N` punched bytes, the body
has `N - floor(N / 9)` columns and the last column has `N mod 9` padding
bits. For example, bytes `80 FF` produce symbols 257 and 508. Packing
continues across input chunks and integrity blocks and restarts for each
archive member.

For CRC32, XOR, and sum8, each symbol contributes two little-endian bytes.
The reader checks block markers, block integrity, exact column count, and
zero padding. The exact punched byte count comes from `# punched-size:` for
a single file, or the `punched=` field on `@file` or `@endfile` for an
archive member. Unknown-length streams supply the count in the trailer.
The count describes bytes after any compression and Base85 transfer encoding.

A zero-byte payload has no columns and no padding. Unlike v8, v9 uses only full holes and blanks.

The [v9 example](Examples/message-v9.Tape) uses an identity transfer.
Select **v9 nine-channel binary (Base512)** in the app or pass `--format v9`
to `--encode-file` or `--pack-folder`. The default write format is v7.

---

## Approximate file size

Sizes below are for the **`.Tape` text file** when the strip holds **raw** punched bytes (no payload compression, no Base85). Real files also grow or shrink if you enable **Compress** or **Base85** on the *payload* before packing — that is independent of format version.

### Per-column body cost (token + newline)

| Format | ≈ bytes per column line | Bits of payload / column |
|--------|-------------------------|---------------------------|
| **v1** | ~**33** B (Unicode + annotation) | 8 |
| **v2** | ~**24** B (Unicode token) | 8 |
| **v3** | ~**10** B (ASCII 9-char + `\n`) | 8 |
| **v4** | ~**10** B (ASCII 9-char + `\n`) | **~12.68** |
| **v5** | ~**10** B (ASCII 9-char + `\n`) | **16** |
| **v6** | ~**10** B (ASCII 9-char + `\n`) | **24** |
| **v7** (default) | ~**10** B (ASCII 9-char + `\n`) | **32** |
| **v8** (experimental) | ~**18** B (16 hex + `o` + `\n`) | **64** |
| **v9** | **11** B (10 ASCII + `\n`) | **9** |

v3–v7 share ~10 B/col text cost; **v8** tokens are longer (~18 B) but still win on large N because of 8× fewer columns. v9 uses 11 B per column, but needs only about 8/9 as many columns as v3.

### Relative body size (raw payload, large N)

| | vs binary columns | vs v3 body (large N) |
|--|-------------------|----------------------|
| **v3** | 1.0× | 100% |
| **v4** | ~0.63× | ~63% |
| **v5** | 0.5× | ~50% |
| **v6** | ~0.33× | ~33% |
| **v7** | 0.25× | ~25% |
| **v8** | **0.125×** | **~20–25%** (longer tokens offset some savings) |
| **v9** | **~0.889×** | **~97.8%** |

**Rules of thumb**

1. **v1 → v3**: often **~65–70% smaller**.
2. **v3 → v7** (default): about **¼** the columns; body ~**25%** of v3.
3. **v3 → v8** (experimental): about **⅛** the columns; body often **~⅕–¼** of v3 despite longer tokens.
4. **v3 → v9**: about 11.1% fewer columns, but only about 2.2% smaller token body (excluding headers and integrity markers).
5. **With Auto compression**, format savings apply to the remaining punched length.

---

## Choosing a version

Listed in **version order** (same as the Format picker). Default write is **v7**.

| Choose | When |
|--------|------|
| **v1 annotated** | Debugging / teaching; Unicode glyphs + per-column notes + terminal preview footer |
| **v2 visual** | Unicode strip look without annotations or preview |
| **v3 ASCII** | Classic binary 1:1 columns; pure ASCII body |
| **v4 ternary** | Three depths (~12.68 bits/col) |
| **v5 quaternary** | Four depths (16 bits/col) |
| **v6 octal** | Eight depths (24 bits/col) |
| **v7 hexadecimal** | **Default**; 16 discrete depths (32 bits/col); multilevel-punch look |
| **v8 base-256 — experimental maximum density** | Densest (64 bits/col); grayscale “byte grid”; longer tokens |
| **v9 nine-channel binary (Base512)** | Classic binary look with one extra data channel; 9 bits/col, 512 patterns |

### Note on “7-bit-safe”

**v3–v9** make the **punched column lines** pure ASCII. Header names and archive paths may still be UTF-8.

### Suggested filenames

```
<source-stem>-v<N>.Tape
```

Examples: `letter-v7.Tape` (default dialect), `backup-v3.Tape`, `dense-v8.Tape`.  
A trailing `-v1`…`-v9` is replaced on re-save (suffixes are not stacked).

---

## Minimal skeletons

### v1

```
# PaperTape File v1
# name: example.txt
# size: N
# punched-size: M
# compression: none
# transfer: identity
# block-size: 64
# integrity: crc32+xor+sum8
# columns: annotated
# channels: 8
# bit-order: channel-1-lsb
# layout: ch1 ch2 ch3 feed ch4 ch5 ch6 ch7 ch8
# ---
# @block 0 off=0 len=… crc32=… xor=… sum8=…
···○●···●  # A  0x41
…
# === terminal paper preview ===
…
```

### v2

Same idea with `v2`, `# columns: compact`, Unicode glyphs, **no** annotations and **no** terminal preview footer.

### v3

Same idea with `v3`, `# columns: ascii`, binary `* . o` tokens, no packing headers.

### v4

Same idea with `v4`, `# columns: ternary`, packing `full` / `block3`, glyphs `* + . o`.

### v5

Same idea with `v5`, `# columns: quaternary`, packing `quat`, glyphs `* = + . o`.

### v6

Same idea with `v6`, `# columns: octal`, packing `oct`, glyphs `* % x = + : , . o`.

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
# glyphs: *=15 @=14 g=13 … .=0 o=sprocket (16 depths)
# packing: hex
# packing-base: 4294967296
# channel-states: 16
# hexadecimal-columns: K
# pack-chunk: 0
# ---
# @block 0 off=0 len=… crc32=… xor=… sum8=…
.:xo%b%=x
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

---

## Related

- [README.md](README.md) — features, usage, build (app **1.12.2**)
- [CHANGELOG.md](CHANGELOG.md) — release history
- [SECURITY.md](SECURITY.md) — what PaperTape is / is not from a security standpoint
- `Examples/*.Tape` — samples (`message-v1.Tape` … `message-v9.Tape`)
