import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' as pw_pdf;
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/ui/mark_placement.dart';

import 'fixtures/pdf_fixtures.dart';

void main() {
  const page = Size(1000, 1414);

  test('the mark is left of the number, centred on it', () {
    final r = markRect(
      pageSize: page,
      anchor: const Rect.fromLTWH(120, 300, 30, 24),
    );
    expect(r.width, closeTo(34, 0.01));
    expect(r.right, lessThan(120));
    expect(r.center.dy, closeTo(312, 0.01));
    expect(120 - r.right, closeTo(r.width * 0.25, 0.01));
  });

  test('clamped inside the page at the left edge', () {
    final r = markRect(
      pageSize: page,
      anchor: const Rect.fromLTWH(5, 300, 30, 24),
    );
    expect(r.left, 0);
    expect(r.top, closeTo(312 - r.height / 2, 0.01));
  });

  test('clamped at the top and bottom edges', () {
    final top = markRect(
      pageSize: page,
      anchor: const Rect.fromLTWH(100, 2, 30, 24),
    );
    expect(top.top, 0);
    final bottom = markRect(
      pageSize: page,
      anchor: const Rect.fromLTWH(100, 1410, 30, 24),
    );
    expect(bottom.bottom, page.height);
  });

  test('scales with the page width', () {
    final r = markRect(
      pageSize: const Size(500, 700),
      anchor: const Rect.fromLTWH(60, 100, 15, 12),
    );
    expect(r.width, closeTo(17, 0.01));
  });

  test('a tiny page still gets a usable mark inside it', () {
    final r = markRect(
      pageSize: const Size(100, 100),
      anchor: const Rect.fromLTWH(0, 0, 10, 10),
    );
    expect(r.width, 16);
    expect(
      const Rect.fromLTWH(0, 0, 100, 100).expandToInclude(r),
      const Rect.fromLTWH(0, 0, 100, 100),
    );
  });

  group('with real pages (PageMapper, odd aspect ratio, rotation)', () {
    setUpAll(initPdfrx);

    Future<void> check(FxDoc doc, {Size? note}) async {
      doc.forcedNoteSize = note;
      final analysis = analyzeDocument(doc.gradingPages({}));
      final mapper = doc.mapper(0);
      final size = doc.noteSize(0);
      for (final q in analysis.questionsByPage[0]!) {
        final anchor = mapper.rectToNote(q.numberRect);
        final r = markRect(pageSize: size, anchor: anchor);
        expect(
          Rect.fromLTWH(0, 0, size.width, size.height).expandToInclude(r),
          Rect.fromLTWH(0, 0, size.width, size.height),
        );
        // Left of the number and vertically on it.
        expect(r.right, lessThanOrEqualTo(anchor.left + 0.01));
        expect((r.center.dy - anchor.center.dy).abs(), lessThan(0.01));
      }
    }

    test('PDF with a different aspect ratio than the note page', () async {
      final doc = await FxDoc.open([questionPage(questions())]);
      addTearDown(doc.dispose);
      await check(doc, note: const Size(1000, 1000));
    });

    for (final rotation in [
      pw_pdf.PdfPageRotation.rotate90,
      pw_pdf.PdfPageRotation.rotate270,
    ]) {
      test('rotated page (${rotation.name})', () async {
        final doc = await FxDoc.open([
          FxPage(questionPage(questions()).texts, rotation: rotation),
        ]);
        addTearDown(doc.dispose);
        await check(doc);
      });
    }
  });
}
