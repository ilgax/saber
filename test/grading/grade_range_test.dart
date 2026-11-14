// Grading a range of pages: the range value (defaults, validation), its
// sidecar storage, and range-limited grading with the key outside the range
// and OCR only for the pages inside it.
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/_asset_cache.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/grading/grade_range.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/grader_service.dart';
import 'package:saber/grading/layout/text_extractor.dart';
import 'package:saber/grading/models.dart';
import 'package:saber/grading/ocr/ocr_store.dart';
import 'package:saber/grading/sidecar_store.dart';

import 'fixtures/flexcil_fixtures.dart';
import 'fixtures/ocr_fixtures.dart';
import 'fixtures/pdf_fixtures.dart';
import 'fixtures/raw_pdf_fixtures.dart';
import 'fixtures/stroke_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initPdfrx);

  group('GradeRange', () {
    test('defaults: nothing graded, or the pages after the last range', () {
      GradeRange d(GradeRange? last) =>
          GradeRange.defaultFor(pageCount: 15, last: last);
      expect(d(null), const GradeRange(0, 14));
      expect(d(const GradeRange(0, 4)), const GradeRange(5, 14));
      expect(d(const GradeRange(5, 8)), const GradeRange(9, 14));
      expect(d(const GradeRange(14, 14)), const GradeRange(0, 14));
      expect(d(const GradeRange(10, 14)), const GradeRange(0, 14));
      // A stored range beyond the note (pages were removed).
      expect(d(const GradeRange(10, 30)), const GradeRange(0, 14));
    });

    test('parse takes 1-based whole numbers within the page count', () {
      GradeRange? ok(String a, String b) =>
          GradeRange.parse(a, b, pageCount: 15).range;
      String? err(String a, String b) =>
          GradeRange.parse(a, b, pageCount: 15).error;
      expect(ok('6', '9'), const GradeRange(5, 8));
      expect(ok(' 1 ', '15'), const GradeRange(0, 14));
      expect(ok('3', '3'), const GradeRange(2, 2));
      expect(err('', '3'), isNotNull);
      expect(err('x', '3'), isNotNull);
      expect(err('1.5', '3'), isNotNull);
      expect(err('0', '3'), isNotNull);
      expect(err('-2', '3'), isNotNull);
      expect(err('1', '16'), isNotNull);
      expect(err('9', '6'), contains('From'));
      expect(ok('9', '6'), isNull);
    });

    test('label and coverage', () {
      expect(const GradeRange(5, 8).label, 'p6–9');
      expect(const GradeRange(5, 5).label, 'p6');
      expect(const GradeRange(0, 14).covers(15), isTrue);
      expect(const GradeRange(0, 13).covers(15), isFalse);
    });
  });

  group('sidecar', () {
    late Directory tmp;
    late SidecarStore store;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('grade_range_sidecar');
      store = SidecarStore(Directory('${tmp.path}/grading'));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('the last range round-trips and other writes keep it', () async {
      expect((await store.load('h')).lastRange, isNull);
      await store.saveLastRange('h', const GradeRange(5, 8));
      expect((await store.load('h')).lastRange, const GradeRange(5, 8));
      await store.saveKeyOverride('h', const KeyOverride({3}));
      final data = await store.load('h');
      expect(data.lastRange, const GradeRange(5, 8));
      expect(data.keyOverride, const KeyOverride({3}));
      await store.saveLastRange('h', const GradeRange(9, 14));
      expect((await store.load('h')).keyOverride, const KeyOverride({3}));
      expect((await store.load('h')).lastRange, const GradeRange(9, 14));
    });

    test('a sidecar without the field or with a bad one still loads', () async {
      store.directory.createSync(recursive: true);
      File('${store.directory.path}/old.json')
          .writeAsStringSync('{"v":1,"key":{"pages":[2]},"corr":[]}');
      final old = await store.load('old');
      expect(old.keyOverride, const KeyOverride({2}));
      expect(old.lastRange, isNull);
      for (final bad in ['"x"', '{"from":"a","to":2}', '{"from":5,"to":2}']) {
        File('${store.directory.path}/bad.json')
            .writeAsStringSync('{"v":1,"key":{"pages":[2]},"range":$bad}');
        final d = await store.load('bad');
        expect(d.lastRange, isNull, reason: bad);
        expect(d.keyOverride, const KeyOverride({2}), reason: bad);
      }
    });
  });

  group('grading a range', () {
    // Three pages of four questions each (numbers 1-12), then a key page.
    const key = 'BCADBCADBCAD';
    List<GradingPage> pagesOf(
      FxDoc doc,
      GradeRange range,
      Map<int, List<InkStroke>> strokes,
    ) => [
      for (final p in doc.gradingPages(strokes))
        GradingPage(
          pageIndex: p.pageIndex,
          text: p.text,
          noteSize: p.noteSize,
          strokes: range.contains(p.pageIndex) ? p.strokes : const [],
          inRange: range.contains(p.pageIndex),
        ),
    ];

    test('only the range is graded, the key page outside it is used', () async {
      final doc = await FxDoc.open([
        for (var p = 0; p < 3; p++)
          questionPage(questions(first: 1 + 4 * p, count: 4)),
        keyPage(key.split('')),
      ]);
      addTearDown(doc.dispose);
      // Right answer on 5 (B... key[4]) and wrong on 9; ink on page 0 too.
      final strokes = {
        0: [ink(circleAround(doc.labelRect(0, 1, 'B')))],
        1: [ink(circleAround(doc.labelRect(1, 5, key[4])))],
        2: [ink(circleAround(doc.labelRect(2, 9, 'D')))],
      };
      final out = gradeDetailed(pagesOf(doc, const GradeRange(1, 1), strokes));
      expect(out.result.grades.map((g) => g.number), [5, 6, 7, 8]);
      expect(out.result.keyStatus, KeyStatus.found);
      expect(summarize(out.result).first, 't0#5 B/B correct');
      expect(out.pages.keys, [1]);
      expect(out.questions.keys.map((id) => id.$2), [5, 6, 7, 8]);

      final all = gradeDetailed(pagesOf(doc, GradeRange.all(4), strokes));
      expect(all.result.grades, hasLength(12));
      // The grades of the range are those of the full run.
      expect(
        out.result.grades,
        all.result.grades.where((g) => g.pageIndex == 1).toList(),
      );
      expect(
        resultInRange(all.result, const GradeRange(1, 1)).grades,
        out.result.grades,
      );
    });

    test('footer keys: pages outside the range are not graded', () async {
      final contents = [
        flexcilContent('DAAEBA'),
        flexcilContent('BCDABE'),
        flexcilContent('ABCDEA'),
      ];
      final doc = await FxDoc.open([for (final c in contents) flexcilPage(c)]);
      addTearDown(doc.dispose);
      final strokes = {
        0: [ink(circleAround(doc.labelRect(0, 1, 'D')))],
        1: [ink(circleAround(doc.labelRect(1, 1, 'B')))],
        2: [ink(circleAround(doc.labelRect(2, 1, 'A')))],
      };
      final out = gradeDetailed(pagesOf(doc, const GradeRange(1, 2), strokes));
      expect(out.result.keyStatus, KeyStatus.found);
      expect(out.result.grades.map((g) => g.pageIndex).toSet(), {1, 2});
      expect(out.result.grades, hasLength(12));
      expect(summarize(out.result).first, 't1#1 B/B correct');
    });
  });

  group('GraderService with a range', () {
    late AssetCache assets;
    late Directory dir;
    setUp(() {
      assets = AssetCache();
      dir = Directory.systemTemp.createTempSync('grade_range_ocr');
    });
    tearDown(() {
      assets.dispose();
      dir.deleteSync(recursive: true);
    });

    Future<List<EditorPage>> thinPages(int n) async {
      final bytes = buildRawPdf([
        for (var i = 0; i < n; i++)
          const RawPage(texts: [Fx(watermark, 120, 20, size: 9)]),
      ]);
      final pdf = await PdfDocument.openData(bytes, sourceName: 't.pdf');
      addTearDown(pdf.dispose);
      const size = Size(1000, 1000 * 792 / 612);
      return [
        for (var i = 0; i < n; i++)
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
              naturalSize: const Size(612, 792),
              onMoveImage: null,
              onDeleteImage: null,
              onMiscChange: null,
            ),
          ),
      ];
    }

    test('OCR runs only for the pages in the range', () async {
      final pages = await thinPages(5);
      final content = flexcilContent('DAAEBA');
      final fake = FakeOcrEngine([content.words()]);
      Future<OcrStore?> store() async => OcrStore(dir);
      final service = GraderService(ocr: fake, ocrStore: store);
      final progress = <(int, int)>[];
      final collected = await service.collectPages(
        pages,
        range: const GradeRange(1, 2),
        onProgress: (d, t) => progress.add((d, t)),
      );
      expect(fake.calls, 2);
      expect(progress, [(1, 2), (2, 2)]);
      expect(collected.map((p) => p.pageIndex), [0, 1, 2, 3, 4]);
      expect(collected.map((p) => p.inRange), [
        false,
        true,
        true,
        false,
        false,
      ]);
      expect(collected.map((p) => p.text.source), [
        TextSource.textLayer,
        TextSource.ocr,
        TextSource.ocr,
        TextSource.textLayer,
        TextSource.textLayer,
      ]);
      expect(collected.every((p) => p.inRange || p.strokes.isEmpty), isTrue);

      // A second service uses the disk cache for pages outside the range, and
      // never recognizes them.
      final again = FakeOcrEngine([content.words()]);
      final second = await GraderService(
        ocr: again,
        ocrStore: store,
      ).collectPages(pages, range: const GradeRange(2, 3));
      expect(again.calls, 1); // page 3 only; page 1 and 2 come from disk.
      expect(second.map((p) => p.text.source), [
        TextSource.textLayer,
        TextSource.ocr, // cached page 1, outside the range
        TextSource.ocr,
        TextSource.ocr,
        TextSource.textLayer,
      ]);
    });

    test('chosen key pages outside the range get OCR', () async {
      final pages = await thinPages(4);
      final fake = FakeOcrEngine([flexcilContent('DAAEBA').words()]);
      final service = GraderService(ocr: fake, ocrStore: () async => null);
      final read = await service.readTexts(pages, {3});
      expect(fake.calls, 1);
      expect(read.map((p) => (p.pageIndex, p.inRange)), [(3, false)]);
      expect(read.single.text.source, TextSource.ocr);
    });
  });
}
