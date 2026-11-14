import 'package:saber/grading/grader.dart';
import 'package:saber/grading/layout/text_extractor.dart';

/// Things in an analysis that look wrong and are worth a human look: gaps in
/// the numbering, questions with few options, key entries without a question
/// and the other way round, text pages without questions. Pages are numbered
/// from 1 in the messages. Contains numbers and letters only, no document
/// text.
List<String> suspiciousFindings(
  DocumentAnalysis analysis,
  Map<int, PageText> texts,
) {
  final found = <String>[];
  final detection = analysis.detection;
  final keyPages = detection.keyPages;
  for (var t = 0; t < analysis.tests.length; t++) {
    final qs = analysis.tests[t];
    if (qs.isEmpty) continue;
    final numbers = {for (final q in qs) q.number}.toList()..sort();
    final missing = <int>[
      for (var n = numbers.first; n <= numbers.last; n++)
        if (!numbers.contains(n)) n,
    ];
    if (missing.isNotEmpty) {
      found.add(
        'test ${t + 1}: gaps in numbering, missing ${missing.join(', ')}',
      );
    }
    if (numbers.first != 1) {
      found.add('test ${t + 1}: numbering starts at ${numbers.first}, not 1');
    }
    for (final q in qs.where((q) => q.options.length < 4)) {
      found.add(
        'test ${t + 1} #${q.number} (page ${q.pageIndex + 1}): only '
        '${q.options.length} option(s): ${q.options.map((o) => o.letter).join()}',
      );
    }
    // Compare with the key block of the same index, paired or not.
    final blocks = analysis.pairedBlocks ?? detection.blocks;
    if (t < blocks.length) {
      final answers = blocks[t].answers;
      final qn = numbers.toSet();
      final noQuestion = answers.keys.where((n) => !qn.contains(n)).toList()
        ..sort();
      final noKey = numbers.where((n) => !answers.containsKey(n)).toList();
      if (noQuestion.isNotEmpty) {
        found.add(
          'key block ${t + 1}: entries with no located question: '
          '${noQuestion.join(', ')}',
        );
      }
      if (noKey.isNotEmpty) {
        found.add(
          'test ${t + 1}: questions with no key entry: ${noKey.join(', ')}',
        );
      }
      for (final q in qs) {
        final a = answers[q.number];
        if (a != null && q.option(a) == null) {
          found.add(
            'test ${t + 1} #${q.number}: key says $a but no such option was located',
          );
        }
      }
    }
  }
  for (final e in texts.entries) {
    if (e.value.hasText &&
        !keyPages.contains(e.key) &&
        (analysis.questionsByPage[e.key] ?? const []).isEmpty) {
      found.add(
        'page ${e.key + 1} has a text layer but no questions and is not a key page',
      );
    }
  }
  return found;
}
