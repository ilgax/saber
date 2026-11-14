// A page like the real Turkish test export: a watermark, two columns of three
// questions (number, diagram gap, statement, five options as a grid or one
// inline row), the answer key of the page as a small footer line and the page
// number beside it.
import 'dart:ui';

import 'pdf_fixtures.dart';

const watermark = '@Kuasar Nemesis @YildizlarLigi_2025PDF @M.G.';

/// A word and where it is, in points from the top-left of the page.
typedef FxWord = ({String text, Rect box});

class FlexcilContent {
  new(this.texts, this._labels);

  /// Everything on the page except the watermark, as text fragments.
  final List<Fx> texts;

  /// `'<question><letter>'` (e.g. `3D`) to the label's word.
  final Map<String, Rect> _labels;

  /// The box of the label (`D)`) of question [number]'s option [letter].
  Rect label(int number, String letter) => _labels['$number$letter']!;

  /// The fragments split into words with approximate boxes (0.45 em per
  /// character), what a fake OCR engine reports.
  List<FxWord> words({bool withWatermark = true}) => [
    for (final t in [if (withWatermark) _watermark, ...texts]) ...wordsOf(t),
  ];

  static const _watermark = Fx(watermark, 120, 20, size: 9);

  static List<FxWord> wordsOf(Fx t) {
    final out = <FxWord>[];
    final w = t.size * 0.45;
    var i = 0;
    for (final part in t.text.split(' ')) {
      if (part.isNotEmpty) {
        out.add((
          text: part,
          box: Rect.fromLTWH(t.x + i * w, t.y, part.length * w, t.size),
        ));
      }
      i += part.length + 1;
    }
    return out;
  }
}

/// Question numbers [first] to `first + 5`, answers [key] (six letters).
FlexcilContent flexcilContent(
  String key, {
  int first = 1,
  bool footer = true,
  String? footerOverride,
  bool pageNumber = true,
}) {
  final texts = <Fx>[];
  final labels = <String, Rect>{};
  void option(int number, String letter, String text, double x, double y) {
    final fx = Fx('$letter) $text', x, y);
    texts.add(fx);
    labels['$number$letter'] = Rect.fromLTWH(x, y, 12, 12);
  }

  for (var i = 0; i < 6; i++) {
    final number = first + i;
    final cx = i < 3 ? 40.0 : 330.0;
    final cy = 80.0 + (i % 3) * 220;
    texts
      ..add(Fx('$number.', cx, cy, size: 14))
      ..add(
        Fx(
          'Yukaridaki sekle gore asagidakilerden hangisi dogrudur?',
          cx,
          cy + 110,
          size: 9,
        ),
      );
    final y = cy + 135;
    if (i % 3 == 2) {
      for (var o = 0; o < 5; o++) {
        option(
          number,
          'ABCDE'[o],
          '[${'BDABC'[o]}${'DACEB'[o]}]',
          cx + 10 + o * 52.0,
          y,
        );
      }
    } else {
      option(number, 'A', '|AB| > |AC| > |BC|', cx + 20, y);
      option(number, 'B', '|AB| > |BC| > |AC|', cx + 150, y);
      option(number, 'C', '|AC| > |AB| > |BC|', cx + 20, y + 16);
      option(number, 'D', '|BC| > |AB| > |AC|', cx + 150, y + 16);
      option(number, 'E', '|BC| > |AC| > |AB|', cx + 75, y + 32);
    }
  }
  if (footer) {
    texts.add(
      Fx(
        footerOverride ??
            [for (var i = 0; i < 6; i++) '${first + i}. ${key[i]}'].join('  '),
        40,
        752,
        size: 7,
      ),
    );
  }
  if (pageNumber) texts.add(const Fx('145', 300, 750, size: 10));
  return FlexcilContent(texts, labels);
}

/// A PDF page whose text layer is the content plus the watermark.
FxPage flexcilPage(FlexcilContent c) =>
    FxPage([const Fx(watermark, 120, 20, size: 9), ...c.texts]);
