// KeyOverride: short keys, keys with explanations, explicit page ranges.
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/key/key_page_detector.dart';
import 'package:saber/grading/models.dart';

import 'fixtures/pdf_fixtures.dart';
import 'fixtures/stroke_fixtures.dart';

GradeResult grade(
  FxDoc doc,
  Map<int, List<InkStroke>> strokes, {
  KeyOverride? override,
}) => gradeDocument(doc.gradingPages(strokes), keyOverride: override);

void main() {
  setUpAll(initPdfrx);

  test('a key with explanations is read through the override only', () async {
    final doc = await FxDoc.open([
      questionPage(questions()),
      keyPageFromLines([
        '1) B because two plus three is five and not six',
        '2) C since 3 + 4 = 7 (see 5. A for a longer example)',
        '3) A when you add one and the answer is A',
        '4) D the fourth one is obviously D',
        '5) B and this is explained in chapter 2. A is wrong',
        '6) C finally',
      ]),
    ]);
    addTearDown(doc.dispose);
    final strokes = {
      0: [
        ink(circleAround(doc.labelRect(0, 1, 'B'))),
        ink(circleAround(doc.labelRect(0, 2, 'A'))),
      ],
    };
    expect(grade(doc, strokes).keyStatus, KeyStatus.unknown);
    final r = grade(doc, strokes, override: const KeyOverride({1}));
    expect(r.keyStatus, KeyStatus.found);
    expect(r.keyDetection.blocks.single.answers, {
      1: 'B',
      2: 'C',
      3: 'A',
      4: 'D',
      5: 'B',
      6: 'C',
    });
    expect(summarize(r).take(2), ['t0#1 B/B correct', 't0#2 A/C wrong']);
  });

  test('a short key (three entries) via the override', () async {
    final doc = await FxDoc.open([
      questionPage(questions(count: 3)),
      keyPage('BCA'.split('')),
    ]);
    addTearDown(doc.dispose);
    final r = grade(doc, {
      0: [ink(circleAround(doc.labelRect(0, 3, 'A')))],
    }, override: const KeyOverride({1}));
    expect(summarize(r).last, 't0#3 A/A correct');
  });

  group('explicit blocks', () {
    Future<FxDoc> three() async {
      // Three tests but a key with only two blocks: automatic pairing fails.
      final doc = await FxDoc.open([
        questionPage(questions()),
        questionPage(questions()),
        questionPage(questions()),
        keyPageFromLines([...keyLines('BCADBC'), ...keyLines('DABBCA')]),
      ]);
      addTearDown(doc.dispose);
      return doc;
    }

    test('automatic pairing fails on a count mismatch', () async {
      final doc = await three();
      final a = analyzeDocument(doc.gradingPages({}));
      expect(a.pairedBlocks, isNull);
      expect(a.pairingProblem, contains('count mismatch: 3 test(s) but 2'));
    });

    test('the user names the question pages of each block', () async {
      final doc = await three();
      final override = KeyOverride.fromBlocks(const [
        KeyBlockOverride(
          firstKeyPage: 3,
          lastKeyPage: 3,
          firstQuestionPage: 0,
          lastQuestionPage: 0,
        ),
        KeyBlockOverride(
          firstKeyPage: 3,
          lastKeyPage: 3,
          firstQuestionPage: 1,
          lastQuestionPage: 1,
        ),
      ]);
      final r = grade(doc, {
        0: [ink(circleAround(doc.labelRect(0, 1, 'B')))],
        1: [ink(circleAround(doc.labelRect(1, 1, 'A')))],
        2: [ink(circleAround(doc.labelRect(2, 1, 'A')))],
      }, override: override);
      // Both blocks share key page 3: each takes one restarting block.
      expect(r.keyDetection.blocks[0].answers[1], 'B');
      expect(r.keyDetection.blocks[1].answers[1], 'D');
      expect(r.grade(1, testIndex: 0)!.verdict, Verdict.correct);
      expect(r.grade(1, testIndex: 1)!.verdict, Verdict.wrong);
      // Test 3 is outside every range: no key, unsure, never wrong.
      expect(r.grade(1, testIndex: 2)!.reason, UnsureReason.keyUnknown);
    });

    test('blocks on separate key pages, test over two pages', () async {
      final doc = await FxDoc.open([
        questionPage(questions(count: 3)),
        questionPage(questions(first: 4, count: 3)),
        questionPage(questions()),
        keyPageFromLines(keyLines('BCADBC')),
        keyPageFromLines(keyLines('DABBCA')),
      ]);
      addTearDown(doc.dispose);
      final override = KeyOverride.fromBlocks(const [
        KeyBlockOverride(
          firstKeyPage: 3,
          lastKeyPage: 3,
          firstQuestionPage: 0,
          lastQuestionPage: 1,
        ),
        KeyBlockOverride(
          firstKeyPage: 4,
          lastKeyPage: 4,
          firstQuestionPage: 2,
          lastQuestionPage: 2,
        ),
      ]);
      final r = grade(doc, {
        0: [ink(circleAround(doc.labelRect(0, 1, 'B')))],
        1: [ink(circleAround(doc.labelRect(1, 5, 'A')))],
        2: [ink(circleAround(doc.labelRect(2, 1, 'D')))],
      }, override: override);
      expect(r.keyStatus, KeyStatus.found);
      expect(summarize(r), [
        't0#1 B/B correct',
        't0#2 -/C unanswered',
        't0#3 -/A unanswered',
        't0#4 -/D unanswered',
        't0#5 A/B wrong',
        't0#6 -/C unanswered',
        't1#1 D/D correct',
        't1#2 -/A unanswered',
        't1#3 -/B unanswered',
        't1#4 -/B unanswered',
        't1#5 -/C unanswered',
        't1#6 -/A unanswered',
      ]);
      expect(r.keyDetection.blocks[0].lastQuestionPage, 1);
    });

    test('a chosen block with no readable entries is unknown', () async {
      final doc = await FxDoc.open([questionPage(questions()), prosePage()]);
      addTearDown(doc.dispose);
      final r = grade(
        doc,
        {
          0: [ink(circleAround(doc.labelRect(0, 1, 'B')))],
        },
        override: KeyOverride.fromBlocks(const [
          KeyBlockOverride(
            firstKeyPage: 1,
            lastKeyPage: 1,
            firstQuestionPage: 0,
            lastQuestionPage: 0,
          ),
        ]),
      );
      expect(r.keyStatus, KeyStatus.unknown);
      expect(summarize(r).first, 't0#1 B/- unsure(keyUnknown)');
    });
  });

  test('KeyOverride round-trips through JSON', () {
    const plain = KeyOverride({2, 5});
    expect(KeyOverride.fromJson(plain.toJson()), plain);
    final blocks = KeyOverride.fromBlocks(const [
      KeyBlockOverride(
        firstKeyPage: 3,
        lastKeyPage: 4,
        firstQuestionPage: 0,
        lastQuestionPage: 2,
      ),
      KeyBlockOverride(firstKeyPage: 6, lastKeyPage: 6),
    ]);
    expect(KeyOverride.fromJson(blocks.toJson()), blocks);
    expect(blocks.keyPages, {3, 4, 6});
  });

  test(
    'mapPages passes indices through a function and drops the unmappable',
    () {
      int? plusOne(int p) => p + 1;
      expect(
        const KeyOverride({1, 4}).mapPages(plusOne),
        const KeyOverride({2, 5}),
      );
      expect(const KeyOverride({1}).mapPages((_) => null), isNull);
      final mapped = KeyOverride.fromBlocks(const [
        KeyBlockOverride(
          firstKeyPage: 3,
          lastKeyPage: 4,
          firstQuestionPage: 0,
          lastQuestionPage: 2,
        ),
        KeyBlockOverride(firstKeyPage: 6, lastKeyPage: 6),
      ]).mapPages(plusOne)!;
      expect(mapped.blocks[0].firstKeyPage, 4);
      expect(mapped.blocks[0].lastKeyPage, 5);
      expect(mapped.blocks[0].firstQuestionPage, 1);
      expect(mapped.blocks[0].lastQuestionPage, 3);
      expect(mapped.blocks[1].firstQuestionPage, isNull);
      // An unmappable question page makes the range "automatic"; an
      // unmappable key page drops the block.
      final partial = KeyOverride.fromBlocks(const [
        KeyBlockOverride(
          firstKeyPage: 3,
          lastKeyPage: 3,
          firstQuestionPage: 0,
          lastQuestionPage: 2,
        ),
        KeyBlockOverride(firstKeyPage: 9, lastKeyPage: 9),
      ]).mapPages((p) => p == 0 || p == 9 ? null : p)!;
      expect(partial.blocks, hasLength(1));
      expect(partial.blocks.single.firstQuestionPage, isNull);
    },
  );
}
