import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saber/grading/corrections.dart';
import 'package:saber/grading/grade_range.dart';
import 'package:saber/grading/key/key_page_detector.dart';

/// What is stored for one PDF.
class SidecarData {
  const new({this.keyOverride, this.corrections = const [], this.lastRange});

  /// The user's key page choice, in PDF page indices.
  final KeyOverride? keyOverride;

  /// Corrections, oldest first.
  final List<Correction> corrections;

  /// The range of note pages graded last, in note page indices.
  final GradeRange? lastRange;

  static const empty = SidecarData();
}

/// Small JSON files with the user's grading decisions, one per PDF, named by
/// the SHA-256 of the PDF's bytes. They live in the app support directory
/// (`grading/`), never in or next to the notes folder, so they are not listed
/// by the file browser and not synced.
///
/// Nothing here throws: a missing directory or file, corrupt JSON, a wrong
/// schema version or a failed write behave as "nothing stored".
class SidecarStore {
  new(this.directory);

  /// The store in `<app support>/grading`.
  static Future<SidecarStore> appDefault() async {
    final support = await getApplicationSupportDirectory();
    return SidecarStore(Directory('${support.path}/grading'));
  }

  final Directory directory;

  static const schemaVersion = 1;

  /// At most this many corrections per file; the oldest are dropped.
  static const maxCorrections = 300;

  /// Serialises read-modify-write cycles.
  Future<void> _queue = Future.value();

  File _file(String hash) => File('${directory.path}/$hash.json');

  /// SHA-256 of [bytes], computed off the UI isolate.
  static Future<String> hashBytes(Uint8List bytes) =>
      Isolate.run(() => sha256.convert(bytes).toString());

  /// SHA-256 of the file at [path], read and hashed off the UI isolate.
  static Future<String> hashFile(String path) => Isolate.run(
    () => sha256.convert(File(path).readAsBytesSync()).toString(),
  );

  /// Combines the hashes of several PDFs (in note order) into one id.
  static String combine(List<String> hashes) => hashes.length == 1
      ? hashes.single
      : sha256.convert(utf8.encode(hashes.join(','))).toString();

  Future<SidecarData> load(String hash) async {
    try {
      final file = _file(hash);
      if (!file.existsSync()) return SidecarData.empty;
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map<String, dynamic> || json['v'] != schemaVersion) {
        return SidecarData.empty;
      }
      KeyOverride? key;
      try {
        final k = json['key'];
        if (k is Map<String, dynamic>) key = KeyOverride.fromJson(k);
      } catch (_) {
        key = null;
      }
      final corrections = <Correction>[];
      for (final c in (json['corr'] as List? ?? const [])) {
        try {
          corrections.add(Correction.fromJson(c as Map<String, dynamic>));
        } catch (_) {
          // Skip one bad entry, keep the rest.
        }
      }
      GradeRange? range;
      try {
        final r = json['range'];
        if (r is Map<String, dynamic>) {
          range = GradeRange.fromJson(r);
          if (range.from < 0 || range.to < range.from) range = null;
        }
      } catch (_) {
        range = null;
      }
      return SidecarData(
        keyOverride: key,
        corrections: corrections,
        lastRange: range,
      );
    } catch (_) {
      return SidecarData.empty;
    }
  }

  /// Stores (or with null removes) the key override of [hash].
  Future<void> saveKeyOverride(String hash, KeyOverride? override) => _update(
    hash,
    (d) => SidecarData(
      keyOverride: override,
      corrections: d.corrections,
      lastRange: d.lastRange,
    ),
  );

  /// Stores the range of note pages graded last.
  Future<void> saveLastRange(String hash, GradeRange range) => _update(
    hash,
    (d) => SidecarData(
      keyOverride: d.keyOverride,
      corrections: d.corrections,
      lastRange: range,
    ),
  );

  /// Adds or replaces the correction of its question. Keeps the newest
  /// [maxCorrections].
  Future<void> setCorrection(String hash, Correction correction) =>
      _update(hash, (d) {
        final list = [
          for (final c in d.corrections)
            if (c.id != correction.id) c,
          correction,
        ];
        final start = list.length > maxCorrections
            ? list.length - maxCorrections
            : 0;
        return SidecarData(
          keyOverride: d.keyOverride,
          corrections: list.sublist(start),
          lastRange: d.lastRange,
        );
      });

  Future<void> clearCorrection(String hash, QuestionId id) => _update(
    hash,
    (d) => SidecarData(
      keyOverride: d.keyOverride,
      corrections: [
        for (final c in d.corrections)
          if (c.id != id) c,
      ],
      lastRange: d.lastRange,
    ),
  );

  Future<void> _update(String hash, SidecarData Function(SidecarData) change) {
    final next = _queue.then((_) async {
      try {
        final data = change(await load(hash));
        await _write(hash, data);
      } catch (_) {
        // Never throw into the UI.
      }
    });
    _queue = next;
    return next;
  }

  Future<void> _write(String hash, SidecarData data) async {
    directory.createSync(recursive: true);
    final json = {
      'v': schemaVersion,
      if (data.keyOverride != null) 'key': data.keyOverride!.toJson(),
      'corr': [for (final c in data.corrections) c.toJson()],
      if (data.lastRange != null) 'range': data.lastRange!.toJson(),
    };
    // Write a temp file and rename it, so a crash never leaves half a file.
    final tmp = File('${directory.path}/$hash.json.tmp');
    tmp.writeAsStringSync(jsonEncode(json), flush: true);
    tmp.renameSync(_file(hash).path);
  }
}
