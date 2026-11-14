// A fake OCR engine for the tests: it "recognizes" the words a test gives it,
// placed on the image the way the real page would be.
import 'dart:ui';

import 'package:saber/grading/ocr/ocr_engine.dart';

import 'flexcil_fixtures.dart';

class FakeOcrEngine implements OcrEngine {
  new(
    this.pages, {
    this.available = true,
    this.symbols = true,
    this.pageWidth = 612,
    this.error,
  });

  /// The words of call 0, call 1, ... (points from the page's top-left).
  final List<List<FxWord>> pages;
  final bool available;

  /// Report a box per character as ML Kit does; otherwise words only.
  final bool symbols;
  final double pageWidth;

  /// Thrown by [recognize] instead of a result.
  final Object? error;

  final images = <OcrImage>[];

  int get calls => images.length;

  @override
  bool get isAvailable => available;

  @override
  Future<OcrPage> recognize(OcrImage image) async {
    final call = images.length;
    images.add(image);
    if (error != null) throw error!;
    final s = image.width / pageWidth;
    Rect px(Rect r) =>
        Rect.fromLTRB(r.left * s, r.top * s, r.right * s, r.bottom * s);
    return OcrPage(
      width: image.width,
      height: image.height,
      words: [
        for (final w in pages[call < pages.length ? call : pages.length - 1])
          OcrWord(
            w.text,
            px(w.box),
            symbols: !symbols
                ? const []
                : [
                    for (var i = 0; i < w.text.length; i++)
                      OcrSymbol(
                        w.text[i],
                        px(
                          Rect.fromLTRB(
                            w.box.left + w.box.width * i / w.text.length,
                            w.box.top,
                            w.box.left + w.box.width * (i + 1) / w.text.length,
                            w.box.bottom,
                          ),
                        ),
                      ),
                  ],
          ),
      ],
    );
  }
}
