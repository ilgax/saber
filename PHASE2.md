# Grader: Phase 2 notes

## Real-PDF layout dump

A test-style tool that runs the Phase 1 core on one of your own PDFs and shows
what it detects, so mis-detections can be found before any UI is built. It
uses the real pipeline (`extractPageText`, `analyzeDocument`, `gradeDocument`
with no strokes, `PageMapper`); it does not reimplement detection. Nothing is
sent anywhere, no network is used, and no PDF or output is committed.

File: `test/grading/tool/dump_layout_test.dart`. Without `GRADER_PDF` it is
skipped with a reason, so the normal `flutter test --no-pub test/grading` run is
unaffected.

### Prerequisites

Same as the rest of the project (see `SPIKE.md`):

- Flutter from `submodules/flutter`, with the version tag fetched in the
  submodule (`git fetch --depth 1 origin tag 3.50.0` inside it, otherwise Flutter
  reports `0.0.0-unknown` and `pub get` fails).
- Linux: `libgtk-3-dev clang cmake ninja-build pkg-config libsecret-1-dev` and a
  Rust toolchain (needed to build the native assets for `flutter test`).
- Run from the repository root (the tool reads a font from `assets/`).

### Environment variables

| Variable | Meaning |
| --- | --- |
| `GRADER_PDF` | Path to the PDF. Required; unset means the tool is skipped. |
| `GRADER_OUT` | Output folder. Default: `grader_dump_<pdf name>` in the system temp dir. The absolute path is printed at the end. |
| `GRADER_SCALE` | Image scale, default `2` (images are 2000 px wide; the grader's note width is 1000). |
| `GRADER_KEY_PAGES` | Comma-separated 1-based page numbers to treat as the key (the manual key path), e.g. `12,13`. |

### Run

Linux / macOS:

```sh
export PATH="$PWD/submodules/flutter/bin:$PATH"
GRADER_PDF=/path/to/test.pdf flutter test --no-pub test/grading/tool/dump_layout_test.dart
# optional: GRADER_OUT=/tmp/dump GRADER_SCALE=2 GRADER_KEY_PAGES=12,13
```

Windows PowerShell:

```powershell
$env:PATH = "$PWD\submodules\flutter\bin;$env:PATH"
$env:GRADER_PDF = "C:\path\to\test.pdf"
# optional: $env:GRADER_OUT = "C:\temp\dump"; $env:GRADER_SCALE = "2"; $env:GRADER_KEY_PAGES = "12,13"
flutter test --no-pub test/grading/tool/dump_layout_test.dart
```

### Output

- `report.txt` (also printed): page count, per page text layer (char count), size,
  rotation; detected key blocks (pages, entry count, number range, confidence,
  status, and why if not found); test/key pairing or why it failed; every
  question with its options and key answer; and a SUSPICIOUS section (gaps in
  numbering, questions with fewer than 4 options, key entries with no question,
  questions with no key entry, text pages with no questions that are not key
  pages).
- `page_001.png`, `page_002.png`, ... every page rendered at note resolution
  (width 1000 times `GRADER_SCALE`) with overlays, exactly as grading would
  place them.

### Colours

- Blue outline: question region.
- Red filled box + `Q<n>`: the question number the locator found.
- Green outline: option box (label plus the rest of its text).
- Orange filled box: option label; the magenta letter to its left is the
  letter the locator assigned.
- Whole page tinted yellow with an orange border and `KEY PAGE` in the corner:
  detected (or overridden) key page. Purple outlines with `n=L`: each parsed key
  entry.
- A label in the top-left corner says if a page has no text layer or has text
  but no questions.

### What to report back

Send `report.txt` and the PNGs of pages that look wrong (missing or misplaced
boxes, wrong letters, a key page not tinted, questions on the wrong page). Say
which pages you expected to be the key and how many questions each test has.
