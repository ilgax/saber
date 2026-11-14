import 'package:saber/grading/diagnostics.dart';
import 'package:saber/grading/grade_range.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/grading_config.dart';
import 'package:saber/grading/layout/text_extractor.dart';
import 'package:saber/grading/models.dart';
import 'package:saber/grading/ocr/ocr_engine.dart';

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
  GradeRange? range,
  int? pageCount,
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

  // With a range: the pages in it, plus the key pages (anywhere) that were
  // used.
  final listed = [
    for (final p in pages)
      if (range == null ||
          range.contains(p.pageIndex) ||
          keyPages.contains(p.pageIndex))
        p,
  ];
  if (range != null) {
    b.writeln(
      'range: pages ${range.from + 1}-${range.to + 1}'
      '${pageCount == null ? '' : ' of $pageCount'}',
    );
  }
  b.writeln('PAGES: ${listed.length}');
  for (final p in listed) {
    final t = p.text;
    final glyphs = t.tokens.fold<int>(0, (n, x) => n + x.text.length);
    final ink = outcome.pages[p.pageIndex];
    final questions = analysis.questionsByPage[p.pageIndex] ?? const [];
    final own = ink?.counts(fromPdf: false);
    final pdf = ink?.counts(fromPdf: true);
    final source = switch (t.source) {
      TextSource.ocr => 'OCR',
      TextSource.textLayer => 'text layer',
    };
    final ocrNote = switch (p.ocrStatus) {
      OcrStatus.unavailable => ' (OCR needed but unavailable)',
      OcrStatus.failed => ' (OCR failed)',
      _ => '',
    };
    b.writeln(
      '  page ${p.pageIndex + 1}: '
      '${t.hasText ? '$source, $glyphs chars' : 'NO text layer'}$ocrNote, '
      '${t.pdfSize.width.toStringAsFixed(0)} x ${t.pdfSize.height.toStringAsFixed(0)} pt, '
      'rotation ${t.rotation}, '
      '${range != null && !range.contains(p.pageIndex) ? 'outside the range, ' : ''}'
      '${keyPages.contains(p.pageIndex) ? 'KEY PAGE' : '${questions.length} question(s)'}'
      '${analysis.footerKeyPages.contains(p.pageIndex) ? ' + key line' : ''}, '
      'strokes ${own?.total ?? 0} '
      '(gradable ${own?.gradable ?? 0}, ignored ${own?.ignored ?? 0}, '
      'unassigned ${own?.unassigned ?? 0})'
      '${pdf == null || pdf.total == 0 ? '' : ' + pdf ink ${pdf.total} (gradable ${pdf.gradable}, ignored ${pdf.ignored}, unassigned ${pdf.unassigned})'}',
    );
  }
  final kinds = <InkKind, int>{};
  final pdfKinds = <InkKind, int>{};
  for (final ink in outcome.pages.values) {
    for (var i = 0; i < ink.classes.length; i++) {
      final target = ink.strokes[i].fromPdf ? pdfKinds : kinds;
      final k = ink.classes[i].kind;
      target[k] = (target[k] ?? 0) + 1;
    }
  }
  String kindList(Map<InkKind, int> m) => m.isEmpty
      ? 'none'
      : [for (final e in m.entries) '${e.key.name} ${e.value}'].join(', ');
  b.writeln('  stroke kinds: ${kindList(kinds)}');
  b.writeln('  pdf ink kinds: ${kindList(pdfKinds)}');

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
  final findings = suspiciousFindings(
    range == null ? analysis : _inRange(analysis, range),
    {
      for (final p in listed)
        if (range == null || range.contains(p.pageIndex)) p.pageIndex: p.text,
    },
  );
  for (final f in findings) {
    b.writeln('  - $f');
  }
  if (findings.isEmpty) b.writeln('  nothing');

  b.writeln();
  b.writeln('CONFIG:');
  GradingConfig.all.forEach((k, v) => b.writeln('  $k = $v'));
  return b.toString();
}

/// [analysis] with only the questions of pages in [range] (the tests keep
/// their positions), so findings about tests are not about pages that were not
/// graded.
DocumentAnalysis _inRange(DocumentAnalysis analysis, GradeRange range) =>
    DocumentAnalysis(
      detection: analysis.detection,
      questionsByPage: {
        for (final e in analysis.questionsByPage.entries)
          if (range.contains(e.key)) e.key: e.value,
      },
      tests: [
        for (final t in analysis.tests)
          [
            for (final q in t)
              if (range.contains(q.pageIndex)) q,
          ],
      ],
      pairedBlocks: analysis.pairedBlocks,
      pairingProblem: analysis.pairingProblem,
      footerKeyPages: analysis.footerKeyPages,
    );
