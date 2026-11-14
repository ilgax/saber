import 'dart:math';
import 'dart:ui';

import 'package:saber/grading/grading_config.dart';
import 'package:saber/grading/key/key_parser.dart';
import 'package:saber/grading/layout/text_extractor.dart';
import 'package:saber/grading/models.dart';

/// One key block the user defined: its key pages and, optionally, the
/// question pages of the test it belongs to. Page indices are the note's.
class KeyBlockOverride {
  const new({
    required this.firstKeyPage,
    required this.lastKeyPage,
    this.firstQuestionPage,
    this.lastQuestionPage,
  });

  factory fromJson(Map<String, dynamic> json) => KeyBlockOverride(
    firstKeyPage: json['kf'] as int,
    lastKeyPage: json['kl'] as int,
    firstQuestionPage: json['qf'] as int?,
    lastQuestionPage: json['ql'] as int?,
  );

  final int firstKeyPage;
  final int lastKeyPage;
  final int? firstQuestionPage;
  final int? lastQuestionPage;

  bool get hasQuestionRange =>
      firstQuestionPage != null && lastQuestionPage != null;

  Map<String, dynamic> toJson() => {
    'kf': firstKeyPage,
    'kl': lastKeyPage,
    'qf': ?firstQuestionPage,
    'ql': ?lastQuestionPage,
  };

  @override
  bool operator ==(Object other) =>
      other is KeyBlockOverride &&
      other.firstKeyPage == firstKeyPage &&
      other.lastKeyPage == lastKeyPage &&
      other.firstQuestionPage == firstQuestionPage &&
      other.lastQuestionPage == lastQuestionPage;

  @override
  int get hashCode => Object.hash(
    firstKeyPage,
    lastKeyPage,
    firstQuestionPage,
    lastQuestionPage,
  );
}

/// The user's decision which pages hold the answer key (Phase 2 UI). The
/// pages are the indices of the note's pages.
///
/// With only [keyPages], the key is read from those pages whatever they look
/// like (short keys and keys with explanations included) and split into
/// blocks where the numbering restarts. With [blocks], each block names its
/// key pages and, when given, the question pages of its test; tests are then
/// formed from those ranges instead of numbering restarts.
class KeyOverride {
  const new(this.keyPages, {this.blocks = const []});

  factory fromBlocks(List<KeyBlockOverride> blocks) => KeyOverride({
    for (final b in blocks)
      for (var p = b.firstKeyPage; p <= b.lastKeyPage; p++) p,
  }, blocks: blocks);

  factory fromJson(Map<String, dynamic> json) {
    final blocks = [
      for (final b in (json['blocks'] as List? ?? const []))
        KeyBlockOverride.fromJson(b as Map<String, dynamic>),
    ];
    final pages = {
      for (final p in (json['pages'] as List? ?? const [])) p as int,
    };
    return blocks.isEmpty ? KeyOverride(pages) : KeyOverride.fromBlocks(blocks);
  }

  final Set<int> keyPages;
  final List<KeyBlockOverride> blocks;

  /// The same decision with every page index passed through [f]. Pages that
  /// [f] cannot map are dropped (a block whose key pages cannot be mapped is
  /// dropped; an unmappable question range becomes "automatic"). Null if
  /// nothing is left.
  KeyOverride? mapPages(int? Function(int) f) {
    if (blocks.isEmpty) {
      final pages = {
        for (final p in keyPages)
          if (f(p) case final int q) q,
      };
      return pages.isEmpty ? null : KeyOverride(pages);
    }
    final mapped = <KeyBlockOverride>[];
    for (final b in blocks) {
      final kf = f(b.firstKeyPage), kl = f(b.lastKeyPage);
      if (kf == null || kl == null) continue;
      final qf = b.firstQuestionPage == null ? null : f(b.firstQuestionPage!);
      final ql = b.lastQuestionPage == null ? null : f(b.lastQuestionPage!);
      mapped.add(
        KeyBlockOverride(
          firstKeyPage: kf,
          lastKeyPage: kl,
          firstQuestionPage: qf != null && ql != null ? qf : null,
          lastQuestionPage: qf != null && ql != null ? ql : null,
        ),
      );
    }
    return mapped.isEmpty ? null : KeyOverride.fromBlocks(mapped);
  }

  Map<String, dynamic> toJson() => {
    'pages': (keyPages.toList()..sort()),
    if (blocks.isNotEmpty) 'blocks': [for (final b in blocks) b.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is KeyOverride &&
      other.keyPages.length == keyPages.length &&
      other.keyPages.containsAll(keyPages) &&
      _listEq(other.blocks, blocks);

  @override
  int get hashCode => Object.hash(
    Object.hashAll((keyPages.toList()..sort())),
    Object.hashAll(blocks),
  );

  static bool _listEq(List<KeyBlockOverride> a, List<KeyBlockOverride> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
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
  /// With [lenient] (the user said this is a key page) only the entry at the
  /// start of a line counts when the line also holds other text, so keys with
  /// explanations parse and prose does not add entries.
  static KeyPageStats analyze(
    int pageIndex,
    PageText text, {
    bool lenient = false,
  }) {
    final entries = <KeyEntry>[];
    var matched = 0, total = 0;
    for (final line in text.lines) {
      final lineText = line.text;
      // Offsets of each token in lineText, to place entries on the page.
      final starts = <int>[];
      var offset = 0;
      for (final t in line.tokens) {
        starts.add(offset);
        offset += t.text.length + 1;
      }
      final lineCoverage = KeyParser.coverage(lineText);
      final pureLine = lineCoverage.matched == lineCoverage.total;
      for (final m in KeyParser.entryPattern.allMatches(lineText)) {
        if (lenient && !pureLine && m.start != 0) continue;
        Rect? rect;
        for (var i = 0; i < line.tokens.length; i++) {
          final end = starts[i] + line.tokens[i].text.length;
          if (starts[i] < m.end && m.start < end) {
            final r = line.tokens[i].rect;
            rect = rect == null ? r : rect.expandToInclude(r);
          }
        }
        entries.add(
          KeyEntry(
            number: int.parse(m.group(1)!),
            letter: m.group(2)!.toUpperCase(),
            pageIndex: pageIndex,
            rect: rect,
          ),
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
    if (override != null && override.blocks.isNotEmpty) {
      return _explicit(indices, pages, override);
    }
    final stats = [
      for (final i in indices)
        analyze(i, pages[i]!, lenient: override?.keyPages.contains(i) ?? false),
    ];
    final keyStats = [
      for (final s in stats)
        if (override != null
            ? override.keyPages.contains(s.pageIndex)
            : s.isKeyPage)
          s,
    ];
    if (keyStats.isEmpty) {
      return override == null
          ? _footerDetection(indices, pages)
          : const KeyDetection.unknown();
    }

    final blocks = _splitBlocks(keyStats);
    if (blocks.isEmpty) return const KeyDetection.unknown();

    final confidence = override != null
        ? 1.0
        : keyStats.map((s) => s.coverage).reduce(min);
    final status = confidence >= GradingConfig.keyAcceptConfidence
        ? KeyStatus.found
        : KeyStatus.unknown;
    return KeyDetection(blocks: blocks, confidence: confidence, status: status);
  }

  /// The key line(s) of a question page: lines in which at least
  /// [GradingConfig.footerKeyLineCoverage] of the tokens are `number letter`
  /// entries (a page number beside the key does not matter), with at least two
  /// entries. Null unless the entries hold a run of
  /// [GradingConfig.keyMinConsecutiveRun] consecutive numbers.
  ///
  /// Also returns [text] without the tokens of those entries, to locate the
  /// questions on: `1. D` must not be read as question 1 with an option D.
  static ({List<KeyEntry> entries, PageText stripped})? footerKey(
    int pageIndex,
    PageText text,
  ) {
    final entries = <KeyEntry>[];
    final removed = <TextToken>{};
    for (final line in text.lines) {
      final lineText = line.text;
      final matches = KeyParser.entryPattern.allMatches(lineText).toList();
      if (matches.length < 2) continue;
      final c = KeyParser.coverage(lineText);
      if (c.matched < GradingConfig.footerKeyLineCoverage * c.total) continue;
      var offset = 0;
      final spans = <(TextToken, int, int)>[];
      for (final t in line.tokens) {
        spans.add((t, offset, offset + t.text.length));
        offset += t.text.length + 1;
      }
      for (final m in matches) {
        Rect? rect;
        for (final (token, start, end) in spans) {
          if (start < m.end && m.start < end) {
            removed.add(token);
            rect = rect == null ? token.rect : rect.expandToInclude(token.rect);
          }
        }
        entries.add(
          KeyEntry(
            number: int.parse(m.group(1)!),
            letter: m.group(2)!.toUpperCase(),
            pageIndex: pageIndex,
            rect: rect,
          ),
        );
      }
    }
    final numbers = {for (final e in entries) e.number};
    var longest = 0, run = 0;
    for (final n in (numbers.toList()..sort())) {
      run = numbers.contains(n - 1) ? run + 1 : 1;
      longest = max(longest, run);
    }
    if (longest < GradingConfig.keyMinConsecutiveRun) return null;
    return (entries: entries, stripped: _without(text, removed));
  }

  /// [text] without [removed] tokens (of its own token list).
  static PageText _without(PageText text, Set<TextToken> removed) {
    final buffer = StringBuffer();
    final rects = <Rect>[];
    for (final t in text.tokens) {
      if (removed.contains(t)) continue;
      buffer.write('${t.text} ');
      rects
        ..addAll(t.charRects)
        ..add(Rect.zero);
    }
    return PageText(
      pageIndex: text.pageIndex,
      pdfSize: text.pdfSize,
      rotation: text.rotation,
      source: text.source,
      fullText: buffer.toString(),
      charRects: rects,
    );
  }

  /// Key lines on question pages, one block per page (and per restart of the
  /// numbering on it), when no page is a key page of its own.
  static KeyDetection _footerDetection(
    List<int> indices,
    Map<int, PageText> pages,
  ) {
    final blocks = <KeyBlock>[];
    for (final i in indices) {
      final footer = footerKey(i, pages[i]!);
      if (footer == null) continue;
      var answers = <int, String>{};
      void flush() {
        if (answers.isEmpty) return;
        blocks.add(
          KeyBlock(
            firstKeyPage: i,
            lastKeyPage: i,
            answers: answers,
            samePage: true,
          ),
        );
        answers = {};
      }

      for (final e in footer.entries) {
        if (answers.containsKey(e.number)) flush();
        answers[e.number] = e.letter;
      }
      flush();
    }
    if (blocks.isEmpty) return const KeyDetection.unknown();
    return KeyDetection(blocks: blocks, confidence: 1, status: KeyStatus.found);
  }

  /// Walks the entries in reading order; a new block starts when the pages
  /// are not consecutive or a number repeats (numbering restarted).
  static List<KeyBlock> _splitBlocks(List<KeyPageStats> keyStats) {
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
    return blocks;
  }

  /// The user defined the blocks: read each block's answers from its pages.
  /// Blocks that name the same key pages (several tests on one key page) each
  /// take one of the restarting sub-blocks there, in order.
  static KeyDetection _explicit(
    List<int> indices,
    Map<int, PageText> pages,
    KeyOverride override,
  ) {
    final wanted = override.keyPages;
    final stats = [
      for (final i in indices)
        if (wanted.contains(i)) analyze(i, pages[i]!, lenient: true),
    ];
    final sub = _splitBlocks(stats);
    final blocks = <KeyBlock>[];
    for (final o in override.blocks) {
      final sharing = [
        for (var j = 0; j < override.blocks.length; j++)
          if (override.blocks[j].firstKeyPage == o.firstKeyPage &&
              override.blocks[j].lastKeyPage == o.lastKeyPage)
            j,
      ];
      final inRange = [
        for (final b in sub)
          if (b.firstKeyPage >= o.firstKeyPage &&
              b.firstKeyPage <= o.lastKeyPage)
            b,
      ];
      final rank = sharing.indexOf(override.blocks.indexOf(o));
      final mine = sharing.length > 1 && inRange.length == sharing.length
          ? [inRange[rank]]
          : inRange;
      final answers = <int, String>{};
      for (final b in mine) {
        for (final e in b.answers.entries) {
          answers.putIfAbsent(e.key, () => e.value);
        }
      }
      var block = KeyBlock(
        firstKeyPage: o.firstKeyPage,
        lastKeyPage: o.lastKeyPage,
        answers: answers,
      );
      if (o.hasQuestionRange) {
        block = block.withQuestionPages(
          o.firstQuestionPage!,
          o.lastQuestionPage!,
        );
      }
      blocks.add(block);
    }
    final ok = blocks.every((b) => b.answers.isNotEmpty);
    return KeyDetection(
      blocks: blocks,
      confidence: ok ? 1.0 : 0.0,
      status: ok ? KeyStatus.found : KeyStatus.unknown,
    );
  }
}
