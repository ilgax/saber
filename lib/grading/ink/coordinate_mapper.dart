import 'dart:math';
import 'dart:ui';

/// Converts a rectangle given the way PDFium/pdfrx reports it (points, origin
/// bottom-left, y up, in the page's unrotated space) to "PDF visual space":
/// points, origin top-left, y down, page rotation applied. This is exactly
/// what pdfrx's `PdfRectExt.toRect(page: page)` computes without scaling.
///
/// [pageWidth] and [pageHeight] are the page size as pdfrx reports it
/// (`PdfPage.width` / `height`), i.e. already rotated. [rotation] is the page
/// rotation in quarter turns clockwise (`PdfPage.rotation.index`).
Rect pdfRectToVisual({
  required double left,
  required double top,
  required double right,
  required double bottom,
  required double pageWidth,
  required double pageHeight,
  required int rotation,
}) {
  final quarter = rotation & 3;
  // Size of the page before rotation.
  final odd = (quarter & 1) == 1;
  final w0 = odd ? pageHeight : pageWidth;
  final h0 = odd ? pageWidth : pageHeight;
  final double l, t, r, b;
  switch (quarter) {
    case 0:
      (l, t, r, b) = (left, top, right, bottom);
    case 1:
      (l, t, r, b) = (bottom, w0 - left, top, w0 - right);
    case 2:
      (l, t, r, b) = (w0 - right, h0 - bottom, w0 - left, h0 - top);
    default:
      (l, t, r, b) = (h0 - top, right, h0 - bottom, left);
  }
  return Rect.fromLTRB(l, pageHeight - t, r, pageHeight - b);
}

/// Maps between PDF visual space and the note page showing it.
///
/// A PDF background is drawn "contain + centred" on the note page (SPIKE.md;
/// `dstRect` and `backgroundFit` are not used by the canvas):
///
/// ```
/// scale = min(noteW / pdfW, noteH / pdfH)
/// x = (noteW - pdfW * scale) / 2 + pdfX * scale
/// y = (noteH - pdfH * scale) / 2 + pdfY * scale        // visual y is top-down
/// ```
class PageMapper {
  new({required this.pdfSize, required this.noteSize});

  /// PDF page size in points (visual, i.e. after rotation).
  final Size pdfSize;
  final Size noteSize;

  late final double scale = min(
    noteSize.width / pdfSize.width,
    noteSize.height / pdfSize.height,
  );

  /// Top-left of the drawn PDF on the note page.
  late final offset = Offset(
    (noteSize.width - pdfSize.width * scale) / 2,
    (noteSize.height - pdfSize.height * scale) / 2,
  );

  Offset visualToNote(Offset p) => offset + p * scale;
  Offset noteToVisual(Offset p) => (p - offset) / scale;

  Rect rectToNote(Rect r) =>
      Rect.fromPoints(visualToNote(r.topLeft), visualToNote(r.bottomRight));
  Rect rectToVisual(Rect r) =>
      Rect.fromPoints(noteToVisual(r.topLeft), noteToVisual(r.bottomRight));
}
