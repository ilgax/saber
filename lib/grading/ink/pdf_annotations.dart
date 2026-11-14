import 'dart:ffi';
import 'dart:math';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium_bindings;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/grading/grading_config.dart';
import 'package:saber/grading/ink/coordinate_mapper.dart';
import 'package:saber/grading/models.dart';
import 'package:sbn/tool_id.dart';

/// A PDF annotation that can be a pen mark, with its geometry in PDF visual
/// space (points, top-left origin, rotation applied).
class PdfInkAnnotation {
  const new({
    required this.subtype,
    required this.paths,
    required this.width,
    required this.opacity,
    this.closed = false,
  });

  /// `Ink`, `Line`, `Polygon`, `PolyLine`, `Circle`, `Square` or `Highlight`.
  final String subtype;

  /// The centre lines (an ink annotation has one per pen stroke).
  final List<List<Offset>> paths;

  /// Line width in points.
  final double width;

  /// The annotation's /CA (1 when absent).
  final double opacity;

  /// Each path is a closed outline (shapes), so the last point joins the
  /// first.
  final bool closed;

  /// Highlighter strokes are not answers: the Highlight subtype and anything
  /// translucent, like Saber's highlighter tool.
  bool get isHighlighter =>
      subtype == 'Highlight' || opacity < GradingConfig.annotationMinOpacity;
}

pdfium_bindings.PDFium? _pdfium;

pdfium_bindings.PDFium get _lib =>
    _pdfium ??= pdfium_bindings.getPdfium(modulePath: Pdfrx.pdfiumModulePath);

/// Reads the pen-like annotations of [page] (/Ink, and Line, Polygon,
/// PolyLine, Circle, Square, Highlight). Never throws: a backend without
/// native handles, a broken page or any native problem yields an empty list.
///
/// SAFETY: PDFium is not thread safe and pdfrx runs all its PDFium calls on
/// one worker isolate. This uses `PdfDocument.useNativeDocumentHandle`
/// (pdfrx_engine 0.9.2, `pdf_document.dart:296-303`, implemented at
/// `native/pdfrx_pdfium.dart:1631`), the documented way to touch PDFium
/// yourself: it keeps the document alive and suspends the worker
/// (`suspendPdfiumWorkerDuringAction`) while the callback runs. The callback
/// below is synchronous, loads and closes its own page and annotation
/// handles, and keeps no native handle after it returns.
Future<List<PdfInkAnnotation>> readPdfAnnotations(PdfPage page) async {
  try {
    return await page.document.useNativeDocumentHandle(
      (handle) => _readNative(handle, page),
    );
  } catch (_) {
    return const [];
  }
}

List<PdfInkAnnotation> _readNative(int documentHandle, PdfPage page) {
  final lib = _lib;
  final document = pdfium_bindings.FPDF_DOCUMENT.fromAddress(documentHandle);
  final pdfPage = lib.FPDF_LoadPage(document, page.pageNumber - 1);
  if (pdfPage == nullptr) return const [];
  try {
    return using((arena) {
      // Same origin shift pdfrx applies to the text of the page.
      final box = arena<pdfium_bindings.FS_RECTF>();
      lib.FPDF_GetPageBoundingBox(pdfPage, box);
      final bbLeft = box.ref.left, bbBottom = box.ref.bottom;
      final rotation = page.rotation.index;

      Offset toVisual(double x, double y) => pdfRectToVisual(
        left: x - bbLeft,
        top: y - bbBottom,
        right: x - bbLeft,
        bottom: y - bbBottom,
        pageWidth: page.width,
        pageHeight: page.height,
        rotation: rotation,
      ).topLeft;

      List<Offset> rectLoop(
        double l,
        double t,
        double r,
        double b,
        bool ellipse,
      ) {
        final a = toVisual(l, t), c = toVisual(r, b);
        final rect = Rect.fromPoints(a, c);
        if (!ellipse) {
          return [
            rect.topLeft,
            rect.topRight,
            rect.bottomRight,
            rect.bottomLeft,
          ];
        }
        const n = 32;
        return [
          for (var i = 0; i < n; i++)
            Offset(
              rect.center.dx + rect.width / 2 * cos(2 * pi * i / n),
              rect.center.dy + rect.height / 2 * sin(2 * pi * i / n),
            ),
        ];
      }

      final key = 'CA'.toNativeUtf8(allocator: arena).cast<Char>();
      final number = arena<Float>();
      final h = arena<Float>(), v = arena<Float>(), w = arena<Float>();
      final rect = arena<pdfium_bindings.FS_RECTF>();
      final result = <PdfInkAnnotation>[];

      final count = lib.FPDFPage_GetAnnotCount(pdfPage);
      for (var i = 0; i < count; i++) {
        final annot = lib.FPDFPage_GetAnnot(pdfPage, i);
        if (annot == nullptr) continue;
        try {
          final flags = lib.FPDFAnnot_GetFlags(annot);
          if (flags &
                  (pdfium_bindings.FPDF_ANNOT_FLAG_HIDDEN |
                      pdfium_bindings.FPDF_ANNOT_FLAG_INVISIBLE |
                      pdfium_bindings.FPDF_ANNOT_FLAG_NOVIEW) !=
              0) {
            continue;
          }
          final subtype = lib.FPDFAnnot_GetSubtype(annot);
          final opacity = lib.FPDFAnnot_GetNumberValue(annot, key, number) != 0
              ? number.value.toDouble().clamp(0.0, 1.0)
              : 1.0;
          var width = GradingConfig.annotationDefaultWidthPts;
          if (lib.FPDFAnnot_GetBorder(annot, h, v, w) != 0 && w.value > 0) {
            width = w.value;
          }
          PdfInkAnnotation make(
            String name,
            List<List<Offset>> paths, {
            bool closed = false,
          }) => PdfInkAnnotation(
            subtype: name,
            paths: paths,
            width: width,
            opacity: opacity,
            closed: closed,
          );

          switch (subtype) {
            case pdfium_bindings.FPDF_ANNOT_INK:
              final paths = <List<Offset>>[];
              final lists = lib.FPDFAnnot_GetInkListCount(annot);
              for (var p = 0; p < lists; p++) {
                final n = lib.FPDFAnnot_GetInkListPath(annot, p, nullptr, 0);
                if (n == 0) continue;
                final buffer = arena<pdfium_bindings.FS_POINTF>(n);
                lib.FPDFAnnot_GetInkListPath(annot, p, buffer, n);
                paths.add([
                  for (var j = 0; j < n; j++)
                    toVisual(buffer[j].x.toDouble(), buffer[j].y.toDouble()),
                ]);
              }
              if (paths.isNotEmpty) result.add(make('Ink', paths));
            case pdfium_bindings.FPDF_ANNOT_POLYGON ||
                pdfium_bindings.FPDF_ANNOT_POLYLINE:
              final n = lib.FPDFAnnot_GetVertices(annot, nullptr, 0);
              if (n < 2) break;
              final buffer = arena<pdfium_bindings.FS_POINTF>(n);
              lib.FPDFAnnot_GetVertices(annot, buffer, n);
              final points = [
                for (var j = 0; j < n; j++)
                  toVisual(buffer[j].x.toDouble(), buffer[j].y.toDouble()),
              ];
              final polygon = subtype == pdfium_bindings.FPDF_ANNOT_POLYGON;
              result.add(
                make(polygon ? 'Polygon' : 'PolyLine', [
                  points,
                ], closed: polygon),
              );
            case pdfium_bindings.FPDF_ANNOT_LINE:
              final a = arena<pdfium_bindings.FS_POINTF>();
              final b = arena<pdfium_bindings.FS_POINTF>();
              if (lib.FPDFAnnot_GetLine(annot, a, b) != 0) {
                result.add(
                  make('Line', [
                    [
                      toVisual(a.ref.x.toDouble(), a.ref.y.toDouble()),
                      toVisual(b.ref.x.toDouble(), b.ref.y.toDouble()),
                    ],
                  ]),
                );
              }
            case pdfium_bindings.FPDF_ANNOT_CIRCLE ||
                pdfium_bindings.FPDF_ANNOT_SQUARE ||
                pdfium_bindings.FPDF_ANNOT_HIGHLIGHT:
              if (lib.FPDFAnnot_GetRect(annot, rect) == 0) break;
              final r = rect.ref;
              final name = switch (subtype) {
                pdfium_bindings.FPDF_ANNOT_CIRCLE => 'Circle',
                pdfium_bindings.FPDF_ANNOT_SQUARE => 'Square',
                _ => 'Highlight',
              };
              result.add(
                make(name, [
                  rectLoop(
                    r.left.toDouble(),
                    r.top.toDouble(),
                    r.right.toDouble(),
                    r.bottom.toDouble(),
                    subtype == pdfium_bindings.FPDF_ANNOT_CIRCLE,
                  ),
                ], closed: true),
              );
          }
        } finally {
          lib.FPDFPage_CloseAnnot(annot);
        }
      }
      return result;
    });
  } finally {
    lib.FPDF_ClosePage(pdfPage);
  }
}

/// Converts [annotation] to strokes in note coordinates, one per path. A
/// stroke's outline is a thin loop around the centre line (as Saber's pen
/// outlines are), at least [GradingConfig.annotationMinOutlineWidth] wide.
List<InkStroke> annotationToStrokes(
  PdfInkAnnotation annotation,
  PageMapper mapper,
) {
  final tool = annotation.isHighlighter
      ? ToolId.highlighter
      : ToolId.ballpointPen;
  final halfWidth =
      max(
        annotation.width * mapper.scale,
        GradingConfig.annotationMinOutlineWidth,
      ) /
      2;
  return [
    for (final path in annotation.paths)
      if (path.isNotEmpty)
        InkStroke(
          outline: thinOutline(
            [for (final p in path) mapper.visualToNote(p)],
            halfWidth,
            closed: annotation.closed,
          ),
          toolId: tool,
          fromPdf: true,
        ),
  ];
}

/// A closed polygon hugging [centreLine]: the line shifted by [halfWidth] to
/// both sides, there and back. A single point becomes a small square.
List<Offset> thinOutline(
  List<Offset> centreLine,
  double halfWidth, {
  bool closed = false,
}) {
  final points = <Offset>[];
  for (final p in centreLine) {
    if (points.isEmpty || (p - points.last).distance > 1e-6) points.add(p);
  }
  if (closed && points.length > 2) points.add(points.first);
  if (points.length == 1) {
    final p = points.single;
    return [
      p + Offset(-halfWidth, -halfWidth),
      p + Offset(halfWidth, -halfWidth),
      p + Offset(halfWidth, halfWidth),
      p + Offset(-halfWidth, halfWidth),
    ];
  }
  final left = <Offset>[], right = <Offset>[];
  for (var i = 0; i < points.length; i++) {
    // Direction at the vertex: the chord of its neighbours.
    final a = points[max(0, i - 1)], b = points[min(points.length - 1, i + 1)];
    final d = b - a;
    final normal = d.distance == 0
        ? Offset.zero
        : Offset(-d.dy, d.dx) / d.distance * halfWidth;
    left.add(points[i] + normal);
    right.add(points[i] - normal);
  }
  return [...left, ...right.reversed];
}
