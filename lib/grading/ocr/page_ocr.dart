import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/grading/grading_config.dart';
import 'package:saber/grading/key/key_page_detector.dart';
import 'package:saber/grading/layout/question_locator.dart';
import 'package:saber/grading/layout/text_extractor.dart';
import 'package:saber/grading/ocr/ocr_engine.dart';
import 'package:saber/grading/ocr/ocr_store.dart';
import 'package:saber/grading/ocr/ocr_text.dart';

/// Whether [text] (a page's text layer) has too little text to be a real
/// page, and OCR should replace it. A page that already yields a key or a
/// question from the text layer never does.
bool textLayerNeedsOcr(PageText text) {
  if (text.source != TextSource.textLayer) return false;
  var chars = 0;
  for (var i = 0; i < text.fullText.length; i++) {
    if (text.fullText[i].trim().isNotEmpty) chars++;
  }
  if (chars >= GradingConfig.ocrMinTextLayerChars) return false;
  if (KeyPageDetector.analyze(text.pageIndex, text).isKeyPage) return false;
  return QuestionLocator.locate(text).isEmpty;
}

/// Renders [page] for OCR: as it looks without annotations (so the user's ink
/// does not pollute the recognition), [GradingConfig.ocrRenderScale] times its
/// size in points, scaled down to at most [GradingConfig.ocrMaxPixels].
Future<OcrImage?> renderForOcr(PdfPage page) async {
  final scale = min(
    GradingConfig.ocrRenderScale,
    sqrt(GradingConfig.ocrMaxPixels / (page.width * page.height)),
  );
  final width = (page.width * scale).round();
  final height = (page.height * scale).round();
  final image = await page.render(
    fullWidth: width.toDouble(),
    fullHeight: height.toDouble(),
    annotationRenderingMode: PdfAnnotationRenderingMode.none,
  );
  if (image == null) return null;
  try {
    final w = image.width, h = image.height;
    // A plain copy: the render's own buffer is native memory.
    final pixels = Uint8List.fromList(image.pixels);
    final png = await Isolate.run(
      () => img.encodePng(
        img.Image.fromBytes(
          width: w,
          height: h,
          bytes: pixels.buffer,
          numChannels: 4,
          order: img.ChannelOrder.bgra,
        ),
        level: 1,
      ),
    );
    return OcrImage(png: png, width: w, height: h);
  } finally {
    image.dispose();
  }
}

/// Recognizes the pages whose text layer is too thin, with an in-memory cache
/// (per document key and page) and an optional on-disk one (per PDF hash).
class OcrReader {
  new(this.engine, {Future<OcrStore?> Function()? store}) : _openStore = store;

  final OcrEngine engine;
  final Future<OcrStore?> Function()? _openStore;

  final _memory = <String, OcrPage>{};
  final _disk = <String, Map<int, OcrPage>>{};
  final _dirty = <String>{};
  OcrStore? _store;
  var _storeTried = false;
  var _engineUnavailable = false;

  Future<OcrStore?> _getStore() async {
    if (_storeTried) return _store;
    _storeTried = true;
    try {
      _store = await _openStore?.call();
    } catch (_) {
      _store = null;
    }
    return _store;
  }

  /// The OCR text of [page], or null (with the reason in the status) when
  /// there is none. [documentKey] keys the in-memory cache, [hash] (the PDF's
  /// SHA-256, when known) the disk cache. With [cachedOnly] nothing is
  /// rendered or recognized: a page without a cached result gives a null text
  /// and [OcrStatus.notNeeded].
  Future<({PageText? text, OcrStatus status})> read(
    PdfPage page, {
    required String documentKey,
    String? hash,
    bool cachedOnly = false,
  }) async {
    if (!cachedOnly && (!engine.isAvailable || _engineUnavailable)) {
      return (text: null, status: OcrStatus.unavailable);
    }
    final key = '$documentKey#${page.pageNumber}';
    final pageIndex = page.pageNumber - 1;
    try {
      var ocr = _memory[key];
      if (ocr == null && hash != null) {
        final store = await _getStore();
        if (store != null) {
          final stored = _disk[hash] ??= await store.load(hash);
          ocr = stored[pageIndex];
        }
      }
      if (ocr == null && cachedOnly) {
        return (text: null, status: OcrStatus.notNeeded);
      }
      if (ocr == null) {
        final image = await renderForOcr(page);
        if (image == null) return (text: null, status: OcrStatus.failed);
        ocr = await engine.recognize(image);
        if (hash != null && _storeTried && _store != null) {
          (_disk[hash] ??= {})[pageIndex] = ocr;
          _dirty.add(hash);
        }
      }
      _memory[key] = ocr;
      final text = ocrToPageText(
        ocr,
        pageIndex: pageIndex,
        pdfSize: Size(page.width, page.height),
        rotation: page.rotation.index * 90,
      );
      return (text: text, status: OcrStatus.used);
    } on OcrUnavailable {
      _engineUnavailable = true;
      return (text: null, status: OcrStatus.unavailable);
    } catch (_) {
      return (text: null, status: OcrStatus.failed);
    }
  }

  /// Writes the pages recognized since the last flush to disk.
  Future<void> flush() async {
    final store = await _getStore();
    if (store == null) return;
    for (final hash in _dirty.toList()) {
      await store.save(hash, _disk[hash] ?? const {});
    }
    _dirty.clear();
  }

  void clear() {
    _memory.clear();
    _disk.clear();
    _dirty.clear();
  }
}
