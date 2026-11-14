import 'dart:async';

import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/layout/text_extractor.dart';
import 'package:saber/grading/models.dart';
import 'package:saber/grading/sidecar_store.dart';

/// Converts a Saber [Stroke] to the plain geometry the grader works on. The
/// outline polygon and bounds come from the public high quality geometry, so
/// no upstream code needs to change.
InkStroke strokeToInk(Stroke stroke) => InkStroke(
  outline: stroke.highQualityPolygon,
  bounds: stroke.highQualityPath.getBounds(),
  toolId: stroke.toolId,
);

/// A note page that shows a PDF page: where the PDF is and which page of it.
class PdfPageRef {
  const new({
    required this.notePage,
    required this.pdfPage,
    required this.documentKey,
  });

  /// Index of the note page.
  final int notePage;

  /// 0-based page of the PDF.
  final int pdfPage;

  /// Cache key of the PDF (a path or `inline_pdf_<id>.pdf`).
  final String documentKey;
}

/// Reads a note into plain grading input. This is the only file of the
/// grader that knows about [EditorPage], [PdfEditorImage] and [Stroke];
/// everything else takes plain data (see [gradeDocument]).
class GraderService {
  final _extractor = TextExtractor();
  final _hashes = <String, Future<String>>{};

  /// The pages of [pages] that show a PDF page, in note order.
  static List<PdfPageRef> pdfPages(List<EditorPage> pages) => [
    for (var i = 0; i < pages.length; i++)
      if (pages[i].backgroundImage case final PdfEditorImage image)
        PdfPageRef(
          notePage: i,
          pdfPage: image.pdfPage,
          documentKey: image.pdfFile?.path ?? 'inline_pdf_${image.id}.pdf',
        ),
  ];

  /// Reads text layer and strokes of every PDF page of [pages]. Pages
  /// without a PDF background are skipped. The text of every PDF page is
  /// extracted once and reused by later calls on this service. Yields to the
  /// event loop between pages and reports progress as (done, total).
  Future<List<GradingPage>> collectPages(
    List<EditorPage> pages, {
    void Function(int done, int total)? onProgress,
  }) async {
    final refs = pdfPages(pages);
    final gradingPages = <GradingPage>[];
    for (var n = 0; n < refs.length; n++) {
      final i = refs[n].notePage;
      final page = pages[i];
      final image = page.backgroundImage as PdfEditorImage;
      final documentKey = refs[n].documentKey;
      final document = await image.assetCache.pdfDocumentCache.load(
        documentKey,
        pdfBytes: image.pdfBytes,
      );
      if (image.pdfPage < 0 || image.pdfPage >= document.pages.length) {
        continue;
      }
      final text = await _extractor.extract(
        document.pages[image.pdfPage],
        documentKey: documentKey,
      );
      gradingPages.add(
        GradingPage(
          pageIndex: i,
          text: text,
          noteSize: page.size,
          strokes: [for (final s in page.strokes) strokeToInk(s)],
        ),
      );
      onProgress?.call(n + 1, refs.length);
      // Let the UI breathe between pages.
      await Future<void>.delayed(Duration.zero);
    }
    return gradingPages;
  }

  /// An id of the PDF(s) shown by [pages]: the SHA-256 of the PDF bytes
  /// (the distinct PDFs combined in note order), computed off the UI thread
  /// and cached per document. [single] tells whether all PDF pages come from
  /// one PDF (the same bytes, even if stored once per page). Null id if there
  /// is no PDF page or hashing failed.
  Future<({String? id, bool single})> documentId(List<EditorPage> pages) async {
    final hashes = <String>[];
    final seen = <String>{};
    for (final page in pages) {
      final image = page.backgroundImage;
      if (image is! PdfEditorImage) continue;
      final key = image.pdfFile?.path ?? 'inline_pdf_${image.id}.pdf';
      if (!seen.add(key)) continue;
      final hash = _hashes.putIfAbsent(key, () {
        final bytes = image.pdfBytes;
        return bytes != null
            ? SidecarStore.hashBytes(bytes)
            : SidecarStore.hashFile(image.pdfFile!.path);
      });
      try {
        final h = await hash;
        if (!hashes.contains(h)) hashes.add(h);
      } catch (_) {
        _hashes.remove(key);
        return (id: null, single: false);
      }
    }
    return hashes.isEmpty
        ? (id: null, single: false)
        : (id: SidecarStore.combine(hashes), single: hashes.length == 1);
  }

  /// Grades [pages] (a note's pages) on the calling isolate.
  Future<GradeResult> grade(
    List<EditorPage> pages, {
    KeyOverride? keyOverride,
  }) async =>
      gradeDocument(await collectPages(pages), keyOverride: keyOverride);

  /// Forget the cached page texts (e.g. when a note is closed).
  void clearCache() {
    _extractor.clear();
    _hashes.clear();
  }
}
