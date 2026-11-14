import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/grading/corrections.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/grader_service.dart';
import 'package:saber/grading/models.dart';
import 'package:sbn/has_size.dart';
import 'package:sbn/tool_id.dart';

import 'fixtures/pdf_fixtures.dart';
import 'fixtures/stroke_fixtures.dart';

void main() {
  setUpAll(initPdfrx);

  group('InkSignature', () {
    final a = ink(circleAround(const Rect.fromLTWH(100, 100, 30, 20)));
    final b = ink(tickBeside(const Rect.fromLTWH(300, 100, 30, 20)));

    test('same ink matches, in any order', () {
      expect(InkSignature.of([a, b]).matches(InkSignature.of([b, a])), isTrue);
    });

    test('moved, added, removed or different-tool ink does not match', () {
      final base = InkSignature.of([a]);
      final moved = ink(circleAround(const Rect.fromLTWH(110, 100, 30, 20)));
      expect(base.matches(InkSignature.of([moved])), isFalse);
      expect(base.matches(InkSignature.of([a, b])), isFalse);
      expect(base.matches(const InkSignature([])), isFalse);
      final pencil = ink(
        circleAround(const Rect.fromLTWH(100, 100, 30, 20)),
        tool: ToolId.pencil,
      );
      expect(base.matches(InkSignature.of([pencil])), isFalse);
    });

    test('a save/load round trip of a stroke stays within tolerance', () {
      // Strokes are stored with float32 precision.
      final s = stroke(
        circleAround(const Rect.fromLTWH(123.456, 789.012, 31.7, 22.3)),
      );
      final loaded = Stroke.fromJson(
        s.toJson(),
        fileVersion: 20,
        pageIndex: 0,
        page: const HasSize(Size(1000, 1414)),
      );
      final before = strokeToInk(s), after = strokeToInk(loaded);
      final moved = [
        (before.bounds.left - after.bounds.left).abs(),
        (before.bounds.top - after.bounds.top).abs(),
        (before.bounds.right - after.bounds.right).abs(),
        (before.bounds.bottom - after.bounds.bottom).abs(),
      ].reduce((a, b) => a > b ? a : b);
      printOnFailure('max bounds shift after save/load: $moved');
      expect(moved, lessThan(InkSignature.defaultTolerance / 10));
      expect(
        InkSignature.of([before]).matches(InkSignature.of([after])),
        isTrue,
      );
    });

    test('JSON round trip', () {
      final sig = InkSignature.of([a, b]);
      expect(InkSignature.fromJson(sig.toJson()).matches(sig), isTrue);
    });
  });

  group('corrections in the grade', () {
    Future<(FxDoc, List<InkStroke>)> setup() async {
      final doc = await FxDoc.open([
        questionPage(questions()),
        keyPage('BCADBC'.split('')),
      ]);
      addTearDown(doc.dispose);
      return (doc, [ink(circleAround(doc.labelRect(0, 1, 'A')))]);
    }

    Correction correct(List<InkStroke> strokes, String letter) => Correction(
      testIndex: 0,
      number: 1,
      letter: letter,
      signature: InkSignature.of(strokes),
    );

    test('applies to the same ink and is marked as edited', () async {
      final (doc, strokes) = await setup();
      final plain = gradeDocument(doc.gradingPages({0: strokes}));
      expect(plain.grade(1)!.verdict, Verdict.wrong);
      final r = gradeDocument(
        doc.gradingPages({0: strokes}),
        corrections: [correct(strokes, 'B')],
      );
      final g = r.grade(1)!;
      expect(g.detectedLetter, 'B');
      expect(g.verdict, Verdict.correct);
      expect(g.corrected, isTrue);
      expect(r.grade(2)!.corrected, isFalse);
    });

    test('a correction can also make a wrong answer', () async {
      final (doc, strokes) = await setup();
      final r = gradeDocument(
        doc.gradingPages({0: strokes}),
        corrections: [correct(strokes, 'D')],
      );
      expect(r.grade(1)!.verdict, Verdict.wrong);
      expect(r.grade(1)!.corrected, isTrue);
    });

    test('changed ink: the correction does not apply', () async {
      final (doc, strokes) = await setup();
      final c = correct(strokes, 'B');
      final other = [ink(circleAround(doc.labelRect(0, 1, 'C')))];
      final r = gradeDocument(doc.gradingPages({0: other}), corrections: [c]);
      expect(r.grade(1)!.detectedLetter, 'C');
      expect(r.grade(1)!.corrected, isFalse);
      // Extra ink in the question: no longer the same attempt.
      final more = [...strokes, ink(tickBeside(doc.labelRect(0, 1, 'D')))];
      expect(
        gradeDocument(
          doc.gradingPages({0: more}),
          corrections: [c],
        ).grade(1)!.corrected,
        isFalse,
      );
    });

    test('a fresh note of the same PDF (no ink) does not inherit', () async {
      final (doc, strokes) = await setup();
      final r = gradeDocument(
        doc.gradingPages({}),
        corrections: [correct(strokes, 'B')],
      );
      expect(r.grade(1)!.verdict, Verdict.unanswered);
      expect(r.grade(1)!.corrected, isFalse);
    });

    test('a letter that is not an option is ignored', () async {
      final (doc, strokes) = await setup();
      final r = gradeDocument(
        doc.gradingPages({0: strokes}),
        corrections: [correct(strokes, 'E')],
      );
      expect(r.grade(1)!.corrected, isFalse);
    });

    test('with an unknown key a corrected answer is still unsure', () async {
      final doc = await FxDoc.open([questionPage(questions())]);
      addTearDown(doc.dispose);
      final strokes = [ink(circleAround(doc.labelRect(0, 1, 'A')))];
      final r = gradeDocument(
        doc.gradingPages({0: strokes}),
        corrections: [correct(strokes, 'B')],
      );
      expect(r.grade(1)!.detectedLetter, 'B');
      expect(r.grade(1)!.reason, UnsureReason.keyUnknown);
    });
  });
}
