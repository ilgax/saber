import 'dart:ui';

import 'package:saber/grading/layout/text_extractor.dart';
import 'package:saber/grading/ocr/ocr_engine.dart';

/// Turns an [OcrPage] of a page rendered as a whole (so the image is the
/// page's visual appearance, rotation included) into the normal [PageText].
///
/// Pixels map to PDF visual space (points, origin top-left, y down) by one
/// scale per axis, so no rotation or y-flip is needed here. [rotation] is only
/// recorded. Each word becomes its characters (with a space between words);
/// a character gets its symbol's box when the engine reports symbols for the
/// word and they spell the word, else an even share of the word's box.
PageText ocrToPageText(
  OcrPage ocr, {
  required int pageIndex,
  required Size pdfSize,
  int rotation = 0,
}) {
  if (ocr.width <= 0 || ocr.height <= 0) {
    return PageText.empty(
      pageIndex: pageIndex,
      pdfSize: pdfSize,
      rotation: rotation,
    );
  }
  final sx = pdfSize.width / ocr.width;
  final sy = pdfSize.height / ocr.height;
  Rect toPdf(Rect r) =>
      Rect.fromLTRB(r.left * sx, r.top * sy, r.right * sx, r.bottom * sy);

  final text = StringBuffer();
  final rects = <Rect>[];
  void space() {
    if (text.isEmpty) return;
    text.write(' ');
    rects.add(Rect.zero);
  }

  for (final word in ocr.words) {
    final w = word.text;
    if (w.trim().isEmpty || !word.box.isFinite || word.box.height <= 0) {
      continue;
    }
    space();
    final spelled = word.symbols.map((s) => s.text).join();
    final perSymbol = word.symbols.isNotEmpty && spelled == w;
    if (perSymbol) {
      for (final s in word.symbols) {
        // A symbol longer than one UTF-16 unit shares its box evenly.
        _addChars(text, rects, s.text, toPdf(s.box));
      }
    } else {
      _addChars(text, rects, w, toPdf(word.box));
    }
  }
  return PageText(
    pageIndex: pageIndex,
    pdfSize: pdfSize,
    rotation: rotation,
    source: TextSource.ocr,
    fullText: text.toString(),
    charRects: rects,
  );
}

void _addChars(StringBuffer text, List<Rect> rects, String chars, Rect box) {
  final n = chars.length;
  for (var i = 0; i < n; i++) {
    text.write(chars[i]);
    rects.add(
      Rect.fromLTRB(
        box.left + box.width * i / n,
        box.top,
        box.left + box.width * (i + 1) / n,
        box.bottom,
      ),
    );
  }
}
