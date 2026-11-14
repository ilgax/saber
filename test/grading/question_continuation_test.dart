// A question split over a page break: number and stem at the bottom of one
// page, options at the top of the next.
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/layout/question_locator.dart';
import 'package:saber/grading/models.dart';

import 'fixtures/pdf_fixtures.dart';
import 'fixtures/stroke_fixtures.dart';

FxPage bottomPage() => const FxPage([
  Fx('1) What is 1 + 2?', 60, 70),
  Fx('A) 2', 90, 94),
  Fx('B) 3', 90, 112),
  Fx('C) 4', 90, 130),
  Fx('2) What is 2 + 3?', 60, 190),
  Fx('A) 4', 90, 214),
  Fx('B) 5', 90, 232),
  Fx('C) 6', 90, 250),
  // Number and stem at the very bottom: the options are on the next page.
  Fx('3) What is 3 + 4?', 60, 790),
]);

FxPage topPage({List<Fx> header = const []}) => FxPage([
  ...header,
  const Fx('A) 6', 90, 60),
  const Fx('B) 7', 90, 78),
  const Fx('C) 8', 90, 96),
  const Fx('4) What is 4 + 5?', 60, 150),
  const Fx('A) 8', 90, 174),
  const Fx('B) 9', 90, 192),
  const Fx('C) 10', 90, 210),
]);

Future<(List<Question>, FxDoc)> locateAll(List<FxPage> pages) async {
  final doc = await FxDoc.open(pages);
  addTearDown(doc.dispose);
  final a = analyzeDocument(doc.gradingPages({}));
  return ([for (final t in a.tests) ...t], doc);
}

void main() {
  setUpAll(initPdfrx);

  test('the locator reports the loose ends of each page', () async {
    final doc = await FxDoc.open([bottomPage(), topPage()]);
    addTearDown(doc.dispose);
    final first = QuestionLocator.locatePage(doc.texts[0]);
    expect(first.questions.map((q) => q.number), [1, 2]);
    expect(first.pending!.number, 3);
    expect(first.leading, isNull);
    final second = QuestionLocator.locatePage(doc.texts[1], pageIndex: 1);
    expect(second.questions.map((q) => q.number), [4]);
    expect(second.pending, isNull);
    expect(second.leading!.options.map((o) => o.letter), ['A', 'B', 'C']);
  });

  test('the split question lives on the page that holds the options', () async {
    final (qs, _) = await locateAll([bottomPage(), topPage()]);
    expect(qs.map((q) => q.number), [1, 2, 3, 4]);
    final split = qs[2];
    expect(split.pageIndex, 1);
    expect(split.continuedFromPage, 0);
    expect(split.testIndex, 0);
    expect(split.options.map((o) => o.letter), ['A', 'B', 'C']);
    // The region covers the options, the anchor sits left of the first one.
    for (final o in split.options) {
      expect(split.region.expandToInclude(o.box), split.region);
    }
    expect(split.numberRect.right, lessThan(split.options.first.box.left));
    expect(split.numberRect.top, closeTo(split.options.first.box.top, 3));
    expect(qs[3].continuedFromPage, isNull);
  });

  test('a split question is graded from ink on the options page', () async {
    final doc = await FxDoc.open([
      bottomPage(),
      topPage(),
      keyPage('BCABD'.split('')),
    ]);
    addTearDown(doc.dispose);
    // Option boxes of the continued question, found like the tests do.
    final a = analyzeDocument(doc.gradingPages({}));
    final q3 = a.questionsByPage[1]!.first.mapRects(doc.mapper(1).rectToNote);
    final r = gradeDocument(
      doc.gradingPages({
        1: [ink(circleAround(q3.option('A')!.labelRect))],
      }),
    );
    expect(summarize(r), [
      't0#1 -/B unanswered',
      't0#2 -/C unanswered',
      't0#3 A/A correct',
      't0#4 -/B unanswered',
    ]);
    expect(r.grade(3)!.pageIndex, 1);
  });

  test('a running header before the options does not stop the join', () async {
    final (qs, _) = await locateAll([
      bottomPage(),
      topPage(header: const [Fx('Maths test 2 - Name: ______', 60, 30)]),
    ]);
    expect(qs.map((q) => q.number), [1, 2, 3, 4]);
  });

  test('page-top text without options is not a continuation', () async {
    for (final header in [
      const [Fx('Maths test 2 - Name: ______', 60, 30)],
      const [Fx('A Level Mathematics', 60, 30)],
      const [Fx('Page 2 of 3', 400, 30), Fx('B students', 60, 45)],
    ]) {
      final (qs, _) = await locateAll([
        bottomPage(),
        FxPage([
          ...header,
          const Fx('4) What is 4 + 5?', 60, 150),
          const Fx('A) 8', 90, 174),
          const Fx('B) 9', 90, 192),
        ]),
      ]);
      // 3 has no options anywhere, so it is dropped as before.
      expect(qs.map((q) => q.number), [1, 2, 4]);
    }
  });

  test('no join over a prose page or when the first page is a key', () async {
    final (qs, _) = await locateAll([bottomPage(), prosePage(), topPage()]);
    expect(qs.map((q) => q.number), [1, 2, 4]);
    final (keyed, _) = await locateAll([
      bottomPage(),
      keyPage('BCABD'.split('')),
      topPage(),
    ]);
    expect(keyed.map((q) => q.number), [1, 2, 4]);
  });

  test('a lone option line is not enough', () async {
    final (qs, _) = await locateAll([
      bottomPage(),
      const FxPage([Fx('A) just one', 90, 60), Fx('4) Next', 60, 150)]),
    ]);
    expect(qs.map((q) => q.number), [1, 2]);
  });
}
