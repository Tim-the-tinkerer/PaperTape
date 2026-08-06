# Changelog

All notable changes to **PaperTape** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/).

## [1.12.1] - 2026-08-05

### Changed

- **Default write format** is again **v7 hexadecimal** (practical multilevel density)
- **v8 base-256** labeled **experimental maximum density** in the Format picker and docs
- Format picker lists versions in order **v1…v8**; default write remains **v7**

## [1.12.0] - 2026-08-04

### Added

- **`.Tape` format v8 (base-256)**: each channel stores a full byte (grayscale intensity 0…255)
- **64 bits/column** packing: \(256^8 = 2^{64}\) → exactly **8 bytes per column** (O(n), densest)
- On-disk tokens use **hex pairs + feed** (17 chars), e.g. `a3f201o00ffc80011` — single ASCII glyphs cannot encode 256 depths
- Strip UI draws true **grayscale holes** from channel bytes (plausibly less “paper tape”, intentionally more “byte grid”)
- Headers: `# columns: base256`, `# packing: b256`, `# channel-states: 256`, `# base256-columns:`
- Format picker: **v8 base-256** (was default write in 1.12.0); stream/archive/integrity supported
- Example: `Examples/message-v8.Tape`

### Density (raw payload columns)

| Format | bits/col | ≈ columns for N bytes |
|--------|----------|------------------------|
| v3 binary | 8 | N |
| v5 quaternary | 16 | ⌈N/2⌉ |
| v6 octal | 24 | ⌈N/3⌉ |
| v7 hexadecimal | 32 | ⌈N/4⌉ |
| **v8 base-256** | **64** | **⌈N/8⌉** |

## [1.11.0] - 2026-08-04

### Added

- **`.Tape` format v7 (hexadecimal)**: sixteen calibrated punch depths per channel  
  (`. , : + = x % a b c d e f g @ *`, feed `o`)
- **32 bits/column** packing: \(16^8 = 2^{32}\) → exactly **4 bytes per column** (O(n), densest)
- Format picker: **v7 hexadecimal** (default write) / v6 … v1
- Headers: `# columns: hexadecimal`, `# packing: hex`, `# packing-base: 4294967296`, `# channel-states: 16`, `# hexadecimal-columns:`
- Stream/archive support; strip/terminal art map 16 depths; integrity over LE 4-byte column values
- Suggested save names: `name-v7.Tape`
- Example: `Examples/message-v7.Tape`

### Density (raw payload columns)

| Format | bits/col | ≈ columns for N bytes |
|--------|----------|------------------------|
| v3 binary | 8 | N |
| v4 ternary | ~12.68 | ~0.63 N |
| v5 quaternary | 16 | ⌈N/2⌉ |
| v6 octal | 24 | ⌈N/3⌉ |
| **v7 hexadecimal** | **32** | **⌈N/4⌉** |

## [1.10.3] - 2026-08-04

### Fixed

- FilePane save-panel **cancel** no longer clears busy flags (avoids killing a concurrent drop-encode)
- Encode controls disabled when **either** local or shared busy is set
- `decodeFileStreaming` removes partial output on failure (no truncated restore left on disk)
- Archive extract stages into a private folder and only promotes on success (failed extract leaves destination clean)
- Stream **ternaryFull** EOF residual matches `# ===` safety (never uses digit count as byte length)
- Understated file-size metadata: probe with a cap instead of `Data(contentsOf:)` for multi-GB OOM risk; stream the real file from disk
- Dense extract truncate guards against negative byte totals

## [1.10.2] - 2026-08-04

### Fixed

- **Unknown-size dense streams** (header `punched-size: unknown`): decode now trims remainder pad using trailer `# punched-size` after body emit
- Stream `# ===` path drains trailer size **before** residual ternary-full unpack; no longer treats digit count as byte count
- Archive **oversized-after-load** ternary members use **block3** (stream-decodable) instead of full pack that exceeded extract buffer caps
- Streamed archive members record `# @endfile punched=N size=N` for pad trim on extract
- Archive extract dense path carries odd **block3** digits across blocks and truncates to punched/size
- Self-test: unknown-size stream pad-trim for v4/v5/v6 remainder lengths

## [1.10.1] - 2026-08-04

### Fixed

- Dense stream decode treats size/punched **0 as unknown**, not an empty cap (no longer drops all archive stream bytes)
- Stream reader honors trailer `# punched-size:`; finishes residual ternary-full unpack before `# ===` EOF
- Block3 stream decode carries an odd digit across integrity blocks (odd block lengths no longer mis-pair)
- Archive stream packing caps chunk size like the blob stream writer (bounded memory)
- Prefer packing when parsing column tokens (v5 tokens with `x` not stolen by octal auto-detect)
- `deserializeHeadered` no longer defaults missing version to latest (avoids forcing octal packing)
- Reads `# quaternary-columns:` / `# octal-columns:` dense column hints (not only ternary)
- Multi-state archive members reserve digit buffer correctly; `columnLine` never annotates octal
- Integrity buffer reserve accounts for 3-byte octal values; packTernary/unpackTernary refuse silent `.octal` misuse
- Self-test covers v5/v6 stream round-trips (non-multiple lengths)

## [1.10.0] - 2026-08-04

### Added

- **`.Tape` format v6 (octal)**: eight calibrated punch depths per channel  
  (`.` `,` `:` `+` `=` `x` `%` `*`, feed `o`)
- **24 bits/column** packing: \(8^8 = 16\,777\,216 = 2^{24}\) → exactly **3 bytes per column** (O(n), densest)
- Format picker: **v6 octal** (default write) / v5 / v4 / v3 / v2 / v1
- Headers: `# columns: octal`, `# packing: oct`, `# packing-base: 16777216`, `# channel-states: 8`
- Stream/archive support; strip draws eight progressive hole sizes; terminal art caption says **octal** when appropriate
- Suggested save names: `name-v6.Tape`
- Example: `Examples/message-v6.Tape`

### Density (raw payload columns)

| Format | bits/col | ≈ columns for N bytes |
|--------|----------|------------------------|
| v3 binary | 8 | N |
| v4 ternary | ~12.68 | ~0.63 N |
| v5 quaternary | 16 | ⌈N/2⌉ |
| **v6 octal** | **24** | **⌈N/3⌉** |

## [1.9.1] - 2026-08-04

### Fixed

- **v5 / large archive extract** no longer fails with `Line too long in archive .Tape body (missing newline?)`: line readers peel complete lines before applying the 256 KiB incomplete-line cap (partial line + next chunk was falsely over the limit)
- Same ordering fix for stream decode and large-tape column preview readers
- Terminal paper caption under multi-state strips says **quaternary** or **ternary** from packing (no longer hardcodes “ternary” for partial previews and folder archives)

### Docs

- Version / About / FORMAT / README aligned with v1–v5 and the extract fix

## [1.9.0] - 2026-08-04

### Added

- **`.Tape` format v5 (quaternary)**: four hole depths per channel (`.` blank, `+` shallow, `=` medium, `*` full, `o` feed)
- **16 bits/column** packing: \(4^8 = 65\,536 = 2^{16}\) → exactly **2 bytes per column** (O(n), densest practical packing)
- Format picker: **v5 quaternary** (default write) / v4 / v3 / v2 / v1
- Headers: `# columns: quaternary`, `# packing: quat`, `# packing-base: 65536`, `# channel-states: 4`
- Stream/archive support for quat packing; strip UI draws four hole sizes
- Suggested save names: `name-v5.Tape`

### Density (raw payload columns)

| Format | bits/col | ≈ columns for N bytes |
|--------|----------|------------------------|
| v3 binary | 8 | N |
| v4 ternary | ~12.68 | ~0.63 N |
| **v5 quaternary** | **16** | **⌈N/2⌉** |

## [1.8.4] - 2026-08-04

### Fixed

- **v4 terminal paper** no longer shows a blank `·` legend: ternary art uses mid-hole glyphs and prints the restored UTF-8 message under the strip
- Removed duplicate **Decoded payload** block under terminal art on the Tape tab

## [1.8.3] - 2026-08-04

### Fixed

- **v4 stream restore via full `deserialize`**: header now includes `# punched-size:` when size is known; trailer punched-size is also scanned; ternary no longer uses `columns.count` as binary length
- Raw identity streams fall back to `# size:` as packed byte count when needed
- **Partial ternary export**: whole-integer full pack refuses unsafe export; block3/chunked export only complete groups
- Line length caps on large-tape preview and archive extract (match stream reader DoS guard)
- Shared busy flag between Files encode and window-drop encode (no concurrent jobs)
- Archive extract integrity: one failure count per bad block (not double-count)

### Tests

- Stream v4 block3: `decodeFileStreaming` **and** full `deserialize` must match original

## [1.8.2] - 2026-08-04

### Fixed

- Archive `@file` lines record durable `pack-chunk=` for v4 full members (extract no longer depends only on heuristics)
- Stream reader progressively unpacks **chunked full** ternary (`pack-chunk > 0`) instead of buffering every digit
- Files open-panel directory/file flags no longer always allowed both (cleanup; behavior preserved)

### Tests

- Self-test: stream block3 round-trip via `TapeStreamWriter` + `decodeFileStreaming`
- Self-test: 50 KiB chunked-full serialize + stream decode
- Self-test: archive v4 `@file` includes `pack-chunk=`

## [1.8.1] - 2026-08-04

### Fixed

- **v4 all-zero payloads** failed open (`missingPayload`): whole-integer pack emitted no columns; now writes a zero digit and restores N zero bytes from `punched-size`
- Legacy empty-body ternary files with `punched-size` > 0 restore correctly
- Archive trailer `punched-size` now counts **binary** punched bytes (not ternary column count); adds `# ternary-columns:` when applicable
- Stream/archive **block3** ternary decode streams to disk (O(1) memory) instead of buffering every digit
- Removed unused `EncodeProbe.swift` stub

### Tests

- Self-test covers all-zero v4 round-trips, suggested filenames, and v4→v3 cross-format re-save

## [1.8.0] - 2026-08-04

### Added

- Suggested encode save names include the format version: `notes-v4.Tape`, `Project-v3.Tape`, etc. (Save .Tape…, file/folder encode, drop-to-punch)
- Re-save strips a prior trailing `-v1`…`-v4` before applying the current version (no stacked suffixes)

### Changed

- Docs (README, FORMAT, About) fully describe **v1–v4**, ternary packing, adaptive pack-chunk, and versioned filenames

## [1.7.0] - 2026-08-04

### Fixed

- **File encode hung / appeared to do nothing** on mid-size+ files with v4: whole-integer base-6561 pack is O(n²); payloads over ~24 KiB now use linear chunked full-pack
- Large v4 `.Tape` open/preview no longer mis-reads ternary as binary (column-token preview path)

### Added

- **`.Tape` format v4 (ternary)**: three-state channels (`.` blank, `+` mid, `*` full, `o` feed) with **full base-6561 packing** (~12.68 bits/column — highest density)
- Format picker lists **v4 / v3 / v2 / v1** (default write is **v4**)
- Headers: `# columns: ternary`, `# packing: full|block3`, `# packing-base: 6561`, `# channel-states: 3`, `# ternary-columns:`, `# pack-chunk:`
- Stream / multi-GB path uses **block3** packing (3 bytes → 2 columns) for O(1) memory; modest in-memory saves use whole-integer full pack, larger payloads use 4 KiB chunked full-pack
- Strip UI draws mid-size holes for ternary state 1
- Integrity CRC/XOR/SUM8 over little-endian column values (UInt16 per ternary column)

### Notes

- v4 omits annotations and terminal-paper preview (same as v2/v3)
- Binary payload pipeline unchanged: compress → Base85 → pack → columns
- See [FORMAT.md](FORMAT.md) for density comparisons

## [1.6.0] - 2026-08-04

### Added

- **Cancel** for file/folder encode and pack (main footer + Files footer; Esc)
- Cooperative cancel through stream/folder encode loops; partial `.Tape` output is deleted
- `.gitignore` for SPM builds, app bundles, and macOS junk

### Fixed

- Compress / Format pickers clipped in the Encode and Tape toolbars (and Files card) — size to label with `fixedSize`
- About / Files copy no longer claims every `.Tape` has a terminal-paper preview (v1 only)
- About lists `# columns: annotated|compact|ascii`
- v3 help text clarifies 7-bit safety applies to the **column body**, not necessarily `# name:` / archive paths

### Changed

- Format label **v2 visual** (was “v2 compact”); on-disk `# columns: compact` unchanged for compatibility

## [1.5.0] - 2026-08-03

### Added

- **`.Tape` format v3 (ASCII)**: column tokens use one-byte glyphs `*` (hole), `.` (blank), `o` (sprocket) — e.g. `...o*..*.`
- Format picker lists **v3 / v2 / v1** (default write is **v3**)
- Header `# columns: ascii` and `# glyphs: *=hole .=blank o=sprocket`
- Readers already accepted ASCII glyphs; v3 writes a 7-bit ASCII **column body** (header `# name:` / paths may still be Unicode)

### Notes

- v3 omits per-column annotations and the terminal paper preview footer (same as v2)
- Integrity, compression, Base85, streaming, and archives work the same across v1–v3
- See [FORMAT.md](FORMAT.md) for dialect details and size comparisons

## [1.4.1] - 2026-08-03

### Changed

- **v2** omits the `# === terminal paper preview ===` footer entirely (v1 still includes it)

## [1.4.0] - 2026-08-03

### Added

- **`.Tape` format v2**: column lines are Unicode visual tokens only — no trailing `# char  0xNN` annotations (smaller files)
- **Format picker** (Encode toolbar + Files): v2 or v1 annotated
- Header field `# columns: annotated|compact`; files declare `# PaperTape File v1` or `v2`
- Readers still accept both dialects (annotations optional when parsing)

### Notes

- Integrity markers, compression, Base85, streaming, and folder archives are unchanged across v1/v2
- Terminal paper preview footer is **v1-only** (comment-only; never parsed as columns)

## [1.3.12] - 2026-08-03

### Fixed

- **Could not export data**: Export was disabled for folder archives and partial previews; archives only showed a status hint
- Folder archives: **Extract archive…** picks a destination and extracts all members (with progress)
- Single-file / blob tapes: Export always available when columns exist; partial previews export best-effort with a warning
- Save panel presented as a sheet on the main window

## [1.3.11] - 2026-08-03

### Fixed

- **Tape tab hid integrity for folder archives / previews**: archive and partial banners short-circuited the integrity slot so CRC/XOR/SUM8 never appeared
- Context banners now stack above the integrity report; integrity is always shown when blocks exist (including archive strip previews)

## [1.3.10] - 2026-08-03

### Fixed

- **Progress bar missing on drop encode**: folder/file punch from drop now drives a linear progress bar + phase label in the main footer (was passing `progress: nil`)

## [1.3.9] - 2026-08-03

### Fixed

- **Drop file/folder only showed “opening Files” and stopped**: encode no longer waits on FilePane `onChange`/`onAppear` (race left the save panel never shown)
- Dropped files and folders now open a **save sheet on the main window** immediately, then pack/encode
- Security-scoped access held for the whole encode; queued drops process after the current job finishes

## [1.3.8] - 2026-08-03

### Fixed

- **Drag and drop from Finder broken**: drop catcher `hitTest` required local `mouseDragged` events, which Finder→app drags usually do not provide, so the window never accepted the drop
- File-drag session tracking via local/global mouse monitors + pasteboard
- SwiftUI root `onDrop` fallback on every tab; broader UTTypes (folder/directory)
- Clicks still pass through when not mid-drag (no UI freeze regression)

## [1.3.7] - 2026-08-03

### Fixed

- **Folder/file encode stuck on “punching…”**: external open set generation *before* the URL, so Files never started the job after the first drop
- External open now reacts to both URL and generation; status updates through save panel → encode → done
- Busy flag is set only after the save destination is chosen (cancel no longer leaves the UI stuck)
- Folders are detected reliably (security-scoped + `FileManager` directory check) before packing

## [1.3.6] - 2026-08-03

### Fixed (second full audit)

- **Finder drops on Encode/Tape** more reliable: drop catcher uses a real drag-session flag (not only `NSApp.currentEvent` mouse-dragged)
- **Concurrent Files jobs**: drops/external opens queue while busy; multi-open processes one at a time and flushes when idle
- **Save after partial preview + typed text** uses the editor as source of truth (no longer always fails via `restoredData`)
- Open `.Tape` from Finder/drop loads **off the main thread**
- Folder pack **deletes partial archives** on error; stream encode checks short reads; stream integrity fails empty/short `@block` bodies
- `loadForDisplay` probes unknown-size files instead of mapping multi-GB blindly; max line length on stream reader
- Security-scoped stream open releases access if handle creation fails
- Compressed/Base85 decode always uses full deserialize (not stream-raw path)
- Fallback UI load preserves `containerMode` / `isPartialPreview`; empty archive placeholder on Tape tab
- Status no longer claims “integrity OK” for partial previews / archives

## [1.3.5] - 2026-08-03

### Fixed (full audit)

- **Folder member size** uses actual bytes read (not stale enumerator size); decompress no longer silently truncates on size mismatch
- **Unknown / zero file size** no longer forces raw stream for small files — probes up to 4 MiB then compresses in memory when possible
- **Folder pack** streams (not whole-loads) when member size is unknown; skips symbolic links; safer root-relative paths
- **Archive open** marks `containerMode: archive` so Save / Export data / re-punch cannot treat multi-file tapes as one blob
- **Partial large-tape previews** flagged; integrity banner says preview is not full-file
- Live Compress/Base85 no longer wipes a loaded binary document when Encode text is empty
- Save never falls back to re-encoding punched/compressed bytes as “original”
- Empty failed loads no longer clear a good tape on the Tape tab
- Multi-file Finder open / drop re-flushes remaining URLs
- External Files open is single-shot (no triple-handle / remount race)
- Stream writer cleans up partial `.Tape` on error; invalid UTF-8 lines throw instead of silent EOF
- Security-scoped stream reader correctly releases access; `isTapeURL` sniffs header only
- App claims **Owner** only for `com.papertape.tape` (not all plain text / data)
- `@block` length mismatch fails integrity even if CRC collides

### Added

- Archive / partial-preview banners on the Tape tab
- Self-test: archive display mode + decompress size-mismatch guard

## [1.3.4] - 2026-08-03

### Fixed

- **Folder pack ignored Compress entirely** — `encodeFolder` always wrote `# compression: none` and punched raw member bytes, so folders of text became enormous
- Per-file **Compress** (Auto / Off) and **Base85** now run on each archive member under 4 MiB before punching
- **Extract folder** restores compressed and Base85 members using each `# @file` codec (`compression=`, `transfer=`, `punched=`, `size=`)
- Legacy archives without per-file codec fields still extract as raw identity (backward compatible)

### Changed

- Archive header: `# compression: per-file` · `# transfer: per-file` · `# preferred-compression:` · `# preferred-transfer:`
- Each member line: `# @file path="…" size=… punched=… compression=… transfer=…`
- Files status after pack reports compressed member count, codec mix, and payload savings percent
- Files copy clarifies that Compress applies to folder members under 4 MiB
- Self-test covers folder pack → extract with Auto compression

### Notes

- Single files ≥ 4 MiB still stream **raw** (whole-file compress needs the full buffer)
- Archive members ≥ 4 MiB still stream raw; smaller members compress independently
- `.Tape` remains a visual text format (one column line per punched byte), so the file is larger than a zip even when the payload is well compressed

## [1.3.3] - 2026-08-03

### Fixed

- **Tape tab empty after Save / Encode / Open** — live recompute could wipe a just-loaded document when `plainText` was applied
- **Integrity banner missing** — report is always built for non-empty tapes; banner pinned at the top of the Tape tab
- Fresh encodes no longer show false integrity **FAIL** (synthetic reports used `hasMarkers: true`, which forced CRC mismatches)
- After writing a `.Tape`, UI load tries multiple paths so the strip is never blank when columns exist
- Save falls back to the in-memory document if disk reload fails
- Pending live encode is cancelled while applying a loaded document (`suppressLiveRecompute`)

### Added

- Files tab: **Open .Tape…** / **Open in Tape tab…** to inspect strip + integrity without extracting
- CLI: `PaperTape --self-test` (exits non-zero on failure)

## [1.3.2] - 2026-08-03

### Fixed

- Open / encode paths load via `loadForDisplay` so the Tape tab and integrity banner get real columns (not an empty document)
- Save reloads from disk (or keeps the punched document) and switches to the Tape tab
- App icon `@2x` asset names no longer mangled (`icon_16x16@2x.png`, not email-style aliases)

### Added

- `TapeEngine.loadForDisplay(from:maxColumns:)` — full load for modest files; first N columns for very large tapes
- Shared `applyLoadedDocument` path for Files open, drop, save, and external open

## [1.3.1] - 2026-08-03

### Fixed

- Integrity verification false-positive cascade (hundreds of blocks failing after one issue)
- Verify each `# @block` section by its own columns, not a blind global re-slice
- Compact integrity banner / summary (no multi-hundred block ID dumps)
- Serialize headers use explicit newlines (reliable `# ---` separators)
- Stream reader accepts `# ---` prefixes; folder archives more robust on extract
- Do not fail open solely on integrity when inspecting a tape

### Changed

- Integrity detail line shows first few failures + “+N more”

## [1.3.0] - 2026-08-03

### Added

- **Large-file streaming**: files ≥ 4 MiB punch/restore via line-oriented I/O (no full column array in RAM)
- **Folder archives**: pack a directory tree into `mode: archive` with `# @file path="…"` sections; extract to a folder
- Progress bar on Files tab for long encode/extract jobs
- Stream header flags: `# mode: stream|archive` · `# stream: 1`

### Notes

- On first release, folder pack punched raw only; **1.3.4** adds per-file Compress / Base85 for members under 4 MiB
- Streaming path for single files ≥ 4 MiB still punches **raw** payload (whole-file compress/Base85 apply under 4 MiB)
- Integrity `# @block` markers work for streamed files and each archive member
- UI may show a preview of large tapes; use Restore to extract full payloads

## [1.2.0] - 2026-08-03

### Added

- **Block integrity** for damaged text transmission: every 64 columns gets a marker with
  - **CRC-32** (IEEE)
  - **XOR** parity of all bytes in the block
  - **SUM8** (sum of bytes mod 256)
- Comment lines `# @block N off=… len=… crc32=… xor=… sum8=…` (do not change ●·○ column aesthetics)
- Header: `# block-size: 64` · `# integrity: crc32+xor+sum8`
- On open: verify each block and report **which block(s) failed** (banner on Tape tab + status line)
- Self-test corrupts a glyph and expects a failed block

## [1.1.1] - 2026-08-03

### Changed

- Base85 toggle labeled **Base85 (+25%)** — encoding expands; use Compress to shrink

## [1.1.0] - 2026-08-03

### Added

- **Base85 (Adobe Ascii85)** optional transfer encoding on the payload
- Pipeline: original → [compress] → [Base85] → punch columns
- Header field `# transfer: identity|ascii85` for lossless restore
- Base85 toggle in Encode toolbar and Files encode card

### Notes

- Visual aesthetic of `.Tape` files (● · ○ columns, terminal paper preview) is unchanged
- PNG export style is unchanged — still draws the same punched-strip look
- Base85 expands data (~25%) but yields printable ASCII on the strip; works with or without compression

## [1.0.9] - 2026-08-03

### Fixed

- Message / Encode-tab compression rarely applied: savings floor (48 bytes, 5%/16 bytes) skipped typical typed text
- Short payloads now compress whenever any codec produces a strictly smaller stream
- Footer reports when Auto keeps raw because nothing was smaller

### Changed

- Minimum size to trial compression lowered to 12 bytes
- Under 1 KB: any 1+ byte savings is accepted; larger data still uses the 5%/16-byte floor

## [1.0.8] - 2026-08-03

### Fixed

- Compress **Off** no longer snaps back to Auto when saving, opening a compressed `.Tape`, or encoding from the Files tab
- Encode and Files share one Compress preference
- Save `.Tape` re-encodes with the current preference so the file matches the picker
- Changing Compress immediately re-punches the current payload

## [1.0.7] - 2026-08-03

### Fixed

- Footer buttons and terminal preview were unresponsive: the full-window drop catcher stole clicks whenever the drag pasteboard still listed files after a drag
- Drop catcher `hitTest` now only claims the view during **active drag motion** (`leftMouseDragged`), never on mouseDown/click
- Terminal paper uses an `NSTextView` for reliable scrolling and selection

## [1.0.6] - 2026-08-03

### Fixed

- Terminal preview never appeared (or was clipped to zero height) when the tape strip took all flexible space
- Preview pane now has a reserved height and higher layout priority than the strip

### Changed

- Terminal preview defaults to **on**
- Encode text area shrinks slightly when the preview is open so both stay visible
- Preview shows an empty-tape placeholder and a local **Copy** control

## [1.0.5] - 2026-08-03

### Fixed

- Drag and drop still failed because SwiftUI views (especially `TextEditor`) stole Finder drops
- Full-window AppKit drop catcher claims hit-testing only while a file drag is active, so clicks still pass through

### Added

- Window-level `FileDropCatcherView` over the hosting view (classic pasteboard types + NSFilenames)
- Drop highlight driven by AppKit drag enter/exit notifications

## [1.0.4] - 2026-08-03

### Fixed

- Drag and drop from Finder was unreliable or non-functional
- Dropped files now use security-scoped access when reading contents
- File URL extraction handles Data, path strings, and `public.file-url` pasteboard types

### Added

- Drop targets on the whole window (any tab) and dedicated encode/decode zones in Files
- Visual drop highlight and dashed drop hints on encode/decode cards

### Changed

- Opening a dropped `.Tape` routes straight to the tape inspector when possible
- Non-`.Tape` drops open the Files flow and punch automatically

## [1.0.3] - 2026-08-03

### Added

- **Auto** compression preference (default): trials LZFSE, Zlib, LZ4, and LZMA
- Savings floor so compression only applies when it matters (≥48 byte input, ≥16 bytes and ≥5% smaller)

### Changed

- Compression UI simplified to **Auto** / **Off**
- `.Tape` header stores the concrete winning codec only (never `auto`)
- Status lines report `auto→Zlib` (or other winner) and savings percent

## [1.0.2] - 2026-08-03

### Added

- Payload compression before punching: LZFSE and Zlib
- Header fields `# compression:`, `# punched-size:` (visual column layout unchanged)
- Compress picker in Encode toolbar and Files encode card
- Column stats show `original→punched` when compressed
- Self-tests for compressed round-trips

### Changed

- Export / restore always return the decompressed original payload
- Serialize/deserialize preserve compression metadata for lossless restore

## [1.0.1] - 2026-08-03

### Fixed

- Crash (`AttributeGraph` abort) when encoding large text or many columns
- Per-column `ForEach` legend no longer exhausts SwiftUI’s attribute table
- Nested `VSplitView` + flex-frame layout recursion reduced

### Changed

- Tape strip is fully Canvas-drawn (holes + legend)
- UI display capped at 1,024 columns (full payload still saved)
- Live encode debounced; large pastes encode off the main thread
- Terminal art, PNG export, and save use safe limits / background work

## [1.0.0] - 2026-08-03

### Added

- Initial release: macOS app that encodes data as classic 8-channel punched paper tape
- Visual tape strip with data holes and sprocket (feed) track
- `.Tape` digital format: UTF-8 header + one visual column per line + terminal paper preview
- Channel map: ch1–ch3, ○feed, ch4–ch8 (ch1 = LSB, ch8 = MSB)
- Glyphs: `●` hole · `·` blank · `○` sprocket
- Encode text (UTF-8) live to punched columns
- Files tab: punch any file to `.Tape`, restore original from `.Tape`
- Save `.Tape`, export payload, export PNG, copy terminal paper art
- Finder document type / double-click to open `.Tape`
- About tab with format notes and self-test
- Example file: `Examples/hello.Tape`
