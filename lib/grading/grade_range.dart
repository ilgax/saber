import 'package:flutter/foundation.dart';
import 'package:saber/grading/models.dart';

/// A range of note pages to grade, as 0-based inclusive page indices.
@immutable
class GradeRange {
  const new(this.from, this.to);

  factory fromJson(Map<String, dynamic> json) =>
      GradeRange(json['from'] as int, json['to'] as int);

  /// Every page of a note with [pageCount] pages.
  factory all(int pageCount) => GradeRange(0, pageCount - 1);

  final int from;
  final int to;

  bool contains(int page) => page >= from && page <= to;

  /// Whether this range is the whole note of [pageCount] pages.
  bool covers(int pageCount) => from <= 0 && to >= pageCount - 1;

  /// The range the dialog starts with: the pages after the [last] graded
  /// range up to the last page, or every page when nothing was graded yet or
  /// [last] already reached the end.
  factory defaultFor({required int pageCount, GradeRange? last}) {
    final end = pageCount - 1;
    if (last == null || last.to >= end) return GradeRange(0, end);
    return GradeRange(last.to + 1, end);
  }

  /// Parses the texts of the From and To fields (1-based page numbers).
  /// Returns the range, or the error in plain words.
  static ({GradeRange? range, String? error}) parse(
    String from,
    String to, {
    required int pageCount,
  }) {
    final a = int.tryParse(from.trim());
    final b = int.tryParse(to.trim());
    if (a == null || b == null) {
      return (range: null, error: 'Enter whole page numbers.');
    }
    if (a < 1 || b < 1 || a > pageCount || b > pageCount) {
      return (range: null, error: 'Pages go from 1 to $pageCount.');
    }
    if (a > b) {
      return (range: null, error: 'From must not be after To.');
    }
    return (range: GradeRange(a - 1, b - 1), error: null);
  }

  /// `p6` or `p6–9`, with 1-based page numbers.
  String get label => from == to ? 'p${from + 1}' : 'p${from + 1}–${to + 1}';

  Map<String, dynamic> toJson() => {'from': from, 'to': to};

  @override
  bool operator ==(Object other) =>
      other is GradeRange && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => 'GradeRange($from, $to)';
}

/// The grades of [result] on pages of [range].
GradeResult resultInRange(GradeResult result, GradeRange range) => GradeResult(
  keyStatus: result.keyStatus,
  keyDetection: result.keyDetection,
  grades: [
    for (final g in result.grades)
      if (range.contains(g.pageIndex)) g,
  ],
);
