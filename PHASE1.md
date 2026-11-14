# Grader: Phase 1 (core, no UI, no LLM)

Everything is in `lib/grading/` and `test/grading/`. No upstream file is
touched and no dependency was added. Tests run with plain `flutter test`
(PDFs are generated with the `pdf` package, strokes are real Saber `Stroke`s).

## Modules

| File | Role |
| --- | --- |
| `models.dart` | `Question`, `Option`, `KeyEntry`, `KeyBlock`, `KeyDetection`, `Verdict`, `UnsureReason`, `Confidence`, `MarkReading`, `QuestionGrade`, `GradeResult`, `InkStroke` (value equality where tests compare) |
| `grading_config.dart` | every tunable number (see below) |
| `layout/text_extractor.dart` | `PageText` (chars, tokens, lines) in PDF visual space; pdfrx wrapper with a per-document-and-page cache |
| `layout/question_locator.dart` | question numbers, option labels, columns, option boxes, regions |
| `key/key_parser.dart` | `1) A`, `1. A`, `(1) A`, `1 - A`, `1: a`, several per line |
| `key/key_page_detector.dart` | key pages by pattern density, restarting blocks, `KeyOverride` |
| `ink/coordinate_mapper.dart` | `pdfRectToVisual` (flip and rotation) and `PageMapper` (visual <-> note page) |
| `ink/ink_matcher.dart` | stroke assignment and the marked-option decision |
| `compare/answer_comparer.dart` | case-insensitive letter match |
| `grader.dart` | pure `gradeDocument(List<GradingPage>, {KeyOverride?}) -> GradeResult` |
| `grader_service.dart` | the only file that knows `EditorPage`, `PdfEditorImage`, `Stroke`; `GraderService.grade(pages)`, `strokeToInk` |

Test pairing rule: questions are split into tests where numbering restarts at
1; test i is paired with key block i. If the counts differ, the key is not
confidently detected, or fewer than half of a test's question numbers appear in
its block, the key is `unknown` and every marked question is `unsure(keyUnknown)`.

## Config constants (defaults)

Lengths named `Pts` are PDF points, other lengths are note units (1000 per page
width).

- Layout: `rowOverlapFraction` 0.5, `tokenGapFraction` 0.5,
  `columnSeparationFraction` 0.25, `columnTolerancePts` 20,
  `inlineOptionGapFraction` 0.5, `minOptionsPerQuestion` 2,
  `maxQuestionNumber` 300, `maxQuestionNumberSkip` 3,
  `optionContinuationGapFraction` 0.8.
- Key: `keyMinConsecutiveRun` 5, `keyMinCoverage` 0.5,
  `keyAcceptConfidence` 0.75, `keyMinQuestionCoverage` 0.5.
- Ink: `gradableTools` {fountainPen, ballpointPen, pencil, shapePen},
  `resampleStep` 3, `regionInflate` 24, `strayDistance` 60,
  `ringMinCoverage` 0.8, `ringSectors` 16, `ringMinRadiusFraction` 0.5,
  `ringMaxInnerFraction` 0.15, `labelInflate` 3, `fillMinFraction` 0.3,
  `tickNearDistance` 25, `tickMaxDistance` 50, `tickScore` 0.85,
  `compactMaxSize` 120, `lineMaxElongation` 0.2, `lineMinLength` 20,
  `lineMaxAngleDegrees` 30, `strikeMinCoverage` 0.6,
  `strikeBandTop`/`Bottom` 0.2/0.72, `underlineBandBottom` 1.6,
  `underlineScore` 0.75, `crossMinHeightFraction` 0.5, `markThreshold` 0.4,
  `decisionMargin` 0.25, `highConfidenceScore` 0.9, `highConfidenceMargin` 0.5.

## Deviations from the plan, and assumptions that were wrong

- **Option boxes are in PDF visual space, not raw PDF coordinates**: points,
  top-left origin, y down, page rotation already applied (what pdfrx's
  `toRect(page:)` gives without scaling). `pdfRectToVisual` does this from the
  page size and rotation as pure math; `PageMapper` then maps visual <-> note
  with the SPIKE formula. Verified against rendered pixels for all four
  rotations (`coordinate_mapper_test.dart`).
- **Rotated pages**: pdfrx's `page.width/height` are already the rotated size,
  while char rects are in the unrotated page. Producing a rotated page with the
  `pdf` package works by setting `PdfPage.rotate` after `addPage`. A real
  "upright after rotation" page needs the content drawn turned the other way;
  the fixture does that (`FxPage.upright`), and the locator and grader run on
  it for 90, 180 and 270 degrees.
- **Char boxes are glyph-tight and spaces are zero-size boxes at unreliable
  positions** (on rotated pages they sit on the wrong side). Words are
  therefore split using "whitespace between two glyphs in the text order", plus
  a gap fallback. Lines are built geometrically; `fullText` order (which pdfrx
  reverses for 180 degree pages) is never relied on. `loadText()` is used, not
  `loadStructuredText()`.
- **`ensureLoaded()` hangs without a page view.** The document cache opens PDFs
  with progressive loading, which only advances when something calls
  `loadPagesProgressively()` (normally `PdfPageView`). The extractor calls it
  itself (safe to call concurrently per pdfrx docs). SPIKE.md did not cover this.
- Question numbers must follow on (`last+1`, up to a skip of 3, or restart at
  1), otherwise they are text. A numbered block without at least A and B in
  sequence is not a question and is dropped (no grade for it).
- A tick is scored by its distance to the *label* (or 0 when it overlaps the
  option text), so a tick between two inline options goes to the nearer label.
- Question and key `pageIndex` values are the note's page indices
  (`GradingPage.pageIndex`), not the PDF's.

## Fixtures

All fixtures in the prompt were built; none was skipped. Layouts: single and
two columns, stacked and inline options, `A)`, `(A)`, `A.`, `1)` and `1.`
numbers, prose pages, a page without text layer, rotated pages. Keys: last page,
two tests each with a key, two tests with one key page of two blocks, all five
formats (also three per line), numbered non-answer list, too-short key,
`KeyOverride`. Strokes: circle (label and whole option), open arc, tick, filled
bubble, underline, strike-through (also slanted), X, two options inked, no ink,
changed answer, stray mark, highlighter, boundary-crossing stroke.

`GraderService` is tested end to end with real `EditorPage`/`PdfEditorImage`
objects (in-memory PDF, so the `inline_pdf_<id>.pdf` cache key path; the
`File` path is not exercised).

## Known weaknesses

- Only PDFs made by the `pdf` package (Helvetica, simple layouts) were tried.
  Real-world PDFs (scans with OCR layers, math fonts, tables, figures between
  options) are untested, as is the real stylus.
- Ticks or marks to the right of the option text are not matched (result is
  `unsure`). A single-stroke X is read as a mark on the label, not as a
  cross-out; only two crossing diagonal strokes count as an X. A wavy
  strike-through that is not straight is read like a scribble.
- A half circle or any compact stroke on an option's line near its label counts
  as a mark on it (medium confidence).
- Column detection needs at least two question numbers per column; a page with
  one question per column is read as one column.
- Options that wrap onto the following lines are only joined when the next line
  is close; an option's own box height is the glyph height (tight).
- Keys with explanations next to each answer have low coverage and need the
  user's key-page override. Keys shorter than 5 entries are never auto-detected.
- Heavy work is synchronous; `GraderService.grade` runs `gradeDocument` on the
  calling isolate (text extraction is cached per document and page).
