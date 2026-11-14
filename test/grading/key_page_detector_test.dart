import 'package:flutter_test/flutter_test.dart';
import 'package:saber/grading/key/key_page_detector.dart';
import 'package:saber/grading/models.dart';

import 'fixtures/pdf_fixtures.dart';

Future<KeyDetection> detect(List<FxPage> pages, {KeyOverride? override}) async {
  final doc = await FxDoc.open(pages);
  addTearDown(doc.dispose);
  return KeyPageDetector.detect({
    for (var i = 0; i < doc.texts.length; i++) i: doc.texts[i],
  }, override: override);
}

void main() {
  setUpAll(initPdfrx);

  final test1 = questionPage(questions());
  const answers1 = 'BCADBC';
  const answers2 = 'DABBCA';

  test('key on the last page', () async {
    final d = await detect([test1, keyPage(answers1.split(''))]);
    expect(d.status, KeyStatus.found);
    expect(d.confidence, greaterThan(0.75));
    expect(d.blocks, hasLength(1));
    expect(d.blocks.single.firstKeyPage, 1);
    expect(d.blocks.single.lastKeyPage, 1);
    expect(d.blocks.single.answers, {
      1: 'B',
      2: 'C',
      3: 'A',
      4: 'D',
      5: 'B',
      6: 'C',
    });
  });

  group('key formats', () {
    final formats = <String, String Function(int, String)>{
      '1) A': (n, l) => '$n) $l',
      '1. A': (n, l) => '$n. $l',
      '(1) A': (n, l) => '($n) $l',
      '1 - A': (n, l) => '$n - $l',
      '1: a': (n, l) => '$n: ${l.toLowerCase()}',
    };
    formats.forEach((name, format) {
      test(name, () async {
        final d = await detect([
          test1,
          keyPage(answers1.split(''), format: format),
        ]);
        expect(d.status, KeyStatus.found);
        expect(d.blocks.single.answers.values.join(), answers1);
      });
      test('$name, three entries per line', () async {
        final d = await detect([
          test1,
          keyPage(answers1.split(''), format: format, perLine: 3),
        ]);
        expect(d.status, KeyStatus.found);
        expect(d.blocks.single.answers.values.join(), answers1);
      });
    });
  });

  test('two tests, each followed by its key', () async {
    final d = await detect([
      test1,
      keyPage(answers1.split('')),
      questionPage(questions()),
      keyPage(answers2.split('')),
    ]);
    expect(d.status, KeyStatus.found);
    expect(d.blocks, hasLength(2));
    expect(d.blocks[0].firstKeyPage, 1);
    expect(d.blocks[1].firstKeyPage, 3);
    expect(d.blocks[0].answers.values.join(), answers1);
    expect(d.blocks[1].answers.values.join(), answers2);
  });

  test('two tests, one key page with two restarting blocks', () async {
    final d = await detect([
      test1,
      questionPage(questions()),
      keyPageFromLines([...keyLines(answers1), ...keyLines(answers2)]),
    ]);
    expect(d.status, KeyStatus.found);
    expect(d.blocks, hasLength(2));
    expect(d.blocks[0].firstKeyPage, 2);
    expect(d.blocks[1].firstKeyPage, 2);
    expect(d.blocks[0].answers.values.join(), answers1);
    expect(d.blocks[1].answers.values.join(), answers2);
  });

  test('a long key over two pages is one block', () async {
    const all = 'ABCDABCDABCDABCDABCD';
    final d = await detect([
      test1,
      keyPageFromLines(keyLines(all.substring(0, 10))),
      keyPageFromLines(keyLines(all.substring(10), first: 11)),
    ]);
    expect(d.blocks, hasLength(1));
    expect(d.blocks.single.firstKeyPage, 1);
    expect(d.blocks.single.lastKeyPage, 2);
    expect(d.blocks.single.answers, hasLength(20));
  });

  test('questions, prose and a numbered list are not a key', () async {
    for (final page in [test1, prosePage(), nonKeyListPage(), blankPage()]) {
      final d = await detect([page]);
      expect(d.status, KeyStatus.unknown);
      expect(d.blocks, isEmpty);
    }
  });

  test('a list of entries that start like answers is not a key', () async {
    // "1) A ..." lines where the "letter" is the word "A".
    final d = await detect([
      const FxPage([
        Fx('1) A cat sat on the mat and looked at', 60, 60),
        Fx('2) B students were late for class today', 60, 80),
        Fx('3) A dog barked at the postman all day', 60, 100),
        Fx('4) C is the third letter of the alphabet', 60, 120),
        Fx('5) A bird sang in the tree outside', 60, 140),
        Fx('6) A fish swam in the bowl by the window', 60, 160),
      ]),
    ]);
    expect(d.status, KeyStatus.unknown);
  });

  test('too few entries are not detected automatically', () async {
    final d = await detect([test1, keyPage('BCA'.split(''))]);
    expect(d.status, KeyStatus.unknown);
  });

  test('a page with no text layer gives unknown, not an error', () async {
    final d = await detect([blankPage(), blankPage()]);
    expect(d.status, KeyStatus.unknown);
    expect(d.confidence, 0);
  });

  test('weak key (lots of other text) is found but not accepted', () async {
    final d = await detect([
      test1,
      keyPage(
        answers1.split(''),
        extra: [const Fx('Remember to check every answer carefully', 60, 400)],
      ),
    ]);
    printOnFailure('confidence ${d.confidence}');
    expect(d.blocks, hasLength(1));
    expect(d.status, KeyStatus.unknown);
  });

  test('override: the user says which pages are the key', () async {
    // Only three entries: not detected on its own.
    final pages = [test1, keyPage('BCA'.split(''))];
    expect((await detect(pages)).status, KeyStatus.unknown);
    final d = await detect(pages, override: const KeyOverride({1}));
    expect(d.status, KeyStatus.found);
    expect(d.confidence, 1);
    expect(d.blocks.single.answers, {1: 'B', 2: 'C', 3: 'A'});
  });

  test('override replaces automatic detection', () async {
    final pages = [test1, keyPage(answers1.split(''))];
    final d = await detect(pages, override: const KeyOverride({0}));
    // Page 0 holds questions, not entries: nothing to read.
    expect(d.status, KeyStatus.unknown);
  });
}
