# EasyPub local Kindling revision

Based on upstream 0.45.6, commit `4627d4d47da5f28b2e048fb1879a64cb4278ef23`.
`UPSTREAM.json` records the pristine source hashes. MIT license retained in LICENSE.
This is a separate Cargo workspace. The bibliography revision is included in
the EasyPub kindle-metadata review package. The contributor change is included
starting with the kindle-translator review package; see the main implementation log.

Changes:

- Parse publisher, description and explicitly typed `urn:isbn:` identifiers.
- Pass description and subject to the existing ordinary-book EXTH builder.
- Assemble publisher (101) and ISBN (104) records before computing record-zero offsets.
- Preserve the package unique identifier independently of ISBN.
- Preserve each OPF contributor in an EXTH 108 record, separately from the author.
- Normalize host path separators before resolving EPUB dot segments in cross-reference checks,
  including nested image references and references escaping the container on Windows.
- Reflowable vertical books (V28): read `<meta name="primary-writing-mode">` from the OPF and,
  for non-fixed-layout books, write it into EXTH 525 (replacing the hard-coded `horizontal-lr`)
  and add EXTH 527 `rtl` when the spine is right-to-left, as KindleGen does. CSS (`writing-mode`,
  `text-combine-upright`, `text-emphasis`) and `<ruby>` already pass through unchanged.

No completed AZW3 files are rewritten. Original source checkout remains read-only.
EXTH 108 is a generic contributor field, not a translator-role field. The EPUB
role refinement and the title-page translator element remain the role-bearing
representations. Mapping reference: https://github.com/kovidgoyal/calibre/blob/master/format_docs/pdb/mobi.txt
Complete visual/device acceptance remains pending.

## V37 build performance (2026-10-14)

- `kindling-cli build --threads N` selects 1–64 Rayon workers. Omit it to use
  Rayon's default (including `RAYON_NUM_THREADS`). The option configures only
  the converter process; the EasyPub settings UI is outside this patch.
- EPUB extraction shares immutable compressed bytes between independent ZIP
  cursors, creates each parent directory once, and writes file chunks in
  parallel. File contents are retained in a per-build `ContentCache` carried
  by `OPFData`, not in a global cache. Readers borrow bytes/text where possible
  and fall back to the filesystem for loose OPFs or uncached paths.
- The cache covers profile detection, shared `ExtractedEpub::read`, encoding
  and content preflight checks, navigation/dictionary/metadata checks, media-type
  sniffing, image inspection, missing image discovery, dictionary/book HTML,
  fonts, NCX/NAV and CSS. Profile detection scans each
  spine item once while retaining dictionary priority over fixed layout.
- Cache keys normalize separators, dot segments and Windows verbatim prefixes.
  Filesystem canonicalization remains the fallback, including symlinks and
  direct OPF paths. Extraction preserves archive-order writes for aliases;
  on Windows, file/directory aliases and alternate-stream names use sequential
  extraction without retained content. Alias detection uses Windows
  `CompareStringOrdinal` with its Unicode uppercase table, sorting normalized
  UTF-16 paths once. Ordinary Chinese and other Unicode entry names retain
  parallel extraction and caching; neither linguistic case folding nor Unicode
  normalization merges distinct filenames. Entries escaping the extraction
  directory are rejected.
- HTML cleanup, font-style stripping, image discovery, CSS link scanning,
  media checks and filesystem queries use indexed parallel collection and
  merge in their original input order (or the original sorted image set).
  CSS references are deduplicated by first-seen href before parallel path
  resolution; resolved aliases are merged in first-seen order as well.
- CSS manifest traversal now follows OPF document order, retaining only the
  effective manifest entry for each ID. The previous randomized HashMap walk
  could emit two different CSS flows for the same book.
- File-case validation indexes each directory with exact and ASCII-folded
  names. This removes both repeated directory enumeration and the remaining
  quadratic in-memory name comparisons, preserving exact-name priority and
  the original last case-insensitive match.
- Temporary files are deleted in parallel before removing the directory tree.
- KF8, HTML cleanup, image rewriting and font-style stripping reuse compiled
  regular expressions across spine parts. Legacy MOBI7 transforms each chapter
  in parallel, then merges in spine order before assigning offsets or resolving
  links, retaining the original first HTML head and cross-document targets.
- `KINDLING_PROFILE=1` emits phase durations on stderr; it is silent when the
  variable is absent. No `KINDLING_SEQ_*` experiment switches are retained.

Byte comparisons mask only PDB offsets `[36, 44)` (creation/modification time).
The original converter's random CSS order is checked by independently matching
each affected output against repeated original builds. These are converter
compatibility checks, not Kindle-device layout acceptance.

Measurements, corpus comparisons, repeatability results and release verification
are recorded in [PERFORMANCE_20261014.md](PERFORMANCE_20261014.md).
The Unicode path follow-up is recorded in
[PERFORMANCE_UNICODE_20261014.md](PERFORMANCE_UNICODE_20261014.md).

## V47 — Kindle guide and StartReading (2026-10-15, OUT-085)

- `opf.rs` / `nav.rs`: read explicit cover/toc/text guide references; EPUB 3
  landmarks fill missing types. Resolve relative URLs, percent-encoded Unicode
  paths/fragments and XML entities without adding landmarks to the chapter TOC.
  Include explicitly referenced HTML manifest items outside the spine in a
  build-local OPF copy (cover first, other extra pages last); extraction bytes
  remain shared and the original package is not changed.
- `mobi.rs`: retain a cover page explicitly targeted by the guide; reserve
  fixed-width MOBI7 guide references before calculating text/link offsets.
  Pass each section's resolved reading start to EXTH and assemble KF8 guide
  records with section-relative header pointers. Convert the declared cover's
  single-image SVG wrapper to an `img` so both formats can resolve the image
  resource; arbitrary SVG artwork is left unchanged.
- `kf8.rs`: resolve targets against final skeleton/fragment markup, emit sorted
  guide INDX/CNCX entries (title tag 1, fid/offset tag 6), and calculate EXTH 116
  in reconstructed text coordinates, following Calibre's writer8 format.
- `exth.rs`: append EXTH 116 only for a resolved text destination. Books without
  guide/landmarks keep their previous metadata, text, and record layout.
- `checks/opf_grammar.rs`: initialize the new OPF guide field in its existing
  test fixture. `tests/easypub_navigation.rs`: verify real output destinations,
  compressed/uncompressed and standalone/dual modes, missing targets and links.

Validation and device limitations: [V47 evidence](../../docs/evidence/v47-kindle-navigation-20261015.md).
