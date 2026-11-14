// Generates small test PDFs with known layouts for the grader tests.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:pdf/pdf.dart' as pw_pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/ink/coordinate_mapper.dart';
import 'package:saber/grading/layout/question_locator.dart';
import 'package:saber/grading/layout/text_extractor.dart';
import 'package:saber/grading/models.dart';

/// A piece of text at an absolute position (points from the top-left).
class Fx {
  const new(this.text, this.x, this.y, {this.size = 12});

  final String text;
  final double x, y;
  final double size;
}

class FxPage {
  const new(
    this.texts, {
    this.rotation = pw_pdf.PdfPageRotation.none,
    this.upright = true,
  });

  final List<Fx> texts;

  /// The page's /Rotate entry.
  final pw_pdf.PdfPageRotation rotation;

  /// Whether [texts] are positioned in the page as displayed (after
  /// [rotation]), so the text reads upright like in a real rotated PDF. If
  /// false, the text is drawn in the unrotated page and ends up sideways.
  final bool upright;
}

class QSpec {
  const new(this.number, this.stem, this.options);

  final int number;
  final String stem;
  final List<String> options;
}

enum LabelStyle { paren, both, dot }

String label(String letter, LabelStyle style) => switch (style) {
  LabelStyle.paren => '$letter)',
  LabelStyle.both => '($letter)',
  LabelStyle.dot => '$letter.',
};

/// Six questions numbered from [first], four options each.
List<QSpec> questions({int first = 1, int count = 6}) => [
  for (var i = 0; i < count; i++)
    QSpec(first + i, 'What is ${i + 1} + ${i + 2}?', [
      '${2 * i + 2}',
      '${2 * i + 3}',
      '${2 * i + 4}',
      '${2 * i + 5}',
    ]),
];

/// A page of questions. [columns] is 1 or 2; options are stacked, or on one
/// line when [inline].
FxPage questionPage(
  List<QSpec> qs, {
  LabelStyle style = LabelStyle.paren,
  bool inline = false,
  int columns = 1,
  String numberSuffix = ')',
}) {
  final texts = <Fx>[];
  final perColumn = (qs.length / columns).ceil();
  for (var i = 0; i < qs.length; i++) {
    final q = qs[i];
    final col = i ~/ perColumn;
    final x = columns == 1 ? 60.0 : 50.0 + col * 280;
    var y = 70.0 + (i % perColumn) * (inline ? 90 : 120);
    texts.add(Fx('${q.number}$numberSuffix ${q.stem}', x, y));
    y += 24;
    for (var o = 0; o < q.options.length; o++) {
      final letter = String.fromCharCode(65 + o);
      final text = '${label(letter, style)} ${q.options[o]}';
      if (inline) {
        texts.add(Fx(text, x + 30 + o * (columns == 1 ? 100 : 60), y));
      } else {
        texts.add(Fx(text, x + 30, y + o * 18));
      }
    }
  }
  return FxPage(texts);
}

/// A key page with one entry per line, or [perLine] entries per line.
FxPage keyPage(
  List<String> answers, {
  int perLine = 1,
  String Function(int number, String letter)? format,
  List<Fx> extra = const [],
  int firstNumber = 1,
}) {
  String fmt(int n, String l) => (format ?? (n, l) => '$n) $l')(n, l);
  final texts = <Fx>[const Fx('Answer Key', 60, 60), ...extra];
  var y = 90.0;
  for (var i = 0; i < answers.length; i += perLine) {
    final entries = [
      for (var j = i; j < i + perLine && j < answers.length; j++)
        fmt(firstNumber + j, answers[j]),
    ];
    texts.add(Fx(entries.join('    '), 60, y));
    y += 20;
  }
  return FxPage(texts);
}

/// A key page with the given literal lines (e.g. `['1) A', '2) B']`).
FxPage keyPageFromLines(List<String> lines) => FxPage([
  const Fx('Answer Key', 60, 60),
  for (var i = 0; i < lines.length; i++) Fx(lines[i], 60, 90.0 + 20 * i),
]);

/// `1) A`, `2) B`, ... for the letters in [answers], numbered from [first].
List<String> keyLines(String answers, {int first = 1}) => [
  for (var i = 0; i < answers.length; i++) '${first + i}) ${answers[i]}',
];

/// A page of prose that happens to contain numbers and capital letters.
FxPage prosePage() => const FxPage([
  Fx('Chapter 3. Notes about the test', 60, 70),
  Fx('A long time ago, in 1999, a committee met to', 60, 100),
  Fx('decide how tests should be written. B students', 60, 120),
  Fx('were not invited. See table 2. for details.', 60, 140),
]);

/// A numbered list that is not an answer key.
FxPage nonKeyListPage() => const FxPage([
  Fx('Shopping list', 60, 60),
  Fx('1) Apples from the market', 60, 90),
  Fx('2) A loaf of bread and some butter', 60, 110),
  Fx('3) Cheese, preferably aged', 60, 130),
  Fx('4) A bottle of olive oil', 60, 150),
  Fx('5) Bananas and oranges', 60, 170),
  Fx('6) A kilo of rice', 60, 190),
  Fx('7) Eggs', 60, 210),
]);

/// A page without any text (only a drawn rectangle), like a scan.
FxPage blankPage() => const FxPage([]);

const _a4Width = 595.275590551181, _a4Height = 841.8897637795275;

Future<Uint8List> buildPdf(List<FxPage> pages) async {
  final doc = pw.Document();
  for (final page in pages) {
    final quarter = page.rotation.index;
    final turned = page.upright && quarter != 0;
    final landscape = quarter.isOdd && turned;
    final content = pw.SizedBox(
      width: _a4Width,
      height: _a4Height,
      child: pw.Stack(
        children: [
          if (page.texts.isEmpty)
            pw.Positioned(
              left: 100,
              top: 100,
              child: pw.Container(
                width: 200,
                height: 100,
                decoration: pw.BoxDecoration(border: pw.Border.all()),
              ),
            ),
          for (final t in page.texts)
            pw.Positioned(
              left: t.x,
              top: t.y,
              child: pw.Text(t.text, style: pw.TextStyle(fontSize: t.size)),
            ),
        ],
      ),
    );
    // For an upright rotated page, draw the content turned the opposite way
    // so that it reads upright once /Rotate is applied.
    final pw.Widget body = switch (turned ? quarter : 0) {
      1 => pw.Positioned(
        left: 0,
        top: _a4Width,
        child: pw.Transform.rotate(
          angle: pi / 2,
          alignment: pw.Alignment.topLeft,
          child: content,
        ),
      ),
      2 => pw.Transform.rotate(angle: pi, child: content),
      3 => pw.Positioned(
        left: _a4Height,
        top: 0,
        child: pw.Transform.rotate(
          angle: -pi / 2,
          alignment: pw.Alignment.topLeft,
          child: content,
        ),
      ),
      _ => content,
    };
    doc.addPage(
      pw.Page(
        pageFormat: landscape
            ? pw_pdf.PdfPageFormat.a4.landscape
            : pw_pdf.PdfPageFormat.a4,
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Stack(children: [body]),
      ),
    );
  }
  final pdfPages = doc.document.pdfPageList.pages;
  for (var i = 0; i < pages.length; i++) {
    pdfPages[i].rotate = pages[i].rotation;
  }
  return doc.save();
}

var _pdfrxReady = false;

/// Initialises pdfrx for plain `flutter test` (no Flutter bindings needed).
Future<void> initPdfrx() async {
  if (_pdfrxReady) return;
  final tmp = await Directory.systemTemp.createTemp('pdfrx_grading');
  await pdfrxInitialize(tmpPath: tmp.path);
  _pdfrxReady = true;
}

/// A generated PDF opened with pdfrx, with the page text of each page.
class FxDoc {
  new(this.document, this.texts);

  final PdfDocument document;
  final List<PageText> texts;

  static Future<FxDoc> open(
    List<FxPage> pages, {
    String name = 'fx.pdf',
  }) async {
    await initPdfrx();
    final document = await PdfDocument.openData(
      await buildPdf(pages),
      sourceName: name,
    );
    return FxDoc(document, [
      for (final p in document.pages) await extractPageText(p),
    ]);
  }

  /// Overrides [noteSize] (a note page whose aspect ratio differs from the
  /// PDF's).
  Size? forcedNoteSize;

  /// Note page size as the editor makes it when importing the PDF.
  Size noteSize(int page) =>
      forcedNoteSize ??
      Size(
        EditorPage.defaultWidth,
        EditorPage.defaultWidth *
            texts[page].pdfSize.height /
            texts[page].pdfSize.width,
      );

  PageMapper mapper(int page) =>
      PageMapper(pdfSize: texts[page].pdfSize, noteSize: noteSize(page));

  /// The located question [number] of [page], in note coordinates.
  Question question(int page, int number) {
    final q = QuestionLocator.locate(texts[page])
        .singleWhere((q) => q.number == number);
    return q.mapRects(mapper(page).rectToNote);
  }

  Rect optionBox(int page, int number, String letter) =>
      question(page, number).option(letter)!.box;

  Rect labelRect(int page, int number, String letter) =>
      question(page, number).option(letter)!.labelRect;

  List<GradingPage> gradingPages(Map<int, List<InkStroke>> strokes) => [
    for (var i = 0; i < texts.length; i++)
      GradingPage(
        pageIndex: i,
        text: texts[i],
        noteSize: noteSize(i),
        strokes: strokes[i] ?? const [],
      ),
  ];

  void dispose() => document.dispose();
}

/// One line per grade: `t0#2 B/C wrong`, `t0#3 -/A unsure(twoOptionsClose)`.
List<String> summarize(GradeResult result) => [
  for (final g in result.grades)
    't${g.testIndex}#${g.number} ${g.detectedLetter ?? '-'}/${g.keyAnswer ?? '-'} '
        '${g.verdict.name}${g.reason == null ? '' : '(${g.reason!.name})'}',
];
