import 'package:flutter_test/flutter_test.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/key/key_page_detector.dart';
import 'package:saber/grading/models.dart';

import 'fixtures/pdf_fixtures.dart';

Future<DocumentAnalysis> analyze(List<FxPage> pages) async {
  final doc = await FxDoc.open(pages);
  addTearDown(doc.dispose);
  return analyzeDocument(doc.gradingPages({}));
}

void main() {
  setUpAll(initPdfrx);

  test('paired: tests, blocks and question pages', () async {
    final a = await analyze([
      questionPage(questions()),
      keyPage('BCADBC'.split('')),
    ]);
    expect(a.pairingProblem, isNull);
    expect(a.tests, hasLength(1));
    expect(a.tests.single.map((q) => q.number), [1, 2, 3, 4, 5, 6]);
    expect(a.pairedBlocks!.single.firstQuestionPage, 0);
    expect(a.questionsByPage.keys, [0]);
  });

  test('key entries know where they are on the page', () async {
    final doc = await FxDoc.open([keyPage('BCADBC'.split(''))]);
    addTearDown(doc.dispose);
    final List<KeyEntry> entries = KeyPageDetector.analyze(
      0,
      doc.texts[0],
    ).entries;
    expect(entries, hasLength(6));
    // Entries are on separate lines, top to bottom, left-aligned at x=60.
    for (var i = 1; i < entries.length; i++) {
      expect(entries[i].rect!.top, greaterThan(entries[i - 1].rect!.top));
    }
    expect(entries.first.rect!.left, closeTo(60, 3));
    expect(entries.first.rect!.width, lessThan(40));
  });

  test('pairing problems are explained', () async {
    expect(
      (await analyze([questionPage(questions())])).pairingProblem,
      'no key pages found',
    );
    expect(
      (await analyze([
        questionPage(questions()),
        questionPage(questions()),
        keyPage('BCADBC'.split('')),
      ])).pairingProblem,
      contains('count mismatch: 2 test(s) but 1 key block(s)'),
    );
    expect(
      (await analyze([
        questionPage(questions()),
        keyPage('BCADBC'.split(''), firstNumber: 21),
      ])).pairingProblem,
      contains('low coverage'),
    );
    expect(
      (await analyze([blankPage(), blankPage()])).pairingProblem,
      'no key pages found',
    );
  });
}
