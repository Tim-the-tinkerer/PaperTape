# Security: what PaperTape is and is not

This document states the security posture of **PaperTape** in plain terms. It is meant to prevent mistaking a visual file format for a security product.

---

## What PaperTape is

PaperTape is a **macOS utility that represents data as punched paper tape with eight or nine data channels** — as an interactive strip and as a portable **`.Tape`** text file.

From a data-handling standpoint it:

| Capability | What it actually does |
|------------|------------------------|
| **Encoding** | Maps bytes → column tokens (holes / multilevel depths / grayscale) in a documented layout |
| **Decoding** | Reverses that mapping to restore the original bytes **losslessly** |
| **Optional compression** | Shrinks the payload (LZFSE, Zlib, LZ4, LZMA, or none) before punching — for size, not secrecy |
| **Optional Base85 (Ascii85)** | Transfer-encodes the payload into a more printable form — for strip aesthetics / text-friendliness, not secrecy |
| **Packing (v4–v9)** | Packs more payload bits into each column — density, not cryptography |
| **Integrity markers** | Writes CRC-32, XOR, and SUM8 over column blocks (`# @block`) so accidental corruption is easier to notice |
| **Archives** | Packs a folder tree into one `.Tape` (`mode: archive`) and can extract it again |
| **Local files** | Reads and writes files you choose (or drop) on your Mac; no network protocol of its own |

Anyone with PaperTape (or a correct implementation of [FORMAT.md](FORMAT.md)) who obtains a `.Tape` file can restore the payload, subject only to file access and correct decoding.

---

## What PaperTape is not

| It is not… | Why that matters |
|------------|------------------|
| **Encryption** | There is no cipher, no key, no password, and no secrecy layer. Compression and Base85 are reversible encodings, not encryption. |
| **Obfuscation for secrecy** | Multilevel glyphs, hex-pair tokens, and dense packing may look opaque to a casual glance, but they are **public, documented encodings**. Treat a `.Tape` like any other export of the same data. |
| **A password manager, vault, or DRM tool** | It does not protect secrets at rest or enforce access control beyond ordinary OS file permissions. |
| **Cryptographic authentication** | Block CRC-32 / XOR / SUM8 detect many **accidental** bit flips and edits. They do **not** prove origin, integrity against a skilled attacker, or authenticity. An adversary can rewrite columns and recompute matching checksums. |
| **A secure channel** | PaperTape does not provide confidentiality, integrity, or authenticity over a network. Sharing a `.Tape` is like sharing the original file (often larger, as text). |
| **Anonymity or anti-forensics** | Headers may record original names, sizes, compression choices, and structure. Restored data is the original payload. |
| **A substitute for backups with integrity guarantees** | Integrity markers help catch glitches; they are not a substitute for proper backup verification or cryptographic hashes you trust end-to-end. |
| **A sandbox or malware scanner** | Punching or extracting untrusted files has the same risk as opening those files any other way. Treat extracted content with normal caution. |

**Rule of thumb:** if the original bytes were not secret, the `.Tape` is not secret. If the original bytes *were* secret, encrypt them with a real tool **before** (or instead of) punching them into paper-tape form.

---

## Integrity vs security

PaperTape’s `# @block … crc32=… xor=… sum8=…` markers are **error-detection aids** for the column body:

- **Useful for:** spotting truncated downloads, botched edits, or media glitches when reading a `.Tape`.
- **Not useful for:** proving “this file came from a trusted party” or “nobody modified it on purpose.”

For cryptographic integrity or authenticity, use signatures or authenticated encryption (e.g. age, OpenPGP, `openssl`, platform keychain-backed tools) **outside** PaperTape.

---

## Threat model (summary)

| Goal | PaperTape appropriate? |
|------|-------------------------|
| Fun / education / visual archival of non-sensitive data | Yes |
| Portable lossless encode of files you already protect with OS permissions | Yes |
| Hide content from someone who can read the `.Tape` file | **No** |
| Password-protect a payload | **No** (use real encryption first) |
| Detect casual corruption of a `.Tape` | Partially (block checksums) |
| Detect hostile tampering | **No** (checksums are forgeable) |
| Safe execution of untrusted binaries after extract | **No** (OS / user judgment) |

---

## Data you should assume is visible

A `.Tape` file is **UTF-8 text**. Besides the column body, headers and markers may expose:

- Original **file or archive member names**
- **Sizes** and packing / compression / transfer choices
- **Block checksum values** (not secrets; aids verification only)
- Structure of folder archives (`# @file …`)

Do not put credentials, keys, or private documents into PaperTape unless you accept that the resulting file is as sensitive as the input — and usually **easier to skim** as text.

---

## Safe practices

1. **Classify the payload first.** Public or already encrypted → fine to punch. Secrets → encrypt with a dedicated tool, then optionally punch the ciphertext if you want the aesthetic.
2. **Use OS permissions.** `.Tape` files on disk are protected only by filesystem ACLs, disk encryption (FileVault), and who you share with.
3. **Do not treat packed formats (including v7/v8/v9) as “harder to read.”** Packing can reduce column count; it does not add secrecy. v9 Base512 is a reversible nine-bit representation, not encryption.
4. **Verify untrusted extracts** the same way you would any download (hash from a trusted channel, antivirus policy, don’t run unknown binaries).
5. **Report real security bugs** (e.g. path traversal on archive extract, unexpected network behavior, memory safety issues) as product defects — not as “crypto breaks,” since there is no crypto product surface.

---

## Scope of this document

This file describes **security intent and non-goals** of PaperTape as a paper-tape encoder/decoder. It is not a penetration-test report, formal threat model, or compliance statement (no SOC 2, FIPS, etc. claims).

For how the format works, see [FORMAT.md](FORMAT.md). For features and usage, see [README.md](README.md).
