import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:path_provider/path_provider.dart';
import 'package:saber/grading/ocr/ocr_engine.dart';

/// OCR results on disk, one JSON file per PDF, named by the SHA-256 of the
/// PDF's bytes (`<app support>/grading/ocr/<hash>.json`), so a test is only
/// recognized once. Like the other grading files it is private to the app:
/// never in the notes folder, never shared. Nothing here throws.
class OcrStore {
  new(this.directory);

  static Future<OcrStore> appDefault() async {
    final support = await getApplicationSupportDirectory();
    return OcrStore(Directory('${support.path}/grading/ocr'));
  }

  final Directory directory;

  static const schemaVersion = 1;

  File _file(String hash) => File('${directory.path}/$hash.json');

  /// The stored pages (0-based PDF page index to result); empty if nothing
  /// usable is stored.
  Future<Map<int, OcrPage>> load(String hash) async {
    try {
      final file = _file(hash);
      if (!file.existsSync()) return {};
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map<String, dynamic> || json['v'] != schemaVersion) {
        return {};
      }
      final pages = <int, OcrPage>{};
      (json['pages'] as Map<String, dynamic>? ?? const {}).forEach((k, v) {
        try {
          final index = int.parse(k);
          pages[index] = _decode(v as Map<String, dynamic>);
        } catch (_) {
          // Skip one bad page, keep the rest.
        }
      });
      return pages;
    } catch (_) {
      return {};
    }
  }

  Future<void> save(String hash, Map<int, OcrPage> pages) async {
    try {
      directory.createSync(recursive: true);
      final json = {
        'v': schemaVersion,
        'pages': {for (final e in pages.entries) '${e.key}': _encode(e.value)},
      };
      final tmp = File('${directory.path}/$hash.json.tmp');
      tmp.writeAsStringSync(jsonEncode(json), flush: true);
      tmp.renameSync(_file(hash).path);
    } catch (_) {
      // A failed write only means the page is recognized again next time.
    }
  }

  static List<double> _rect(Rect r) => [
    _round(r.left),
    _round(r.top),
    _round(r.right),
    _round(r.bottom),
  ];

  static double _round(double v) => (v * 10).roundToDouble() / 10;

  static Rect _unrect(List<dynamic> l) => Rect.fromLTRB(
    (l[0] as num).toDouble(),
    (l[1] as num).toDouble(),
    (l[2] as num).toDouble(),
    (l[3] as num).toDouble(),
  );

  static Map<String, dynamic> _encode(OcrPage p) => {
    'w': p.width,
    'h': p.height,
    'words': [
      for (final w in p.words)
        [
          w.text,
          _rect(w.box),
          [
            for (final s in w.symbols) [s.text, _rect(s.box)],
          ],
        ],
    ],
  };

  static OcrPage _decode(Map<String, dynamic> j) => OcrPage(
    width: j['w'] as int,
    height: j['h'] as int,
    words: [
      for (final w in (j['words'] as List))
        OcrWord(
          (w as List)[0] as String,
          _unrect(w[1] as List),
          symbols: [
            for (final s in (w[2] as List))
              OcrSymbol((s as List)[0] as String, _unrect(s[1] as List)),
          ],
        ),
    ],
  );
}
