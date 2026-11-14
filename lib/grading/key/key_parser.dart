/// Parses answer key text such as `1) A`, `1. A`, `(1) A`, `1 - A`, `1: a`
/// and several entries on a line (`1) A  2) C  3) B`).
abstract final class KeyParser {
  /// `number separator letter`, the letter being a standalone token (so
  /// `1) Apples` does not match). Spaces only, never a newline, between the
  /// parts of one entry.
  static final entryPattern = RegExp(
    r'(?<![A-Za-z0-9.])\(?(\d{1,3})[ \t]*[.):\-–—][ \t]*([A-Ea-e])(?![A-Za-z0-9])',
    multiLine: true,
  );

  /// The entries in [text], in order of appearance, with upper-case letters.
  /// A number may occur more than once (several tests).
  static List<({int number, String letter})> parseEntries(String text) => [
    for (final m in entryPattern.allMatches(text))
      (number: int.parse(m.group(1)!), letter: m.group(2)!.toUpperCase()),
  ];

  /// Number to letter; the first entry wins for repeated numbers.
  static Map<int, String> parse(String text) {
    final result = <int, String>{};
    for (final e in parseEntries(text)) {
      result.putIfAbsent(e.number, () => e.letter);
    }
    return result;
  }

  /// How many whitespace-separated tokens of [text] belong to key entries,
  /// and how many there are in total.
  static ({int matched, int total}) coverage(String text) {
    final matches = entryPattern.allMatches(text).toList();
    var matched = 0, total = 0;
    for (final token in RegExp(r'\S+').allMatches(text)) {
      total++;
      if (matches.any((m) => m.start < token.end && token.start < m.end)) {
        matched++;
      }
    }
    return (matched: matched, total: total);
  }
}
