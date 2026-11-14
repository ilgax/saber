// Builds real Saber strokes for the grader tests.
import 'dart:math';
import 'dart:ui';

import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/grading/grader_service.dart';
import 'package:saber/grading/models.dart';
import 'package:sbn/has_size.dart';
import 'package:sbn/tool_id.dart';

/// A real [Stroke] drawn through [points] (note coordinates), converted the
/// way the service does it.
InkStroke ink(
  List<Offset> points, {
  ToolId tool = .fountainPen,
  double size = 5,
}) => strokeToInk(stroke(points, tool: tool, size: size));

Stroke stroke(
  List<Offset> points, {
  ToolId tool = .fountainPen,
  double size = 5,
}) {
  final s = Stroke(
    color: Stroke.defaultColor,
    pressureEnabled: false,
    options: StrokeOptions(size: size),
    pageIndex: 0,
    page: const HasSize(Size(1000, 1414)),
    toolId: tool,
  );
  for (final p in points) {
    s.addPoint(p);
  }
  return s;
}

/// Points along the segments of [corners], one every ~[step] units.
List<Offset> polyline(List<Offset> corners, {double step = 2}) {
  final out = <Offset>[];
  for (var i = 0; i + 1 < corners.length; i++) {
    final a = corners[i], b = corners[i + 1];
    final n = max(1, ((b - a).distance / step).ceil());
    for (var k = 0; k < n; k++) {
      out.add(Offset.lerp(a, b, k / n)!);
    }
  }
  out.add(corners.last);
  return out;
}

/// An ellipse around [target], [margin] units away, closed after
/// [turns] turns (1.0 = closed ring; 0.9 = open arc).
List<Offset> circleAround(
  Rect target, {
  double margin = 10,
  double turns = 1.05,
}) {
  final rx = target.width / 2 + margin;
  final ry = target.height / 2 + margin;
  const n = 60;
  return [
    for (var i = 0; i <= n * turns; i++)
      Offset(
        target.center.dx + rx * cos(2 * pi * i / n - pi / 2),
        target.center.dy + ry * sin(2 * pi * i / n - pi / 2),
      ),
  ];
}

/// A check mark beside [label]: to its left, [gap] units away.
List<Offset> tickBeside(Rect label, {double gap = 12}) {
  final right = label.left - gap;
  final h = label.height;
  return polyline([
    Offset(right - 0.7 * h, label.center.dy),
    Offset(right - 0.45 * h, label.center.dy + 0.4 * h),
    Offset(right, label.center.dy - 0.5 * h),
  ]);
}

/// A scribble that fills [target].
List<Offset> scribbleOn(Rect target) {
  final r = target.deflate(2);
  final corners = <Offset>[];
  for (var i = 0; i < 8; i++) {
    corners.add(Offset(i.isEven ? r.left : r.right, r.top + r.height * i / 7));
  }
  return polyline(corners);
}

/// A straight line at fraction [t] of [box]'s height (0.5 = middle of the
/// text, 1.15 = just under the baseline), over [coverage] of its width.
List<Offset> horizontalLine(
  Rect box,
  double t, {
  double coverage = 1,
  double slope = 0,
}) {
  final y = box.top + t * box.height;
  final x0 = box.left - 2;
  final x1 = box.left + box.width * coverage + 2;
  return polyline([Offset(x0, y - slope), Offset(x1, y + slope)]);
}

/// Two crossing diagonals over [box]: returns the two strokes' points.
List<List<Offset>> crossOver(Rect box) => [
  polyline([box.topLeft, box.bottomRight]),
  polyline([box.topRight, box.bottomLeft]),
];
