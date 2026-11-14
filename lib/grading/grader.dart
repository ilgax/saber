import 'dart:ui';

import 'package:saber/grading/compare/answer_comparer.dart';
import 'package:saber/grading/grading_config.dart';
import 'package:saber/grading/ink/coordinate_mapper.dart';
import 'package:saber/grading/ink/ink_matcher.dart';
import 'package:saber/grading/key/key_page_detector.dart';
import 'package:saber/grading/layout/question_locator.dart';
import 'package:saber/grading/layout/text_extractor.dart';
import 'package:saber/grading/models.dart';

export 'package:saber/grading/key/key_page_detector.dart' show KeyOverride;

/// Everything the grader needs to know about one note page, as plain data.
class GradingPage {
  const new({
    required this.pageIndex,
    required this.text,
    required this.noteSize,
    required this.strokes,
  });

  /// Index of the page in the note.
  final int pageIndex;

  /// The text layer of the PDF shown on this page.
  final PageText text;

  /// Size of the note page the PDF is drawn on and the strokes live in.
  final Size noteSize;

  /// All strokes of the page, in note coordinates.
  final List<InkStroke> strokes;
}

/// What the grader found in a document before any ink is read: the key, the
/// located questions and how tests and key blocks pair up. Questions are in
/// PDF visual space. Used by [gradeDocument] and by diagnostic tools.
class DocumentAnalysis {
  const new({
    required this.detection,
    required this.questionsByPage,
    required this.tests,
    required this.pairedBlocks,
    required this.pairingProblem,
  });

  /// The key as detected (or overridden), before pairing.
  final KeyDetection detection;

  /// Located questions per note page index (non-key pages only).
  final Map<int, List<Question>> questionsByPage;

  /// The questions split into tests, in document order.
  final List<List<Question>> tests;

  /// Key block i is for test i, with question pages set; null when the key is
  /// not usable (see [pairingProblem]).
  final List<KeyBlock>? pairedBlocks;

  /// Why [pairedBlocks] is null, in words; null when paired.
  final String? pairingProblem;
}

/// Finds the key, locates the questions and pairs tests with key blocks.
DocumentAnalysis analyzeDocument(
  List<GradingPage> pages, {
  KeyOverride? keyOverride,
}) {
  final sorted = [...pages]..sort((a, b) => a.pageIndex.compareTo(b.pageIndex));
  final detection = KeyPageDetector.detect({
    for (final p in sorted) p.pageIndex: p.text,
  }, override: keyOverride);
  final keyPages = detection.keyPages;

  // Locate questions on all non-key pages and split them into tests: the
  // numbering restarts at 1 for each test.
  final located = <int, List<Question>>{};
  final tests = <List<Question>>[];
  PageLayout? previousLayout;
  int? previousPage;
  final explicit = [
    for (final b in detection.blocks)
      if (keyOverride != null && keyOverride.blocks.isNotEmpty) b,
  ];
  final byRange =
      explicit.isNotEmpty && explicit.every((b) => b.firstQuestionPage != null);
  int? previous;

  /// The test a question on [page] with [number] belongs to.
  int testFor(int page, int number) {
    if (byRange) {
      for (var i = 0; i < explicit.length; i++) {
        if (page >= explicit[i].firstQuestionPage! &&
            page <= explicit[i].lastQuestionPage!) {
          return i;
        }
      }
      // Outside every range: its own (key-less) test.
      return explicit.length;
    }
    if (previous == null || (number == 1 && previous >= 1)) {
      if (previous != null || tests.isEmpty) return tests.length;
    }
    return tests.isEmpty ? 0 : tests.length - 1;
  }

  for (final page in sorted) {
    if (keyPages.contains(page.pageIndex)) continue;
    final layout = QuestionLocator.locatePage(
      page.text,
      pageIndex: page.pageIndex,
    );
    final found = [...layout.questions];
    // A question split over a page break: number and stem at the bottom of
    // the previous page, options at the top of this one.
    final pending = previousLayout?.pending;
    final lead = layout.leading;
    if (pending != null && lead != null && previousPage == page.pageIndex - 1) {
      found.insert(0, QuestionLocator.continuation(pending, lead));
    }
    previousLayout = layout;
    previousPage = page.pageIndex;
    final questions = <Question>[];
    for (final q in found) {
      final t = testFor(page.pageIndex, q.number);
      while (tests.length <= t) {
        tests.add([]);
      }
      previous = q.number;
      final tagged = q.withTestIndex(t);
      tests[t].add(tagged);
      questions.add(tagged);
    }
    located[page.pageIndex] = questions;
  }
  // Ranges without any question leave empty tests behind; keep the indices
  // (test i pairs with block i) but they hold nothing.

  final (blocks, problem) = byRange
      ? _pairExplicit(tests, detection)
      : _pair(tests, detection);
  return DocumentAnalysis(
    detection: detection,
    questionsByPage: located,
    tests: tests,
    pairedBlocks: blocks,
    pairingProblem: problem,
  );
}

/// Grades a document: locates the key and the questions, reads the ink, and
/// compares. Pure and synchronous.
///
/// [keyOverride] states which pages are the key (the user's decision); the
/// automatic detection is skipped then.
GradeResult gradeDocument(List<GradingPage> pages, {KeyOverride? keyOverride}) {
  final sorted = [...pages]..sort((a, b) => a.pageIndex.compareTo(b.pageIndex));
  final analysis = analyzeDocument(pages, keyOverride: keyOverride);
  final detection = analysis.detection;
  final blocks = analysis.pairedBlocks;
  final paired = blocks != null;

  final grades = <QuestionGrade>[];
  for (final page in sorted) {
    final questions = analysis.questionsByPage[page.pageIndex];
    if (questions == null || questions.isEmpty) continue;
    final mapper = PageMapper(
      pdfSize: page.text.pdfSize,
      noteSize: page.noteSize,
    );
    final inNote = [for (final q in questions) q.mapRects(mapper.rectToNote)];
    final readings = InkMatcher.readAll(inNote, page.strokes);
    for (var i = 0; i < inNote.length; i++) {
      final q = inNote[i];
      final block = blocks != null && q.testIndex < blocks.length
          ? blocks[q.testIndex]
          : null;
      grades.add(_grade(q, readings[i], block));
    }
  }

  return GradeResult(
    keyStatus:
        (analysis.tests.isEmpty ? detection.status == KeyStatus.found : paired)
        ? KeyStatus.found
        : KeyStatus.unknown,
    keyDetection: paired
        ? KeyDetection(
            blocks: blocks,
            confidence: detection.confidence,
            status: detection.status,
          )
        : detection,
    grades: grades,
  );
}

/// The user named the question pages of each key block: test i is the
/// questions of block i's range. No count or coverage checks; the user's word
/// stands.
(List<KeyBlock>?, String?) _pairExplicit(
  List<List<Question>> tests,
  KeyDetection detection,
) {
  if (detection.status != KeyStatus.found) {
    return (null, 'a chosen key block has no readable entries');
  }
  return (detection.blocks, null);
}

/// Pairs test i with key block i (both in document order). Returns the blocks
/// in test order with their question pages set, or null and the reason when
/// the key is not trustworthy: not found, different counts, or entries that do
/// not match the test's question numbers.
(List<KeyBlock>?, String?) _pair(
  List<List<Question>> tests,
  KeyDetection detection,
) {
  if (detection.blocks.isEmpty) return (null, 'no key pages found');
  if (detection.status != KeyStatus.found) {
    return (
      null,
      'key confidence ${detection.confidence.toStringAsFixed(2)} is below '
          '${GradingConfig.keyAcceptConfidence}',
    );
  }
  if (tests.isEmpty) return (null, 'no questions located');
  if (tests.length != detection.blocks.length) {
    return (
      null,
      'count mismatch: ${tests.length} test(s) but '
          '${detection.blocks.length} key block(s)',
    );
  }
  final result = <KeyBlock>[];
  for (var i = 0; i < tests.length; i++) {
    final block = detection.blocks[i];
    final numbers = {for (final q in tests[i]) q.number};
    final covered = numbers.where(block.answers.containsKey).length;
    if (covered < GradingConfig.keyMinQuestionCoverage * numbers.length) {
      return (
        null,
        'low coverage: key block ${i + 1} has entries for only $covered of '
            '${numbers.length} questions of test ${i + 1}',
      );
    }
    final pages = tests[i].map((q) => q.pageIndex);
    result.add(
      block.withQuestionPages(
        pages.reduce((a, b) => a < b ? a : b),
        pages.reduce((a, b) => a > b ? a : b),
      ),
    );
  }
  return (result, null);
}

QuestionGrade _grade(Question q, MarkReading reading, KeyBlock? block) {
  final keyAnswer = block?.answers[q.number];
  QuestionGrade make(Verdict verdict, {UnsureReason? reason}) => QuestionGrade(
    testIndex: q.testIndex,
    number: q.number,
    pageIndex: q.pageIndex,
    detectedLetter: reading.letter,
    keyAnswer: keyAnswer,
    verdict: verdict,
    reason: reason,
    confidence: reading.confidence,
    anchorInNote: q.numberRect,
  );

  switch (reading.state) {
    case MarkState.unanswered:
      return make(Verdict.unanswered);
    case MarkState.unsure:
      return make(Verdict.unsure, reason: reading.reason);
    case MarkState.marked:
      if (block == null)
        return make(Verdict.unsure, reason: UnsureReason.keyUnknown);
      if (keyAnswer == null) {
        return make(Verdict.unsure, reason: UnsureReason.noKeyEntry);
      }
      if (q.option(keyAnswer) == null) {
        return make(Verdict.unsure, reason: UnsureReason.keyNotAnOption);
      }
      return make(
        AnswerComparer.lettersMatch(reading.letter!, keyAnswer)
            ? Verdict.correct
            : Verdict.wrong,
      );
  }
}
