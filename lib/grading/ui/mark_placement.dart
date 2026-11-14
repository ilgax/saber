import 'dart:math';
import 'dart:ui';

/// Size of a mark relative to the page width (1000 note units: 34 units).
const markSizeFraction = 0.034;

/// Where to draw the mark of a question, in note-page coordinates.
///
/// The mark sits in the left margin beside the question number: its right
/// edge a small gap left of [anchor] (the question number's rect), centred on
/// the number vertically. It is clamped inside the page; when the number is
/// so close to the left edge that the margin is too narrow, the mark is
/// pushed to the edge and overlaps the number minimally rather than leaving
/// the page.
Rect markRect({required Size pageSize, required Rect anchor}) {
  final size = max(16.0, pageSize.width * markSizeFraction);
  final gap = size * 0.25;
  final maxLeft = max(0.0, pageSize.width - size);
  final maxTop = max(0.0, pageSize.height - size);
  final left = (anchor.left - gap - size).clamp(0.0, maxLeft);
  final top = (anchor.center.dy - size / 2).clamp(0.0, maxTop);
  return Rect.fromLTWH(left, top, size, size);
}
