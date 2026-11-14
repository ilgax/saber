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

/// Grades a document: locates the key and the questions, reads the ink, and
/// compares. Pure and synchronous.
///
/// [keyOverride] states which pages are the key (the user's decision); the
/// automatic detection is skipped then.
GradeResult gradeDocument(List<GradingPage> pages, {KeyOverride? keyOverride}) {
  final sorted = [...pages]..sort((a, b) => a.pageIndex.compareTo(b.pageIndex));
  final detection = KeyPageDetector.detect({
    for (final p in sorted) p.pageIndex: p.text,
  }, override: keyOverride);
  final keyPages = detection.keyPages;

  // Locate questions on all non-key pages and split them into tests: the
  // numbering restarts at 1 for each test.
  final located = <GradingPage, List<Question>>{};
  final tests = <List<Question>>[];
  int? previous;
  for (final page in sorted) {
    if (keyPages.contains(page.pageIndex)) continue;
    final questions = <Question>[];
    for (final q in QuestionLocator.locate(
      page.text,
      pageIndex: page.pageIndex,
    )) {
      if (previous == null || (q.number == 1 && previous >= 1)) {
        if (previous != null || tests.isEmpty) tests.add([]);
      }
      previous = q.number;
      final tagged = q.withTestIndex(tests.length - 1);
      tests.last.add(tagged);
      questions.add(tagged);
    }
    located[page] = questions;
  }

  final blocks = _pair(tests, detection);
  final paired = blocks != null;

  final grades = <QuestionGrade>[];
  for (final page in sorted) {
    final questions = located[page];
    if (questions == null || questions.isEmpty) continue;
    final mapper = PageMapper(
      pdfSize: page.text.pdfSize,
      noteSize: page.noteSize,
    );
    final inNote = [for (final q in questions) q.mapRects(mapper.rectToNote)];
    final readings = InkMatcher.readAll(inNote, page.strokes);
    for (var i = 0; i < inNote.length; i++) {
      final q = inNote[i];
      final block = blocks?[q.testIndex];
      grades.add(_grade(q, readings[i], block));
    }
  }

  return GradeResult(
    keyStatus: (tests.isEmpty ? detection.status == KeyStatus.found : paired)
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

/// Pairs test i with key block i (both in document order). Returns the blocks
/// in test order with their question pages set, or null when the key is not
/// trustworthy: not found, different counts, or entries that do not match the
/// test's question numbers.
List<KeyBlock>? _pair(List<List<Question>> tests, KeyDetection detection) {
  if (detection.status != KeyStatus.found) return null;
  if (tests.isEmpty || tests.length != detection.blocks.length) return null;
  final result = <KeyBlock>[];
  for (var i = 0; i < tests.length; i++) {
    final block = detection.blocks[i];
    final numbers = {for (final q in tests[i]) q.number};
    final covered = numbers.where(block.answers.containsKey).length;
    if (covered < GradingConfig.keyMinQuestionCoverage * numbers.length) {
      return null;
    }
    final pages = tests[i].map((q) => q.pageIndex);
    result.add(
      block.withQuestionPages(
        pages.reduce((a, b) => a < b ? a : b),
        pages.reduce((a, b) => a > b ? a : b),
      ),
    );
  }
  return result;
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
