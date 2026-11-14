// Phase 0 spike: verifies that stroke geometry and the tool used can be read
// through Stroke's public API (no upstream edits). See SPIKE.md.
import 'dart:math';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:sbn/has_size.dart';
import 'package:sbn/tool_id.dart';

Stroke _circle(ToolId toolId, {double size = 5}) {
  final stroke = Stroke(
    color: Stroke.defaultColor,
    pressureEnabled: false,
    options: StrokeOptions(size: size),
    pageIndex: 0,
    page: const HasSize(Size(1000, 1414)),
    toolId: toolId,
  );
  // Circle of radius 20 centred on (200, 300).
  for (var i = 0; i <= 40; i++) {
    final a = 2 * pi * i / 40;
    stroke.addPoint(Offset(200 + 20 * cos(a), 300 + 20 * sin(a)));
  }
  return stroke;
}

void main() {
  test('stroke bounds are readable via the public path', () {
    final stroke = _circle(.fountainPen);
    final bounds = stroke.highQualityPath.getBounds();
    // The path is the stroke's outline, so it is the centreline +- size / 2.
    expect(bounds.center.dx, closeTo(200, 3));
    expect(bounds.center.dy, closeTo(300, 3));
    expect(bounds.width, inInclusiveRange(40, 50));
    expect(bounds.height, inInclusiveRange(40, 50));
    expect(stroke.lowQualityPath.getBounds().overlaps(bounds), isTrue);
    expect(stroke.lowQualityPolygon, isNotEmpty);
  });

  test('the outline path does not contain the centre of a drawn circle', () {
    // i.e. a circled option is a ring, not a filled blob.
    final stroke = _circle(.fountainPen);
    expect(stroke.highQualityPath.contains(const Offset(200, 300)), isFalse);
    expect(stroke.highQualityPath.contains(const Offset(220, 300)), isTrue);
  });

  test('toolId distinguishes pens from the highlighter', () {
    expect(_circle(.highlighter, size: 50).toolId, ToolId.highlighter);
    expect(_circle(.ballpointPen).toolId, ToolId.ballpointPen);
    expect(_circle(.pencil).toolId, ToolId.pencil);
  });
}
