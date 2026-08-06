# PaperTape

A macOS app that encodes data as **classic 8-channel punched paper tape** — both as an interactive visual strip and as a portable **`.Tape`** digital file.

## Features

- **Encode text** — type or paste; live strip updates as you go
- **Visual tape** — warm teleprinter paper with data holes and a sprocket (feed) track (binary full/blank; multi-state v4–v6 draw progressive hole depths)
- **`.Tape` files** — UTF-8 visual column format that round-trips losslessly (**v1–v8** write dialects)
- **v7 hexadecimal (default)** — **32 bits/column** (4 bytes/col); 16 hole depths + feed `o`
- **v8 base-256 — experimental maximum density** — **64 bits/column** (8 bytes/col); each channel is a grayscale byte; tokens use hex pairs + `o`
- **v6 octal** — **24 bits/column** (3 bytes/col); glyphs `.` `,` `:` `+` `=` `x` `%` `*` `o`
- **v5 quaternary** — **16 bits/column** (2 bytes/col); glyphs `.` `+` `=` `*` `o`
- **v4 ternary** — ~12.68 bits/column via base-6561; glyphs `.` `+` `*` `o`
- **Versioned save names** — suggested filenames include the format: `notes-v7.Tape`, `Project-v3.Tape`, …
- **Auto compression** — trials **LZFSE, Zlib, LZ4, and LZMA**; keeps the smallest worthwhile result (or raw)
- **Base85 (Ascii85)** — optional transfer encoding after compression for printable strip payloads (~+25% size)
- **Integrity blocks** — CRC-32 + XOR + SUM8 every 64 columns (`# @block` markers)
- **Any file** — punch arbitrary binaries into `.Tape`, then restore the original bytes
- **Large-file streaming** — files ≥ 4 MiB punch/restore without holding the full column array in RAM
- **Folder archives** — pack a directory tree (`mode: archive`) with per-file compression; extract to a folder
- **Cancel** long file/folder encodes (progress bar + **Cancel**)
- **Terminal art** — copy ASCII paper-tape art for terminals and docs (in-app; v1 also embeds a preview footer in the file)
- **Export PNG** / **Export data…** / **Extract archive…**
- **Finder integration** — double-click a `.Tape` file to open it; drag files/folders onto the window

## Channel map

Physical layout across the strip (edge → edge):

```
ch1  ch2  ch3  ○feed  ch4  ch5  ch6  ch7  ch8
```

| Channel | Bit |
|---------|-----|
| ch1     | 0 (LSB) |
| ch2     | 1 |
| ch3     | 2 |
| ○ feed  | always punched (not data) |
| ch4     | 3 |
| ch5     | 4 |
| ch6     | 5 |
| ch7     | 6 |
| ch8     | 7 (MSB) |

Glyphs in the digital format:

| Dialect | Depths | Glyphs (data + feed) |
|---------|--------|----------------------|
| **v1 / v2** | 2 | `●` hole, `·` blank, `○` feed |
| **v3** | 2 | `*` hole, `.` blank, `o` feed |
| **v4** | 3 | `.` `+` `*` + `o` feed |
| **v5** | 4 | `.` `+` `=` `*` + `o` feed |
| **v6** | 8 | `.` `,` `:` `+` `=` `x` `%` `*` + `o` feed |
| **v7** | 16 | `.` `,` `:` `+` `=` `x` `%` `a`…`g` `@` `*` + `o` feed |
| **v8** | 256 | hex pairs `00`–`ff` per channel + `o` feed (grayscale) |

## Pipeline

```
original bytes → [compress] → [Base85] → [dense pack if v4–v8] → column tokens → .Tape text
```

Inverse on restore / export:

```
.Tape columns → [dense unpack if v4–v8] → [Base85 decode] → [decompress] → original bytes
```

Compression and Base85 only change which **payload** bytes sit on the strip. Format chooses packing and column glyphs. The in-app strip and PNG keep a classic paper look (multi-state formats draw multiple hole sizes).

## `.Tape` file format

UTF-8 text. The body (column lines + `# @block` markers) is the source of truth for decode. A terminal-paper preview footer is written only for **v1** (comments only; never parsed as columns).

**Dialect details and size comparisons:** see **[FORMAT.md](FORMAT.md)** (v1–v8, glyphs, packing, approximate reductions).

### Format versions

| Version | Column glyphs | Packing | Annotations | Preview | UI label |
|---------|---------------|---------|-------------|---------|----------|
| **v1** | Unicode `● · ○` | 1 byte/col | `  # T  0x54` | Yes | **v1 annotated** |
| **v2** | Unicode `● · ○` | 1 byte/col | No | No | **v2 visual** |
| **v3** | ASCII `* . o` | 1 byte/col | No | No | **v3 ASCII** |
| **v4** | ASCII `* + . o` | base-6561 (~12.68 bits/col) | No | No | **v4 ternary** |
| **v5** | ASCII `* = + . o` | **2 bytes/col (16 bits)** | No | No | **v5 quaternary** |
| **v6** | ASCII multilevel + `o` | **3 bytes/col (24 bits)** | No | No | **v6 octal** |
| **v7** (default write) | 16 ASCII depths + `o` | **4 bytes/col (32 bits)** | No | No | **v7 hexadecimal** |
| **v8** | hex pairs `00`–`ff` + `o` | **8 bytes/col (64 bits)** | No | No | **v8 base-256 — experimental maximum density** |

Example v8 token: `a3f201o00ffc80011` — two hex digits per channel (full byte), feed `o`.  
Visually the strip is eight **grayscale** holes per column (less classic “punch depth”, intentionally more byte-grid).

**v7** (default): \(16^8 = 2^{32}\) → four bytes/col — practical multilevel density.  
**v8 base-256 — experimental maximum density**: \(256^8 = 2^{64}\) → **eight payload bytes per column** (⌈N/8⌉).  
**v6** octal: three bytes/col. **v5** quat: two bytes/col. **v4** ternary: ~12.68 bits/col.

All versions share integrity markers, compression/Base85, streaming, and archives. Readers accept any known version. Only **writing** is controlled by the **Format** picker.

### Suggested filenames

When encoding or saving a `.Tape`, the save panel suggests a name with the **format version** suffix:

| Source | Format | Suggested name |
|--------|--------|----------------|
| `notes.txt` | v4 | `notes-v4.Tape` |
| `report.pdf` | v3 | `report-v3.Tape` |
| folder `Photos` | v2 | `Photos-v2.Tape` |

Re-saving `notes-v3.Tape` as v4 becomes `notes-v4.Tape` (prior `-vN` is replaced, not stacked). You can still rename freely in the save panel.

### Example (v4 ternary blob)

```
# PaperTape File v4
# name: message.txt
# size: 19
# punched-size: 19
# compression: none
# transfer: identity
# block-size: 64
# integrity: crc32+xor+sum8
# columns: ternary
# channels: 8
# packing: full
# packing-base: 6561
# channel-states: 3
# ternary-columns: 12
# pack-chunk: 0
# glyphs: *=full +=mid .=blank o=sprocket
# ---
# @block 0 off=0 len=12 crc32=… xor=… sum8=…
..+o*+.*+
…one ternary column token per line…
```

- **v3**: binary ASCII `* . o`, one column per byte (`# columns: ascii`)
- **v2**: Unicode tokens (`··●○·●·●·`) and `# columns: compact`
- **v1**: Unicode tokens + annotations + `# === terminal paper preview ===` footer

See `Examples/` in the repo.

### Header fields

| Field | Meaning |
|-------|---------|
| `# name:` | Original filename (or folder name for archives) |
| `# size:` | Uncompressed original length (bytes); for archives, total of members |
| `# punched-size:` | Binary payload bytes on the strip (before dense pack for v4–v6) |
| `# compression: none\|lzfse\|zlib\|lz4\|lzma` | Codec actually used (never `auto`) |
| `# transfer: identity\|ascii85` | Transfer encoding after compression |
| `# block-size:` | Columns per integrity block (default **64**) |
| `# integrity: crc32+xor+sum8` | Integrity scheme |
| `# columns: annotated\|compact\|ascii\|ternary\|quaternary\|octal\|hexadecimal\|base256` | Write dialect body style |
| `# packing: full\|block3\|quat\|oct\|hex\|b256` | Dense pack mode |
| `# packing-base:` | States per column (v4…v8: 6561 … \(2^{64}\)) |
| `# channel-states:` | **3** / **4** / **8** / **16** / **256** for v4…v8 |
| `# ternary-columns:` / `# quaternary-columns:` / `# octal-columns:` / `# hexadecimal-columns:` / `# base256-columns:` | Dense column counts |
| `# pack-chunk:` | v4 full pack: 0 = whole payload; 4096 = fixed chunks (linear time) |
| `# mode: blob\|stream\|archive` | Container kind (omitted ⇒ blob) |
| `# stream: 1` | Large-file / archive streaming write |
| `# preferred-compression:` / `# preferred-transfer:` | Archive-level preferences (per-member codecs may differ) |

### Integrity blocks

Between payload columns, comment markers record checksums:

```
# @block N off=<column> len=<n> crc32=<hex8> xor=<hex2> sum8=<hex2>
```

Integrity is CRC-32 + XOR + SUM8 over each block’s **integrity bytes** (not the glyph text):

| Dialect | Integrity unit per column |
|---------|---------------------------|
| **v1–v3** binary | 1 byte (the punched byte) |
| **v4** ternary | 2-byte little-endian column value |
| **v5** quaternary | 2-byte little-endian column value |
| **v6** octal | 3-byte little-endian column value (24-bit) |
| **v7** hexadecimal | 4-byte little-endian column value (32-bit) |
| **v8** base-256 | 8 channel bytes (ch1…ch8 order) |

On open, PaperTape verifies each block and shows **Integrity OK** or **FAIL** (which block(s)) on the Tape tab. Damaged transmission can be localized without re-checking the entire tape as one unit.

### Payload compression (Auto)

Compression runs on the **original bytes before punching**, not on the `.Tape` text wrapper.

**Auto** (default UI choice) trials **LZFSE, Zlib, LZ4, and LZMA**, then keeps the **smallest** result when it is worthwhile:

| Payload size | Rule |
|--------------|------|
| &lt; 12 bytes | Skip trials (framing usually expands) |
| &lt; 1 KB | Any strict reduction of 1+ bytes is kept |
| ≥ 1 KB | Need ≥ 16 bytes saved **and** ≥ 5% smaller |

Otherwise the payload is punched raw (`compression: none`). The header always stores the concrete winner, never `auto`.

UI control: **Compress → Auto / Off**.

### Base85 (Ascii85)

Optional step **after** compression, **before** punching. Makes payload bytes printable ASCII on the strip (~4 bytes → 5 characters, about **+25%**). It does **not** shrink data — use **Compress (Auto)** to shrink.

| Header | Meaning |
|--------|---------|
| `# transfer: identity` | Punch compressed/raw bytes directly |
| `# transfer: ascii85` | Ascii85 after compression |

UI control: **Base85 (+25%)** checkbox.

### Large-file streaming

Files **≥ 4 MiB** use line-oriented streaming I/O:

- Punch raw columns to disk (whole-file compress/Base85 need a full buffer)
- Header notes preferred compress/transfer when they were not applied
- `# mode: stream` and `# stream: 1`

Restore streams back to a single file. The Tape tab may show a **partial preview** of the first columns for very large `.Tape` text.

### Folder archives

Pack a directory into one `.Tape`:

```
# mode: archive
# compression: per-file
# transfer: per-file
# preferred-compression: auto
# ---
# @file path="docs/readme.txt" size=1234 punched=400 compression=lzfse transfer=identity
# @block …
…columns for this member…
# @endfile
# @file path="img/logo.png" …
```

- Each member under 4 MiB can use **Compress / Base85** independently  
- Members ≥ 4 MiB stream raw  
- Symlinks and junk (`.DS_Store`, `.git`, `node_modules`, …) are skipped  
- **Extract archive…** (Tape tab) or **Files → Restore** unpacks to a chosen folder  

## Build & run

```bash
cd ~/PaperTape
chmod +x build-app.sh
./build-app.sh
```

Options:

- `./build-app.sh --no-launch` — build the `.app` without opening it

CLI self-test (release binary):

```bash
swift build -c release
.build/release/PaperTape --self-test
```

Requires macOS 13+ and Xcode command-line tools / Swift 5.9+.

## Usage

1. **Encode** — type text; columns appear on the strip as you type  
2. **Compress** — **Auto** (default) or **Off** (payload only)  
3. **Base85** — optional printable transfer encoding after compression  
4. **Format** — **v7 hexadecimal** (default), **v8 base-256 — experimental maximum density**, …, or **v1 annotated** (see [FORMAT.md](FORMAT.md))  
5. **Save .Tape…** — write the digital visual representation (suggested name includes `-vN`, e.g. `message-v7.Tape`)  
6. **Drop** a file or folder onto the window — save sheet, then punch (**progress** + **Cancel** in the footer)  
7. **Files** — choose file/folder to punch (also **Cancel** while working), open a `.Tape`, or restore/extract  
8. **Tape tab** — strip, integrity banner, folder-archive / partial-preview notes  
9. **Export data…** / **Extract archive…** — restore a single payload or unpack a folder archive  
10. **Copy terminal art** — paste the ASCII strip into a terminal or README  
11. **Export PNG…** — share a picture of the punched strip  

## Self-test

- **About** tab → **Run self-test**, or  
- `PaperTape --self-test` (exits non-zero on failure)

Covers text/unicode round-trips, compression codecs, Base85, integrity blocks, dense packing (v4–v8), and folder archive pack/extract.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for release history. Format dialects: [FORMAT.md](FORMAT.md). Security posture (what this is / is not): [SECURITY.md](SECURITY.md).

## License

Copyright © 2026. All rights reserved.
