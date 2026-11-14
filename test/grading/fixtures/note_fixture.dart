// A real EditorCoreInfo whose pages show a generated PDF, for controller and
// widget tests.
import 'dart:typed_data';

import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';

import 'pdf_fixtures.dart';
import 'stroke_fixtures.dart';

class NoteFixture {
  new(this.doc, this.bytes, this.coreInfo);

  final FxDoc doc;
  final Uint8List bytes;
  final EditorCoreInfo coreInfo;

  static Future<NoteFixture> create(
    List<FxPage> pdf, {
    String path = '/n.sbn2',
    Uint8List? sameBytes,
  }) async {
    final doc = await FxDoc.open(pdf);
    final bytes = sameBytes ?? await buildPdf(pdf);
    final coreInfo = EditorCoreInfo(filePath: path);
    for (var i = 0; i < doc.texts.length; i++) {
      coreInfo.pages.add(
        EditorPage(
          size: doc.noteSize(i),
          backgroundImage: PdfEditorImage(
            id: coreInfo.nextImageId++,
            assetCache: coreInfo.assetCache,
            pdfBytes: bytes,
            pdfFile: null,
            pdfPage: i,
            pageIndex: i,
            pageSize: doc.noteSize(i),
            naturalSize: doc.texts[i].pdfSize,
            onMoveImage: null,
            onDeleteImage: null,
            onMiscChange: null,
          ),
        ),
      );
    }
    return NoteFixture(doc, bytes, coreInfo);
  }

  void circle(int page, int q, String letter) => coreInfo.pages[page].strokes
      .add(stroke(circleAround(doc.labelRect(page, q, letter))));

  void dispose() {
    coreInfo.assetCache.dispose();
    doc.dispose();
  }
}
