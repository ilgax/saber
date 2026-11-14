// PDF ink annotations read as marks: geometry, opacity, subtypes, rotation and
// end to end through GraderService.
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/_asset_cache.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/grader_service.dart';
import 'package:saber/grading/grading_config.dart';
import 'package:saber/grading/ink/coordinate_mapper.dart';
import 'package:saber/grading/ink/pdf_annotations.dart';
import 'package:saber/grading/ocr/ocr_engine.dart';
import 'package:saber/grading/report.dart';
import 'package:sbn/tool_id.dart';

import 'fixtures/flexcil_fixtures.dart';
import 'fixtures/pdf_fixtures.dart';
import 'fixtures/raw_pdf_fixtures.dart';
import 'fixtures/stroke_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initPdfrx);

  Future<PdfDocument> open(List<RawPage> pages) async {
    await initPdfrx();
    final doc = await PdfDocument.openData(
      buildRawPdf(pages),
      sourceName: 'raw.pdf',
    );
    addTearDown(doc.dispose);
    return doc;
  }

  group('reading annotations', () {
    test(
      'ink paths come out in PDF visual space with width and opacity',
      () async {
        final doc = await open([
          const RawPage(
            annots: [
              RawAnnot.ink([
                [Offset(100, 700), Offset(120, 690), Offset(140, 700)],
                [Offset(300, 100), Offset(310, 110)],
              ], width: 3),
              RawAnnot.ink([
                [Offset(50, 400), Offset(60, 410)],
              ], opacity: 0.3),
            ],
          ),
        ]);
        final read = await readPdfAnnotations(doc.pages[0]);
        expect(read, hasLength(2));
        final ink = read[0];
        expect(ink.subtype, 'Ink');
        expect(ink.paths, hasLength(2));
        expect(ink.paths[0].first.dx, closeTo(100, 0.01));
        expect(ink.paths[0].first.dy, closeTo(pageHeight - 700, 0.01));
        expect(ink.paths[1].last.dy, closeTo(pageHeight - 110, 0.01));
        expect(ink.width, closeTo(3, 0.01));
        expect(ink.opacity, 1);
        expect(ink.isHighlighter, isFalse);
        expect(read[1].opacity, closeTo(0.3, 0.01));
        expect(read[1].isHighlighter, isTrue);
      },
    );

    test('other subtypes, hidden annotations and highlights', () async {
      final doc = await open([
        const RawPage(
          annots: [
            RawAnnot.shape('Circle', Rect.fromLTRB(100, 500, 140, 520)),
            RawAnnot.shape('Square', Rect.fromLTRB(200, 500, 240, 520)),
            RawAnnot.shape('Highlight', Rect.fromLTRB(300, 500, 340, 520)),
            RawAnnot.poly('Line', [Offset(10, 10), Offset(60, 10)]),
            RawAnnot.poly('Polygon', [
              Offset(10, 100),
              Offset(60, 100),
              Offset(35, 140),
            ]),
            RawAnnot.poly('PolyLine', [
              Offset(10, 200),
              Offset(60, 200),
              Offset(35, 240),
            ]),
            // Hidden: flag 2.
            RawAnnot.ink([
              [Offset(5, 5), Offset(6, 6)],
            ], flags: 2),
          ],
        ),
      ]);
      final read = await readPdfAnnotations(doc.pages[0]);
      expect(read.map((a) => a.subtype), [
        'Circle',
        'Square',
        'Highlight',
        'Line',
        'Polygon',
        'PolyLine',
      ]);
      final circle = read[0];
      expect(circle.closed, isTrue);
      final b = circle.paths.single.fold<Rect>(
        Rect.fromPoints(circle.paths.single.first, circle.paths.single.first),
        (r, p) => r.expandToInclude(Rect.fromPoints(p, p)),
      );
      expect(b.left, closeTo(100, 0.5));
      expect(b.right, closeTo(140, 0.5));
      expect(b.top, closeTo(pageHeight - 520, 0.5));
      expect(read[2].isHighlighter, isTrue);
      expect(read[3].paths.single, hasLength(2));
      expect(read[4].closed, isTrue);
      expect(read[5].closed, isFalse);
    });

    test('a rotated page maps like the text does', () async {
      final doc = await open([
        const RawPage(
          rotate: 90,
          annots: [
            RawAnnot.ink([
              [Offset(100, 700), Offset(150, 650)],
            ]),
          ],
        ),
      ]);
      final page = doc.pages[0];
      expect(page.width, 792);
      final read = await readPdfAnnotations(page);
      final expected = pdfRectToVisual(
        left: 100,
        top: 700,
        right: 100,
        bottom: 700,
        pageWidth: page.width,
        pageHeight: page.height,
        rotation: page.rotation.index,
      ).topLeft;
      final p = read.single.paths.single.first;
      expect(p.dx, closeTo(expected.dx, 0.01));
      expect(p.dy, closeTo(expected.dy, 0.01));
      expect(p.dx, inInclusiveRange(0, page.width));
      expect(p.dy, inInclusiveRange(0, page.height));
      expect(p.dx, isNot(closeTo(100, 1)));
    });

    test('a page without annotations gives nothing', () async {
      final doc = await open([
        const RawPage(texts: [Fx('hello', 50, 50)]),
      ]);
      expect(await readPdfAnnotations(doc.pages[0]), isEmpty);
    });
  });

  group('conversion', () {
    final mapper = PageMapper(
      pdfSize: const Size(612, 792),
      noteSize: const Size(1000, 1000 * 792 / 612),
    );

    test('a thin outline in note units, gradable or highlighter', () {
      const path = [Offset(100, 100), Offset(200, 100), Offset(250, 150)];
      final pen = annotationToStrokes(
        const PdfInkAnnotation(
          subtype: 'Ink',
          paths: [path],
          width: 2,
          opacity: 1,
        ),
        mapper,
      ).single;
      expect(pen.fromPdf, isTrue);
      expect(GradingConfig.gradableTools.contains(pen.toolId), isTrue);
      final start = mapper.visualToNote(path.first);
      expect(pen.bounds.left, closeTo(start.dx, 2));
      expect(pen.bounds.contains(mapper.visualToNote(path[1])), isTrue);
      // Thin: a few units around the centre line, not a blob.
      expect(
        pen.bounds.width,
        lessThan((path.last.dx - path.first.dx) * mapper.scale + 10),
      );
      expect(pen.outline.length, 6);

      final marker = annotationToStrokes(
        const PdfInkAnnotation(
          subtype: 'Ink',
          paths: [path],
          width: 2,
          opacity: 0.3,
        ),
        mapper,
      ).single;
      expect(marker.toolId, ToolId.highlighter);
      expect(GradingConfig.gradableTools.contains(marker.toolId), isFalse);
    });

    test('a single point and repeated points make a small outline', () {
      final o = thinOutline([const Offset(5, 5), const Offset(5, 5)], 1);
      expect(o, hasLength(4));
      final r = Rect.fromPoints(o.first, o[2]);
      expect(r.width, closeTo(2, 1e-9));
    });
  });

  group('graded together with the text', () {
    late AssetCache assets;
    setUp(() => assets = AssetCache());
    tearDown(() => assets.dispose());

    test('rings, a translucent check and a stray scribble', () async {
      final content = flexcilContent('DAAEBA');
      final texts = [const Fx(watermark, 120, 20, size: 9), ...content.texts];
      final annots = [
        // Q1: ring around D) (right). Q2: ring around C) (wrong, key A).
        RawAnnot.ink([ringUser(content.label(1, 'D'))]),
        RawAnnot.ink([ringUser(content.label(2, 'C'))]),
        // Q3: Flexcil's big translucent check across the whole question.
        const RawAnnot.ink(
          [
            [
              Offset(60, pageHeight - 560),
              Offset(110, pageHeight - 640),
              Offset(260, pageHeight - 540),
            ],
          ],
          opacity: 0.35,
          width: 14,
        ),
        // Q4 (right column): ring around E) drawn as a Circle annotation.
        RawAnnot.shape(
          'Circle',
          Rect.fromLTRB(
            content.label(4, 'E').left - 6,
            pageHeight - content.label(4, 'E').bottom - 6,
            content.label(4, 'E').right + 6,
            pageHeight - content.label(4, 'E').top + 6,
          ),
        ),
      ];
      final bytes = buildRawPdf([RawPage(texts: texts, annots: annots)]);
      await initPdfrx();
      final pdf = await PdfDocument.openData(bytes, sourceName: 'x.pdf');
      addTearDown(pdf.dispose);
      final size = Size(1000, 1000 * pdf.pages[0].height / pdf.pages[0].width);
      final pages = [
        EditorPage(
          size: size,
          backgroundImage: PdfEditorImage(
            id: 1,
            assetCache: assets,
            pdfBytes: bytes,
            pdfFile: null,
            pdfPage: 0,
            pageIndex: 0,
            pageSize: size,
            naturalSize: Size(pdf.pages[0].width, pdf.pages[0].height),
            onMoveImage: null,
            onDeleteImage: null,
            onMiscChange: null,
          ),
        ),
      ];
      // A real stroke of the note on the same page (Q5, right column: B).
      pages[0].strokes.add(
        stroke(
          circleAround(
            PageMapper(
              pdfSize: Size(pdf.pages[0].width, pdf.pages[0].height),
              noteSize: size,
            ).rectToNote(content.label(5, 'B')),
          ),
        ),
      );

      final service = GraderService(ocr: _NoOcr(), ocrStore: () async => null);
      final collected = await service.collectPages(pages);
      final strokes = collected.single.strokes;
      expect(strokes.where((s) => s.fromPdf), hasLength(4));
      expect(strokes.where((s) => !s.fromPdf), hasLength(1));

      final out = gradeDetailed(collected);
      expect(summarize(out.result), [
        't0#1 D/D correct',
        't0#2 C/A wrong',
        't0#3 -/A unanswered',
        't0#4 E/E correct',
        't0#5 B/B correct',
        't0#6 -/A unanswered',
      ]);
      final ink = out.pages[0]!;
      expect(ink.counts(fromPdf: true).total, 4);
      expect(ink.counts(fromPdf: true).ignored, 1);
      expect(ink.counts(fromPdf: false).total, 1);

      final report = buildGradingReport(
        pages: collected,
        outcome: out,
        timings: const GradingTimings(
          extraction: Duration.zero,
          grading: Duration.zero,
        ),
      );
      printOnFailure(report);
      expect(report, contains('strokes 1 (gradable 1, ignored 0'));
      expect(report, contains('+ pdf ink 4 (gradable 3, ignored 1'));
      expect(report, contains('pdf ink kinds: ring'));
      expect(report, contains('key line'));
      expect(report, isNot(contains('Yukaridaki')));
      expect(report, isNot(contains('Kuasar')));
    });
  });
}

class _NoOcr implements OcrEngine {
  @override
  bool get isAvailable => false;

  @override
  Future<OcrPage> recognize(OcrImage image) => throw const OcrUnavailable();
}
