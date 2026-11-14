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
  static MarkReading read(Question question, List<InkStroke> strokes) {
    final inks = [
      for (final s in strokes)
        if (GradingConfig.gradableTools.contains(s.toolId) &&
            s.outline.isNotEmpty)
          _Prepared(s),
    ];
    if (inks.isEmpty) return const MarkReading.unanswered();

    final marks = {for (final o in question.options) o.letter: 0.0};
    final crossed = <String>{};
    final diagonals = <String, List<_Prepared>>{};

    for (final ink in inks) {
      if (ink.isLine) {
        if (ink.angle.abs() <= GradingConfig.lineMaxAngleDegrees) {
          _horizontalLine(ink, question, marks, crossed);
        } else {
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
        rings.forEach((l, s) => marks[l] = max(marks[l]!, s));
      } else if (max(ink.bounds.width, ink.bounds.height) <=
          GradingConfig.compactMaxSize) {
        for (final o in question.options) {
          marks[o.letter] = max(marks[o.letter]!, _compactScore(ink, o));
        }
      }
    }
    diagonals.forEach((letter, list) {
      if (_formsCross(list)) crossed.add(letter);
    });

    final candidates = [
      for (final e in marks.entries)
        if (!crossed.contains(e.key)) e,
    ]..sort((a, b) => b.value.compareTo(a.value));
    if (candidates.isEmpty ||
        candidates.first.value < GradingConfig.markThreshold) {
      return MarkReading.unsure(
        crossed.isEmpty
            ? UnsureReason.noOptionAboveThreshold
            : UnsureReason.crossedOutAmbiguous,
      );
    }
    final top = candidates.first.value;
    final second = candidates.length > 1 ? candidates[1].value : 0.0;
    if (top - second < GradingConfig.decisionMargin) {
      return const MarkReading.unsure(UnsureReason.twoOptionsClose);
    }
    final confidence =
        top >= GradingConfig.highConfidenceScore &&
            top - second >= GradingConfig.highConfidenceMargin
        ? Confidence.high
        : Confidence.medium;
    return MarkReading.marked(candidates.first.key, confidence: confidence);
  }

  // ---------------------------------------------------------------- lines

  /// A roughly horizontal straight stroke: a strike-through when it runs
  /// through the middle of an option's text, an underline below it.
  static void _horizontalLine(
    _Prepared ink,
    Question q,
    Map<String, double> marks,
    Set<String> crossed,
  ) {
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
        }
      } else if (t > GradingConfig.strikeBandBottom &&
          t <= GradingConfig.underlineBandBottom) {
        if (overlap / min(box.width, ink.bounds.width) >=
            GradingConfig.strikeMinCoverage) {
          marks[o.letter] = max(marks[o.letter]!, GradingConfig.underlineScore);
        }
      }
    }
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
