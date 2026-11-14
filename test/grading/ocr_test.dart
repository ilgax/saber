// OCR: conversion of recognized words to page text, the decision to run it,
// rendering without annotations, the caches, and a whole Flexcil-like page
// (watermark-only text layer, questions and key in the image, answers as PDF
// ink annotations) graded through GraderService with a fake engine.
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/_asset_cache.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/grader_service.dart';
import 'package:saber/grading/grading_config.dart';
import 'package:saber/grading/layout/question_locator.dart';
import 'package:saber/grading/layout/text_extractor.dart';
import 'package:saber/grading/ocr/ocr_engine.dart';
import 'package:saber/grading/ocr/ocr_store.dart';
import 'package:saber/grading/ocr/ocr_text.dart';
import 'package:saber/grading/ocr/page_ocr.dart';
import 'package:saber/grading/report.dart';

import 'fixtures/flexcil_fixtures.dart';
import 'fixtures/ocr_fixtures.dart';
import 'fixtures/pdf_fixtures.dart';
import 'fixtures/raw_pdf_fixtures.dart';

const _pdfSize = Size(612, 792);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initPdfrx);

  group('ocrToPageText', () {
    const box = Rect.fromLTWH(120, 240, 60, 30); // 2 x 3 pixel scale
    PageText convert(OcrWord word) => ocrToPageText(
      OcrPage(width: 1224, height: 1584, words: [word]),
      pageIndex: 3,
      pdfSize: _pdfSize,
      rotation: 90,
    );

    test('scales pixels to points and splits boxes per symbol', () {
      final t = convert(
        const OcrWord(
          'D)',
          box,
          symbols: [
            OcrSymbol('D', Rect.fromLTWH(120, 240, 40, 30)),
            OcrSymbol(')', Rect.fromLTWH(160, 240, 20, 30)),
          ],
        ),
      );
      expect(t.source, TextSource.ocr);
      expect(t.pageIndex, 3);
      expect(t.rotation, 90);
      expect(t.fullText, 'D)');
      expect(t.charRects[0], const Rect.fromLTRB(60, 120, 80, 135));
      expect(t.charRects[1], const Rect.fromLTRB(80, 120, 90, 135));
      expect(t.tokens.single.text, 'D)');
    });

    test('without symbols the word box is shared evenly', () {
      final t = convert(const OcrWord('AB', box));
      expect(t.charRects[0], const Rect.fromLTRB(60, 120, 75, 135));
      expect(t.charRects[1], const Rect.fromLTRB(75, 120, 90, 135));
    });

    test('symbols that do not spell the word are ignored', () {
      final t = convert(
        const OcrWord(
          'AB',
          box,
          symbols: [OcrSymbol('X', Rect.fromLTWH(0, 0, 10, 10))],
        ),
      );
      expect(t.charRects[0].left, 60);
    });

    test(
      'words are separate tokens; blank and degenerate words are skipped',
      () {
        final t = ocrToPageText(
          const OcrPage(
            width: 612,
            height: 792,
            words: [
              OcrWord('1.', Rect.fromLTWH(10, 10, 12, 10)),
              OcrWord('D', Rect.fromLTWH(26, 10, 6, 10)),
              OcrWord('  ', Rect.fromLTWH(40, 10, 6, 10)),
              OcrWord('X', Rect.fromLTWH(50, 10, 6, 0)),
            ],
          ),
          pageIndex: 0,
          pdfSize: _pdfSize,
        );
        expect(t.tokens.map((x) => x.text), ['1.', 'D']);
      },
    );

    test('an empty image size gives an empty page', () {
      final t = ocrToPageText(
        const OcrPage(width: 0, height: 0, words: []),
        pageIndex: 0,
        pdfSize: _pdfSize,
      );
      expect(t.hasText, isFalse);
    });
  });

  group('textLayerNeedsOcr', () {
    test('a watermark-only text layer needs OCR, real pages do not', () async {
      final doc = await FxDoc.open([
        const FxPage([Fx(watermark, 120, 20, size: 9)]),
        questionPage(questions()),
        keyPage('BCADBC'.split('')),
        blankPage(),
      ]);
      addTearDown(doc.dispose);
      expect(doc.texts[0].fullText.trim().length, lessThan(60));
      expect(textLayerNeedsOcr(doc.texts[0]), isTrue);
      expect(textLayerNeedsOcr(doc.texts[1]), isFalse);
      expect(textLayerNeedsOcr(doc.texts[2]), isFalse);
      expect(textLayerNeedsOcr(doc.texts[3]), isTrue);
    });

    test('a short page with questions is not recognized again', () async {
      final doc = await FxDoc.open([questionPage(questions(count: 2))]);
      addTearDown(doc.dispose);
      expect(
        doc.texts[0].fullText.replaceAll(RegExp(r'\s'), '').length,
        lessThan(GradingConfig.ocrMinTextLayerChars),
      );
      expect(textLayerNeedsOcr(doc.texts[0]), isFalse);
    });

    test('OCR text is never recognized again', () {
      final t = ocrToPageText(
        const OcrPage(width: 612, height: 792, words: []),
        pageIndex: 0,
        pdfSize: _pdfSize,
      );
      expect(textLayerNeedsOcr(t), isFalse);
    });
  });

  group('OcrStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ocr_store'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('round trips pages and survives corruption', () async {
      final store = OcrStore(Directory('${dir.path}/ocr'));
      expect(await store.load('abc'), isEmpty);
      const page = OcrPage(
        width: 100,
        height: 200,
        words: [
          OcrWord(
            'D)',
            Rect.fromLTRB(1.5, 2.5, 3.5, 4.5),
            symbols: [OcrSymbol('D', Rect.fromLTRB(1.5, 2.5, 2.5, 4.5))],
          ),
        ],
      );
      await store.save('abc', {2: page});
      final back = (await store.load('abc'))[2]!;
      expect(back.width, 100);
      expect(back.words.single.text, 'D)');
      expect(back.words.single.box, const Rect.fromLTRB(1.5, 2.5, 3.5, 4.5));
      expect(back.words.single.symbols.single.text, 'D');

      File('${dir.path}/ocr/abc.json').writeAsStringSync('{not json');
      expect(await store.load('abc'), isEmpty);
      File('${dir.path}/ocr/abc.json').writeAsStringSync('{"v":99,"pages":{}}');
      expect(await store.load('abc'), isEmpty);
    });
  });

  group('OcrReader', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ocr_reader'));
    tearDown(() => dir.deleteSync(recursive: true));

    final content = flexcilContent('DAAEBA');

    Future<PdfDocument> open() async {
      final doc = await PdfDocument.openData(
        buildRawPdf([
          RawPage(
            texts: const [Fx(watermark, 120, 20, size: 9)],
            // The user's ink must not be part of the OCR render.
            annots: [
              RawAnnot.ink([ringUser(content.label(1, 'D'))], width: 6),
            ],
          ),
        ]),
        sourceName: 'o.pdf',
      );
      addTearDown(doc.dispose);
      return doc;
    }

    test('renders at the configured scale without annotations', () async {
      final doc = await open();
      final fake = FakeOcrEngine([content.words()]);
      final reader = OcrReader(fake);
      final r = await reader.read(doc.pages[0], documentKey: 'k');
      expect(r.status, OcrStatus.used);
      final image = fake.images.single;
      expect(image.width, (612 * GradingConfig.ocrRenderScale).round());
      expect(image.height, (792 * GradingConfig.ocrRenderScale).round());
      expect(image.width * image.height, lessThan(GradingConfig.ocrMaxPixels));
      final png = img.decodePng(image.png)!;
      expect(png.width, image.width);
      // White where the ring is drawn in the annotation.
      final ring = ringUser(content.label(1, 'D')).first;
      final p = png.getPixel(
        (ring.dx * GradingConfig.ocrRenderScale).round(),
        ((792 - ring.dy) * GradingConfig.ocrRenderScale).round(),
      );
      expect(p.r, 255);
      expect(p.g, 255);
      expect(p.b, 255);
      // And the page is not simply blank: the watermark text is dark.
      var dark = 0;
      for (final px in png) {
        if (px.r < 128) dark++;
      }
      expect(dark, greaterThan(50));

      final text = r.text!;
      expect(text.source, TextSource.ocr);
      final questions = QuestionLocator.locate(text);
      expect(questions.map((q) => q.number), [1, 2, 3, 4, 5, 6]);
    });

    test('a page is recognized once per session and once per PDF', () async {
      final doc = await open();
      final fake = FakeOcrEngine([content.words()]);
      Future<OcrStore?> store() async => OcrStore(dir);
      final reader = OcrReader(fake, store: store);
      await reader.read(doc.pages[0], documentKey: 'k', hash: 'h1');
      await reader.read(doc.pages[0], documentKey: 'k', hash: 'h1');
      expect(fake.calls, 1);
      await reader.flush();
      expect(File('${dir.path}/h1.json').existsSync(), isTrue);

      // A new session reads it from disk.
      final again = FakeOcrEngine([content.words()]);
      final r = await OcrReader(
        again,
        store: store,
      ).read(doc.pages[0], documentKey: 'other', hash: 'h1');
      expect(r.status, OcrStatus.used);
      expect(again.calls, 0);
      expect(QuestionLocator.locate(r.text!), hasLength(6));

      // Another PDF is recognized again.
      await OcrReader(
        again,
        store: store,
      ).read(doc.pages[0], documentKey: 'other', hash: 'h2');
      expect(again.calls, 1);
    });

    test('unavailable, failing and throwing engines', () async {
      final doc = await open();
      final off = FakeOcrEngine(const [], available: false);
      expect(
        (await OcrReader(off).read(doc.pages[0], documentKey: 'k')).status,
        OcrStatus.unavailable,
      );
      expect(off.calls, 0);

      final missing = FakeOcrEngine(const [
        [],
      ], error: const OcrUnavailable('no plugin'));
      final reader = OcrReader(missing);
      expect(
        (await reader.read(doc.pages[0], documentKey: 'k')).status,
        OcrStatus.unavailable,
      );
      // Once unavailable, not tried again.
      await reader.read(doc.pages[0], documentKey: 'k');
      expect(missing.calls, 1);

      final broken = FakeOcrEngine(const [[]], error: StateError('x'));
      final r = await OcrReader(broken).read(doc.pages[0], documentKey: 'k');
      expect(r.status, OcrStatus.failed);
      expect(r.text, isNull);
    });
  });

  group('a Flexcil-like export through GraderService', () {
    late AssetCache assets;
    late Directory dir;
    setUp(() {
      assets = AssetCache();
      dir = Directory.systemTemp.createTempSync('ocr_service');
    });
    tearDown(() {
      assets.dispose();
      dir.deleteSync(recursive: true);
    });

    test('OCR finds questions and key, annotations are the marks', () async {
      final a = flexcilContent('DAAEBA');
      final b = flexcilContent('BCDABE');
      final bytes = buildRawPdf([
        RawPage(
          texts: const [Fx(watermark, 120, 20, size: 9)],
          annots: [
            RawAnnot.ink([ringUser(a.label(1, 'D'))]),
            RawAnnot.ink([ringUser(a.label(2, 'C'))]),
            const RawAnnot.ink(
              [
                [Offset(60, 232), Offset(110, 152), Offset(260, 252)],
              ],
              opacity: 0.35,
              width: 14,
            ),
          ],
        ),
        RawPage(
          texts: const [Fx(watermark, 120, 20, size: 9)],
          annots: [
            RawAnnot.ink([ringUser(b.label(1, 'B'))]),
            RawAnnot.ink([ringUser(b.label(6, 'E'))]),
          ],
        ),
      ]);
      final pdf = await PdfDocument.openData(bytes, sourceName: 'f.pdf');
      addTearDown(pdf.dispose);
      const size = Size(1000, 1000 * 792 / 612);
      final pages = [
        for (var i = 0; i < 2; i++)
          EditorPage(
            size: size,
            backgroundImage: PdfEditorImage(
              id: 1 + i,
              assetCache: assets,
              pdfBytes: bytes,
              pdfFile: null,
              pdfPage: i,
              pageIndex: i,
              pageSize: size,
              naturalSize: _pdfSize,
              onMoveImage: null,
              onDeleteImage: null,
              onMiscChange: null,
            ),
          ),
      ];
      final fake = FakeOcrEngine([a.words(), b.words()]);
      Future<OcrStore?> store() async => OcrStore(dir);
      final service = GraderService(ocr: fake, ocrStore: store);
      final progress = <int>[];
      final collected = await service.collectPages(
        pages,
        onProgress: (d, t) => progress.add(d),
      );
      expect(progress, [1, 2]);
      expect(fake.calls, 2);
      expect(collected.map((p) => p.text.source), [
        TextSource.ocr,
        TextSource.ocr,
      ]);
      expect(collected.map((p) => p.ocrStatus), [
        OcrStatus.used,
        OcrStatus.used,
      ]);

      final out = gradeDetailed(collected);
      expect(out.analysis.footerKeyPages, {0, 1});
      expect(summarize(out.result), [
        't0#1 D/D correct',
        't0#2 C/A wrong',
        't0#3 -/A unanswered',
        't0#4 -/E unanswered',
        't0#5 -/B unanswered',
        't0#6 -/A unanswered',
        't1#1 B/B correct',
        't1#2 -/C unanswered',
        't1#3 -/D unanswered',
        't1#4 -/A unanswered',
        't1#5 -/B unanswered',
        't1#6 E/E correct',
      ]);
      expect(out.pages[0]!.counts(fromPdf: true).ignored, 1);

      final report = buildGradingReport(
        pages: collected,
        outcome: out,
        timings: const GradingTimings(
          extraction: Duration.zero,
          grading: Duration.zero,
        ),
      );
      printOnFailure(report);
      expect(report, contains('page 1: OCR, '));
      expect(report, contains('6 question(s) + key line'));
      expect(
        report,
        contains(
          'strokes 0 (gradable 0, ignored 0, unassigned 0) + pdf ink 3 (gradable 2, ignored 1',
        ),
      );
      // OCR text never reaches the report.
      for (final secret in ['Yukaridaki', 'Kuasar', 'YildizlarLigi']) {
        expect(report, isNot(contains(secret)));
      }

      // A second service (a new session) reads the pages from the disk cache.
      final again = FakeOcrEngine([a.words(), b.words()]);
      final second = await GraderService(
        ocr: again,
        ocrStore: store,
      ).collectPages(pages);
      expect(again.calls, 0);
      expect(
        second.map((p) => p.text.fullText),
        collected.map((p) => p.text.fullText),
      );
      expect(
        Directory(dir.path).listSync().whereType<File>().map((f) => f.path),
        hasLength(1),
      );
    });

    test('without an engine the page behaves as before', () async {
      final bytes = buildRawPdf([
        const RawPage(texts: [Fx(watermark, 120, 20, size: 9)]),
      ]);
      const size = Size(1000, 1000 * 792 / 612);
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
            naturalSize: _pdfSize,
            onMoveImage: null,
            onDeleteImage: null,
            onMiscChange: null,
          ),
        ),
      ];
      final fake = FakeOcrEngine(const [], available: false);
      final collected = await GraderService(
        ocr: fake,
        ocrStore: () async => null,
      ).collectPages(pages);
      expect(collected.single.ocrStatus, OcrStatus.unavailable);
      expect(collected.single.text.source, TextSource.textLayer);
      expect(collected.single.text.tokens.length, 4);
      final out = gradeDetailed(collected);
      final report = buildGradingReport(
        pages: collected,
        outcome: out,
        timings: const GradingTimings(
          extraction: Duration.zero,
          grading: Duration.zero,
        ),
      );
      expect(report, contains('text layer, 41 chars'));
      expect(report, contains('(OCR needed but unavailable)'));
      expect(report, contains('0 question(s)'));
    });
  });
}
