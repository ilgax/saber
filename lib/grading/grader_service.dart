import 'dart:async';

import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/grading/grade_range.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/ink/coordinate_mapper.dart';
import 'package:saber/grading/ink/pdf_annotations.dart';
import 'package:saber/grading/layout/text_extractor.dart';
import 'package:saber/grading/models.dart';
import 'package:saber/grading/ocr/mlkit_ocr_engine.dart';
import 'package:saber/grading/ocr/ocr_engine.dart';
import 'package:saber/grading/ocr/ocr_store.dart';
import 'package:saber/grading/ocr/page_ocr.dart';
import 'package:saber/grading/sidecar_store.dart';

/// Converts a Saber [Stroke] to the plain geometry the grader works on. The
/// outline polygon and bounds come from the public high quality geometry, so
/// no upstream code needs to change.
InkStroke strokeToInk(Stroke stroke) => InkStroke(
  outline: stroke.highQualityPolygon,
  bounds: stroke.highQualityPath.getBounds(),
  toolId: stroke.toolId,
);

/// Whether a page whose text layer is too thin gets OCR.
enum OcrMode {
  /// Recognize it (or use a cached result).
  run,

  /// Use an already cached result only.
  cached,

  /// Never.
  skip,
}

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
  /// [ocr] defaults to ML Kit (available on Android and iOS only); with
  /// [ocrStore] null OCR results are cached in memory and in the app support
  /// directory.
  new({OcrEngine? ocr, Future<OcrStore?> Function()? ocrStore})
    : _ocr = OcrReader(
        ocr ?? MlKitOcrEngine(),
        store: ocrStore ?? () => OcrStore.appDefault(),
      );

  final _extractor = TextExtractor();
  final OcrReader _ocr;
  final _hashes = <String, Future<String>>{};

  Future<String> _hashOf(PdfEditorImage image, String key) =>
      _hashes.putIfAbsent(key, () {
        final bytes = image.pdfBytes;
        return bytes != null
            ? SidecarStore.hashBytes(bytes)
            : SidecarStore.hashFile(image.pdfFile!.path);
      });

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

  /// The text of [image]'s PDF page, with OCR when the text layer is too thin
  /// and [ocr] says so: [OcrMode.cached] only uses OCR results that are
  /// already cached, [OcrMode.skip] never.
  Future<({PageText text, PdfPage pdfPage, OcrStatus status})?> _readText(
    PdfEditorImage image,
    String documentKey,
    OcrMode ocr,
  ) async {
    final document = await image.assetCache.pdfDocumentCache.load(
      documentKey,
      pdfBytes: image.pdfBytes,
    );
    if (image.pdfPage < 0 || image.pdfPage >= document.pages.length) {
      return null;
    }
    var text = await _extractor.extract(
      document.pages[image.pdfPage],
      documentKey: documentKey,
    );
    // After the extraction the page is loaded (size and rotation are real).
    final pdfPage = document.pages[image.pdfPage];
    var ocrStatus = OcrStatus.notNeeded;
    if (ocr != OcrMode.skip && textLayerNeedsOcr(text)) {
      String? hash;
      try {
        hash = await _hashOf(image, documentKey);
      } catch (_) {
        _hashes.remove(documentKey);
      }
      final read = await _ocr.read(
        pdfPage,
        documentKey: documentKey,
        hash: hash,
        cachedOnly: ocr == OcrMode.cached,
      );
      ocrStatus = read.status;
      text = read.text ?? text;
    }
    return (text: text, pdfPage: pdfPage, status: ocrStatus);
  }

  /// Reads text layer and strokes of the PDF pages of [pages]. Pages
  /// without a PDF background are skipped. The text of every PDF page is
  /// extracted once and reused by later calls on this service.
  ///
  /// With a [range] only the pages in it are graded pages: they get OCR when
  /// their text layer is too thin, their strokes and PDF ink. The other pages
  /// are returned with [GradingPage.inRange] false, with text only (the text
  /// layer, or OCR already cached in memory or on disk, never new OCR), so
  /// the key can still be found there. [ocrPages] (note page indices) are
  /// out-of-range pages that get OCR anyway, e.g. the key pages the user
  /// chose. Yields to the event loop between pages and reports progress as
  /// (done, total) over the graded pages.
  Future<List<GradingPage>> collectPages(
    List<EditorPage> pages, {
    GradeRange? range,
    Set<int> ocrPages = const {},
    void Function(int done, int total)? onProgress,
  }) async {
    final refs = pdfPages(pages);
    final total = refs.where((r) => range?.contains(r.notePage) ?? true).length;
    var done = 0;
    final gradingPages = <GradingPage>[];
    for (final ref in refs) {
      final i = ref.notePage;
      final page = pages[i];
      final image = page.backgroundImage as PdfEditorImage;
      final inRange = range?.contains(i) ?? true;
      final read = await _readText(
        image,
        ref.documentKey,
        inRange
            ? OcrMode.run
            : ocrPages.contains(i)
            ? OcrMode.run
            : OcrMode.cached,
      );
      if (read == null) continue;
      final text = read.text;
      if (!inRange) {
        gradingPages.add(
          GradingPage(
            pageIndex: i,
            text: text,
            noteSize: page.size,
            strokes: const [],
            ocrStatus: read.status,
            inRange: false,
          ),
        );
        continue;
      }
      // Ink drawn into the PDF itself by another app (annotations), graded
      // together with the note's own strokes.
      final mapper = PageMapper(pdfSize: text.pdfSize, noteSize: page.size);
      final pdfInk = [
        for (final a in await readPdfAnnotations(read.pdfPage))
          ...annotationToStrokes(a, mapper),
      ];
      gradingPages.add(
        GradingPage(
          pageIndex: i,
          text: text,
          noteSize: page.size,
          strokes: [for (final s in page.strokes) strokeToInk(s), ...pdfInk],
          ocrStatus: read.status,
        ),
      );
      onProgress?.call(++done, total);
      // Let the UI breathe between pages.
      await Future<void>.delayed(Duration.zero);
    }
    await _ocr.flush();
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
      try {
        final h = await _hashOf(image, key);
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
    GradeRange? range,
  }) async => gradeDocument(
    await collectPages(pages, range: range),
    keyOverride: keyOverride,
  );

  /// Forget the cached page texts (e.g. when a note is closed).
  void clearCache() {
    _extractor.clear();
    _ocr.clear();
    _hashes.clear();
  }
}
