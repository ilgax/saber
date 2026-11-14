import 'dart:ui';

import 'package:pdfrx/pdfrx.dart';
import 'package:saber/grading/grading_config.dart';
import 'package:saber/grading/ink/coordinate_mapper.dart';

/// A run of characters without a gap, usually a word or a label like `B)`.
class TextToken {
  const new({required this.text, required this.rect, required this.charRects});

  final String text;

  /// In PDF visual space.
  final Rect rect;

  /// One rect per UTF-16 unit of [text].
  final List<Rect> charRects;

  /// Union of the rects of the first [count] characters.
  Rect prefixRect(int count) =>
      charRects.take(count).reduce((a, b) => a.expandToInclude(b));

  @override
  String toString() => 'Token($text)';
}

/// Tokens that share a row, left to right.
class TextLine {
  new(this.tokens)
    : bounds = tokens.map((t) => t.rect).reduce((a, b) => a.expandToInclude(b));

  final List<TextToken> tokens;
  final Rect bounds;

  String get text => tokens.map((t) => t.text).join(' ');

  @override
  String toString() => 'Line($text)';
}

/// The text layer of one PDF page, in PDF visual space (points, top-left
/// origin, y down, page rotation applied).
///
/// Order of [fullText] is whatever PDFium reports; all grading logic works on
/// the geometry ([tokens], [lines]) and never relies on that order.
class PageText {
  new({
    required this.pageIndex,
    required this.pdfSize,
    required this.fullText,
    required this.charRects,
  }) : assert(fullText.length == charRects.length);

  /// A page without a text layer.
  new empty({required this.pageIndex, required this.pdfSize})
    : fullText = '',
      charRects = const [];

  /// Index of the page within its PDF document (0-based).
  final int pageIndex;

  /// Visual page size in points.
  final Size pdfSize;
  final String fullText;

  /// One rect per UTF-16 unit of [fullText].
  final List<Rect> charRects;

  bool get hasText => tokens.isNotEmpty;

  /// All words of the page, in no particular order.
  late final List<TextToken> tokens = buildTokens(fullText, charRects);

  /// Rows of the whole page width, top to bottom.
  late final List<TextLine> lines = buildLines(tokens);
}

/// Groups [items] into rows: items whose vertical extents overlap enough.
/// Rows are returned top to bottom, items in a row left to right.
List<List<T>> _groupRows<T>(List<T> items, Rect Function(T) rectOf) {
  final sorted = [...items]
    ..sort((a, b) => rectOf(a).center.dy.compareTo(rectOf(b).center.dy));
  final rows = <({List<T> items, Rect bounds})>[];
  for (final item in sorted) {
    final r = rectOf(item);
    var placed = false;
    // Only the most recent rows can still match (sorted by centre y).
    for (var i = rows.length - 1; i >= 0 && i >= rows.length - 3; i--) {
      final row = rows[i];
      final overlap =
          (r.bottom < row.bounds.bottom ? r.bottom : row.bounds.bottom) -
          (r.top > row.bounds.top ? r.top : row.bounds.top);
      final smaller = r.height < row.bounds.height
          ? r.height
          : row.bounds.height;
      if (overlap > 0 &&
          overlap >= GradingConfig.rowOverlapFraction * smaller) {
        row.items.add(item);
        rows[i] = (items: row.items, bounds: row.bounds.expandToInclude(r));
        placed = true;
        break;
      }
    }
    if (!placed) rows.add((items: [item], bounds: r));
  }
  return [
    for (final row in rows)
      row.items..sort((a, b) => rectOf(a).left.compareTo(rectOf(b).left)),
  ];
}

/// Builds tokens from characters.
///
/// PDFium reports glyph-tight boxes and gives spaces zero-size boxes at
/// unreliable positions, so space characters are used only as text-order
/// facts: two glyphs with whitespace between them in [fullText] are separate
/// words, however they are laid out. Large gaps also split words (text layers
/// without space characters).
List<TextToken> buildTokens(String fullText, List<Rect> charRects) {
  final chars = <({int index, String ch, Rect rect})>[];
  final breaks = <(int, int)>{};
  int? previousGlyph;
  var sawSpace = false;
  for (var i = 0; i < fullText.length; i++) {
    final rect = charRects[i];
    final ch = fullText[i];
    if (ch.trim().isEmpty) {
      sawSpace = true;
      continue;
    }
    if (!rect.isFinite || rect.height <= 0) continue;
    if (sawSpace && previousGlyph != null) breaks.add((previousGlyph, i));
    chars.add((index: i, ch: ch, rect: rect));
    previousGlyph = i;
    sawSpace = false;
  }
  bool spaced(int a, int b) => breaks.contains(a < b ? (a, b) : (b, a));

  final tokens = <TextToken>[];
  for (final row in _groupRows(chars, (c) => c.rect)) {
    final rowRect = row
        .map((c) => c.rect)
        .reduce((a, b) => a.expandToInclude(b));
    final gap = GradingConfig.tokenGapFraction * rowRect.height;
    var current = <({int index, String ch, Rect rect})>[];
    void flush() {
      if (current.isEmpty) return;
      tokens.add(
        TextToken(
          text: current.map((c) => c.ch).join(),
          rect: current
              .map((c) => c.rect)
              .reduce((a, b) => a.expandToInclude(b)),
          charRects: [for (final c in current) c.rect],
        ),
      );
      current = [];
    }

    for (final c in row) {
      if (current.isNotEmpty) {
        final prev = current.last;
        if (spaced(prev.index, c.index) ||
            c.rect.left - prev.rect.right > gap) {
          flush();
        }
      }
      current.add(c);
    }
    flush();
  }
  return tokens;
}

/// Groups tokens into lines, top to bottom.
List<TextLine> buildLines(List<TextToken> tokens) => [
  for (final row in _groupRows(tokens, (t) => t.rect)) TextLine(row),
];

/// Extracts and caches [PageText] with pdfrx.
class TextExtractor {
  final Map<String, Future<PageText>> _cache = {};

  /// The text of [page]. Extracted once per ([documentKey], [pageIndex]).
  Future<PageText> extract(PdfPage page, {required String documentKey}) {
    return _cache.putIfAbsent(
      '$documentKey#${page.pageNumber}',
      () => extractPageText(page),
    );
  }

  void clear() => _cache.clear();
}

/// Reads the text layer of [page]. A page without text yields empty text.
Future<PageText> extractPageText(PdfPage page) async {
  if (!page.isLoaded) {
    // A progressively loaded document only measures its pages while something
    // (normally a PdfPageView) asks it to; without a view `ensureLoaded` would
    // wait forever. This is safe to call concurrently with such a view.
    final document = page.document;
    await document.loadPagesProgressively(startPageNumber: page.pageNumber);
    page = document.pages[page.pageNumber - 1];
    if (!page.isLoaded) page = await page.ensureLoaded();
  }
  final size = Size(page.width, page.height);
  final pageIndex = page.pageNumber - 1;
  final raw = await page.loadText();
  if (raw == null || raw.fullText.isEmpty) {
    return PageText.empty(pageIndex: pageIndex, pdfSize: size);
  }
  final rotation = page.rotation.index;
  return PageText(
    pageIndex: pageIndex,
    pdfSize: size,
    fullText: raw.fullText,
    charRects: [
      for (final r in raw.charRects)
        pdfRectToVisual(
          left: r.left,
          top: r.top,
          right: r.right,
          bottom: r.bottom,
          pageWidth: page.width,
          pageHeight: page.height,
          rotation: rotation,
        ),
    ],
  );
}
