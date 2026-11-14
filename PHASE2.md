# Grader: Phase 2 (grading UI)

Everything here is tested on a Galaxy Tab S9 FE+ from a sideloaded CI APK, so
all diagnostics are visible or shareable in the app. Core logic is pure Dart in
`lib/grading/`; the UI is in `lib/grading/ui/`; the strings are English
constants in `lib/grading/ui/grading_strings.dart` (no i18n/slang file is
touched, to keep merges with upstream trivial).

## What was built

- **Grade button** (first entry of the editor app bar). Tap: reads the PDF text
  of every page (with a progress ring), grades on a background isolate, shows a
  chip like `17/20 correct, 2 unsure, 1 unanswered` and opens the results sheet.
  Tap the chip later to reopen the sheet. Long-press the button or chip toggles
  the debug overlay. Errors show a readable message (snackbar and tooltip),
  never a crash.
- **Marks on the pages**, in the left margin beside the question number:
  green check = correct, red cross plus the correct letter = wrong, amber `?` =
  unsure, small gray dot = unanswered, a small blue dot on a mark = you edited
  the answer. The question you opened is outlined and its read option
  highlighted.
- **Results sheet**: summary (including the wrong count), timings, key status in
  plain words, buttons *Grade again*, *Hide marks / Show marks*, *Key pages…*,
  *Share grading report*, *Copy report*, a *Debug overlay* switch, and the list of
  all questions (tap for the detail).
- **Question detail**: question, page, what was read (letter, ink type,
  confidence), the key's answer, verdict, the unsure reason in plain words, one
  *Set my answer to X* button per located option and *Clear correction*.
- **Key pages…** dialog: every PDF page with "looks like a key" and its entry
  count, checkboxes for the key pages, and per key block an optional range of
  question pages ("questions on pages 3 to 5"). The (+) button adds another
  block for the same key pages (two tests on one key page). *Reset to
  automatic* clears the choice. With a choice, keys that fail the automatic
  test still work: fewer than 5 entries, and entries followed by explanations.
- **Debug overlay** (switch in the sheet, or long-press): question regions,
  question numbers, option boxes with letters, label rects, every stroke's
  bounds tinted with the colour of the question it was assigned to and labelled
  `Q3 ring` (kinds: ring, fill, tick, underline, strike, diagonal, ignored;
  unassigned strokes gray), key pages tinted with each parsed entry outlined
  (`3=A`), and a badge per page (`p3: 6 questions`, `p5: key page, block 1, conf
  0.92`, `no text layer`).
- **Grading report** (share or copy; plain text): build info, timings, per page
  text layer / size / rotation / questions / key page / stroke counts (gradable,
  ignored, unassigned), key blocks and the pairing result, every question with
  option letters, reading (letter, ink type, confidence), key, verdict, reason,
  edited flag, a "suspicious" list (numbering gaps, fewer than 4 options, key
  entries without a question, questions without key entry, text pages without
  questions) and every `GradingConfig` constant. **Privacy:** it contains no
  PDF text except question numbers and option letters, no file names or paths
  and no stroke coordinates (unit test with distinctive words and a file name).
- **Split questions**: a question whose number and stem are at the bottom of
  one page and whose options are at the top of the next is joined. It lives on
  the page that holds the options (its anchor is a small rect left of the first
  option line, its region the options), so marks and ink matching work there.
  Only punctuated labels (`A)`, `(A)`, `A.`) count at the top of a page, and a
  page-top header without options is not a continuation.

## The two upstream hooks

See `HOOKS.md`: `GradeButton(coreInfo: coreInfo)` in the editor app bar and
`.withGradeMarks(coreInfo: coreInfo, pageIndex: pageIndex)` on the page's
`InnerCanvas` in `canvas.dart`. `git diff --stat d15bd86 -- lib ':!lib/grading'`
shows only those two files (4 lines).

State lives in a `GradeController` found through an `Expando` keyed on the
note's `EditorCoreInfo`, so button and page overlays share it and the marks
vanish when the note closes. When nothing is graded (or marks are hidden) the
overlay builds `SizedBox.shrink()`: no paint, no hit area.

### Pointer safety

Saber draws through an ancestor `Listener` + scale `GestureDetector`. All
painted content (marks, highlight, debug) is under `IgnorePointer`. Tapping a
mark uses a small `GestureDetector(supportedDevices: {touch, mouse})`, so a
stylus never enters its gesture arena. Widget tests prove: a stylus
down/move/up over a mark reaches an ancestor `Listener` and starts the
ancestor's scale gesture without opening the detail; a finger tap and a mouse
click open it; with no results the overlay has no size and no hit-testable
widget. The results sheet list is the guaranteed route to the same detail. (A
finger that draws on the page and starts on a mark can start a tap instead of a
stroke; with a stylus this cannot happen.)

## Persistence

`SidecarStore` writes small JSON files to
`<app support directory>/grading/<sha256 of the PDF bytes>.json`: never in or
next to the notes folder, never in the note file, so nothing is listed by the
file browser or synced. Writes go to a temp file and are renamed; a missing
directory or file, corrupt JSON, a wrong schema version or a failed write behave
as "nothing stored" and never throw into the UI.

- **Per PDF**: the key pages choice, stored as the PDF's own page numbers (for a
  note with one PDF), so it survives inserting pages and applies to a fresh note
  of the same PDF.
- **Per attempt**: corrections (question id, chosen letter, and an ink signature:
  tool and rounded bounds of every stroke assigned to the question). A correction
  applies only if the question's current ink matches the signature within
  1.5 note units, so a fresh note, or changed ink, does not inherit it. Measured:
  a real stroke saved with `Stroke.toJson` and loaded with `Stroke.fromJson`
  keeps its bounds exactly (shift 0.0), so the tolerance is only a safety
  margin. At most 300 corrections per file; the oldest are dropped.

## Timing (container, not the tablet)

A generated 20-question, 5-question-page test plus a key page, graded through
the real `GradeController` and a real isolate (so everything sent between
isolates is proven sendable): text extraction about 120 ms, grading about
45-55 ms, 170-180 ms wall; a second run with the page text cached about
10-20 ms. Real PDFs with more text and strokes will be slower: the sheet and the
report show the numbers measured on the tablet.

## Known limits

- Marks right of the option text and single-stroke X cross-outs are not handled
  (unchanged Phase 1 weaknesses).
- Marks are computed when you tap Grade; ink written afterwards is not reflected
  until *Grade again*.
- A note with several different PDFs stores the key choice by note page index.
- Only questions with at least A and B located are graded; a split question
  needs punctuated labels at the top of the next page.
- Key pages: at most one page range per block; two tests on one key page need the
  (+) button.
- UI strings are English only.
- The pointer-safety claims are proven in widget tests, not on the stylus; see
  the checklist.

## Optional: laptop dump tool

`test/grading/tool/dump_layout_test.dart` renders every page with the detected
layout and writes `report.txt`. It is skipped unless `GRADER_PDF` is set:

```sh
export PATH="$PWD/submodules/flutter/bin:$PATH"
GRADER_PDF=/path/to/test.pdf flutter test --no-pub test/grading/tool/dump_layout_test.dart
# optional: GRADER_OUT=/tmp/dump GRADER_SCALE=2 GRADER_KEY_PAGES=12,13
```

PowerShell: `$env:PATH = "$PWD\submodules\flutter\bin;$env:PATH"; $env:GRADER_PDF =
"C:\path\to\test.pdf"; flutter test --no-pub test/grading/tool/dump_layout_test.dart`.
Colours: blue region, red number, green option box, orange label, magenta
letter, yellow tinted page with purple outlines for key pages. Prerequisites:
Flutter from `submodules/flutter` with the version tag fetched, the Linux
packages and Rust listed in `SPIKE.md`.

## Device checklist (Galaxy Tab S9 FE+, Lamy pen; also the S Pen if available)

Note any difference between the pens in pressure, hover and palm rejection.
If an item fails, send the shared report and a screenshot with the debug
overlay on (long-press the Grade button).

- [ ] Pen latency feels unchanged while writing with no results, and with
  marks shown. *Send: which pen, notes on lag.*
- [ ] The marks and the debug overlay stay aligned with the page while zooming
  and scrolling. *Send: screenshot at an angle where it drifts.*
- [ ] Pen strokes can be drawn over a mark and across the page, and marks never
  block pen input (start a stroke on a mark with the pen). *Send: what
  happened.*
- [ ] A finger tap on a mark opens the question detail; the results sheet list
  opens the same detail. *Send: which route failed.*
- [ ] Correct, wrong, unsure and unanswered are shown correctly on three real
  test PDFs. *Send: report + screenshots of wrong reads with debug on.*
- [ ] A question split over a page break is graded on the options page. *Send:
  report + screenshots of both pages.*
- [ ] Key pages choice and corrections persist after closing and reopening the
  note, and after closing and reopening the app.
- [ ] A fresh note of the same PDF keeps the key pages choice but does not
  inherit corrections.
- [ ] No files appear in the notes folder (file browser) next to the notes.
- [ ] No Nextcloud upload of grading data (check the server's folder).
- [ ] Grading time for a real 20-question test (shown in the results sheet).
  *Send: the number.*
- [ ] *Share grading report* opens the share sheet and the text contains no
  question text, no file name and no coordinates. *Send: the report.*
