import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:sbn/tool_id.dart';

/// One answer option of a [Question], e.g. `B) 4`.
@immutable
class Option {
  const new({required this.letter, required this.labelRect, required this.box});

  /// Upper-case letter, `A` to `E`.
  final String letter;

  /// Where the label (`B)`) is.
  final Rect labelRect;

  /// The label plus the rest of its text (the rest of the line, or up to the
  /// next label for inline options).
  final Rect box;

  Option mapRects(Rect Function(Rect) f) =>
      Option(letter: letter, labelRect: f(labelRect), box: f(box));

  @override
  bool operator ==(Object other) =>
      other is Option &&
      other.letter == letter &&
      other.labelRect == labelRect &&
      other.box == box;

  @override
  int get hashCode => Object.hash(letter, labelRect, box);

  @override
  String toString() => 'Option($letter, $box)';
}

/// A multiple choice question located on a page.
///
/// Rects are in "PDF visual space" (points, top-left origin, rotation
/// applied) when they come from the locator and in note-page coordinates
/// after [mapRects].
@immutable
class Question {
  const new({
    required this.testIndex,
    required this.number,
    required this.pageIndex,
    required this.numberRect,
    required this.region,
    required this.options,
  });

  /// Which test of the document this belongs to (numbering restarts at 1 for
  /// every test).
  final int testIndex;
  final int number;
  final int pageIndex;
  final Rect numberRect;

  /// Bounds of the whole question (stem and options).
  final Rect region;
  final List<Option> options;

  Question withTestIndex(int testIndex) => Question(
    testIndex: testIndex,
    number: number,
    pageIndex: pageIndex,
    numberRect: numberRect,
    region: region,
    options: options,
  );

  Question mapRects(Rect Function(Rect) f) => Question(
    testIndex: testIndex,
    number: number,
    pageIndex: pageIndex,
    numberRect: f(numberRect),
    region: f(region),
    options: [for (final o in options) o.mapRects(f)],
  );

  Option? option(String letter) {
    for (final o in options) {
      if (o.letter == letter) return o;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is Question &&
      other.testIndex == testIndex &&
      other.number == number &&
      other.pageIndex == pageIndex &&
      other.numberRect == numberRect &&
      other.region == region &&
      listEquals(other.options, options);

  @override
  int get hashCode => Object.hash(
    testIndex,
    number,
    pageIndex,
    numberRect,
    region,
    Object.hashAll(options),
  );

  @override
  String toString() =>
      'Question(test $testIndex, #$number, page $pageIndex, '
      '${options.map((o) => o.letter).join()})';
}

/// One `1) A` entry of an answer key.
@immutable
class KeyEntry {
  const new({
    required this.number,
    required this.letter,
    required this.pageIndex,
  });

  final int number;

  /// Upper-case letter.
  final String letter;
  final int pageIndex;

  @override
  bool operator ==(Object other) =>
      other is KeyEntry &&
      other.number == number &&
      other.letter == letter &&
      other.pageIndex == pageIndex;

  @override
  int get hashCode => Object.hash(number, letter, pageIndex);

  @override
  String toString() => 'KeyEntry($number$letter @p$pageIndex)';
}

/// The answers of one test, found on one or more consecutive key pages.
@immutable
class KeyBlock {
  const new({
    required this.firstKeyPage,
    required this.lastKeyPage,
    required this.answers,
    this.firstQuestionPage,
    this.lastQuestionPage,
  });

  final int firstKeyPage;
  final int lastKeyPage;

  /// Question number to upper-case letter.
  final Map<int, String> answers;

  /// The question pages of the test this block was paired with (null until
  /// paired).
  final int? firstQuestionPage;
  final int? lastQuestionPage;

  KeyBlock withQuestionPages(int first, int last) => KeyBlock(
    firstKeyPage: firstKeyPage,
    lastKeyPage: lastKeyPage,
    answers: answers,
    firstQuestionPage: first,
    lastQuestionPage: last,
  );

  @override
  bool operator ==(Object other) =>
      other is KeyBlock &&
      other.firstKeyPage == firstKeyPage &&
      other.lastKeyPage == lastKeyPage &&
      mapEquals(other.answers, answers) &&
      other.firstQuestionPage == firstQuestionPage &&
      other.lastQuestionPage == lastQuestionPage;

  @override
  int get hashCode => Object.hash(
    firstKeyPage,
    lastKeyPage,
    Object.hashAll(answers.entries.map((e) => Object.hash(e.key, e.value))),
    firstQuestionPage,
    lastQuestionPage,
  );

  @override
  String toString() => 'KeyBlock(p$firstKeyPage-$lastKeyPage, $answers)';
}

enum KeyStatus { found, unknown }

/// Result of looking for the answer key.
@immutable
class KeyDetection {
  const new({
    required this.blocks,
    required this.confidence,
    required this.status,
  });

  const new unknown()
    : blocks = const [],
      confidence = 0,
      status = KeyStatus.unknown;

  /// In document order.
  final List<KeyBlock> blocks;

  /// 0 to 1.
  final double confidence;
  final KeyStatus status;

  Set<int> get keyPages => {
    for (final b in blocks)
      for (var p = b.firstKeyPage; p <= b.lastKeyPage; p++) p,
  };

  @override
  String toString() => 'KeyDetection($status, $confidence, $blocks)';
}

enum Verdict {
  correct,
  wrong,

  /// Ambiguous or not checkable; never shown as wrong.
  unsure,

  /// No ink in the question.
  unanswered,
}

/// Why a question is [Verdict.unsure].
enum UnsureReason {
  /// Ink in the question, but no option is clearly marked.
  noOptionAboveThreshold,

  /// Two options are marked about equally.
  twoOptionsClose,

  /// An option is crossed out and the rest is not one clear mark.
  crossedOutAmbiguous,

  /// The answer key could not be found or paired with this test.
  keyUnknown,

  /// The key has no entry for this question number.
  noKeyEntry,

  /// The key's letter is not one of the question's options.
  keyNotAnOption,
}

enum Confidence { low, medium, high }

enum MarkState { marked, unsure, unanswered }

/// What the ink matcher read from one question.
@immutable
class MarkReading {
  const new marked(String this.letter, {this.confidence = Confidence.medium})
    : state = MarkState.marked,
      reason = null;

  const new unsure(UnsureReason this.reason)
    : letter = null,
      state = MarkState.unsure,
      confidence = Confidence.low;

  const new unanswered()
    : letter = null,
      state = MarkState.unanswered,
      reason = null,
      confidence = Confidence.high;

  /// The marked letter; null when unsure or unanswered.
  final String? letter;
  final MarkState state;
  final UnsureReason? reason;
  final Confidence confidence;

  @override
  bool operator ==(Object other) =>
      other is MarkReading &&
      other.letter == letter &&
      other.state == state &&
      other.reason == reason &&
      other.confidence == confidence;

  @override
  int get hashCode => Object.hash(letter, state, reason, confidence);

  @override
  String toString() => 'MarkReading($letter, $state, $reason)';
}

/// The grade of one question.
@immutable
class QuestionGrade {
  const new({
    required this.testIndex,
    required this.number,
    required this.pageIndex,
    required this.verdict,
    required this.confidence,
    required this.anchorInNote,
    this.detectedLetter,
    this.keyAnswer,
    this.reason,
  });

  final int testIndex;
  final int number;
  final int pageIndex;

  /// The option the student marked, when one was read.
  final String? detectedLetter;

  /// The key's answer, when known.
  final String? keyAnswer;
  final Verdict verdict;

  /// Set when [verdict] is [Verdict.unsure].
  final UnsureReason? reason;
  final Confidence confidence;

  /// Where to draw the mark, in note-page coordinates (the question number).
  final Rect anchorInNote;

  @override
  bool operator ==(Object other) =>
      other is QuestionGrade &&
      other.testIndex == testIndex &&
      other.number == number &&
      other.pageIndex == pageIndex &&
      other.detectedLetter == detectedLetter &&
      other.keyAnswer == keyAnswer &&
      other.verdict == verdict &&
      other.reason == reason &&
      other.confidence == confidence &&
      other.anchorInNote == anchorInNote;

  @override
  int get hashCode => Object.hash(
    testIndex,
    number,
    pageIndex,
    detectedLetter,
    keyAnswer,
    verdict,
    reason,
    confidence,
    anchorInNote,
  );

  @override
  String toString() =>
      'Grade(t$testIndex #$number: ${detectedLetter ?? '-'} vs '
      '${keyAnswer ?? '-'} -> $verdict${reason == null ? '' : ' $reason'})';
}

/// The result of grading a whole document.
@immutable
class GradeResult {
  const new({
    required this.keyStatus,
    required this.keyDetection,
    required this.grades,
  });

  /// [KeyStatus.found] only when a key was detected with enough confidence
  /// and paired with every test.
  final KeyStatus keyStatus;
  final KeyDetection keyDetection;

  /// In document order.
  final List<QuestionGrade> grades;

  int count(Verdict verdict) =>
      grades.where((g) => g.verdict == verdict).length;

  QuestionGrade? grade(int number, {int testIndex = 0}) {
    for (final g in grades) {
      if (g.testIndex == testIndex && g.number == number) return g;
    }
    return null;
  }

  @override
  String toString() => 'GradeResult($keyStatus, $grades)';
}

/// One stroke of ink in note-page coordinates, reduced to what grading needs.
@immutable
class InkStroke {
  new({required this.outline, required this.toolId, Rect? bounds})
    : bounds = bounds ?? _boundsOf(outline);

  /// The stroke's outline polygon (a thin loop around the pen path, not the
  /// pen path itself).
  final List<Offset> outline;
  final Rect bounds;
  final ToolId toolId;

  static Rect _boundsOf(List<Offset> points) {
    if (points.isEmpty) return Rect.zero;
    var r = Rect.fromPoints(points.first, points.first);
    for (final p in points) {
      r = r.expandToInclude(Rect.fromPoints(p, p));
    }
    return r;
  }

  @override
  String toString() => 'InkStroke($toolId, $bounds)';
}
