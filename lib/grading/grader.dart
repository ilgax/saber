import 'dart:math';
import 'dart:ui';

import 'package:saber/grading/compare/answer_comparer.dart';
import 'package:saber/grading/corrections.dart';
import 'package:saber/grading/grading_config.dart';
import 'package:saber/grading/ink/coordinate_mapper.dart';
import 'package:saber/grading/ink/ink_matcher.dart';
import 'package:saber/grading/key/key_page_detector.dart';
import 'package:saber/grading/layout/question_locator.dart';
import 'package:saber/grading/layout/text_extractor.dart';
import 'package:saber/grading/models.dart';
import 'package:saber/grading/ocr/ocr_engine.dart';

export 'package:saber/grading/key/key_page_detector.dart' show KeyOverride;

/// Everything the grader needs to know about one note page, as plain data.
class GradingPage {
  const new({
    required this.pageIndex,
    required this.text,
    required this.noteSize,
    required this.strokes,
    this.ocrStatus = OcrStatus.notNeeded,
  });

  /// Index of the page in the note.
  final int pageIndex;

  /// The text layer of the PDF shown on this page.
  final PageText text;

  /// Size of the note page the PDF is drawn on and the strokes live in.
  final Size noteSize;

  /// All strokes of the page, in note coordinates: the note's own strokes
  /// and the PDF's ink annotations ([InkStroke.fromPdf]).
  final List<InkStroke> strokes;

  /// Whether the text of the page came from OCR (see [PageText.source]) or
  /// why not although the text layer was too thin.
  final OcrStatus ocrStatus;
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
    this.footerKeyPages = const {},
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

  /// Question pages that hold the key as a line (`1. D 2. A ...`), see
  /// [KeyBlock.samePage].
  final Set<int> footerKeyPages;
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
  final footerPages = detection.footerPages;

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
    // A key line in the footer of a question page is not question text.
    final footer = footerPages.contains(page.pageIndex)
        ? KeyPageDetector.footerKey(page.pageIndex, page.text)
        : null;
    final layout = QuestionLocator.locatePage(
      footer?.stripped ?? page.text,
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
      : footerPages.isNotEmpty
      ? _pairFooter(tests, located, detection)
      : _pair(tests, detection);
  return DocumentAnalysis(
    detection: detection,
    questionsByPage: located,
    tests: tests,
    pairedBlocks: blocks,
    pairingProblem: problem,
    footerKeyPages: footerPages,
  );
}

/// What was read for one question, with the evidence.
class QuestionOutcome {
  const new({
    required this.question,
    required this.detail,
    required this.signature,
    required this.strokeCount,
    required this.corrected,
  });

  /// The question in note coordinates.
  final Question question;
  final ReadDetail detail;

  /// Fingerprint of the ink assigned to the question.
  final InkSignature signature;
  final int strokeCount;

  /// A stored correction was applied to this question.
  final bool corrected;
}

/// Ink statistics of one page.
class PageInk {
  const new({
    required this.strokes,
    required this.classes,
    required this.questions,
  });

  /// The page's strokes (note coordinates).
  final List<InkStroke> strokes;

  /// One per stroke: the question it was assigned to and what it was.
  final List<StrokeClassification> classes;

  /// The page's questions in note coordinates, in the order the
  /// classifications' question indices refer to.
  final List<Question> questions;

  /// Counts of the page's own strokes, or with [fromPdf] of the PDF's ink
  /// annotations: total, gradable, ignored (not gradable) and unassigned
  /// (gradable but near no question).
  ({int total, int gradable, int ignored, int unassigned}) counts({
    required bool fromPdf,
  }) {
    var total = 0, gradable = 0, unassigned = 0;
    for (var i = 0; i < strokes.length; i++) {
      if (strokes[i].fromPdf != fromPdf) continue;
      total++;
      if (!GradingConfig.gradableTools.contains(strokes[i].toolId)) continue;
      gradable++;
      if (classes[i].questionIndex == null) unassigned++;
    }
    return (
      total: total,
      gradable: gradable,
      ignored: total - gradable,
      unassigned: unassigned,
    );
  }

  int get gradable => strokes
      .where((s) => GradingConfig.gradableTools.contains(s.toolId))
      .length;
  int get ignored => strokes.length - gradable;
  int get unassigned => classes
      .asMap()
      .entries
      .where(
        (e) =>
            e.value.questionIndex == null &&
            GradingConfig.gradableTools.contains(strokes[e.key].toolId),
      )
      .length;
}

/// Everything [gradeDetailed] computed.
class GradingOutcome {
  const new({
    required this.analysis,
    required this.result,
    required this.questions,
    required this.pages,
  });

  final DocumentAnalysis analysis;
  final GradeResult result;
  final Map<QuestionId, QuestionOutcome> questions;

  /// Per note page index.
  final Map<int, PageInk> pages;
}

/// Grades a document: locates the key and the questions, reads the ink, and
/// compares. Pure and synchronous.
///
/// [keyOverride] states which pages are the key (the user's decision); the
/// automatic detection is skipped then.
GradeResult gradeDocument(
  List<GradingPage> pages, {
  KeyOverride? keyOverride,
  List<Correction> corrections = const [],
}) => gradeDetailed(
  pages,
  keyOverride: keyOverride,
  corrections: corrections,
).result;

/// Like [gradeDocument], with the evidence behind every grade. A
/// [Correction] replaces the reading of its question only when the ink
/// assigned to the question still matches the correction's signature.
GradingOutcome gradeDetailed(
  List<GradingPage> pages, {
  KeyOverride? keyOverride,
  List<Correction> corrections = const [],
}) {
  final sorted = [...pages]..sort((a, b) => a.pageIndex.compareTo(b.pageIndex));
  final analysis = analyzeDocument(pages, keyOverride: keyOverride);
  final detection = analysis.detection;
  final blocks = analysis.pairedBlocks;
  final paired = blocks != null;
  final byId = {for (final c in corrections) c.id: c};

  final grades = <QuestionGrade>[];
  final outcomes = <QuestionId, QuestionOutcome>{};
  final pageInk = <int, PageInk>{};
  for (final page in sorted) {
    final questions = analysis.questionsByPage[page.pageIndex] ?? const [];
    final mapper = PageMapper(
      pdfSize: page.text.pdfSize,
      noteSize: page.noteSize,
    );
    final inNote = [for (final q in questions) q.mapRects(mapper.rectToNote)];
    final ink = InkMatcher.analyzePage(inNote, page.strokes);
    pageInk[page.pageIndex] = PageInk(
      strokes: page.strokes,
      classes: ink.classes,
      questions: inNote,
    );
    for (var i = 0; i < inNote.length; i++) {
      final q = inNote[i];
      final block = blocks != null && q.testIndex < blocks.length
          ? blocks[q.testIndex]
          : null;
      final signature = InkSignature.of(ink.assigned[i]);
      var reading = ink.details[i].reading;
      final c = byId[(q.testIndex, q.number)];
      final corrected =
          c != null &&
          q.option(c.letter) != null &&
          c.signature.matches(signature);
      if (corrected) {
        reading = MarkReading.marked(c.letter, confidence: Confidence.high);
      }
      grades.add(_grade(q, reading, block, corrected: corrected));
      outcomes[(q.testIndex, q.number)] = QuestionOutcome(
        question: q,
        detail: ink.details[i],
        signature: signature,
        strokeCount: ink.assigned[i].length,
        corrected: corrected,
      );
    }
  }

  final result = GradeResult(
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
  return GradingOutcome(
    analysis: analysis,
    result: result,
    questions: outcomes,
    pages: pageInk,
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

/// Pairs the key lines on question pages with the tests: a key line belongs
/// to the test of the questions on its page (the k-th key line of a page to
/// the k-th test that has questions there); a page without questions belongs
/// to the test of the closest questions before it. Key lines of one test
/// (a test over several pages with a key line each) are merged. Returns the
/// blocks in test order.
(List<KeyBlock>?, String?) _pairFooter(
  List<List<Question>> tests,
  Map<int, List<Question>> located,
  KeyDetection detection,
) {
  if (tests.isEmpty) return (null, 'no questions located');
  final pagesWithQuestions = [
    for (final e in located.entries)
      if (e.value.isNotEmpty) e.key,
  ]..sort();
  final byTest = <int, KeyBlock>{};
  final seenOnPage = <int, int>{};
  for (final block in detection.blocks) {
    final page = block.firstKeyPage;
    final here = <int>[];
    for (final q in located[page] ?? const <Question>[]) {
      if (!here.contains(q.testIndex)) here.add(q.testIndex);
    }
    final nth = seenOnPage[page] = (seenOnPage[page] ?? -1) + 1;
    int? test;
    if (here.isNotEmpty) {
      test = here[nth < here.length ? nth : here.length - 1];
    } else {
      final before = pagesWithQuestions.where((p) => p < page).lastOrNull;
      if (before != null) test = located[before]!.last.testIndex;
    }
    if (test == null) {
      return (
        null,
        'the key line on page ${page + 1} has no questions before it',
      );
    }
    final merged = byTest[test];
    if (merged == null) {
      byTest[test] = block;
    } else {
      byTest[test] = KeyBlock(
        firstKeyPage: min(merged.firstKeyPage, block.firstKeyPage),
        lastKeyPage: max(merged.lastKeyPage, block.lastKeyPage),
        answers: {...block.answers, ...merged.answers},
        samePage: true,
      );
    }
  }
  final result = <KeyBlock>[];
  for (var i = 0; i < tests.length; i++) {
    final block = byTest[i];
    if (block == null) {
      return (null, 'test ${i + 1} has no key line on its pages');
    }
    final numbers = {for (final q in tests[i]) q.number};
    final covered = numbers.where(block.answers.containsKey).length;
    if (covered < GradingConfig.keyMinQuestionCoverage * numbers.length) {
      return (
        null,
        'low coverage: the key line of test ${i + 1} has entries for only '
            '$covered of ${numbers.length} questions',
      );
    }
    final pages = tests[i].map((q) => q.pageIndex);
    result.add(block.withQuestionPages(pages.reduce(min), pages.reduce(max)));
  }
  return (result, null);
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

QuestionGrade _grade(
  Question q,
  MarkReading reading,
  KeyBlock? block, {
  bool corrected = false,
}) {
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
    readKind: reading.kind,
    corrected: corrected,
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
