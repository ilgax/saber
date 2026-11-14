// Phase 0 spike: verifies the pdfrx text API and the PDF -> note-page
// coordinate mapping without a device. See SPIKE.md.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' as pw_pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/data/editor/page.dart';

const _optionLeft = 90.0;
const _optionBTop = 160.0;

Future<Uint8List> _buildTestPdf() async {
  final doc = pw.Document();
  pw.Widget at(double left, double top, String text) => pw.Positioned(
    left: left,
    top: top,
    child: pw.Text(text, style: const pw.TextStyle(fontSize: 14)),
  );
  doc.addPage(
    pw.Page(
      pageFormat: pw_pdf.PdfPageFormat.a4,
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.Stack(
        children: [
          at(72, 100, '1) What is 2 + 2?'),
          at(_optionLeft, 130, 'A) 3'),
          at(_optionLeft, _optionBTop, 'B) 4'),
          at(_optionLeft, 190, 'C) 5'),
        ],
      ),
    ),
  );
  doc.addPage(
    pw.Page(
      pageFormat: pw_pdf.PdfPageFormat.a4,
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.Stack(children: [at(72, 100, '1) B')]),
    ),
  );
  return doc.save();
}

/// Maps a rect in PDF page coordinates (origin bottom-left, points) to
/// note-page coordinates, assuming the PDF is drawn "contain + centered"
/// in [noteSize] (which is how a background [PdfEditorImage] is laid out).
Rect _pdfToNote(PdfRect r, PdfPage page, Size noteSize) {
  final scale = min(noteSize.width / page.width, noteSize.height / page.height);
  final dx = (noteSize.width - page.width * scale) / 2;
  final dy = (noteSize.height - page.height * scale) / 2;
  final rotated = r.rotate(page.rotation.index, page);
  return Rect.fromLTRB(
    dx + rotated.left * scale,
    dy + (page.height - rotated.top) * scale,
    dx + rotated.right * scale,
    dy + (page.height - rotated.bottom) * scale,
  );
}

void main() {
  late PdfDocument document;

  setUpAll(() async {
    final tmp = await Directory.systemTemp.createTemp('pdfrx_spike');
    await pdfrxInitialize(tmpPath: tmp.path);
    document = await PdfDocument.openData(
      await _buildTestPdf(),
      sourceName: 'spike.pdf',
    );
  });
  tearDownAll(() => document.dispose());

  test('loadText returns text and one rect per character', () async {
    final raw = (await document.pages[0].loadText())!;
    printOnFailure(raw.fullText);
    expect(raw.charRects.length, raw.fullText.length);
    expect(raw.fullText, contains('1) What is 2 + 2?'));
    expect(raw.fullText, contains('B) 4'));

    final key = (await document.pages[1].loadText())!;
    expect(key.fullText.trim(), '1) B');
  });

  test('loadStructuredText groups text into fragments with bounds', () async {
    final text = await document.pages[0].loadStructuredText();
    expect(text.fragments, isNotEmpty);
    final joined = text.fragments.map((f) => f.text).join('|');
    printOnFailure(joined);
    expect(joined, contains('B)'));
  });

  test('char rect maps onto the rendered glyph in note coordinates', () async {
    final page = document.pages[0];
    final noteSize = Size(
      EditorPage.defaultWidth,
      EditorPage.defaultWidth * page.height / page.width,
    );
    final raw = (await page.loadText())!;
    final index = raw.fullText.indexOf('B) 4');
    final rect = _pdfToNote(raw.charRects[index], page, noteSize);

    // The glyph was placed at (_optionLeft, _optionBTop) pt from the top-left.
    final scale = noteSize.width / page.width;
    expect(rect.left, closeTo(_optionLeft * scale, 3));
    expect(rect.top, greaterThan(_optionBTop * scale - 2));
    expect(rect.bottom, lessThan((_optionBTop + 18) * scale));

    // Render the page at note resolution and check the ink is in the rect.
    final w = noteSize.width.round(), h = noteSize.height.round();
    final image = (await page.render(fullWidth: w * 1.0, fullHeight: h * 1.0))!;
    final px = image.pixels;
    bool dark(int x, int y) {
      final i = (y * image.width + x) * 4;
      return px[i] + px[i + 1] + px[i + 2] < 384;
    }

    int darkIn(Rect r) {
      var n = 0;
      for (var y = r.top.floor(); y < r.bottom.ceil(); y++) {
        for (var x = r.left.floor(); x < r.right.ceil(); x++) {
          if (dark(x, y)) n++;
        }
      }
      return n;
    }

    final inside = darkIn(rect);
    final above = darkIn(
      Rect.fromLTRB(rect.left, rect.top - 6, rect.right, rect.top - 2),
    );
    final leftOf = darkIn(
      Rect.fromLTRB(rect.left - 8, rect.top, rect.left - 2, rect.bottom),
    );
    image.dispose();
    expect(inside / (rect.width * rect.height), greaterThan(0.15));
    expect(above, 0);
    expect(leftOf, 0);
  });
}
