import 'dart:math';
import 'dart:ui';

import 'package:saber/grading/grading_config.dart';
import 'package:saber/grading/models.dart';

/// Decides which option of a question the ink marks. All coordinates are note
/// page coordinates; questions must already be mapped there. All numbers come
/// from [GradingConfig].
///
/// A stroke's outline is a thin loop around the pen path, so a circled option
/// is a ring: nothing here relies on "the path contains the option".
abstract final class InkMatcher {
  /// Reads every question of one page. The result has one entry per question,
  /// in the same order.
  static List<MarkReading> readAll(
    List<Question> questions,
    List<InkStroke> strokes,
  ) {
    final assigned = assign(questions, strokes);
    return [
      for (var i = 0; i < questions.length; i++)
        read(questions[i], assigned[i]),
    ];
  }

  /// Assigns every gradable stroke to at most one question: the one whose
  /// (inflated) region holds most of its outline points, else the nearest
  /// within [GradingConfig.strayDistance]. Returns one list per question.
  static List<List<InkStroke>> assign(
    List<Question> questions,
    List<InkStroke> strokes,
  ) {
    final result = List.generate(questions.length, (_) => <InkStroke>[]);
    if (questions.isEmpty) return result;
    final inflated = [
      for (final q in questions) q.region.inflate(GradingConfig.regionInflate),
    ];
    for (final s in strokes) {
      if (!GradingConfig.gradableTools.contains(s.toolId)) continue;
      if (s.outline.isEmpty) continue;
      var best = -1;
      var bestCount = 0;
      var bestDistance = double.infinity;
      for (var i = 0; i < questions.length; i++) {
        var count = 0;
        for (final p in s.outline) {
          if (inflated[i].contains(p)) count++;
        }
        final d = _distance(s.bounds, questions[i].region);
        if (count > bestCount ||
            (count == bestCount && count > 0 && d < bestDistance)) {
          best = i;
          bestCount = count;
          bestDistance = d;
        }
      }
      if (best < 0) {
        for (var i = 0; i < questions.length; i++) {
          final d = _distance(s.bounds, questions[i].region);
          if (d < bestDistance) {
            best = i;
            bestDistance = d;
          }
        }
        if (bestDistance > GradingConfig.strayDistance) continue;
      }
      result[best].add(s);
    }
    return result;
  }

  /// Reads the answer of [question] from the strokes assigned to it.
  static MarkReading read(Question question, List<InkStroke> strokes) =>
      analyze(question, strokes).reading;

  /// Like [read], plus what each of [strokes] was taken for (parallel to
  /// [strokes]) and the score of every option.
  static ReadDetail analyze(Question question, List<InkStroke> strokes) {
    final kinds = List.filled(strokes.length, InkKind.ignored);
    final inks = <_Prepared>[];
    final indexOf = <_Prepared, int>{};
    for (var i = 0; i < strokes.length; i++) {
      final s = strokes[i];
      if (GradingConfig.gradableTools.contains(s.toolId) &&
          s.outline.isNotEmpty) {
        final p = _Prepared(s);
        inks.add(p);
        indexOf[p] = i;
      }
    }
    if (inks.isEmpty) {
      return ReadDetail(const MarkReading.unanswered(), kinds, const {});
    }

    final marks = {for (final o in question.options) o.letter: 0.0};
    final markKinds = <String, InkKind>{};
    void mark(String letter, double score, InkKind kind) {
      if (score > marks[letter]!) {
        marks[letter] = score;
        markKinds[letter] = kind;
      }
    }

    final crossed = <String>{};
    final diagonals = <String, List<_Prepared>>{};

    for (final ink in inks) {
      final at = indexOf[ink]!;
      if (ink.isLine) {
        if (ink.angle.abs() <= GradingConfig.lineMaxAngleDegrees) {
          kinds[at] = _horizontalLine(ink, question, mark, crossed);
        } else {
          kinds[at] = InkKind.diagonal;
          _diagonalLine(ink, question, diagonals);
        }
        continue;
      }
      final rings = <String, double>{};
      for (final o in question.options) {
        final score = _ringScore(ink, o);
        if (score > 0) rings[o.letter] = score;
      }
      if (rings.isNotEmpty) {
        rings.forEach((l, s) => mark(l, s, InkKind.ring));
        kinds[at] = InkKind.ring;
      } else if (max(ink.bounds.width, ink.bounds.height) <=
          GradingConfig.compactMaxSize) {
        var best = 0.0;
        for (final o in question.options) {
          final score = _compactScore(ink, o);
          // Only a filled bubble scores a full 1.
          mark(o.letter, score, score >= 1 ? InkKind.fill : InkKind.tick);
          best = max(best, score);
        }
        if (best > 0) kinds[at] = best >= 1 ? InkKind.fill : InkKind.tick;
      }
    }
    diagonals.forEach((letter, list) {
      if (_formsCross(list)) {
        crossed.add(letter);
        for (final d in list) {
          kinds[indexOf[d]!] = InkKind.strike;
        }
      }
    });

    final candidates = [
      for (final e in marks.entries)
        if (!crossed.contains(e.key)) e,
    ]..sort((a, b) => b.value.compareTo(a.value));
    MarkReading reading;
    if (candidates.isEmpty ||
        candidates.first.value < GradingConfig.markThreshold) {
      reading = MarkReading.unsure(
        crossed.isEmpty
            ? UnsureReason.noOptionAboveThreshold
            : UnsureReason.crossedOutAmbiguous,
      );
    } else {
      final top = candidates.first.value;
      final second = candidates.length > 1 ? candidates[1].value : 0.0;
      if (top - second < GradingConfig.decisionMargin) {
        reading = const MarkReading.unsure(UnsureReason.twoOptionsClose);
      } else {
        final confidence =
            top >= GradingConfig.highConfidenceScore &&
                top - second >= GradingConfig.highConfidenceMargin
            ? Confidence.high
            : Confidence.medium;
        reading = MarkReading.marked(
          candidates.first.key,
          confidence: confidence,
          kind: markKinds[candidates.first.key],
        );
      }
    }
    return ReadDetail(reading, kinds, marks, crossed: crossed);
  }

  /// Assigns, reads and classifies a whole page in one go.
  static PageInkAnalysis analyzePage(
    List<Question> questions,
    List<InkStroke> strokes,
  ) {
    final assigned = assign(questions, strokes);
    final details = [
      for (var q = 0; q < questions.length; q++)
        analyze(questions[q], assigned[q]),
    ];
    final classes = [
      for (final _ in strokes)
        const StrokeClassification(null, InkKind.ignored),
    ];
    final index = {for (var i = 0; i < strokes.length; i++) strokes[i]: i};
    for (var q = 0; q < questions.length; q++) {
      for (var i = 0; i < assigned[q].length; i++) {
        classes[index[assigned[q][i]]!] = StrokeClassification(
          q,
          details[q].kinds[i],
        );
      }
    }
    return PageInkAnalysis(assigned, details, classes);
  }

  /// What every stroke of a page was taken for, for diagnostics: which
  /// question it was assigned to (null if none) and its [InkKind]. Parallel
  /// to [strokes].
  static List<StrokeClassification> classify(
    List<Question> questions,
    List<InkStroke> strokes,
  ) => analyzePage(questions, strokes).classes;

  // ---------------------------------------------------------------- lines

  /// A roughly horizontal straight stroke: a strike-through when it runs
  /// through the middle of an option's text, an underline below it.
  static InkKind _horizontalLine(
    _Prepared ink,
    Question q,
    void Function(String, double, InkKind) mark,
    Set<String> crossed,
  ) {
    var kind = InkKind.ignored;
    for (final o in q.options) {
      final box = o.box;
      final overlap =
          min(ink.bounds.right, box.right) - max(ink.bounds.left, box.left);
      if (overlap <= 0) continue;
      final t = (ink.bounds.center.dy - box.top) / box.height;
      if (t >= GradingConfig.strikeBandTop &&
          t <= GradingConfig.strikeBandBottom) {
        if (overlap / box.width >= GradingConfig.strikeMinCoverage) {
          crossed.add(o.letter);
          kind = InkKind.strike;
        }
      } else if (t > GradingConfig.strikeBandBottom &&
          t <= GradingConfig.underlineBandBottom) {
        if (overlap / min(box.width, ink.bounds.width) >=
            GradingConfig.strikeMinCoverage) {
          mark(o.letter, GradingConfig.underlineScore, InkKind.underline);
          if (kind != InkKind.strike) kind = InkKind.underline;
        }
      }
    }
    return kind;
  }

  /// A steep straight stroke: remembered per option, two crossing ones make
  /// an X.
  static void _diagonalLine(
    _Prepared ink,
    Question q,
    Map<String, List<_Prepared>> diagonals,
  ) {
    for (final o in q.options) {
      final box = o.box.inflate(GradingConfig.labelInflate);
      if (box.contains(ink.bounds.center) &&
          ink.bounds.height >=
              GradingConfig.crossMinHeightFraction * o.box.height) {
        diagonals.putIfAbsent(o.letter, () => []).add(ink);
      }
    }
  }

  static bool _formsCross(List<_Prepared> lines) {
    for (var i = 0; i < lines.length; i++) {
      for (var j = i + 1; j < lines.length; j++) {
        final a = lines[i], b = lines[j];
        if (a.angle.sign != b.angle.sign &&
            a.bounds.overlaps(b.bounds) &&
            _centerNear(a, b)) {
          return true;
        }
      }
    }
    return false;
  }

  static bool _centerNear(_Prepared a, _Prepared b) {
    final d = (a.bounds.center - b.bounds.center).distance;
    return d <= 0.5 * max(a.length, b.length);
  }

  // ---------------------------------------------------------- ring, mark

  /// How well [ink] surrounds the label of [o]: the fraction of angular
  /// sectors around the label centre that hold stroke points. 0 when the
  /// stroke does not surround the label (or is a filled scribble).
  static double _ringScore(_Prepared ink, Option o) {
    final c = o.labelRect.center;
    if (!ink.bounds.inflate(2).contains(c)) return 0;
    final minR =
        GradingConfig.ringMinRadiusFraction *
        min(o.labelRect.width, o.labelRect.height);
    final sectors = List.filled(GradingConfig.ringSectors, false);
    var inner = 0;
    final label = o.labelRect.inflate(GradingConfig.labelInflate);
    for (final p in ink.points) {
      if (label.contains(p)) inner++;
      final v = p - c;
      if (v.distance < minR) continue;
      final a = (atan2(v.dy, v.dx) + pi) / (2 * pi);
      sectors[(a * GradingConfig.ringSectors).floor() %
              GradingConfig.ringSectors] =
          true;
    }
    final coverage = sectors.where((s) => s).length / GradingConfig.ringSectors;
    if (coverage < GradingConfig.ringMinCoverage) return 0;
    if (inner / ink.points.length > GradingConfig.ringMaxInnerFraction)
      return 0;
    return coverage;
  }

  /// A small stroke on or beside an option: a filled bubble (ink on the
  /// label) scores 1, a tick scores by how close it is and whether it sits on
  /// the option's line.
  static double _compactScore(_Prepared ink, Option o) {
    final label = o.labelRect.inflate(GradingConfig.labelInflate);
    final inner = ink.points.where(label.contains).length / ink.points.length;
    if (inner >= GradingConfig.fillMinFraction) return 1;
    // A dot (pen rest, tap) is not a tick.
    if (max(ink.bounds.width, ink.bounds.height) < GradingConfig.tickMinSize) {
      return 0;
    }
    final band =
        min(ink.bounds.bottom, o.labelRect.bottom) -
        max(ink.bounds.top, o.labelRect.top);
    if (band <= 0) return 0;
    final onLine = (band / o.labelRect.height).clamp(0.0, 1.0);
    // Distance to the label, or 0 when the mark overlaps the option's text.
    final gap = ink.bounds.overlaps(o.box)
        ? 0.0
        : _gapX(ink.bounds, o.labelRect);
    final proximity = gap <= GradingConfig.tickNearDistance
        ? 1.0
        : max(
            0.0,
            1 -
                (gap - GradingConfig.tickNearDistance) /
                    (GradingConfig.tickMaxDistance -
                        GradingConfig.tickNearDistance),
          );
    return GradingConfig.tickScore * onLine * proximity;
  }

  static double _gapX(Rect a, Rect b) =>
      max(0.0, max(b.left - a.right, a.left - b.right));

  static double _distance(Rect a, Rect b) {
    final dx = max(0.0, max(b.left - a.right, a.left - b.right));
    final dy = max(0.0, max(b.top - a.bottom, a.top - b.bottom));
    return sqrt(dx * dx + dy * dy);
  }
}

/// What [InkMatcher.analyze] found.
class ReadDetail {
  const new(this.reading, this.kinds, this.scores, {this.crossed = const {}});

  final MarkReading reading;

  /// What each input stroke was taken for.
  final List<InkKind> kinds;

  /// The mark score (0 to 1) of each option letter.
  final Map<String, double> scores;

  /// Letters of options that were crossed out.
  final Set<String> crossed;
}

/// The result of [InkMatcher.analyzePage].
class PageInkAnalysis {
  const new(this.assigned, this.details, this.classes);

  /// Strokes assigned to each question.
  final List<List<InkStroke>> assigned;

  /// The reading of each question.
  final List<ReadDetail> details;

  /// One per input stroke.
  final List<StrokeClassification> classes;
}

/// Where a stroke went and what it was taken for.
class StrokeClassification {
  const new(this.questionIndex, this.kind);

  /// Index into the page's questions; null when unassigned (stray or not a
  /// gradable tool).
  final int? questionIndex;
  final InkKind kind;
}

/// A stroke with its resampled outline and line statistics.
class _Prepared {
  new(this.stroke) : points = _resample(stroke.outline) {
    final n = points.length;
    var mx = 0.0, my = 0.0;
    for (final p in points) {
      mx += p.dx;
      my += p.dy;
    }
    mx /= n;
    my /= n;
    var sxx = 0.0, syy = 0.0, sxy = 0.0;
    for (final p in points) {
      final dx = p.dx - mx, dy = p.dy - my;
      sxx += dx * dx;
      syy += dy * dy;
      sxy += dx * dy;
    }
    final trace = sxx + syy;
    final det = sxx * syy - sxy * sxy;
    final disc = sqrt(max(0, trace * trace / 4 - det));
    final l1 = trace / 2 + disc, l2 = max(0.0, trace / 2 - disc);
    elongation = l1 <= 0 ? 1 : sqrt(l2 / l1);
    final theta = 0.5 * atan2(2 * sxy, sxx - syy);
    // Angle of the major axis from horizontal in (-90, 90], y pointing down.
    angle = theta * 180 / pi;
    final cosT = cos(theta), sinT = sin(theta);
    var lo = double.infinity, hi = double.negativeInfinity;
    for (final p in points) {
      final u = (p.dx - mx) * cosT + (p.dy - my) * sinT;
      lo = min(lo, u);
      hi = max(hi, u);
    }
    length = hi - lo;
  }

  final InkStroke stroke;
  final List<Offset> points;
  late final double elongation;
  late final double angle;
  late final double length;

  Rect get bounds => stroke.bounds;

  /// Straight enough and long enough to be a strike, underline or diagonal.
  bool get isLine =>
      elongation <= GradingConfig.lineMaxElongation &&
      length >= GradingConfig.lineMinLength;

  /// Densifies a closed polygon so that no edge is longer than the resample
  /// step.
  static List<Offset> _resample(List<Offset> polygon) {
    final out = <Offset>[];
    for (var i = 0; i < polygon.length; i++) {
      final a = polygon[i], b = polygon[(i + 1) % polygon.length];
      final steps = max(
        1,
        ((b - a).distance / GradingConfig.resampleStep).ceil(),
      );
      for (var s = 0; s < steps; s++) {
        out.add(Offset.lerp(a, b, s / steps)!);
      }
    }
    return out;
  }
}
