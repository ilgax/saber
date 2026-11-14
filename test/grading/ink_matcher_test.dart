// Unit tests of the ink matcher on hand-made questions (note coordinates).
import 'dart:math';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:saber/grading/ink/ink_matcher.dart';
import 'package:saber/grading/models.dart';
import 'package:sbn/tool_id.dart';

import 'fixtures/stroke_fixtures.dart';

/// Four stacked options at x = 100, 50 units apart, label 20 x 20, box 120
/// wide. Question [n] sits [dy] lower than the first.
Question question(int n, {double dy = 0}) {
  final options = [
    for (var i = 0; i < 4; i++)
      Option(
        letter: String.fromCharCode(65 + i),
        labelRect: Rect.fromLTWH(100, 100 + dy + i * 50, 20, 20),
        box: Rect.fromLTWH(100, 100 + dy + i * 50, 120, 20),
      ),
  ];
  return Question(
    testIndex: 0,
    number: n,
    pageIndex: 0,
    numberRect: Rect.fromLTWH(60, 60 + dy, 20, 20),
    region: Rect.fromLTWH(60, 60 + dy, 200, 180),
    options: options,
  );
}

Rect label(Question q, String l) => q.option(l)!.labelRect;
Rect box(Question q, String l) => q.option(l)!.box;

MarkReading read(Question q, List<InkStroke> strokes) =>
    InkMatcher.read(q, strokes);

void main() {
  final q = question(1);

  group('read', () {
    test('no strokes: unanswered', () {
      expect(read(q, []), const MarkReading.unanswered());
    });

    test('only highlighter or non-gradable tools: unanswered', () {
      final s = ink(
        circleAround(label(q, 'B')),
        tool: ToolId.highlighter,
        size: 20,
      );
      expect(read(q, [s]), const MarkReading.unanswered());
    });

    test('a clean circle is read with high confidence', () {
      final r = read(q, [ink(circleAround(label(q, 'C')))]);
      expect(r.letter, 'C');
      expect(r.state, MarkState.marked);
      expect(r.confidence, Confidence.high);
    });

    test('circles of different sizes and pen widths', () {
      for (final margin in [6.0, 10.0, 14.0]) {
        for (final size in [2.0, 5.0, 9.0]) {
          final r = read(q, [
            ink(circleAround(label(q, 'B'), margin: margin), size: size),
          ]);
          expect(r.letter, 'B', reason: 'margin $margin size $size');
        }
      }
    });

    test('a wobbly, off-centre circle', () {
      final random = Random(7);
      final pts = [
        for (final p in circleAround(label(q, 'D'), margin: 12, turns: 1.1))
          p +
              Offset(
                random.nextDouble() * 3 - 1.5,
                random.nextDouble() * 3 - 1.5,
              ) +
              const Offset(4, -3),
      ];
      expect(read(q, [ink(pts)]).letter, 'D');
    });

    test('a circle drawn twice is still one option', () {
      final r = read(q, [
        ink(circleAround(label(q, 'B'), margin: 9)),
        ink(circleAround(label(q, 'B'), margin: 12)),
      ]);
      expect(r.letter, 'B');
    });

    test('half a circle around a label still points at that label', () {
      final r = read(q, [ink(circleAround(label(q, 'B'), turns: 0.5))]);
      expect(r.letter, 'B');
      expect(r.confidence, isNot(Confidence.high));
    });

    test('a small arc far from the label is not a mark', () {
      final r = read(q, [
        ink(circleAround(const Rect.fromLTWH(400, 150, 20, 20), turns: 0.5)),
      ]);
      expect(r, const MarkReading.unsure(UnsureReason.noOptionAboveThreshold));
    });

    test('a filled bubble is not mistaken for a ring', () {
      final r = read(q, [ink(scribbleOn(label(q, 'C')))]);
      expect(r.letter, 'C');
      // ... and a scribble on one label does not leak to its neighbours.
      final both = read(q, [
        ink(scribbleOn(label(q, 'B'))),
        ink(scribbleOn(label(q, 'C'))),
      ]);
      expect(both, const MarkReading.unsure(UnsureReason.twoOptionsClose));
    });

    test('a tick left of the label, at different distances', () {
      for (final gap in [4.0, 12.0, 24.0]) {
        expect(
          read(q, [ink(tickBeside(label(q, 'B'), gap: gap))]).letter,
          'B',
          reason: 'gap $gap',
        );
      }
    });

    test('a tick far from every label is not a mark', () {
      final r = read(q, [ink(tickBeside(label(q, 'B'), gap: 90))]);
      expect(r, const MarkReading.unsure(UnsureReason.noOptionAboveThreshold));
    });

    test('a tick that touches two lines equally does not choose', () {
      // Spans from the middle of B's line to the middle of C's line.
      final t = polyline([
        const Offset(80, 160),
        const Offset(70, 185),
        const Offset(85, 210),
      ]);
      final r = read(q, [ink(t)]);
      expect(r, const MarkReading.unsure(UnsureReason.twoOptionsClose));
    });

    test('a tick right of the option text is not matched (known limit)', () {
      final tick = tickBeside(const Rect.fromLTWH(300, 150, 20, 20), gap: 0);
      expect(read(q, [ink(tick)]).state, MarkState.unsure);
    });

    test('underline needs to be under the text, not through it', () {
      expect(read(q, [ink(horizontalLine(box(q, 'D'), 1.3))]).letter, 'D');
      // Through the middle it is a strike: crossed out.
      expect(
        read(q, [ink(horizontalLine(box(q, 'D'), 0.5))]),
        const MarkReading.unsure(UnsureReason.crossedOutAmbiguous),
      );
    });

    test('a short stroke through part of the text is not a strike', () {
      final r = read(q, [ink(horizontalLine(box(q, 'A'), 0.5, coverage: 0.3))]);
      expect(r, const MarkReading.unsure(UnsureReason.noOptionAboveThreshold));
    });

    test('a long strike through all four options crosses them all out', () {
      final r = read(q, [
        for (final l in ['A', 'B', 'C', 'D'])
          ink(horizontalLine(box(q, l), 0.5)),
        ink(circleAround(label(q, 'B'))),
      ]);
      expect(r, const MarkReading.unsure(UnsureReason.crossedOutAmbiguous));
    });

    test('a single diagonal slash over a label is no mark', () {
      final l = label(q, 'B');
      final r = read(q, [
        ink(polyline([l.topLeft, l.bottomRight])),
      ]);
      expect(r, const MarkReading.unsure(UnsureReason.noOptionAboveThreshold));
    });

    test('a slash through the whole option is a (slanted) strike-through', () {
      final b = box(q, 'B');
      final r = read(q, [
        ink(polyline([b.topLeft, b.bottomRight])),
      ]);
      expect(r, const MarkReading.unsure(UnsureReason.crossedOutAmbiguous));
    });

    test('two parallel diagonals are not an X', () {
      final b = box(q, 'B');
      final r = read(q, [
        ink(polyline([b.topLeft, b.bottomLeft + const Offset(30, 0)])),
        ink(
          polyline([
            b.topLeft + const Offset(10, 0),
            b.bottomLeft + const Offset(40, 0),
          ]),
        ),
        ink(circleAround(label(q, 'C'))),
      ]);
      expect(r.letter, 'C');
    });

    test('an X crossing out one option leaves the circled one', () {
      final x = crossOver(box(q, 'A'));
      final r = read(q, [
        ink(circleAround(label(q, 'A'))),
        ink(x[0]),
        ink(x[1]),
        ink(circleAround(label(q, 'D'))),
      ]);
      expect(r.letter, 'D');
    });

    test('the same input always gives the same result', () {
      final strokes = [ink(circleAround(label(q, 'B')))];
      expect(read(q, strokes), read(q, strokes));
    });
  });

  group('assign', () {
    final q1 = question(1), q2 = question(2, dy: 260);

    test('a stroke goes to the question that holds most of it', () {
      final s = ink(circleAround(label(q1, 'D'), margin: 10));
      final a = InkMatcher.assign([q1, q2], [s]);
      expect(a[0], [s]);
      expect(a[1], isEmpty);
    });

    test('a stroke straddling two regions goes to one', () {
      // Centred in the gap between the two questions.
      final gap = Rect.fromLTRB(
        100,
        q1.region.bottom - 20,
        200,
        q2.region.top + 20,
      );
      final s = ink(circleAround(gap, margin: 0));
      final a = InkMatcher.assign([q1, q2], [s]);
      expect(a[0].length + a[1].length, 1);
    });

    test('a stray mark far away is dropped; a close one is kept', () {
      final far = ink(circleAround(const Rect.fromLTWH(800, 800, 30, 30)));
      final near = ink(
        circleAround(
          Rect.fromLTWH(q1.region.right + 20, 150, 20, 20),
          margin: 4,
        ),
      );
      final a = InkMatcher.assign([q1, q2], [far, near]);
      expect(a[0], [near]);
      expect(a[1], isEmpty);
    });

    test('non-gradable tools are dropped', () {
      final s = ink(circleAround(label(q1, 'A')), tool: ToolId.highlighter);
      expect(InkMatcher.assign([q1, q2], [s]), [isEmpty, isEmpty]);
    });

    test('no questions: nothing to assign', () {
      expect(
        InkMatcher.assign([], [ink(circleAround(label(q1, 'A')))]),
        isEmpty,
      );
    });

    test('readAll reads each question from its own ink', () {
      final r = InkMatcher.readAll(
        [q1, q2],
        [ink(circleAround(label(q1, 'B'))), ink(circleAround(label(q2, 'C')))],
      );
      expect(r.map((e) => e.letter), ['B', 'C']);
    });
  });
}
