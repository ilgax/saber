import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' as pw_pdf;
import 'package:saber/grading/ink/coordinate_mapper.dart';

import 'fixtures/pdf_fixtures.dart';

void main() {
  group('PageMapper', () {
    test('same aspect ratio: scale only', () {
      final m = PageMapper(
        pdfSize: const Size(500, 700),
        noteSize: const Size(1000, 1400),
      );
      expect(m.scale, 2);
      expect(m.offset, Offset.zero);
      expect(
        m.rectToNote(const Rect.fromLTRB(10, 20, 30, 50)),
        const Rect.fromLTRB(20, 40, 60, 100),
      );
    });

    test('different aspect ratio: contain and centre', () {
      // Note page is wider than the PDF: scale by height, centre in x.
      final wide = PageMapper(
        pdfSize: const Size(100, 200),
        noteSize: const Size(1000, 1000),
      );
      expect(wide.scale, 5);
      expect(wide.offset, const Offset(250, 0));
      expect(wide.visualToNote(const Offset(10, 20)), const Offset(300, 100));
      // Note page is taller: scale by width, centre in y.
      final tall = PageMapper(
        pdfSize: const Size(200, 100),
        noteSize: const Size(1000, 1000),
      );
      expect(tall.scale, 5);
      expect(tall.offset, const Offset(0, 250));
      expect(tall.visualToNote(const Offset(10, 20)), const Offset(50, 350));
    });

    test('note to visual is the inverse', () {
      final m = PageMapper(
        pdfSize: const Size(300, 500),
        noteSize: const Size(1000, 1000),
      );
      const r = Rect.fromLTRB(12, 34, 56, 78);
      final back = m.rectToVisual(m.rectToNote(r));
      expect(back.left, closeTo(r.left, 1e-9));
      expect(back.bottom, closeTo(r.bottom, 1e-9));
    });
  });

  group('pdfRectToVisual', () {
    test('rotation 0 flips y', () {
      final r = pdfRectToVisual(
        left: 10,
        top: 780,
        right: 30,
        bottom: 760,
        pageWidth: 600,
        pageHeight: 800,
        rotation: 0,
      );
      expect(r, const Rect.fromLTRB(10, 20, 30, 40));
    });

    test('quarter turns keep the rect inside the visual page', () {
      for (final rotation in [1, 2, 3]) {
        final odd = rotation.isOdd;
        // Unrotated page is 600 x 800; visual size swaps for odd rotations.
        final r = pdfRectToVisual(
          left: 10,
          top: 780,
          right: 30,
          bottom: 760,
          pageWidth: odd ? 800 : 600,
          pageHeight: odd ? 600 : 800,
          rotation: rotation,
        );
        expect(r.width, 20 * (odd ? 1 : 1));
        expect(r.left, greaterThanOrEqualTo(0));
        expect(r.top, greaterThanOrEqualTo(0));
        expect(r.right, lessThanOrEqualTo(odd ? 800 : 600));
        expect(r.bottom, lessThanOrEqualTo(odd ? 600 : 800));
      }
    });

    test('corner moves as the page turns clockwise', () {
      // A point near the bottom-left of the unrotated page ends up at the
      // top-left after 90 degrees clockwise, the top-right after 180.
      Rect at(int rotation) => pdfRectToVisual(
        left: 10,
        top: 30,
        right: 30,
        bottom: 10,
        pageWidth: rotation.isOdd ? 800 : 600,
        pageHeight: rotation.isOdd ? 600 : 800,
        rotation: rotation,
      );
      expect(at(0).center.dx, lessThan(100));
      expect(at(0).center.dy, greaterThan(700));
      expect(at(1).center.dx, lessThan(100));
      expect(at(1).center.dy, lessThan(100));
      expect(at(2).center.dx, greaterThan(500));
      expect(at(2).center.dy, lessThan(100));
      expect(at(3).center.dx, greaterThan(700));
      expect(at(3).center.dy, greaterThan(500));
    });
  });

  group('rotated pages against rendered pixels', () {
    for (final rotation in pw_pdf.PdfPageRotation.values) {
      test('${rotation.name}: char rect lands on the glyph', () async {
        final doc = await FxDoc.open([
          FxPage(
            [const Fx('1) What is 2 + 2?', 72, 100), const Fx('B) 4', 90, 160)],
            rotation: rotation,
            upright: false,
          ),
        ]);
        addTearDown(doc.dispose);
        final page = doc.document.pages[0];
        final text = doc.texts[0];
        expect(
          rotation.index.isOdd
              ? page.width > page.height
              : page.width < page.height,
          isTrue,
          reason: 'pdfrx reports the visual (rotated) size',
        );

        // The B in visual space (the text is sideways here).
        final index = text.fullText.indexOf('B'); // the only B on the page
        expect(index, greaterThanOrEqualTo(0));
        final rect = text.charRects[index];

        // Render the page at 2 px per point and check the ink.
        const px = 2.0;
        final image = (await page.render(
          fullWidth: page.width * px,
          fullHeight: page.height * px,
        ))!;
        addTearDown(image.dispose);
        bool dark(int x, int y) {
          if (x < 0 || y < 0 || x >= image.width || y >= image.height) {
            return false;
          }
          final i = (y * image.width + x) * 4;
          return image.pixels[i] + image.pixels[i + 1] + image.pixels[i + 2] <
              384;
        }

        int darkIn(Rect r) {
          var n = 0;
          for (var y = (r.top * px).floor(); y < (r.bottom * px).ceil(); y++) {
            for (
              var x = (r.left * px).floor();
              x < (r.right * px).ceil();
              x++
            ) {
              if (dark(x, y)) n++;
            }
          }
          return n;
        }

        final area = rect.width * rect.height * px * px;
        expect(darkIn(rect) / area, greaterThan(0.1));
        // The rect is tight: just outside it, beside the glyph, is empty.
        final horizontal = rotation.index.isEven;
        final strips = horizontal
            ? [
                Rect.fromLTRB(
                  rect.left,
                  rect.top - 5,
                  rect.right,
                  rect.top - 1,
                ),
                Rect.fromLTRB(
                  rect.left,
                  rect.bottom + 1,
                  rect.right,
                  rect.bottom + 5,
                ),
              ]
            : [
                Rect.fromLTRB(
                  rect.left - 5,
                  rect.top,
                  rect.left - 1,
                  rect.bottom,
                ),
                Rect.fromLTRB(
                  rect.right + 1,
                  rect.top,
                  rect.right + 5,
                  rect.bottom,
                ),
              ];
        for (final strip in strips) {
          expect(darkIn(strip), 0, reason: 'strip $strip');
        }
      });
    }
  });
}
