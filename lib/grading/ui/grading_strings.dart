import 'package:saber/grading/models.dart';

/// All user-visible text of the grading UI, in English. (Upstream's i18n
/// files are not touched, to keep merges with upstream trivial.)
abstract final class GradingStrings {
  static const grade = 'Grade';
  static const gradeTooltip = 'Grade this test (long-press: debug overlay)';
  static const grading = 'Grading…';
  static const results = 'Grading results';
  static const gradeAgain = 'Grade again';
  static const hideMarks = 'Hide marks';
  static const showMarks = 'Show marks';
  static const keyPages = 'Key pages…';
  static const shareReport = 'Share grading report';
  static const copyReport = 'Copy report';
  static const reportCopied = 'Report copied to the clipboard';
  static const debugOverlay = 'Debug overlay';
  static const close = 'Close';
  static const cancel = 'Cancel';
  static const ok = 'OK';
  static const noPdfPages = 'This note has no PDF pages to grade.';
  static const noQuestions =
      'No multiple choice questions were found in this note.';
  static const questions = 'Questions';
  static const editedBadge = 'edited';
  static const clearCorrection = 'Clear correction';
  static const resetToAutomatic = 'Reset to automatic';
  static const keyPagesTitle = 'Which pages are the answer key?';
  static const keyPagesHelp =
      'Tick the pages that hold the answer key. If one PDF holds several '
      'tests, say which question pages each key block belongs to.';
  static const keyPagesAuto = 'auto';
  static const splitBlock = 'Another test on these key pages';
  static const removeBlock = 'Remove';
  static const apply = 'Apply';

  static String errorText(Object error) =>
      'Grading failed: ${error.toString().split('\n').first}';

  static String summary(GradeResult r) {
    final total = r.grades.length;
    final unsure = r.count(Verdict.unsure);
    final unanswered = r.count(Verdict.unanswered);
    return '${r.count(Verdict.correct)}/$total correct'
        '${unsure > 0 ? ', $unsure unsure' : ''}'
        '${unanswered > 0 ? ', $unanswered unanswered' : ''}';
  }

  static String fullSummary(GradeResult r) =>
      '${r.count(Verdict.correct)} correct, ${r.count(Verdict.wrong)} wrong, '
      '${r.count(Verdict.unsure)} unsure, ${r.count(Verdict.unanswered)} '
      'unanswered (of ${r.grades.length})';

  static String verdict(Verdict v) => switch (v) {
    Verdict.correct => 'Correct',
    Verdict.wrong => 'Wrong',
    Verdict.unsure => 'Unsure',
    Verdict.unanswered => 'Unanswered',
  };

  static String reason(UnsureReason? r) => switch (r) {
    null => '',
    UnsureReason.noOptionAboveThreshold =>
      'There is ink in this question, but no option is clearly marked.',
    UnsureReason.twoOptionsClose => 'Two options look marked about equally.',
    UnsureReason.crossedOutAmbiguous =>
      'An option is crossed out and what is left is not one clear mark.',
    UnsureReason.keyUnknown =>
      'The answer key could not be found or matched to this test.',
    UnsureReason.noKeyEntry => 'The answer key has no entry for this question.',
    UnsureReason.keyNotAnOption =>
      "The key's answer is not one of this question's options.",
  };

  static String inkKind(InkKind? k) => switch (k) {
    null => '-',
    InkKind.ring => 'circle',
    InkKind.fill => 'filled bubble',
    InkKind.tick => 'tick or small mark',
    InkKind.underline => 'underline',
    InkKind.strike => 'cross-out',
    InkKind.diagonal => 'diagonal line',
    InkKind.ignored => 'ignored',
  };

  static String confidence(Confidence c) => switch (c) {
    Confidence.low => 'low',
    Confidence.medium => 'medium',
    Confidence.high => 'high',
  };

  static String keyStatusText(GradeResult r, String? pairingProblem) {
    if (r.keyStatus == KeyStatus.found) {
      return 'Answer key found (confidence '
          '${(r.keyDetection.confidence * 100).round()}%).';
    }
    return 'No usable answer key: ${pairingProblemText(pairingProblem)} '
        'Marked answers are shown as unsure until the key is known.';
  }

  /// [pairingProblem] from the core, in plain words.
  static String pairingProblemText(String? problem) {
    if (problem == null) return 'unknown reason.';
    if (problem == 'no key pages found') {
      return 'no page looks like an answer key.';
    }
    if (problem.startsWith('key confidence')) {
      return 'a page looks like a key but only weakly.';
    }
    if (problem == 'no questions located') {
      return 'no questions were found to compare with.';
    }
    if (problem.startsWith('count mismatch')) {
      final m = RegExp(r'(\d+) test\(s\) but (\d+) key').firstMatch(problem);
      return m == null
          ? 'the number of tests and key blocks differ.'
          : 'found ${m.group(1)} test(s) but ${m.group(2)} key block(s).';
    }
    if (problem.startsWith('low coverage')) {
      return 'the key does not cover enough of the questions.';
    }
    return '$problem.';
  }
}
