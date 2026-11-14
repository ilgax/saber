// End to end tests of the pure grader on generated PDFs and real strokes:
// every case asserts the exact grades, including unsure and unanswered.
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' as pw_pdf;
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/models.dart';
import 'package:sbn/tool_id.dart';

import 'fixtures/pdf_fixtures.dart';
import 'fixtures/stroke_fixtures.dart';

const key1 = 'BCADBC';
const key2 = 'DABBCA';

/// The expected summary: every question unanswered unless overridden by
/// [marks] (question number -> text after `t0#N `).
List<String> expected(
  Map<int, String> marks, {
  String key = key1,
  int test = 0,
  int count = 6,
}) => [
  for (var n = 1; n <= count; n++)
    't$test#$n ${marks[n] ?? '-/${key[n - 1]} unanswered'}',
];

/// A one page test followed by its key page.
Future<FxDoc> singleTest({
  FxPage? page,
  String key = key1,
  List<FxPage> before = const [],
}) async {
  final doc = await FxDoc.open([
    ...before,
    page ?? questionPage(questions()),
    keyPage(key.split('')),
  ]);
  addTearDown(doc.dispose);
  return doc;
}

GradeResult grade(
  FxDoc doc,
  Map<int, List<InkStroke>> strokes, {
  KeyOverride? override,
}) => gradeDocument(doc.gradingPages(strokes), keyOverride: override);

void main() {
  setUpAll(initPdfrx);

  group('marks', () {
    test('no ink at all: every question is unanswered, key is found', () async {
      final doc = await singleTest();
      final r = grade(doc, {});
      expect(r.keyStatus, KeyStatus.found);
      expect(summarize(r), expected({}));
    });

    test('circle around the label: correct, wrong, correct', () async {
      final doc = await singleTest();
      final r = grade(doc, {
        0: [
          ink(circleAround(doc.labelRect(0, 1, 'B'))),
          ink(circleAround(doc.labelRect(0, 2, 'A'))),
          ink(circleAround(doc.labelRect(0, 3, 'A'))),
        ],
      });
      expect(
        summarize(r),
        expected({1: 'B/B correct', 2: 'A/C wrong', 3: 'A/A correct'}),
      );
      expect(r.count(Verdict.correct), 2);
      expect(r.count(Verdict.wrong), 1);
      expect(r.count(Verdict.unanswered), 3);
    });

    test('circle around the whole option text', () async {
      final doc = await singleTest();
      final r = grade(doc, {
        0: [
          ink(circleAround(doc.optionBox(0, 1, 'B'), margin: 8)),
          ink(circleAround(doc.optionBox(0, 2, 'D'), margin: 8)),
        ],
      });
      expect(summarize(r), expected({1: 'B/B correct', 2: 'D/C wrong'}));
    });

    test('a circle that is not quite closed still counts', () async {
      final doc = await singleTest();
      final r = grade(doc, {
        0: [ink(circleAround(doc.labelRect(0, 1, 'B'), turns: 0.92))],
      });
      expect(summarize(r), expected({1: 'B/B correct'}));
    });

    test('tick next to the label', () async {
      final doc = await singleTest();
      final r = grade(doc, {
        0: [
          ink(tickBeside(doc.labelRect(0, 1, 'B'))),
          ink(tickBeside(doc.labelRect(0, 2, 'D'))),
        ],
      });
      expect(summarize(r), expected({1: 'B/B correct', 2: 'D/C wrong'}));
    });

    test('a lone dot beside a label is never read as a letter', () async {
      final doc = await singleTest();
      for (final size in [2.0, 5.0, 9.0]) {
        final l = doc.labelRect(0, 1, 'A');
        final dot = Offset(l.left - 12, l.center.dy);
        final r = grade(doc, {
          0: [
            ink([dot, dot + const Offset(0.5, 0)], size: size),
          ],
        });
        expect(
          summarize(r),
          expected({1: '-/B unsure(noOptionAboveThreshold)'}),
          reason: 'pen size $size',
        );
      }
    });

    test('a dot beside A does not disturb a circle on B', () async {
      final doc = await singleTest();
      final l = doc.labelRect(0, 1, 'A');
      final dot = Offset(l.left - 12, l.center.dy);
      final r = grade(doc, {
        0: [
          ink([dot], size: 5),
          ink(circleAround(doc.labelRect(0, 1, 'B'))),
        ],
      });
      expect(summarize(r), expected({1: 'B/B correct'}));
    });

    test('filled bubble on the label', () async {
      final doc = await singleTest();
      final r = grade(doc, {
        0: [
          ink(scribbleOn(doc.labelRect(0, 1, 'B'))),
          ink(scribbleOn(doc.labelRect(0, 2, 'A'))),
        ],
      });
      expect(summarize(r), expected({1: 'B/B correct', 2: 'A/C wrong'}));
    });

    test('underline under the option', () async {
      final doc = await singleTest();
      final r = grade(doc, {
        0: [ink(horizontalLine(doc.optionBox(0, 1, 'B'), 1.3))],
      });
      expect(summarize(r), expected({1: 'B/B correct'}));
    });

    test('every pen tool is graded', () async {
      final doc = await singleTest();
      final r = grade(doc, {
        0: [
          ink(circleAround(doc.labelRect(0, 1, 'B')), tool: ToolId.pencil),
          ink(
            circleAround(doc.labelRect(0, 2, 'C')),
            tool: ToolId.ballpointPen,
          ),
          ink(circleAround(doc.labelRect(0, 3, 'A')), tool: ToolId.shapePen),
          ink(circleAround(doc.labelRect(0, 4, 'D')), tool: ToolId.fountainPen),
        ],
      });
      expect(
        summarize(r),
        expected({
          1: 'B/B correct',
          2: 'C/C correct',
          3: 'A/A correct',
          4: 'D/D correct',
        }),
      );
    });

    test('two options inked: unsure, never wrong', () async {
      final doc = await singleTest();
      final r = grade(doc, {
        0: [
          ink(circleAround(doc.labelRect(0, 1, 'A'))),
          ink(circleAround(doc.labelRect(0, 1, 'B'))),
          // One circle and one tick on different options.
          ink(circleAround(doc.labelRect(0, 2, 'C'))),
          ink(tickBeside(doc.labelRect(0, 2, 'D'))),
        ],
      });
      expect(
        summarize(r),
        expected({
          1: '-/B unsure(twoOptionsClose)',
          2: '-/C unsure(twoOptionsClose)',
        }),
      );
    });

    test('one circle around two options is ambiguous', () async {
      final doc = await singleTest();
      final both = doc
          .labelRect(0, 1, 'A')
          .expandToInclude(doc.labelRect(0, 1, 'B'));
      final r = grade(doc, {
        0: [ink(circleAround(both, margin: 12))],
      });
      expect(summarize(r), expected({1: '-/B unsure(twoOptionsClose)'}));
    });

    test('ink that marks nothing is unsure, not unanswered', () async {
      final doc = await singleTest();
      final n = doc.question(0, 1).numberRect;
      // A scribble over the question's own text.
      final r = grade(doc, {
        0: [ink(scribbleOn(Rect.fromLTWH(n.left, n.top, 100, n.height)))],
      });
      expect(summarize(r), expected({1: '-/B unsure(noOptionAboveThreshold)'}));
    });

    test('circling the question number marks no option', () async {
      final doc = await singleTest();
      final n = doc.question(0, 2).numberRect;
      final r = grade(doc, {
        0: [ink(circleAround(n, margin: 8))],
      });
      expect(summarize(r), expected({2: '-/C unsure(noOptionAboveThreshold)'}));
    });

    test('underlining the question text marks no option', () async {
      final doc = await singleTest();
      final q = doc.question(0, 2);
      final stem = Rect.fromLTRB(
        q.numberRect.left,
        q.numberRect.top,
        q.numberRect.left + 150,
        q.numberRect.bottom,
      );
      final r = grade(doc, {
        0: [ink(horizontalLine(stem, 1.3))],
      });
      expect(summarize(r), expected({2: '-/C unsure(noOptionAboveThreshold)'}));
    });

    test('a highlighter over an option is ignored', () async {
      final doc = await singleTest();
      final r = grade(doc, {
        0: [
          ink(
            scribbleOn(doc.optionBox(0, 1, 'B')),
            tool: ToolId.highlighter,
            size: 20,
          ),
        ],
      });
      expect(summarize(r), expected({}));
    });

    test('the highlighter does not disturb a pen mark', () async {
      final doc = await singleTest();
      final r = grade(doc, {
        0: [
          ink(
            scribbleOn(doc.optionBox(0, 1, 'A')),
            tool: ToolId.highlighter,
            size: 20,
          ),
          ink(circleAround(doc.labelRect(0, 1, 'B'))),
        ],
      });
      expect(summarize(r), expected({1: 'B/B correct'}));
    });

    test('a stray mark far from any question is ignored', () async {
      final doc = await singleTest();
      final r = grade(doc, {
        0: [
          ink(circleAround(const Rect.fromLTWH(880, 60, 30, 30))),
          ink(scribbleOn(const Rect.fromLTWH(700, 1350, 60, 30))),
        ],
      });
      expect(summarize(r), expected({}));
    });

    test('a stroke crossing into the next question belongs to one', () async {
      final doc = await singleTest();
      final d = doc.optionBox(0, 1, 'D');
      final nextTop = doc.question(0, 2).region.top;
      // Ring around option D of question 1 that dips 15 units into the
      // (inflated) region of question 2.
      final target = Rect.fromLTRB(d.left, d.top, d.right, nextTop - 24 + 5);
      final r = grade(doc, {
        0: [ink(circleAround(target, margin: 10))],
      });
      expect(summarize(r), expected({1: 'D/B wrong'}));
    });
  });

  group('crossed out options', () {
    test(
      'circled, crossed out, then another circled: changed answer',
      () async {
        final doc = await singleTest();
        final r = grade(doc, {
          0: [
            ink(circleAround(doc.labelRect(0, 1, 'A'))),
            ink(horizontalLine(doc.optionBox(0, 1, 'A'), 0.5)),
            ink(circleAround(doc.labelRect(0, 1, 'B'))),
          ],
        });
        expect(summarize(r), expected({1: 'B/B correct'}));
      },
    );

    test('changed answer to a wrong one is wrong', () async {
      final doc = await singleTest();
      final r = grade(doc, {
        0: [
          ink(circleAround(doc.labelRect(0, 1, 'B'))),
          ink(horizontalLine(doc.optionBox(0, 1, 'B'), 0.5)),
          ink(circleAround(doc.labelRect(0, 1, 'C'))),
        ],
      });
      expect(summarize(r), expected({1: 'C/B wrong'}));
    });

    test('crossed out with an X, then another circled', () async {
      final doc = await singleTest();
      final x = crossOver(doc.optionBox(0, 2, 'A'));
      final r = grade(doc, {
        0: [
          ink(circleAround(doc.labelRect(0, 2, 'A'))),
          ink(x[0]),
          ink(x[1]),
          ink(circleAround(doc.labelRect(0, 2, 'C'))),
        ],
      });
      expect(summarize(r), expected({2: 'C/C correct'}));
    });

    test('a slanted strike-through counts as a strike', () async {
      final doc = await singleTest();
      final r = grade(doc, {
        0: [
          ink(circleAround(doc.labelRect(0, 1, 'A'))),
          ink(horizontalLine(doc.optionBox(0, 1, 'A'), 0.5, slope: 3)),
          ink(circleAround(doc.labelRect(0, 1, 'B'))),
        ],
      });
      expect(summarize(r), expected({1: 'B/B correct'}));
    });

    test('a lone strike-through is unsure', () async {
      final doc = await singleTest();
      final r = grade(doc, {
        0: [ink(horizontalLine(doc.optionBox(0, 1, 'A'), 0.5))],
      });
      expect(summarize(r), expected({1: '-/B unsure(crossedOutAmbiguous)'}));
    });

    test('a lone X is unsure', () async {
      final doc = await singleTest();
      final x = crossOver(doc.optionBox(0, 1, 'A'));
      final r = grade(doc, {
        0: [ink(x[0]), ink(x[1])],
      });
      expect(summarize(r), expected({1: '-/B unsure(crossedOutAmbiguous)'}));
    });

    test('circled and then crossed out, nothing else: unsure', () async {
      final doc = await singleTest();
      final r = grade(doc, {
        0: [
          ink(circleAround(doc.labelRect(0, 1, 'B'))),
          ink(horizontalLine(doc.optionBox(0, 1, 'B'), 0.5)),
        ],
      });
      expect(summarize(r), expected({1: '-/B unsure(crossedOutAmbiguous)'}));
    });

    test('several options crossed out and no mark: unsure', () async {
      final doc = await singleTest();
      final r = grade(doc, {
        0: [
          ink(horizontalLine(doc.optionBox(0, 1, 'A'), 0.5)),
          ink(horizontalLine(doc.optionBox(0, 1, 'C'), 0.5)),
          ink(horizontalLine(doc.optionBox(0, 1, 'D'), 0.5)),
        ],
      });
      expect(summarize(r), expected({1: '-/B unsure(crossedOutAmbiguous)'}));
    });

    test('one option circled while another is crossed out', () async {
      final doc = await singleTest();
      final r = grade(doc, {
        0: [
          ink(circleAround(doc.labelRect(0, 1, 'B'))),
          ink(horizontalLine(doc.optionBox(0, 1, 'C'), 0.5)),
        ],
      });
      expect(summarize(r), expected({1: 'B/B correct'}));
    });

    test('an underline is not a cross-out', () async {
      final doc = await singleTest();
      final r = grade(doc, {
        0: [ink(horizontalLine(doc.optionBox(0, 1, 'B'), 1.3))],
      });
      expect(summarize(r), expected({1: 'B/B correct'}));
    });
  });

  group('layouts', () {
    final layouts = <String, FxPage Function()>{
      'stacked A)': () => questionPage(questions()),
      'stacked (A)': () => questionPage(questions(), style: LabelStyle.both),
      'stacked A.': () => questionPage(questions(), style: LabelStyle.dot),
      'inline A)': () => questionPage(questions(), inline: true),
      'two columns': () => questionPage(questions(), columns: 2),
      'two columns inline': () =>
          questionPage(questions(), columns: 2, inline: true),
      'number 1.': () => questionPage(questions(), numberSuffix: '.'),
    };
    layouts.forEach((name, page) {
      test(name, () async {
        final doc = await singleTest(page: page());
        final r = grade(doc, {
          0: [
            ink(circleAround(doc.labelRect(0, 1, 'B'))),
            ink(circleAround(doc.labelRect(0, 2, 'A'))),
            ink(tickBeside(doc.labelRect(0, 4, 'D'))),
            ink(circleAround(doc.labelRect(0, 5, 'B'))),
            ink(circleAround(doc.labelRect(0, 6, 'D'))),
          ],
        });
        expect(
          summarize(r),
          expected({
            1: 'B/B correct',
            2: 'A/C wrong',
            4: 'D/D correct',
            5: 'B/B correct',
            6: 'D/C wrong',
          }),
        );
      });
    });

    test('an unrelated page of prose before, between and after', () async {
      final doc = await FxDoc.open([
        prosePage(),
        questionPage(questions()),
        prosePage(),
        keyPage(key1.split('')),
        prosePage(),
      ]);
      addTearDown(doc.dispose);
      final r = grade(doc, {
        1: [ink(circleAround(doc.labelRect(1, 3, 'A')))],
      });
      expect(r.keyStatus, KeyStatus.found);
      expect(summarize(r), expected({3: 'A/A correct'}));
      expect(r.grades.every((g) => g.pageIndex == 1), isTrue);
    });

    test('a test over two pages', () async {
      final doc = await FxDoc.open([
        questionPage(questions(count: 3)),
        questionPage(questions(first: 4, count: 3)),
        keyPage(key1.split('')),
      ]);
      addTearDown(doc.dispose);
      final r = grade(doc, {
        0: [ink(circleAround(doc.labelRect(0, 1, 'B')))],
        1: [ink(circleAround(doc.labelRect(1, 5, 'A')))],
      });
      expect(summarize(r), expected({1: 'B/B correct', 5: 'A/B wrong'}));
      expect(r.grade(5)!.pageIndex, 1);
    });

    test('a note page with a different aspect ratio than the PDF', () async {
      final doc = await singleTest();
      doc.forcedNoteSize = const Size(1000, 1000);
      final r = grade(doc, {
        0: [
          ink(circleAround(doc.labelRect(0, 1, 'B'))),
          ink(circleAround(doc.labelRect(0, 2, 'D'))),
        ],
      });
      expect(summarize(r), expected({1: 'B/B correct', 2: 'D/C wrong'}));
    });

    for (final rotation in [
      pw_pdf.PdfPageRotation.rotate90,
      pw_pdf.PdfPageRotation.rotate180,
      pw_pdf.PdfPageRotation.rotate270,
    ]) {
      test('a rotated PDF page (${rotation.name})', () async {
        final texts = questionPage(questions()).texts;
        final doc = await FxDoc.open([
          FxPage(texts, rotation: rotation),
          keyPage(key1.split('')),
        ]);
        addTearDown(doc.dispose);
        final r = grade(doc, {
          0: [
            ink(circleAround(doc.labelRect(0, 1, 'B'))),
            ink(circleAround(doc.labelRect(0, 2, 'A'))),
            ink(tickBeside(doc.labelRect(0, 3, 'A'))),
          ],
        });
        expect(
          summarize(r),
          expected({1: 'B/B correct', 2: 'A/C wrong', 3: 'A/A correct'}),
        );
      });
    }
  });

  group('answer key', () {
    test('two tests, each followed by its key', () async {
      final doc = await FxDoc.open([
        questionPage(questions()),
        keyPage(key1.split('')),
        questionPage(questions()),
        keyPage(key2.split('')),
      ]);
      addTearDown(doc.dispose);
      final r = grade(doc, {
        0: [
          ink(circleAround(doc.labelRect(0, 1, 'B'))),
          ink(circleAround(doc.labelRect(0, 2, 'A'))),
        ],
        2: [
          ink(circleAround(doc.labelRect(2, 1, 'D'))),
          ink(circleAround(doc.labelRect(2, 2, 'D'))),
        ],
      });
      expect(r.keyStatus, KeyStatus.found);
      expect(r.keyDetection.blocks, hasLength(2));
      expect(summarize(r), [
        ...expected({1: 'B/B correct', 2: 'A/C wrong'}),
        ...expected({1: 'D/D correct', 2: 'D/A wrong'}, key: key2, test: 1),
      ]);
    });

    test('two tests and one key page with two blocks', () async {
      final doc = await FxDoc.open([
        questionPage(questions()),
        questionPage(questions()),
        keyPageFromLines([...keyLines(key1), ...keyLines(key2)]),
      ]);
      addTearDown(doc.dispose);
      final r = grade(doc, {
        0: [ink(circleAround(doc.labelRect(0, 3, 'A')))],
        1: [ink(circleAround(doc.labelRect(1, 3, 'B')))],
      });
      expect(r.keyStatus, KeyStatus.found);
      expect(summarize(r), [
        ...expected({3: 'A/A correct'}),
        ...expected({3: 'B/B correct'}, key: key2, test: 1),
      ]);
      expect(r.keyDetection.blocks[1].firstQuestionPage, 1);
    });

    test('key entries in a different format and several per line', () async {
      final doc = await FxDoc.open([
        questionPage(questions()),
        keyPage(
          key1.split(''),
          perLine: 3,
          format: (n, l) => '($n) ${l.toLowerCase()}',
        ),
      ]);
      addTearDown(doc.dispose);
      final r = grade(doc, {
        0: [ink(circleAround(doc.labelRect(0, 2, 'C')))],
      });
      expect(summarize(r), expected({2: 'C/C correct'}));
    });

    test('no key in the document: unsure, never wrong', () async {
      final doc = await FxDoc.open([questionPage(questions())]);
      addTearDown(doc.dispose);
      final r = grade(doc, {
        0: [
          ink(circleAround(doc.labelRect(0, 1, 'B'))),
          ink(circleAround(doc.labelRect(0, 2, 'A'))),
        ],
      });
      expect(r.keyStatus, KeyStatus.unknown);
      expect(summarize(r), [
        't0#1 B/- unsure(keyUnknown)',
        't0#2 A/- unsure(keyUnknown)',
        for (var n = 3; n <= 6; n++) 't0#$n -/- unanswered',
      ]);
    });

    test('a numbered list of non-answers is not taken as the key', () async {
      final doc = await FxDoc.open([
        questionPage(questions()),
        nonKeyListPage(),
      ]);
      addTearDown(doc.dispose);
      final r = grade(doc, {
        0: [ink(circleAround(doc.labelRect(0, 1, 'B')))],
      });
      expect(r.keyStatus, KeyStatus.unknown);
      expect(summarize(r).first, 't0#1 B/- unsure(keyUnknown)');
    });

    test('tests and key blocks that do not pair up: unknown', () async {
      final doc = await FxDoc.open([
        questionPage(questions()),
        questionPage(questions()),
        keyPage(key1.split('')),
      ]);
      addTearDown(doc.dispose);
      final r = grade(doc, {
        0: [ink(circleAround(doc.labelRect(0, 1, 'B')))],
      });
      expect(r.keyStatus, KeyStatus.unknown);
      expect(summarize(r).first, 't0#1 B/- unsure(keyUnknown)');
      expect(r.grades.where((g) => g.verdict == Verdict.wrong), isEmpty);
    });

    test('a key that does not match the questions is not used', () async {
      // The key is for numbers 21..26: nothing matches test 1..6.
      final doc = await FxDoc.open([
        questionPage(questions()),
        keyPage(key1.split(''), firstNumber: 21),
      ]);
      addTearDown(doc.dispose);
      final r = grade(doc, {
        0: [ink(circleAround(doc.labelRect(0, 1, 'B')))],
      });
      expect(r.keyStatus, KeyStatus.unknown);
      expect(summarize(r).first, 't0#1 B/- unsure(keyUnknown)');
    });

    test('a question without a key entry is unsure', () async {
      final doc = await singleTest(key: 'BCADB');
      final r = grade(doc, {
        0: [ink(circleAround(doc.labelRect(0, 6, 'C')))],
      });
      expect(r.keyStatus, KeyStatus.found);
      expect(summarize(r), [
        for (var n = 1; n <= 5; n++) 't0#$n -/${'BCADB'[n - 1]} unanswered',
        't0#6 C/- unsure(noKeyEntry)',
      ]);
    });

    test('a key letter that is not an option is unsure', () async {
      final doc = await singleTest(key: 'BCADBE');
      final r = grade(doc, {
        0: [ink(circleAround(doc.labelRect(0, 6, 'C')))],
      });
      expect(summarize(r).last, 't0#6 C/E unsure(keyNotAnOption)');
    });

    test('the key override names the key pages', () async {
      // Only three questions and three entries: too short to detect.
      final doc = await FxDoc.open([
        questionPage(questions(count: 3)),
        keyPage('BCA'.split('')),
      ]);
      addTearDown(doc.dispose);
      final strokes = {
        0: [
          ink(circleAround(doc.labelRect(0, 1, 'B'))),
          ink(circleAround(doc.labelRect(0, 2, 'D'))),
        ],
      };
      final auto = grade(doc, strokes);
      expect(auto.keyStatus, KeyStatus.unknown);
      expect(summarize(auto).first, 't0#1 B/- unsure(keyUnknown)');

      final r = grade(doc, strokes, override: const KeyOverride({1}));
      expect(r.keyStatus, KeyStatus.found);
      expect(summarize(r), [
        't0#1 B/B correct',
        't0#2 D/C wrong',
        't0#3 -/A unanswered',
      ]);
    });
  });

  group('no text layer', () {
    test('a scanned PDF: key unknown, nothing located, no crash', () async {
      final doc = await FxDoc.open([blankPage(), blankPage(), blankPage()]);
      addTearDown(doc.dispose);
      final r = grade(doc, {
        0: [ink(circleAround(const Rect.fromLTWH(200, 300, 40, 40)))],
      });
      expect(r.keyStatus, KeyStatus.unknown);
      expect(r.grades, isEmpty);
    });

    test('questions with a text layer but a scanned key page', () async {
      final doc = await FxDoc.open([questionPage(questions()), blankPage()]);
      addTearDown(doc.dispose);
      final r = grade(doc, {
        0: [ink(circleAround(doc.labelRect(0, 1, 'B')))],
      });
      expect(r.keyStatus, KeyStatus.unknown);
      expect(summarize(r).first, 't0#1 B/- unsure(keyUnknown)');
    });

    test('no pages at all', () {
      final r = gradeDocument(const []);
      expect(r.keyStatus, KeyStatus.unknown);
      expect(r.grades, isEmpty);
    });
  });

  test('anchors lie on the question number in note coordinates', () async {
    final doc = await singleTest();
    final r = grade(doc, {});
    for (final g in r.grades) {
      expect(g.anchorInNote, doc.question(0, g.number).numberRect);
    }
  });

  test('result is deterministic and value-comparable', () async {
    final doc = await singleTest();
    final strokes = {
      0: [ink(circleAround(doc.labelRect(0, 1, 'B')))],
    };
    final a = grade(doc, strokes), b = grade(doc, strokes);
    expect(a.grades, b.grades);
  });
}
