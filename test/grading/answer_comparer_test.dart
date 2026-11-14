import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:saber/grading/compare/answer_comparer.dart';
import 'package:saber/grading/models.dart';

void main() {
  test('letters match case-insensitively', () {
    expect(AnswerComparer.lettersMatch('A', 'a'), isTrue);
    expect(AnswerComparer.lettersMatch(' b ', 'B'), isTrue);
    expect(AnswerComparer.lettersMatch('A', 'B'), isFalse);
    expect(AnswerComparer.lettersMatch('', 'A'), isFalse);
  });

  test('models compare by value', () {
    const option = Option(
      letter: 'A',
      labelRect: Rect.fromLTWH(0, 0, 10, 10),
      box: Rect.fromLTWH(0, 0, 50, 10),
    );
    const same = Option(
      letter: 'A',
      labelRect: Rect.fromLTWH(0, 0, 10, 10),
      box: Rect.fromLTWH(0, 0, 50, 10),
    );
    expect(option, same);
    expect(option.hashCode, same.hashCode);
    expect(
      const KeyEntry(number: 1, letter: 'A', pageIndex: 0),
      const KeyEntry(number: 1, letter: 'A', pageIndex: 0),
    );
    expect(
      const MarkReading.unsure(UnsureReason.twoOptionsClose),
      const MarkReading.unsure(UnsureReason.twoOptionsClose),
    );
    expect(
      const MarkReading.unsure(UnsureReason.twoOptionsClose),
      isNot(const MarkReading.unsure(UnsureReason.noKeyEntry)),
    );
    expect(
      const KeyBlock(firstKeyPage: 1, lastKeyPage: 1, answers: {1: 'A'}),
      const KeyBlock(firstKeyPage: 1, lastKeyPage: 1, answers: {1: 'A'}),
    );
  });
}
