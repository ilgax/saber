import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' as pw_pdf;
import 'package:saber/grading/layout/question_locator.dart';
import 'package:saber/grading/models.dart';

import 'fixtures/pdf_fixtures.dart';

Future<List<Question>> locate(FxPage page) async {
  final doc = await FxDoc.open([page]);
  addTearDown(doc.dispose);
  return QuestionLocator.locate(doc.texts[0]);
}

String letters(Question q) => q.options.map((o) => o.letter).join();

void main() {
  setUpAll(initPdfrx);

  test('single column, stacked options, label style A)', () async {
    final qs = await locate(questionPage(questions()));
    expect(qs.map((q) => q.number), [1, 2, 3, 4, 5, 6]);
    expect(qs.map(letters), everyElement('ABCD'));
    // Question 2 starts at y = 70 + 120 pt; its options are 18 pt apart.
    final q = qs[1];
    expect(q.numberRect.left, closeTo(60, 2));
    expect(q.numberRect.top, closeTo(190, 4));
    final a = q.option('A')!, b = q.option('B')!, d = q.option('D')!;
    expect(a.labelRect.left, closeTo(90, 2));
    expect(a.labelRect.top, closeTo(214, 4));
    expect(b.labelRect.top - a.labelRect.top, closeTo(18, 1));
    expect(d.labelRect.top - a.labelRect.top, closeTo(54, 1));
    // The box covers the label and the text after it ("A) 4" is ~25 pt).
    expect(a.box.left, closeTo(a.labelRect.left, 0.01));
    expect(a.box.right, greaterThan(a.labelRect.right + 5));
    expect(a.box.bottom, lessThan(b.box.top + 2));
    // The region holds the number and every option.
    for (final o in q.options) {
      expect(q.region.expandToInclude(o.box), q.region);
    }
    expect(q.region.expandToInclude(q.numberRect), q.region);
  });

  for (final style in LabelStyle.values) {
    test('label style ${style.name}', () async {
      final qs = await locate(questionPage(questions(), style: style));
      expect(qs.map((q) => q.number), [1, 2, 3, 4, 5, 6]);
      expect(qs.map(letters), everyElement('ABCD'));
    });
  }

  test('question numbers written "1." instead of "1)"', () async {
    final qs = await locate(questionPage(questions(), numberSuffix: '.'));
    expect(qs.map((q) => q.number), [1, 2, 3, 4, 5, 6]);
  });

  test('inline options share a line and do not overlap', () async {
    final qs = await locate(questionPage(questions(), inline: true));
    expect(qs.map((q) => q.number), [1, 2, 3, 4, 5, 6]);
    for (final q in qs) {
      expect(letters(q), 'ABCD');
      for (var i = 0; i + 1 < q.options.length; i++) {
        final a = q.options[i].box, b = q.options[i + 1].box;
        expect(a.right, lessThanOrEqualTo(b.left), reason: 'q${q.number}');
        expect(a.top, closeTo(b.top, 2));
      }
    }
  });

  test('inline options with label style (A)', () async {
    final qs = await locate(
      questionPage(questions(), inline: true, style: LabelStyle.both),
    );
    expect(qs.map(letters), everyElement('ABCD'));
  });

  test('two columns are read column by column', () async {
    final qs = await locate(questionPage(questions(), columns: 2));
    expect(qs.map((q) => q.number), [1, 2, 3, 4, 5, 6]);
    expect(qs.map(letters), everyElement('ABCD'));
    expect(
      qs.take(3).map((q) => q.numberRect.left),
      everyElement(closeTo(50, 2)),
    );
    expect(
      qs.skip(3).map((q) => q.numberRect.left),
      everyElement(closeTo(330, 2)),
    );
    // Boxes stay inside their column.
    for (final q in qs.take(3)) {
      expect(q.region.right, lessThan(300));
    }
  });

  test('two columns with inline options', () async {
    final qs = await locate(
      questionPage(questions(), columns: 2, inline: true),
    );
    expect(qs.map((q) => q.number), [1, 2, 3, 4, 5, 6]);
    expect(qs.map(letters), everyElement('ABCD'));
    for (final q in qs.take(3)) {
      expect(q.region.right, lessThan(320));
    }
  });

  test('prose, a numbered non-question list and a blank page', () async {
    expect(await locate(prosePage()), isEmpty);
    expect(await locate(nonKeyListPage()), isEmpty);
    expect(await locate(blankPage()), isEmpty);
  });

  test('a stem line starting with "A" is not an option', () async {
    final qs = await locate(
      const FxPage([
        Fx('1) Read the text below carefully', 60, 70),
        Fx('A car travels 120 km in two hours.', 60, 90),
        Fx('What is its speed?', 60, 106),
        Fx('A) 40', 90, 130),
        Fx('B) 60', 90, 148),
        Fx('C) 80', 90, 166),
      ]),
    );
    expect(qs.single.options.map((o) => o.letter), ['A', 'B', 'C']);
    // The real A is the one at y = 130, not the stem line at y = 90.
    expect(qs.single.options.first.labelRect.top, greaterThan(125));
  });

  test('option text that wraps extends the box', () async {
    final qs = await locate(
      const FxPage([
        Fx('1) Pick one', 60, 70),
        Fx('A) the first answer is long and', 90, 100),
        Fx('continues here', 100, 113),
        Fx('B) short', 90, 140),
      ]),
    );
    final a = qs.single.option('A')!, b = qs.single.option('B')!;
    expect(a.box.height, greaterThan(20));
    expect(a.box.bottom, lessThan(b.box.top));
  });

  test('a question with a single option is not a question', () async {
    final qs = await locate(
      const FxPage([Fx('1) Pick one', 60, 70), Fx('A) only', 90, 100)]),
    );
    expect(qs, isEmpty);
  });

  test('numbers must follow on: a stray "7." inside text is ignored', () async {
    final qs = await locate(
      const FxPage([
        Fx('1) Compute', 60, 70),
        Fx('7. is the result of the sum', 60, 86),
        Fx('A) 1', 90, 110),
        Fx('B) 2', 90, 128),
        Fx('2) Next', 60, 160),
        Fx('A) 3', 90, 180),
        Fx('B) 4', 90, 198),
      ]),
    );
    expect(qs.map((q) => q.number), [1, 2]);
  });

  test('decimals are not question numbers', () async {
    final qs = await locate(
      const FxPage([
        Fx('1) Compute', 60, 70),
        Fx('3.5 is a number', 60, 86),
        Fx('A) 1', 90, 110),
        Fx('B) 2', 90, 128),
      ]),
    );
    expect(qs.single.number, 1);
  });

  test('numbering that restarts at 1 is kept (two tests on a page)', () async {
    final qs = await locate(
      const FxPage([
        Fx('1) First', 60, 70),
        Fx('A) x', 90, 90),
        Fx('B) y', 90, 108),
        Fx('2) Second', 60, 140),
        Fx('A) x', 90, 160),
        Fx('B) y', 90, 178),
        Fx('1) Again', 60, 220),
        Fx('A) x', 90, 240),
        Fx('B) y', 90, 258),
      ]),
    );
    expect(qs.map((q) => q.number), [1, 2, 1]);
  });

  test('page rotation: questions on an upright rotated page', () async {
    for (final rotation in [
      pw_pdf.PdfPageRotation.values[1],
      pw_pdf.PdfPageRotation.values[2],
      pw_pdf.PdfPageRotation.values[3],
    ]) {
      final doc = await FxDoc.open([
        FxPage(questionPage(questions(count: 3)).texts, rotation: rotation),
      ]);
      addTearDown(doc.dispose);
      final qs = QuestionLocator.locate(doc.texts[0]);
      expect(qs.map((q) => q.number), [1, 2, 3], reason: rotation.name);
      expect(qs.map(letters), everyElement('ABCD'));
      // Same visual position as on the unrotated page.
      expect(qs[1].numberRect.left, closeTo(60, 2), reason: rotation.name);
      expect(qs[1].numberRect.top, closeTo(190, 4), reason: rotation.name);
    }
  });
}
