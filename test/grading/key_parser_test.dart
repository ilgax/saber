import 'package:flutter_test/flutter_test.dart';
import 'package:saber/grading/key/key_parser.dart';

void main() {
  group('KeyParser', () {
    test('accepts the supported entry formats', () {
      expect(KeyParser.parse('1) A'), {1: 'A'});
      expect(KeyParser.parse('2. B'), {2: 'B'});
      expect(KeyParser.parse('(3) C'), {3: 'C'});
      expect(KeyParser.parse('4 - D'), {4: 'D'});
      expect(KeyParser.parse('5: e'), {5: 'E'});
      expect(KeyParser.parse('6-a'), {6: 'A'});
      expect(KeyParser.parse('7–B'), {7: 'B'});
    });

    test('normalises letters to upper case', () {
      expect(KeyParser.parse('1) a\n2) b\n3) c'), {1: 'A', 2: 'B', 3: 'C'});
    });

    test('several entries on one line and several lines', () {
      expect(KeyParser.parse('1) A  2) C  3) B\n4) D   5) E'), {
        1: 'A',
        2: 'C',
        3: 'B',
        4: 'D',
        5: 'E',
      });
      expect(KeyParser.parse('1. A, 2. B; 3. C'), {1: 'A', 2: 'B', 3: 'C'});
    });

    test('mixed formats in one text', () {
      expect(KeyParser.parse('1) A\n(2) B\n3. C\n4 - D\n5: e'), {
        1: 'A',
        2: 'B',
        3: 'C',
        4: 'D',
        5: 'E',
      });
    });

    test('the letter must be a standalone token', () {
      expect(KeyParser.parse('1) Apples and pears'), isEmpty);
      expect(KeyParser.parse('2. Bananas'), isEmpty);
      expect(KeyParser.parse('3) Dogs'), isEmpty);
    });

    test('letters outside A-E are not answers', () {
      expect(KeyParser.parse('1) F'), isEmpty);
      expect(KeyParser.parse('1) Z'), isEmpty);
    });

    test('does not read across lines', () {
      expect(KeyParser.parse('1)\nA'), isEmpty);
    });

    test('decimals and years are not entries', () {
      expect(KeyParser.parse('3.5 A'), isEmpty);
      expect(KeyParser.parse('in 1999. A committee'), isEmpty);
    });

    test('repeated numbers keep the first entry in the map', () {
      expect(KeyParser.parse('1) A\n1) B'), {1: 'A'});
      expect(KeyParser.parseEntries('1) A\n1) B').length, 2);
    });

    test('coverage is high for a key and low for prose', () {
      final key = KeyParser.coverage('1) A  2) B  3) C');
      expect(key.matched / key.total, 1.0);
      final prose = KeyParser.coverage('1) A car travels at a constant speed');
      expect(prose.matched / prose.total, lessThan(0.3));
    });
  });
}
