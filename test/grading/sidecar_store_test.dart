import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:saber/grading/corrections.dart';
import 'package:saber/grading/key/key_page_detector.dart';
import 'package:saber/grading/models.dart';
import 'package:saber/grading/sidecar_store.dart';
import 'package:sbn/tool_id.dart';

Correction corr(int test, int number, String letter, {double x = 100}) =>
    Correction(
      testIndex: test,
      number: number,
      letter: letter,
      signature: InkSignature.of([
        InkStroke(
          outline: [Offset(x, 10), Offset(x + 20, 30)],
          toolId: ToolId.fountainPen,
        ),
      ]),
    );

void main() {
  late Directory tmp;
  late SidecarStore store;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sidecar_test');
    store = SidecarStore(Directory('${tmp.path}/grading'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test(
    'nothing stored: empty data, directory not created by reading',
    () async {
      final d = await store.load('abc');
      expect(d.keyOverride, isNull);
      expect(d.corrections, isEmpty);
      expect(store.directory.existsSync(), isFalse);
    },
  );

  test('key pages per PDF round-trip, including explicit blocks', () async {
    await store.saveKeyOverride('h1', const KeyOverride({3, 4}));
    await store.saveKeyOverride(
      'h2',
      KeyOverride.fromBlocks(const [
        KeyBlockOverride(
          firstKeyPage: 5,
          lastKeyPage: 5,
          firstQuestionPage: 0,
          lastQuestionPage: 2,
        ),
      ]),
    );
    expect((await store.load('h1')).keyOverride, const KeyOverride({3, 4}));
    expect(
      (await store.load('h2')).keyOverride!.blocks.single.lastQuestionPage,
      2,
    );
    // Another PDF is unaffected.
    expect((await store.load('h3')).keyOverride, isNull);
    // Reset to automatic.
    await store.saveKeyOverride('h1', null);
    expect((await store.load('h1')).keyOverride, isNull);
  });

  test('corrections round-trip and replace per question', () async {
    await store.setCorrection('h', corr(0, 1, 'B'));
    await store.setCorrection('h', corr(0, 2, 'C'));
    await store.setCorrection('h', corr(0, 1, 'D', x: 200));
    final d = await store.load('h');
    expect(d.corrections.map((c) => (c.number, c.letter)), [
      (2, 'C'),
      (1, 'D'),
    ]);
    expect(
      d.corrections.last.signature.matches(corr(0, 1, 'D', x: 200).signature),
      isTrue,
    );
    await store.clearCorrection('h', (0, 2));
    expect((await store.load('h')).corrections.map((c) => c.number), [1]);
  });

  test('key override and corrections are kept together', () async {
    await store.saveKeyOverride('h', const KeyOverride({1}));
    await store.setCorrection('h', corr(0, 1, 'B'));
    await store.saveKeyOverride('h', const KeyOverride({2}));
    final d = await store.load('h');
    expect(d.keyOverride, const KeyOverride({2}));
    expect(d.corrections, hasLength(1));
  });

  test('the number of corrections is capped, oldest dropped', () async {
    for (var i = 1; i <= SidecarStore.maxCorrections + 5; i++) {
      await store.setCorrection('h', corr(0, i, 'A'));
    }
    final d = await store.load('h');
    expect(d.corrections, hasLength(SidecarStore.maxCorrections));
    expect(d.corrections.first.number, 6);
    expect(d.corrections.last.number, SidecarStore.maxCorrections + 5);
  });

  group('robustness', () {
    File file(String h) => File('${store.directory.path}/$h.json');

    test(
      'corrupt JSON behaves as nothing stored and is repaired by a write',
      () async {
        store.directory.createSync(recursive: true);
        file('h').writeAsStringSync('{"v":1, "key": ');
        expect((await store.load('h')).corrections, isEmpty);
        await store.setCorrection('h', corr(0, 1, 'B'));
        expect((await store.load('h')).corrections, hasLength(1));
      },
    );

    test('wrong schema version or shape', () async {
      store.directory.createSync(recursive: true);
      file('old').writeAsStringSync('{"v":0,"corr":[]}');
      file('new').writeAsStringSync('{"v":99,"key":{"pages":[1]}}');
      file('list').writeAsStringSync('[1,2,3]');
      for (final h in ['old', 'new', 'list']) {
        final d = await store.load(h);
        expect(d.keyOverride, isNull, reason: h);
        expect(d.corrections, isEmpty, reason: h);
      }
    });

    test('one bad correction does not lose the others', () async {
      store.directory.createSync(recursive: true);
      file('h').writeAsStringSync(
        '{"v":1,"corr":[{"t":0},{"t":0,"n":2,"l":"C","s":[[1,0,0,10,10]]}]}',
      );
      final d = await store.load('h');
      expect(d.corrections.map((c) => c.number), [2]);
    });

    test('an unwritable location does not throw', () async {
      // A file where the directory should be.
      final blocked = File('${tmp.path}/blocked')..writeAsStringSync('x');
      final bad = SidecarStore(Directory('${blocked.path}/grading'));
      await bad.setCorrection('h', corr(0, 1, 'B'));
      await bad.saveKeyOverride('h', const KeyOverride({1}));
      expect((await bad.load('h')).corrections, isEmpty);
    });

    test('a leftover temp file from a crash is ignored', () async {
      await store.setCorrection('h', corr(0, 1, 'B'));
      File('${store.directory.path}/h.json.tmp').writeAsStringSync('{broken');
      expect((await store.load('h')).corrections, hasLength(1));
      await store.setCorrection('h', corr(0, 2, 'C'));
      expect((await store.load('h')).corrections, hasLength(2));
    });

    test('concurrent writes are not lost', () async {
      await Future.wait([
        for (var i = 1; i <= 20; i++) store.setCorrection('h', corr(0, i, 'A')),
      ]);
      expect((await store.load('h')).corrections, hasLength(20));
    });
  });

  test('hashes: same bytes give the same id, different bytes do not', () async {
    final a = Uint8List.fromList([1, 2, 3]);
    final h1 = await SidecarStore.hashBytes(a);
    expect(await SidecarStore.hashBytes(Uint8List.fromList([1, 2, 3])), h1);
    expect(
      await SidecarStore.hashBytes(Uint8List.fromList([1, 2, 4])),
      isNot(h1),
    );
    final f = File('${tmp.path}/x.bin')..writeAsBytesSync([1, 2, 3]);
    expect(await SidecarStore.hashFile(f.path), h1);
    expect(SidecarStore.combine([h1]), h1);
    expect(
      SidecarStore.combine([h1, 'b']),
      isNot(SidecarStore.combine(['b', h1])),
    );
  });

  test('files are named by hash and stay inside the given directory', () async {
    await store.saveKeyOverride('abc123', const KeyOverride({1}));
    final names = store.directory.listSync().map(
      (e) => e.uri.pathSegments.last,
    );
    expect(names, ['abc123.json']);
  });
}
