// End to end test of GraderService: real EditorPage objects with a PDF
// background (in memory, as for an inline asset) and real strokes.
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/_asset_cache.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/grader_service.dart';
import 'package:saber/grading/models.dart';
import 'package:sbn/tool_id.dart';

import 'fixtures/pdf_fixtures.dart';
import 'fixtures/stroke_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initPdfrx);

  late AssetCache assets;
  setUp(() => assets = AssetCache());
  tearDown(() => assets.dispose());

  // The note pages the editor would make for [doc] (an in-memory PDF).
  List<EditorPage> notePages(FxDoc doc, Uint8List bytes) => [
    for (var i = 0; i < doc.texts.length; i++)
      EditorPage(
        size: doc.noteSize(i),
        backgroundImage: PdfEditorImage(
          id: 1 + i,
          assetCache: assets,
          pdfBytes: bytes,
          pdfFile: null,
          pdfPage: i,
          pageIndex: i,
          pageSize: doc.noteSize(i),
          naturalSize: doc.texts[i].pdfSize,
          onMoveImage: null,
          onDeleteImage: null,
          onMiscChange: null,
        ),
      ),
  ];

  Future<(FxDoc, List<EditorPage>)> open(List<FxPage> pdf) async {
    final doc = await FxDoc.open(pdf);
    addTearDown(doc.dispose);
    return (doc, notePages(doc, await buildPdf(pdf)));
  }

  test('strokeToInk keeps outline, bounds and tool', () {
    final s = stroke(circleAround(const Rect.fromLTWH(100, 100, 30, 20)));
    final i = strokeToInk(s);
    expect(i.toolId, ToolId.fountainPen);
    expect(i.outline, s.highQualityPolygon);
    expect(i.bounds, s.highQualityPath.getBounds());
    expect(i.bounds.center.dx, closeTo(115, 3));
  });

  test('grades a note: PDF backgrounds, strokes, key', () async {
    final (doc, pages) = await open([
      questionPage(questions()),
      keyPage('BCADBC'.split('')),
    ]);
    pages[0].strokes
      ..add(stroke(circleAround(doc.labelRect(0, 1, 'B'))))
      ..add(stroke(circleAround(doc.labelRect(0, 2, 'A'))))
      ..add(
        stroke(
          circleAround(doc.labelRect(0, 3, 'D')),
          tool: ToolId.highlighter,
          size: 20,
        ),
      );

    final service = GraderService();
    final result = await service.grade(pages);
    expect(result.keyStatus, KeyStatus.found);
    expect(summarize(result), [
      't0#1 B/B correct',
      't0#2 A/C wrong',
      't0#3 -/A unanswered',
      't0#4 -/D unanswered',
      't0#5 -/B unanswered',
      't0#6 -/C unanswered',
    ]);
  });

  test('pages without a PDF background are skipped; text is cached', () async {
    final (doc, pages) = await open([
      questionPage(questions()),
      keyPage('BCADBC'.split('')),
    ]);
    // A plain page in front and a trailing blank page, as Saber adds one.
    pages.insert(0, EditorPage());
    pages.add(EditorPage());
    pages[1].strokes.add(stroke(circleAround(doc.labelRect(0, 1, 'B'))));

    final service = GraderService();
    final first = await service.grade(pages);
    final second = await service.grade(pages);
    expect(summarize(first).first, 't0#1 B/B correct');
    expect(first.grades, second.grades);
    // Grades refer to the note's page indices (the PDF page is note page 1).
    expect(first.grades.every((g) => g.pageIndex == 1), isTrue);
    service.clearCache();
    expect((await service.grade(pages)).grades, first.grades);
  });

  test('a note without any PDF page has nothing to grade', () async {
    final result = await GraderService().grade([EditorPage(), EditorPage()]);
    expect(result.keyStatus, KeyStatus.unknown);
    expect(result.grades, isEmpty);
  });

  test('the key override is passed through', () async {
    final (doc, pages) = await open([
      questionPage(questions(count: 3)),
      keyPage('BCA'.split('')),
    ]);
    pages[0].strokes.add(stroke(circleAround(doc.labelRect(0, 1, 'B'))));
    final service = GraderService();
    expect((await service.grade(pages)).keyStatus, KeyStatus.unknown);
    final r = await service.grade(pages, keyOverride: const KeyOverride({1}));
    expect(r.keyStatus, KeyStatus.found);
    expect(summarize(r).first, 't0#1 B/B correct');
  });
}
