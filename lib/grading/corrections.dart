import 'dart:math';

import 'package:saber/grading/models.dart';

/// Identifies a question within a document: (test index, number).
typedef QuestionId = (int test, int number);

/// A fingerprint of the ink assigned to a question: one entry per stroke, its
/// tool and bounds. Strokes are saved with float32 precision, so signatures
/// are compared with a tolerance, never by exact hash.
class InkSignature {
  const new(this.entries);

  factory of(List<InkStroke> strokes) {
    final entries = [
      for (final s in strokes)
        InkSignatureEntry(
          s.toolId.index,
          s.bounds.left,
          s.bounds.top,
          s.bounds.right,
          s.bounds.bottom,
        ),
    ]..sort();
    return InkSignature(entries);
  }

  factory fromJson(List<dynamic> json) => InkSignature([
    for (final e in json)
      InkSignatureEntry(
        (e as List)[0] as int,
        (e[1] as num).toDouble(),
        (e[2] as num).toDouble(),
        (e[3] as num).toDouble(),
        (e[4] as num).toDouble(),
      ),
  ]);

  /// Sorted by tool, then position.
  final List<InkSignatureEntry> entries;

  List<dynamic> toJson() => [
    for (final e in entries)
      [
        e.tool,
        double.parse(e.left.toStringAsFixed(1)),
        double.parse(e.top.toStringAsFixed(1)),
        double.parse(e.right.toStringAsFixed(1)),
        double.parse(e.bottom.toStringAsFixed(1)),
      ],
  ];

  /// Whether [other] is the same ink: same strokes (count and tools), every
  /// bound within [tolerance] note units.
  bool matches(InkSignature other, {double tolerance = defaultTolerance}) {
    if (entries.length != other.entries.length) return false;
    for (var i = 0; i < entries.length; i++) {
      final a = entries[i], b = other.entries[i];
      if (a.tool != b.tool) return false;
      final d = max(
        max((a.left - b.left).abs(), (a.top - b.top).abs()),
        max((a.right - b.right).abs(), (a.bottom - b.bottom).abs()),
      );
      if (d > tolerance) return false;
    }
    return true;
  }

  /// Float32 storage moves coordinates by well under 0.01 units on a
  /// 1000-unit page; this is far above that and far below a deliberate edit.
  static const defaultTolerance = 1.5;
}

class InkSignatureEntry implements Comparable<InkSignatureEntry> {
  const new(this.tool, this.left, this.top, this.right, this.bottom);

  final int tool;
  final double left, top, right, bottom;

  @override
  int compareTo(InkSignatureEntry other) {
    for (final c in [
      tool.compareTo(other.tool),
      left.compareTo(other.left),
      top.compareTo(other.top),
      right.compareTo(other.right),
      bottom.compareTo(other.bottom),
    ]) {
      if (c != 0) return c;
    }
    return 0;
  }
}

/// The user's decision that a question was answered with [letter], valid for
/// the ink that [signature] describes (one attempt), not for the PDF in
/// general.
class Correction {
  const new({
    required this.testIndex,
    required this.number,
    required this.letter,
    required this.signature,
  });

  factory fromJson(Map<String, dynamic> json) => Correction(
    testIndex: json['t'] as int,
    number: json['n'] as int,
    letter: json['l'] as String,
    signature: InkSignature.fromJson(json['s'] as List<dynamic>),
  );

  final int testIndex;
  final int number;
  final String letter;
  final InkSignature signature;

  QuestionId get id => (testIndex, number);

  Map<String, dynamic> toJson() => {
    't': testIndex,
    'n': number,
    'l': letter,
    's': signature.toJson(),
  };
}
