# Grader: Phase 0 spike results

Base: upstream `d15bd86` (after v1.37.2). Checked on Linux in a headless
container, so nothing here was run on the tablet.

## Summary

| Item | Result |
| --- | --- |
| `flutter pub get` | Works |
| `flutter test` | Works; baseline recorded below |
| `flutter build apk --debug` | **Not run** (no Android SDK here, see below) |
| pdfrx text + per-character rects | Verified by test |
| PDF -> note coordinate mapping | Verified by test; **plan change** (ignore `dstRect`/`backgroundFit`) |
| Stroke geometry + `toolId` without upstream edits | Verified by test |
| Note keeps the original PDF after save/reopen | Verified by reading the code, not by a test |
| Mark persistence | Decided: computed overlay + small sidecar outside the notes folder |

## Toolchain

- Flutter **3.50.0** (Dart 3.14.0), pinned by the `submodules/flutter` git
  submodule at `ab2912035e`. `pubspec.yaml` requires `flutter: ">=3.50.0"`.
- Upstream CI already uses the submodule
  (`adil192/setup-flutter-submodule`), so the version is pinned in CI with no
  extra work. The Phase 5 sync workflow should do the same.
- A shallow submodule clone has no tags, and Flutter then reports version
  `0.0.0-unknown` and `pub get` fails. Fix: `git fetch --depth 1 origin tag
  3.50.0` inside the submodule (or clone with tags).
- `flutter test` on Linux builds a Rust native asset
  (`super_native_extensions`), which needs `libgtk-3-dev` (plus `clang cmake
  ninja-build pkg-config libsecret-1-dev`) and a Rust toolchain.
- **APK build not verified.** The container has no Android SDK, and installing
  one needs the Android SDK licences accepted, which I did not do on your
  behalf. Needs: JDK 25 (upstream CI uses `JAVA_HOME_25_X64`), `compileSdk 37`,
  NDK `29.0.14206865`.

Baseline `flutter test` on the untouched tree: see "Baseline tests" at the end.

## pdfrx text API (pdfrx 2.12.1, pdfrx_engine 0.9.2)

`pubspec.yaml` says `^2.5.0`; the lockfile resolves to 2.12.1. Signatures used:

```dart
// pdfrx_engine: PdfPage
Future<PdfPageRawText?> loadText();
// PdfPageRawText: String fullText; List<PdfRect> charRects;  (same length)

// extension on PdfPage
Future<PdfPageText> loadStructuredText({bool ensureLoaded = false});
// PdfPageText: fullText, charRects, List<PdfPageTextFragment> fragments
// PdfPageTextFragment: index, length, text, PdfRect bounds, charRects, direction

// PdfRect(left, top, right, bottom): PDF points, origin bottom-left, top > bottom
PdfRect rotate(int rotation, PdfPage page);

Future<PdfImage?> render({double? fullWidth, double? fullHeight, ...});
```

- `charRects[i]` is the box of `fullText[i]`, so regex match offsets map
  straight to rectangles. `loadStructuredText` additionally groups characters
  into word/line fragments with bounds, which suits option boxes.
- In tests, `pdfrxInitialize(tmpPath: ...)` (the pure Dart initialiser) loads
  PDFium from `pdfium_dart`'s native asset. No Flutter bindings or device are
  needed, so the Phase 1 fixtures can run in plain `flutter test`.
- Test PDFs can be generated with the `pdf` package, which is already a
  dependency.

Test: `test/grading/spike_pdf_text_test.dart`.

## Reaching the PDF from a note

`PdfEditorImage._pdfDocument` is private, but everything needed to reopen the
same document is public, and the call hits the same cache entry the editor
uses (no second copy in memory, no upstream edit):

```dart
final image = page.backgroundImage as PdfEditorImage;
final doc = await image.assetCache.pdfDocumentCache.load(
  image.pdfFile?.path ?? 'inline_pdf_${image.id}.pdf',
  pdfBytes: image.pdfBytes,
);
final pdfPage = doc.pages[image.pdfPage]; // pdfPage is 0-based
```

The cache key expression is copied from `PdfEditorImage.firstLoad`; if upstream
changes it we would only lose the cache sharing, not correctness.

## Coordinate mapping (plan change)

The plan says to honour `dstRect` and `backgroundFit`. For a PDF **background**
neither is used when drawing:

- `CanvasImage` positions a background image at `0,0` with the full page size
  and ignores `dstRect` (`canvas_image.dart`, `isBackground` branch).
- `PdfEditorImage.buildImageWidget` ignores `overrideBoxFit`/`backgroundFit`
  and returns a pdfrx `PdfPageView`, which always scales the page to fit and
  centres it.

So the mapper only needs the PDF page size and `EditorPage.size`:

```
scale = min(noteW / pdfW, noteH / pdfH)
x = (noteW - pdfW * scale) / 2 + pdfX * scale
y = (noteH - pdfH * scale) / 2 + (pdfH - pdfY) * scale    // y flips
```

(with `PdfRect.rotate` applied first for rotated pages). For imported PDFs the
note page has the PDF's aspect ratio, so the offsets are zero and
`scale = 1000 / pdfW`.

Verified in `spike_pdf_text_test.dart`: the mapped rect of a known glyph lands
at the expected position and, after rendering the page at note resolution,
contains the glyph's dark pixels with none just above or left of it. This is a
pixel check against pdfrx's renderer, not the on-screen debug overlay the plan
asked for; the overlay check on the tablet is still worth doing once in
Phase 2.

Not covered: PDFs set as background on a page with a different aspect ratio,
and rotated pages (formula follows pdfrx's own `toRect`, untested).

## Stroke geometry and tools

- `stroke.highQualityPath.getBounds()` and `lowQualityPath` work with no
  upstream edit. `lowQualityPolygon` / `highQualityPolygon` (`List<Offset>`)
  are public too.
- The path is the stroke's **outline** (perfect_freehand polygon), not the
  centreline. A circled option is a ring: `path.contains(centre)` is false.
  The ink matcher must therefore score on outline points/bounds, not on
  "path contains the option".
- `stroke.toolId` is a `ToolId` enum from `packages/sbn`: `highlighter`,
  `fountainPen`, `ballpointPen`, `pencil`, `shapePen` are stored strokes.
  `eraser`, `select`, `textEditing`, `laserPointer` never end up in
  `page.strokes` (laser strokes are in `page.laserStrokes`). Grading should
  use fountain pen, ballpoint, pencil and shape pen, and skip highlighter.

Test: `test/grading/spike_stroke_geometry_test.dart`.

## Does the note keep the PDF?

Yes, by reading the code (not exercised by a test):

- Import creates `PdfEditorImage(pdfFile: File(path), pdfBytes: null)`.
- On save, `PdfEditorImage.toJson` calls `assets.addFile(pdfFile)`, so the PDF
  is written as a note asset (`<note>.sbn2.<n>`). All pages of one PDF share
  one asset.
- On load, `fromJson` points `pdfFile` at that asset file and stores the page
  index in `pdfi`.

## Mark persistence: decision

**Computed overlay, nothing written into the note.** Grading a note is cheap
and deterministic, so results are recomputed when the user taps Grade. Only
the user's own decisions are persisted, in one small JSON file per test:

- which pages are the key (and question ranges, for multi-test PDFs),
- manual corrections of misread answers.

Location: the app support directory (`grading/<sha of the PDF bytes>.json`),
**not** next to the note. Reasons:

- Saber's documents folder is listed by the file browser and synced to
  Nextcloud; an extra file beside the note risks showing up or being uploaded,
  which conflicts with "no sync of grading data".
- Keying on the PDF's hash survives renaming or moving the note, with no hook
  into Saber's file manager.

Rejected: drawing marks as strokes. They would change the note's content,
be erasable, sync to the server, appear in exports, and would have to be
recognised and excluded on the next grading run.

Trade-off accepted: marks vanish when the note is closed and need one tap to
come back. If that is annoying in practice, cache the last result in the same
sidecar, keyed by a hash of the page's strokes.

## Hook points (proposal for Phase 2)

Two small edits to upstream files, to be recorded in `HOOKS.md`:

1. `lib/pages/editor/editor.dart`: one `GradeButton(coreInfo: coreInfo)` in
   the app bar `actions` list. `EditorCoreInfo.pages` is public, so the
   service needs no further hook.
2. `lib/components/canvas/canvas.dart`: wrap `InnerCanvas` in a `Stack` with
   the marks overlay. It sits inside the page's transformed box, so it follows
   zoom and scroll for free. `inner_canvas.dart` stays untouched.

## Other findings

- `flutter_secure_storage` and `http` are already dependencies (Phase 3 needs
  no new packages for key storage or the API call).
- No expression/solver package is present (`math_expressions` is not a
  dependency; `petitparser` is only transitive). Decide in Phase 3/4 whether
  to add one or hand-write the small linear/quadratic solver.
- The key regex in 3.3.1 needs the `multiLine` flag in Dart rather than
  `(?m)`.

## Baseline tests

`flutter test` on this container: 292 passed, 12 skipped, **14 failed**. All 14
failures are golden-image comparisons in upstream tests
(`glassy_container_test`, `home_theme_test`, `login_golden_test`,
`screenshot_goldens_test`), unrelated to grading. Upstream CI runs these in its
own container image after `dart run golden_screenshot:download_apple_fonts`,
which was not done here, so I expect them to be environment differences, but
that is not confirmed. The six spike tests in `test/grading/` pass, and
`flutter analyze test/grading` is clean.
