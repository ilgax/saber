import 'dart:math';

import 'package:saber/grading/grading_config.dart';
import 'package:saber/grading/key/key_parser.dart';
import 'package:saber/grading/layout/text_extractor.dart';
import 'package:saber/grading/models.dart';

/// The user's decision which pages hold the answer key (Phase 2 UI). The
/// pages are the indices of the note's pages.
class KeyOverride {
  const new(this.keyPages);

  final Set<int> keyPages;
}

/// Key statistics of one page.
class KeyPageStats {
  const new({
    required this.pageIndex,
    required this.entries,
    required this.coverage,
    required this.longestRun,
  });

  final int pageIndex;

  /// In reading order (rows top to bottom, left to right).
  final List<KeyEntry> entries;

  /// Fraction of the page's tokens that belong to `number letter` entries.
  final double coverage;

  /// Longest run of consecutive question numbers among the entries.
  final int longestRun;

  bool get isKeyPage =>
      longestRun >= GradingConfig.keyMinConsecutiveRun &&
      coverage >= GradingConfig.keyMinCoverage;
}

/// Finds the answer key pages by pattern density.
abstract final class KeyPageDetector {
  static KeyPageStats analyze(int pageIndex, PageText text) {
    final entries = <KeyEntry>[];
    var matched = 0, total = 0;
    for (final line in text.lines) {
      final lineText = line.text;
      for (final e in KeyParser.parseEntries(lineText)) {
        entries.add(
          KeyEntry(number: e.number, letter: e.letter, pageIndex: pageIndex),
        );
      }
      final c = KeyParser.coverage(lineText);
      matched += c.matched;
      total += c.total;
    }
    final numbers = {for (final e in entries) e.number};
    var longest = 0, run = 0;
    for (final n in (numbers.toList()..sort())) {
      run = numbers.contains(n - 1) ? run + 1 : 1;
      longest = max(longest, run);
    }
    return KeyPageStats(
      pageIndex: pageIndex,
      entries: entries,
      coverage: total == 0 ? 0 : matched / total,
      longestRun: longest,
    );
  }

  /// Detects the key in [pages] (note page index to text), or uses
  /// [override]. Returns [KeyStatus.unknown] when there is no convincing key.
  static KeyDetection detect(
    Map<int, PageText> pages, {
    KeyOverride? override,
  }) {
    final indices = pages.keys.toList()..sort();
    final stats = [for (final i in indices) analyze(i, pages[i]!)];
    final keyStats = [
      for (final s in stats)
        if (override != null
            ? override.keyPages.contains(s.pageIndex)
            : s.isKeyPage)
          s,
    ];
    if (keyStats.isEmpty) return const KeyDetection.unknown();

    // Walk the entries in reading order; a new block starts when the pages
    // are not consecutive or a number repeats (numbering restarted).
    final blocks = <KeyBlock>[];
    int? first, last;
    var answers = <int, String>{};
    void flush() {
      if (first != null && answers.isNotEmpty) {
        blocks.add(
          KeyBlock(firstKeyPage: first!, lastKeyPage: last!, answers: answers),
        );
      }
      first = null;
      answers = {};
    }

    for (final s in keyStats) {
      if (last != null && s.pageIndex != last + 1) flush();
      first ??= s.pageIndex;
      last = s.pageIndex;
      for (final e in s.entries) {
        if (answers.containsKey(e.number)) {
          flush();
          first = s.pageIndex;
          last = s.pageIndex;
        }
        answers[e.number] = e.letter;
      }
    }
    flush();
    if (blocks.isEmpty) return const KeyDetection.unknown();

    final confidence = override != null
        ? 1.0
        : keyStats.map((s) => s.coverage).reduce(min);
    final status = confidence >= GradingConfig.keyAcceptConfidence
        ? KeyStatus.found
        : KeyStatus.unknown;
    return KeyDetection(blocks: blocks, confidence: confidence, status: status);
  }
}
