/// Compares the marked option with the key's answer.
abstract final class AnswerComparer {
  /// Multiple choice: case-insensitive letter match only. Non-multiple-choice
  /// equivalence is out of scope for release 1.
  static bool lettersMatch(String a, String b) =>
      a.trim().toUpperCase() == b.trim().toUpperCase();
}
