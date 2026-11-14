import 'dart:math';
import 'dart:ui';

import 'package:saber/grading/grading_config.dart';
import 'package:saber/grading/layout/text_extractor.dart';
import 'package:saber/grading/models.dart';

final _numberPattern = RegExp(r'^\(?(\d{1,3})[.)](?!\d)');
final _parenLabel = RegExp(r'^\(([A-E])\)');
final _punctLabel = RegExp(r'^([A-E])[.)]');
final _bareLabel = RegExp(r'^([A-E])$');

class _Label {
  new(this.letter, this.rect, this.line, this.token, this.length);

  final String letter;
  final Rect rect;
  final int line;
  final int token;

  /// Characters of the token that form the label.
  final int length;
}

({String letter, int length})? _matchLabel(String text) {
  var m = _parenLabel.firstMatch(text);
  m ??= _punctLabel.firstMatch(text);
  if (m != null) return (letter: m.group(1)!, length: m.end);
  m = _bareLabel.firstMatch(text);
  if (m != null) return (letter: m.group(1)!, length: 1);
  return null;
}

class _Draft {
  new(this.number, this.numberRect, TextLine first) : lines = [first];

  final int number;
  final Rect numberRect;

  /// The question's lines, the first one holding the number.
  final List<TextLine> lines;
}

/// Finds multiple choice questions in a page's text layer.
abstract final class QuestionLocator {
  /// The questions of [page], column by column, top to bottom. Rects are in
  /// PDF visual space. [Question.testIndex] is 0; the caller splits tests.
  ///
  /// Only questions with at least [GradingConfig.minOptionsPerQuestion]
  /// options (A, B, ... in sequence) are returned; other numbered text is
  /// not a question.
  static List<Question> locate(PageText page) {
    if (!page.hasText) return const [];
    final questions = <Question>[];
    final columns = _splitColumns(page);
    for (final column in columns) {
      for (final draft in _draftQuestions(buildLines(column))) {
        final q = _finish(draft, page.pageIndex);
        if (q != null) questions.add(q);
      }
    }
    return questions;
  }

  /// Splits the page's tokens into columns by clustering where question
  /// numbers start.
  static List<List<TextToken>> _splitColumns(PageText page) {
    final lefts = [
      for (final t in page.tokens)
        if (_numberPattern.hasMatch(t.text)) t.rect.left,
    ]..sort();
    final clusters = <List<double>>[];
    for (final x in lefts) {
      if (clusters.isNotEmpty &&
          x - clusters.last.last <= GradingConfig.columnTolerancePts) {
        clusters.last.add(x);
      } else {
        clusters.add([x]);
      }
    }
    // Merge clusters that are not really separate columns, drop stray ones.
    final minSeparation =
        GradingConfig.columnSeparationFraction * page.pdfSize.width;
    final starts = <double>[];
    final sizes = <int>[];
    for (final c in clusters) {
      if (starts.isNotEmpty && c.first - starts.last < minSeparation) {
        sizes[sizes.length - 1] += c.length;
      } else {
        starts.add(c.first);
        sizes.add(c.length);
      }
    }
    final kept = <double>[
      for (var i = 0; i < starts.length; i++)
        if (sizes[i] >= 2 || i == 0) starts[i],
    ];
    if (kept.length <= 1) return [page.tokens];
    final columns = List.generate(kept.length, (_) => <TextToken>[]);
    for (final t in page.tokens) {
      var k = 0;
      for (var i = 1; i < kept.length; i++) {
        if (t.rect.left >= kept[i] - GradingConfig.columnTolerancePts) k = i;
      }
      columns[k].add(t);
    }
    return columns;
  }

  /// Groups a column's lines under the question number that precedes them.
  static List<_Draft> _draftQuestions(List<TextLine> lines) {
    final drafts = <_Draft>[];
    int? last;
    for (final line in lines) {
      final first = line.tokens.first;
      final m = _numberPattern.firstMatch(first.text);
      if (m != null) {
        final n = int.parse(m.group(1)!);
        if (_acceptNumber(n, last)) {
          last = n;
          drafts.add(_Draft(n, first.prefixRect(m.end), line));
          continue;
        }
      }
      if (drafts.isNotEmpty) drafts.last.lines.add(line);
    }
    return drafts;
  }

  static bool _acceptNumber(int n, int? last) {
    if (n < 1 || n > GradingConfig.maxQuestionNumber) return false;
    if (last == null || n == 1) return true;
    return n > last && n - last <= GradingConfig.maxQuestionNumberSkip;
  }

  static Question? _finish(_Draft draft, int pageIndex) {
    final lines = draft.lines;
    final candidates = <_Label>[];
    for (var li = 1; li < lines.length; li++) {
      final line = lines[li];
      for (var ti = 0; ti < line.tokens.length; ti++) {
        final token = line.tokens[ti];
        final m = _matchLabel(token.text);
        if (m == null) continue;
        if (ti > 0) {
          final gap = token.rect.left - line.tokens[ti - 1].rect.right;
          if (gap <
              GradingConfig.inlineOptionGapFraction * line.bounds.height) {
            continue;
          }
        }
        candidates.add(
          _Label(m.letter, token.prefixRect(m.length), li, ti, m.length),
        );
      }
    }
    final chain = _bestChain(candidates);
    if (chain.length < GradingConfig.minOptionsPerQuestion) return null;

    final chosenLines = {for (final l in chain) l.line};
    final options = <Option>[];
    var region = draft.numberRect.expandToInclude(draft.lines.first.bounds);
    for (var li = 1; li < chain.first.line; li++) {
      region = region.expandToInclude(lines[li].bounds);
    }
    for (var ci = 0; ci < chain.length; ci++) {
      final label = chain[ci];
      final line = lines[label.line];
      // Up to the next chosen label on the same line, else the line's end.
      var end = line.tokens.length;
      for (final other in chain) {
        if (other.line == label.line && other.token > label.token) {
          end = min(end, other.token);
        }
      }
      var box = line.tokens
          .sublist(label.token, end)
          .map((t) => t.rect)
          .reduce((a, b) => a.expandToInclude(b));
      final alone = chain.where((l) => l.line == label.line).length == 1;
      if (alone) {
        // Text of the option that wraps onto the following lines.
        var bottom = line.bounds.bottom;
        for (var li = label.line + 1; li < lines.length; li++) {
          final next = lines[li];
          final isLabelLine =
              chosenLines.contains(li) ||
              _numberPattern.hasMatch(next.tokens.first.text) ||
              _matchLabel(next.tokens.first.text) != null;
          final gap = next.bounds.top - bottom;
          if (isLabelLine ||
              gap >
                  GradingConfig.optionContinuationGapFraction *
                      next.bounds.height) {
            break;
          }
          box = box.expandToInclude(next.bounds);
          bottom = next.bounds.bottom;
        }
      }
      options.add(
        Option(letter: label.letter, labelRect: label.rect, box: box),
      );
      region = region.expandToInclude(box);
    }
    return Question(
      testIndex: 0,
      number: draft.number,
      pageIndex: pageIndex,
      numberRect: draft.numberRect,
      region: region,
      options: options,
    );
  }

  /// The longest sequence A, B, C, ... in reading order; of equally long
  /// ones, the one that starts latest (the real options rather than a stem
  /// line that happens to start with "A").
  static List<_Label> _bestChain(List<_Label> candidates) {
    var best = <_Label>[];
    for (var i = 0; i < candidates.length; i++) {
      if (candidates[i].letter != 'A') continue;
      final chain = [candidates[i]];
      for (var j = i + 1; j < candidates.length; j++) {
        final expected = String.fromCharCode('A'.codeUnitAt(0) + chain.length);
        if (candidates[j].letter == expected) chain.add(candidates[j]);
      }
      if (chain.length >= best.length) best = chain;
    }
    return best;
  }
}
