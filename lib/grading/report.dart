import 'package:saber/grading/diagnostics.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/grading_config.dart';
import 'package:saber/grading/models.dart';

/// How long a grading run took.
class GradingTimings {
  const new({required this.extraction, required this.grading});

  /// Reading the text layer of every page.
  final Duration extraction;

  /// `gradeDetailed` (in an isolate).
  final Duration grading;

  Duration get total => extraction + grading;
}

/// The grading report as plain text, to paste into a chat.
///
/// PRIVACY: it contains no document text other than question numbers and
/// option letters (no stems, no option text, no key explanations), no file
/// names or paths, and no stroke coordinates (counts and classifications
/// only). Keep it that way: everything below prints numbers, letters, enum
/// names and fixed words only.
String buildGradingReport({
  required List<GradingPage> pages,
  required GradingOutcome outcome,
  required GradingTimings timings,
  KeyOverride? keyOverride,
  String buildInfo = '',
}) {
  final b = StringBuffer();
  final analysis = outcome.analysis;
  final detection = analysis.detection;
  final result = outcome.result;
  final keyPages = detection.keyPages;

  b.writeln('GRADING REPORT');
  if (buildInfo.isNotEmpty) b.writeln('build: $buildInfo');
  b.writeln(
    'timings: text extraction ${timings.extraction.inMilliseconds} ms, '
    'grading ${timings.grading.inMilliseconds} ms, '
    'total ${timings.total.inMilliseconds} ms',
  );
  b.writeln();

  b.writeln('PAGES: ${pages.length}');
  for (final p in pages) {
    final t = p.text;
    final glyphs = t.tokens.fold<int>(0, (n, x) => n + x.text.length);
    final ink = outcome.pages[p.pageIndex];
    final questions = analysis.questionsByPage[p.pageIndex] ?? const [];
    b.writeln(
      '  page ${p.pageIndex + 1}: '
      '${t.hasText ? 'text layer, $glyphs chars' : 'NO text layer'}, '
      '${t.pdfSize.width.toStringAsFixed(0)} x ${t.pdfSize.height.toStringAsFixed(0)} pt, '
      'rotation ${t.rotation}, '
      '${keyPages.contains(p.pageIndex) ? 'KEY PAGE' : '${questions.length} question(s)'}, '
      'strokes ${p.strokes.length} '
      '(gradable ${ink?.gradable ?? 0}, ignored ${ink?.ignored ?? 0}, '
      'unassigned ${ink?.unassigned ?? 0})',
    );
  }
  final kinds = <InkKind, int>{};
  for (final ink in outcome.pages.values) {
    for (final c in ink.classes) {
      kinds[c.kind] = (kinds[c.kind] ?? 0) + 1;
    }
  }
  b.writeln(
    '  stroke kinds: ${kinds.isEmpty ? 'none' : [for (final e in kinds.entries) '${e.key.name} ${e.value}'].join(', ')}',
  );

  b.writeln();
  b.writeln(
    'KEY: ${keyOverride == null ? 'automatic detection' : 'chosen by the user'}',
  );
  b.writeln(
    '  status ${detection.status.name}, confidence '
    '${detection.confidence.toStringAsFixed(2)}, ${detection.blocks.length} block(s)',
  );
  for (var i = 0; i < detection.blocks.length; i++) {
    final k = detection.blocks[i];
    final numbers = k.answers.keys.toList()..sort();
    b.writeln(
      '  block ${i + 1}: pages ${k.firstKeyPage + 1}-${k.lastKeyPage + 1}, '
      '${k.answers.length} entries'
      '${numbers.isEmpty ? '' : ', numbers ${numbers.first}-${numbers.last}'}'
      '${k.firstQuestionPage == null ? '' : ', for question pages ${k.firstQuestionPage! + 1}-${k.lastQuestionPage! + 1}'}',
    );
  }
  b.writeln(
    'PAIRING: ${analysis.pairedBlocks != null ? 'ok, ${analysis.tests.length} test(s)' : 'FAILED: ${analysis.pairingProblem}'}',
  );

  b.writeln();
  b.writeln('QUESTIONS:');
  for (final g in result.grades) {
    final q = outcome.questions[(g.testIndex, g.number)];
    final options = q?.question.options.map((o) => o.letter).join() ?? '';
    b.writeln(
      '  test ${g.testIndex + 1} #${g.number} page ${g.pageIndex + 1}: '
      'options $options, '
      'read ${g.detectedLetter ?? '-'}'
      '${g.corrected ? ' (edited by user)' : ''}'
      '${g.readKind == null ? '' : ' (${g.readKind!.name}, ${g.confidence.name})'}, '
      'key ${g.keyAnswer ?? '-'}, ${g.verdict.name}'
      '${g.reason == null ? '' : ' (${g.reason!.name})'}'
      '${q == null || q.question.continuedFromPage == null ? '' : ', continued from page ${q.question.continuedFromPage! + 1}'}'
      '${q == null ? '' : ', ${q.strokeCount} stroke(s)'}',
    );
  }
  if (result.grades.isEmpty) b.writeln('  none located');
  b.writeln(
    '  totals: correct ${result.count(Verdict.correct)}, '
    'wrong ${result.count(Verdict.wrong)}, unsure ${result.count(Verdict.unsure)}, '
    'unanswered ${result.count(Verdict.unanswered)}',
  );

  b.writeln();
  b.writeln('SUSPICIOUS:');
  final findings = suspiciousFindings(analysis, {
    for (final p in pages) p.pageIndex: p.text,
  });
  for (final f in findings) {
    b.writeln('  - $f');
  }
  if (findings.isEmpty) b.writeln('  nothing');

  b.writeln();
  b.writeln('CONFIG:');
  GradingConfig.all.forEach((k, v) => b.writeln('  $k = $v'));
  return b.toString();
}
