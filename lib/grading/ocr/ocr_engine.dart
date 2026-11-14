import 'dart:typed_data';
import 'dart:ui';

/// A recognized symbol (one character, usually) with its box in image pixels.
class OcrSymbol {
  const new(this.text, this.box);

  final String text;
  final Rect box;
}

/// A recognized word with its box in image pixels. [symbols] may be empty
/// (the engine reports words only); the conversion then splits [box] evenly
/// per character.
class OcrWord {
  const new(this.text, this.box, {this.symbols = const []});

  final String text;
  final Rect box;
  final List<OcrSymbol> symbols;
}

/// What an [OcrEngine] found in one image. Coordinates are pixels of the image
/// that was handed in (origin top-left, y down).
class OcrPage {
  const new({required this.width, required this.height, required this.words});

  final int width;
  final int height;
  final List<OcrWord> words;
}

/// A rendered page handed to an [OcrEngine].
class OcrImage {
  const new({required this.png, required this.width, required this.height});

  /// PNG encoded pixels.
  final Uint8List png;
  final int width;
  final int height;
}

/// OCR is not available on this platform or the engine cannot run (plugin
/// missing, engine failed to load). Grading then works on the text layer only.
class OcrUnavailable implements Exception {
  const new([this.reason = '']);

  final String reason;

  @override
  String toString() => 'OcrUnavailable($reason)';
}

/// Recognizes text in a rendered page. The grader's core never depends on a
/// concrete engine: the app uses `MlKitOcrEngine`, tests use fakes.
///
/// PRIVACY: implementations must not log, persist (other than the grading
/// OCR cache) or send the recognized text anywhere.
abstract interface class OcrEngine {
  /// Whether [recognize] can work on this platform. A cheap check; a false
  /// here means OCR is skipped silently.
  bool get isAvailable;

  /// Recognizes the text of [image]. Throws [OcrUnavailable] when the engine
  /// cannot run; any other error is a failure of this one image.
  Future<OcrPage> recognize(OcrImage image);
}

/// What happened with OCR on one page.
enum OcrStatus {
  /// The text layer was enough, OCR was not tried.
  notNeeded,

  /// The page's text is the OCR result.
  used,

  /// The page needed OCR but the engine is not available here.
  unavailable,

  /// The page needed OCR but recognizing it failed.
  failed,
}
