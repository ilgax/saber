import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/layout/text_extractor.dart';
import 'package:saber/grading/models.dart';

/// Converts a Saber [Stroke] to the plain geometry the grader works on. The
/// outline polygon and bounds come from the public high quality geometry, so
/// no upstream code needs to change.
InkStroke strokeToInk(Stroke stroke) => InkStroke(
  outline: stroke.highQualityPolygon,
  bounds: stroke.highQualityPath.getBounds(),
  toolId: stroke.toolId,
);

/// Grades a note. This is the only file of the grader that knows about
/// [EditorPage], [PdfEditorImage] and [Stroke]; everything else takes plain
/// data (see [gradeDocument]).
class GraderService {
  final _extractor = TextExtractor();

  /// Grades [pages] (a note's pages). Pages whose background is not a PDF are
  /// skipped. The text of every PDF page is extracted once and reused by later
  /// calls on this service.
  Future<GradeResult> grade(
    List<EditorPage> pages, {
    KeyOverride? keyOverride,
  }) async {
    final gradingPages = <GradingPage>[];
    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      final image = page.backgroundImage;
      if (image is! PdfEditorImage) continue;

      final documentKey = image.pdfFile?.path ?? 'inline_pdf_${image.id}.pdf';
      final document = await image.assetCache.pdfDocumentCache.load(
        documentKey,
        pdfBytes: image.pdfBytes,
      );
      if (image.pdfPage < 0 || image.pdfPage >= document.pages.length) continue;
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
    }
    return gradeDocument(gradingPages, keyOverride: keyOverride);
  }

  /// Forget the cached page texts (e.g. when a note is closed).
  void clearCache() => _extractor.clear();
}
