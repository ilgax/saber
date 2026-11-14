// Hand-written PDFs: the `pdf` package cannot write /CA (opacity) or the other
// annotation entries a real export has, and cannot make a page whose text
// layer holds only a watermark.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'pdf_fixtures.dart';

/// An annotation, in PDF user space of the unrotated page (points, origin
/// bottom-left, y up).
class RawAnnot {
  const new ink(this.paths, {this.opacity = 1, this.width = 2, this.flags = 4})
    : subtype = 'Ink',
      rect = null,
      line = null;

  const new shape(
    this.subtype,
    Rect this.rect, {
    this.opacity = 1,
    this.width = 2,
    this.flags = 4,
  }) : paths = const [],
       line = null;

  /// A Line, or with [closed] a Polygon / without a PolyLine, through [points].
  const new poly(
    this.subtype,
    List<Offset> points, {
    this.opacity = 1,
    this.width = 2,
    this.flags = 4,
  }) : paths = const [],
       rect = null,
       line = points;

  final String subtype;
  final List<List<Offset>> paths;
  final Rect? rect;
  final List<Offset>? line;
  final double opacity;
  final double width;
  final int flags;

  String _nums(Iterable<Offset> pts) =>
      pts.map((p) => '${p.dx} ${p.dy}').join(' ');

  String dict() {
    final all = [for (final p in paths) ...p, ...?line];
    var bounds = rect;
    if (bounds == null && all.isNotEmpty) {
      bounds = Rect.fromPoints(all.first, all.first);
      for (final p in all) {
        bounds = bounds!.expandToInclude(Rect.fromPoints(p, p));
      }
      bounds = bounds!.inflate(width + 1);
    }
    final b = bounds ?? Rect.zero;
    final parts = <String>[
      '/Type /Annot /Subtype /$subtype',
      '/Rect [${b.left} ${b.top} ${b.right} ${b.bottom}]',
      // PDF rects are left bottom right top, with bottom the smaller y; our
      // Rect has top < bottom, so top is the PDF bottom.
      if (paths.isNotEmpty)
        '/InkList [${paths.map((p) => '[${_nums(p)}]').join(' ')}]',
      if (line != null && subtype == 'Line') '/L [${_nums(line!)}]',
      if (line != null && subtype != 'Line') '/Vertices [${_nums(line!)}]',
      '/C [0 0 0] /CA $opacity /F $flags',
      '/Border [0 0 $width] /BS << /W $width /S /S >>',
    ];
    return '<< ${parts.join(' ')} >>';
  }
}

class RawPage {
  const new({
    this.texts = const [],
    this.annots = const [],
    this.rotate = 0,
    this.width = 612,
    this.height = 792,
  });

  /// Text positioned from the top-left of the unrotated page, in points.
  final List<Fx> texts;
  final List<RawAnnot> annots;
  final int rotate;
  final double width, height;
}

String _escape(String s) =>
    s.replaceAll(r'\', r'\\').replaceAll('(', r'\(').replaceAll(')', r'\)');

Uint8List buildRawPdf(List<RawPage> pages) {
  final objects = <int, String>{};
  var next = 1;
  int alloc() => next++;
  final catalog = alloc(), pagesId = alloc(), font = alloc();
  final kids = <int>[];
  for (final page in pages) {
    final pageId = alloc(), contentId = alloc();
    final annotIds = [for (final _ in page.annots) alloc()];
    kids.add(pageId);
    final content = StringBuffer();
    for (final t in page.texts) {
      final y = page.height - t.y - t.size * 0.8;
      content.writeln(
        'BT /F1 ${t.size} Tf 1 0 0 1 ${t.x} $y Tm (${_escape(t.text)}) Tj ET',
      );
    }
    objects[contentId] =
        '<< /Length ${content.length} >>\nstream\n$content\nendstream';
    for (var i = 0; i < page.annots.length; i++) {
      objects[annotIds[i]] = page.annots[i].dict();
    }
    objects[pageId] =
        '<< /Type /Page /Parent $pagesId 0 R '
        '/MediaBox [0 0 ${page.width} ${page.height}] '
        '/Rotate ${page.rotate} /Contents $contentId 0 R '
        '/Resources << /Font << /F1 $font 0 R >> >> '
        '/Annots [${annotIds.map((id) => '$id 0 R').join(' ')}] >>';
  }
  objects[catalog] = '<< /Type /Catalog /Pages $pagesId 0 R >>';
  objects[pagesId] =
      '<< /Type /Pages /Kids [${kids.map((k) => '$k 0 R').join(' ')}] '
      '/Count ${kids.length} >>';
  objects[font] = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>';

  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int, int>{};
  for (var id = 1; id < next; id++) {
    offsets[id] = out.length;
    out.write('$id 0 obj\n${objects[id]}\nendobj\n');
  }
  final xref = out.length;
  out
    ..write('xref\n0 $next\n0000000000 65535 f \n')
    ..writeAll([
      for (var id = 1; id < next; id++)
        '${offsets[id].toString().padLeft(10, '0')} 00000 n \n',
    ])
    ..write(
      'trailer\n<< /Size $next /Root $catalog 0 R >>\nstartxref\n$xref\n%%EOF\n',
    );
  // Everything is ASCII, so string offsets are byte offsets.
  return Uint8List.fromList(latin1.encode(out.toString()));
}

const pageHeight = 792.0;

/// A ring (user space, y up) around the visual-space [label] box.
List<Offset> ringUser(Rect label, {double margin = 6}) {
  final c = label.center;
  final rx = label.width / 2 + margin, ry = label.height / 2 + margin;
  return [
    for (var i = 0; i <= 44; i++)
      Offset(
        c.dx + rx * cos(2 * pi * i / 40),
        pageHeight - (c.dy + ry * sin(2 * pi * i / 40)),
      ),
  ];
}
