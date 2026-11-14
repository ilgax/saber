// A key printed as a line at the bottom of each question page (and not on a
// page of its own), paired with the questions of the same page.
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/key/key_page_detector.dart';
import 'package:saber/grading/models.dart';

import 'fixtures/flexcil_fixtures.dart';
import 'fixtures/pdf_fixtures.dart';
import 'fixtures/stroke_fixtures.dart';

void main() {
  setUpAll(initPdfrx);

  Future<FxDoc> open(List<FlexcilContent> pages) async {
    final doc = await FxDoc.open([for (final p in pages) flexcilPage(p)]);
    addTearDown(doc.dispose);
    return doc;
  }

  test('the footer key is found, paired and not read as a question', () async {
    final doc = await open([flexcilContent('DAAEBA')]);
    final strokes = {
      0: [
        // 1 -> D (right), 2 -> C (wrong, key A), 3 -> A (right), 5 -> E.
        ink(circleAround(doc.labelRect(0, 1, 'D'))),
        ink(circleAround(doc.labelRect(0, 2, 'C'))),
        ink(circleAround(doc.labelRect(0, 3, 'A'))),
        ink(circleAround(doc.labelRect(0, 5, 'E'))),
      ],
    };
    final out = gradeDetailed(doc.gradingPages(strokes));
    final analysis = out.analysis;
    expect(analysis.footerKeyPages, {0});
    expect(analysis.detection.keyPages, isEmpty);
    expect(analysis.pairingProblem, isNull);
    expect(analysis.tests, hasLength(1));
    expect(analysis.tests.single.map((q) => q.number), [1, 2, 3, 4, 5, 6]);
    for (final q in analysis.tests.single) {
      expect(q.options.map((o) => o.letter).join(), 'ABCDE');
    }
    expect(out.result.keyStatus, KeyStatus.found);
    expect(summarize(out.result), [
      't0#1 D/D correct',
      't0#2 C/A wrong',
      't0#3 A/A correct',
      't0#4 -/E unanswered',
      't0#5 E/B wrong',
      't0#6 -/A unanswered',
    ]);
  });

  test('every page numbered 1-6 pairs with its own footer key', () async {
    final doc = await open([
      flexcilContent('DAAEBA'),
      flexcilContent('BCDABE'),
    ]);
    final strokes = {
      0: [ink(circleAround(doc.labelRect(0, 1, 'D')))],
      1: [
        ink(circleAround(doc.labelRect(1, 1, 'B'))),
        ink(circleAround(doc.labelRect(1, 6, 'E'))),
        ink(circleAround(doc.labelRect(1, 4, 'D'))),
      ],
    };
    final r = gradeDocument(doc.gradingPages(strokes));
    expect(r.keyStatus, KeyStatus.found);
    expect(summarize(r), [
      't0#1 D/D correct',
      't0#2 -/A unanswered',
      't0#3 -/A unanswered',
      't0#4 -/E unanswered',
      't0#5 -/B unanswered',
      't0#6 -/A unanswered',
      't1#1 B/B correct',
      't1#2 -/C unanswered',
      't1#3 -/D unanswered',
      't1#4 D/A wrong',
      't1#5 -/B unanswered',
      't1#6 E/E correct',
    ]);
    expect(
      r.grades.where((g) => g.testIndex == 1).every((g) => g.pageIndex == 1),
      isTrue,
    );
  });

  test('a test over two pages merges the key lines of its pages', () async {
    final doc = await open([
      flexcilContent('DAAEBA'),
      flexcilContent('BCDABE', first: 7),
    ]);
    final out = gradeDetailed(doc.gradingPages({}));
    expect(out.analysis.tests, hasLength(1));
    expect(out.analysis.tests.single, hasLength(12));
    final block = out.analysis.pairedBlocks!.single;
    expect(block.answers[1], 'D');
    expect(block.answers[7], 'B');
    expect(block.answers[12], 'E');
    expect(out.result.grades, hasLength(12));
    expect(out.result.keyStatus, KeyStatus.found);
  });

  test('a page number in the key line row does not hide the key', () async {
    final doc = await open([flexcilContent('DAAEBA')]);
    final footer = KeyPageDetector.footerKey(0, doc.texts[0])!;
    expect(
      footer.entries.map((e) => '${e.number}${e.letter}').join(' '),
      '1D 2A 3A 4E 5B 6A',
    );
    expect(footer.entries.every((e) => e.rect != null), isTrue);
    // The stripped text keeps the questions and the page number only.
    expect(footer.stripped.tokens.any((t) => t.text == '145'), isTrue);
    expect(footer.stripped.fullText.contains('1. D'), isFalse);
  });

  test('a short or missing key line is not a key', () async {
    final doc = await open([
      flexcilContent('DAAEBA', footerOverride: '1. D  2. A  3. A  4. E'),
      flexcilContent('DAAEBA', footer: false),
    ]);
    expect(KeyPageDetector.footerKey(0, doc.texts[0]), isNull);
    expect(KeyPageDetector.footerKey(1, doc.texts[1]), isNull);
    final out = gradeDetailed(doc.gradingPages({}));
    expect(out.analysis.footerKeyPages, isEmpty);
    expect(out.result.keyStatus, KeyStatus.unknown);
    expect(
      out.result.grades.every((g) => g.verdict == Verdict.unanswered),
      isTrue,
    );
  });

  test('a separate key page still wins over footer lines', () async {
    final doc = await FxDoc.open([
      flexcilPage(flexcilContent('DAAEBA')),
      keyPage('DAAEBA'.split('')),
    ]);
    addTearDown(doc.dispose);
    final out = gradeDetailed(doc.gradingPages({}));
    expect(out.analysis.detection.keyPages, {1});
    expect(out.analysis.footerKeyPages, isEmpty);
    expect(out.result.keyStatus, KeyStatus.found);
  });
}
