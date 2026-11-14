import 'dart:io';

import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart'
    as mlkit;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:saber/grading/ocr/ocr_engine.dart';

/// On-device OCR with Google ML Kit (Latin script, bundled model: no network
/// and no model download). Only Android and iOS have the plugin; elsewhere
/// [isAvailable] is false.
class MlKitOcrEngine implements OcrEngine {
  new({Future<Directory> Function()? tempDirectory})
    : _tempDirectory = tempDirectory ?? getTemporaryDirectory;

  final Future<Directory> Function() _tempDirectory;
  mlkit.TextRecognizer? _recognizer;

  @override
  bool get isAvailable => Platform.isAndroid || Platform.isIOS;

  @override
  Future<OcrPage> recognize(OcrImage image) async {
    if (!isAvailable) throw const OcrUnavailable('platform');
    final dir = await _tempDirectory();
    // A file is the most reliable way to hand a page to ML Kit; it exists
    // only for the duration of the call.
    final file = File(
      p.join(
        dir.path,
        'grader_ocr_${DateTime.now().microsecondsSinceEpoch}.png',
      ),
    );
    await file.writeAsBytes(image.png, flush: true);
    try {
      final recognizer = _recognizer ??= mlkit.TextRecognizer();
      final text = await recognizer.processImage(
        mlkit.InputImage.fromFilePath(file.path),
      );
      return OcrPage(
        width: image.width,
        height: image.height,
        words: [
          for (final block in text.blocks)
            for (final line in block.lines)
              for (final element in line.elements)
                OcrWord(
                  element.text,
                  element.boundingBox,
                  symbols: [
                    for (final s in element.symbols)
                      OcrSymbol(s.text, s.boundingBox),
                  ],
                ),
        ],
      );
    } on MissingPluginException catch (e) {
      throw OcrUnavailable(e.message ?? 'plugin missing');
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    final r = _recognizer;
    _recognizer = null;
    try {
      await r?.close();
    } catch (_) {}
  }
}
