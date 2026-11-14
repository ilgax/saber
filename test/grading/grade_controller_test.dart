// GradeController end to end: a real EditorCoreInfo with PDF background
// pages, real strokes, the real isolate runner and a sidecar store in a temp
// directory.
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/grading/grade_range.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/models.dart';
import 'package:saber/grading/sidecar_store.dart';
import 'package:saber/grading/ui/grade_controller.dart';

import 'fixtures/note_fixture.dart';
import 'fixtures/pdf_fixtures.dart';
import 'fixtures/stroke_fixtures.dart';

const key20 = 'BCADBCADBCADBCADBCAD';

/// Five pages of four questions each (20 questions), then the key page.
List<FxPage> twentyQuestionPdf() => [
  for (var p = 0; p < 5; p++)
    questionPage(questions(first: 1 + 4 * p, count: 4)),
  keyPage(key20.split('')),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    FlavorConfig.setup();
    await initPdfrx();
  });

  late Directory tmp;
  late SidecarStore store;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('grade_controller_test');
    store = SidecarStore(Directory('${tmp.path}/grading'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('grades a 20-question, 5-page test and reports the time', () async {
    final note = await NoteFixture.create(twentyQuestionPdf());
    addTearDown(note.dispose);
    for (var p = 0; p < 5; p++) {
      for (var i = 0; i < 4; i++) {
        final n = 1 + 4 * p + i;
        // Mark the right answer on all but every fifth question.
        note.circle(p, n, n % 5 == 0 ? 'D' : key20[n - 1]);
      }
    }
    final c = GradeController(note.coreInfo, store: store);
    final states = <GradeStatus>[];
    c.addListener(() => states.add(c.status));
    final wall = Stopwatch()..start();
    await c.grade();
    wall.stop();

    expect(c.status, GradeStatus.done, reason: c.error);
    expect(states.first, GradeStatus.running);
    expect(c.result!.grades, hasLength(20));
    expect(c.result!.count(Verdict.correct), 17);
    expect(c.result!.count(Verdict.wrong), 3);
    expect(c.timings!.extraction, greaterThan(Duration.zero));
    // ignore: avoid_print
    print(
      'TIMING 20 questions / 6 pages: extraction '
      '${c.timings!.extraction.inMilliseconds} ms, grading '
      '${c.timings!.grading.inMilliseconds} ms, wall '
      '${wall.elapsedMilliseconds} ms',
    );
    expect(wall.elapsed, lessThan(const Duration(seconds: 15)));

    // Second run reuses the cached page texts.
    final second = Stopwatch()..start();
    await c.grade();
    second.stop();
    // ignore: avoid_print
    print('TIMING second run (cached text): ${second.elapsedMilliseconds} ms');
    expect(c.result!.count(Verdict.correct), 17);
  });

  test('progress is reported per page', () async {
    final note = await NoteFixture.create(twentyQuestionPdf());
    addTearDown(note.dispose);
    final c = GradeController(note.coreInfo, store: store);
    final seen = <(int, int)>[];
    c.addListener(() {
      if (c.status == GradeStatus.running)
        seen.add((c.doneCount, c.totalCount));
    });
    await c.grade();
    expect(seen.last, (6, 6));
    expect(seen.map((e) => e.$1).toSet(), containsAll([0, 1, 6]));
  });

  test('no PDF pages: a readable error, no crash', () async {
    final c = GradeController(
      EditorCoreInfo(filePath: '/e.sbn2'),
      store: store,
    );
    await c.grade();
    expect(c.status, GradeStatus.error);
    expect(c.error, contains('no PDF pages'));
    expect(c.hasResults, isFalse);
  });

  test('a failing job becomes an error message', () async {
    final note = await NoteFixture.create(twentyQuestionPdf());
    addTearDown(note.dispose);
    final c = GradeController(
      note.coreInfo,
      store: store,
      runJob: (_) async => throw StateError('boom'),
    );
    await c.grade();
    expect(c.status, GradeStatus.error);
    expect(c.error, 'Grading failed: Bad state: boom');
  });

  test('the controller is shared per note and dropped with it', () {
    final a = EditorCoreInfo(filePath: '/a.sbn2');
    final b = EditorCoreInfo(filePath: '/b.sbn2');
    expect(GradeController.of(a), same(GradeController.of(a)));
    expect(GradeController.of(a), isNot(same(GradeController.of(b))));
  });

  group('persistence', () {
    test(
      'key pages and corrections come back, per PDF, not per note',
      () async {
        final pdf = [
          questionPage(questions(count: 3)),
          keyPage('BCA'.split('')),
        ];
        final first = await NoteFixture.create(pdf, path: '/one.sbn2');
        addTearDown(first.dispose);
        first.circle(0, 1, 'A');
        final c1 = GradeController(first.coreInfo, store: store);
        await c1.grade();
        // Too short to be detected: unknown until the user says so.
        expect(c1.result!.keyStatus, KeyStatus.unknown);
        await c1.setKeyOverride(const KeyOverride({1}));
        expect(c1.result!.keyStatus, KeyStatus.found);
        expect(c1.result!.grade(1)!.verdict, Verdict.wrong);
        // The user corrects the reading to B (the right answer).
        await c1.setCorrection((0, 1), 'B');
        expect(c1.result!.grade(1)!.verdict, Verdict.correct);
        expect(c1.result!.grade(1)!.corrected, isTrue);

        // The same note, closed and reopened (new controller, same store).
        final c2 = GradeController(first.coreInfo, store: store);
        await c2.grade();
        expect(c2.keyOverride, const KeyOverride({1}));
        expect(c2.result!.keyStatus, KeyStatus.found);
        expect(c2.result!.grade(1)!.corrected, isTrue);
        expect(c2.result!.grade(1)!.verdict, Verdict.correct);

        // A fresh note of the same PDF: the key choice applies (it is about
        // the PDF), the correction does not (it is about this attempt).
        final fresh = await NoteFixture.create(
          pdf,
          path: '/two.sbn2',
          sameBytes: first.bytes,
        );
        addTearDown(fresh.dispose);
        final c3 = GradeController(fresh.coreInfo, store: store);
        await c3.grade();
        expect(c3.result!.keyStatus, KeyStatus.found);
        expect(c3.result!.grade(1)!.verdict, Verdict.unanswered);
        expect(c3.result!.grade(1)!.corrected, isFalse);
        // The same PDF again with different ink: no inherited correction.
        fresh.coreInfo.pages[0].strokes.add(
          stroke(circleAround(fresh.doc.labelRect(0, 1, 'A'), margin: 16)),
        );
        await c3.grade();
        expect(c3.result!.grade(1)!.corrected, isFalse);
        expect(c3.result!.grade(1)!.verdict, Verdict.wrong);

        // Clearing and resetting.
        await c2.clearCorrection((0, 1));
        expect(c2.result!.grade(1)!.corrected, isFalse);
        await c2.setKeyOverride(null);
        expect(c2.result!.keyStatus, KeyStatus.unknown);
        final c4 = GradeController(first.coreInfo, store: store);
        await c4.grade();
        expect(c4.keyOverride, isNull);
        expect(c4.corrections, isEmpty);
      },
    );

    test('nothing is written next to the note', () async {
      final noteDir = Directory('${tmp.path}/notes')..createSync();
      final note = await NoteFixture.create([
        questionPage(questions(count: 3)),
        keyPage('BCA'.split('')),
      ], path: '${noteDir.path}/n.sbn2');
      addTearDown(note.dispose);
      final c = GradeController(note.coreInfo, store: store);
      await c.grade();
      await c.setKeyOverride(const KeyOverride({1}));
      expect(noteDir.listSync(), isEmpty);
      expect(store.directory.listSync(), isNotEmpty);
    });

    test('a store that cannot write never breaks grading', () async {
      final blocked = File('${tmp.path}/blocked')..writeAsStringSync('x');
      final note = await NoteFixture.create([
        questionPage(questions(count: 3)),
        keyPage('BCA'.split('')),
      ]);
      addTearDown(note.dispose);
      final c = GradeController(
        note.coreInfo,
        store: SidecarStore(Directory('${blocked.path}/grading')),
      );
      await c.grade();
      await c.setKeyOverride(const KeyOverride({1}));
      expect(c.status, GradeStatus.done);
      expect(c.result!.keyStatus, KeyStatus.found);
    });
  });

  test(
    'key pages are stored as PDF pages: inserting a page keeps them',
    () async {
      final pdf = [questionPage(questions(count: 3)), keyPage('BCA'.split(''))];
      final note = await NoteFixture.create(pdf);
      addTearDown(note.dispose);
      final c1 = GradeController(note.coreInfo, store: store);
      await c1.grade();
      await c1.setKeyOverride(const KeyOverride({1}));
      // The user inserts a blank page in front: the key is now note page 2.
      note.coreInfo.pages.insert(0, EditorPage());
      final c2 = GradeController(note.coreInfo, store: store);
      await c2.grade();
      printOnFailure('c2 override ${c2.keyOverride?.keyPages} err ${c2.error}');
      expect(c2.keyOverride, const KeyOverride({2}));
      expect(c2.result!.keyStatus, KeyStatus.found);
    },
  );

  test('the report is available and private', () async {
    final note = await NoteFixture.create(twentyQuestionPdf());
    addTearDown(note.dispose);
    final c = GradeController(note.coreInfo, store: store, buildInfo: 'test');
    expect(c.report(), isEmpty);
    await c.grade();
    final r = c.report();
    expect(r, contains('GRADING REPORT'));
    expect(r, contains('build: test'));
    expect(r, isNot(contains('/n.sbn2')));
  });

  test(
    'debug data: key pages list their entries, question pages count',
    () async {
      final note = await NoteFixture.create(twentyQuestionPdf());
      addTearDown(note.dispose);
      final c = GradeController(note.coreInfo, store: store);
      await c.grade();
      expect(c.debugFor(0).badge, 'p1: 4 questions');
      expect(c.debugFor(0).isKey, isFalse);
      final key = c.debugFor(5);
      expect(key.isKey, isTrue);
      expect(key.badge, startsWith('p6: key page, block 1, conf '));
      expect(key.keyEntries, hasLength(20));
      expect(key.keyEntries.first.text, '1=B');
      expect(
        const Rect.fromLTWH(
          0,
          0,
          1000,
          1500,
        ).expandToInclude(key.keyEntries.first.rect),
        const Rect.fromLTWH(0, 0, 1000, 1500),
      );
    },
  );

  test('PageIndexMap with several PDFs uses note indices', () {
    // (Kept simple: the single-PDF behaviour is covered above.)
    const m = PageIndexMap([], single: false);
    expect(m.toStored(3), 3);
    expect(m.fromStored(3), 3);
  });

  group('grading a range', () {
    Future<(NoteFixture, GradeController)> open() async {
      final note = await NoteFixture.create(twentyQuestionPdf());
      addTearDown(note.dispose);
      // Right answers on every question of pages 0-3 (1-16), none on page 4.
      for (var n = 1; n <= 16; n++) {
        note.circle((n - 1) ~/ 4, n, key20[n - 1]);
      }
      return (note, GradeController(note.coreInfo, store: store));
    }

    test('only the range is graded, the key page outside it is used', () async {
      final (_, c) = await open();
      final seen = <(int, int)>[];
      c.addListener(() {
        if (c.status == GradeStatus.running)
          seen.add((c.doneCount, c.totalCount));
      });
      await c.grade(range: const GradeRange(1, 2));
      expect(c.status, GradeStatus.done, reason: c.error);
      expect(c.result!.grades.map((g) => g.number), [
        for (var n = 5; n <= 12; n++) n,
      ]);
      expect(c.result!.count(Verdict.correct), 8);
      expect(c.result!.keyStatus, KeyStatus.found);
      expect(c.latestRange, const GradeRange(1, 2));
      // Progress counts the pages of the range only.
      expect(seen.last, (2, 2));
      expect(seen.every((e) => e.$2 <= 2), isTrue);
      expect(c.earlierGrades, isEmpty);
    });

    test('marks accumulate over ranges and regrading replaces them', () async {
      final (note, c) = await open();
      await c.grade(range: const GradeRange(0, 1));
      expect(c.outcome!.result.grades, hasLength(8));

      // Later ink on page 0 is not seen until page 0 is graded again.
      note.coreInfo.pages[0].strokes.clear();
      await c.grade(range: const GradeRange(2, 3));
      expect(c.result!.grades, hasLength(8));
      expect(c.outcome!.result.grades, hasLength(16));
      expect(c.earlierGrades.map((g) => g.pageIndex).toSet(), {0, 1});
      expect(c.outcome!.result.grade(1)!.verdict, Verdict.correct);
      expect(c.outcome!.pages.keys.toSet(), {0, 1, 2, 3});

      // Grade pages 1-2 again: page 1 and 2 are replaced, 0 and 3 stay.
      note.coreInfo.pages[1].strokes.clear();
      note.circle(1, 5, 'D'); // key B
      await c.grade(range: const GradeRange(1, 2));
      expect(c.outcome!.result.grades, hasLength(16));
      expect(c.result!.grades, hasLength(8));
      expect(c.outcome!.result.grade(5)!.verdict, Verdict.wrong);
      expect(c.outcome!.result.grade(6)!.verdict, Verdict.unanswered);
      expect(c.outcome!.result.grade(1)!.verdict, Verdict.correct);
      expect(c.earlierGrades.map((g) => g.pageIndex).toSet(), {0, 3});
    });

    test('corrections and key overrides work on earlier ranges', () async {
      final (_, c) = await open();
      await c.grade(range: const GradeRange(0, 0));
      await c.grade(range: const GradeRange(2, 2));
      await c.setCorrection((0, 2), 'D'); // page 0, key C, ink on C
      expect(c.outcome!.result.grade(2)!.verdict, Verdict.wrong);
      expect(c.outcome!.result.grade(2)!.corrected, isTrue);
      expect(c.corrections, hasLength(1));
      await c.clearCorrection((0, 2));
      expect(c.outcome!.result.grade(2)!.verdict, Verdict.correct);
      await c.setKeyOverride(const KeyOverride({5}));
      expect(c.outcome!.result.grades, hasLength(8));
    });

    test(
      'the last range survives a new controller; defaults follow it',
      () async {
        final (note, c) = await open();
        expect(await c.suggestedRange(), const GradeRange(0, 5));
        await c.grade(range: const GradeRange(0, 1));
        expect(await c.suggestedRange(), const GradeRange(2, 5));

        final again = GradeController(note.coreInfo, store: store);
        expect(await again.suggestedRange(), const GradeRange(2, 5));
        await again.grade(range: const GradeRange(3, 5));
        final third = GradeController(note.coreInfo, store: store);
        expect(await third.suggestedRange(), const GradeRange(0, 5));
      },
    );

    test('the report names the range and lists only its pages', () async {
      final (_, c) = await open();
      await c.grade(range: const GradeRange(0, 1));
      final r = c.report();
      expect(r, contains('range: pages 1-2 of 6'));
      expect(r, contains('  page 1: '));
      expect(r, contains('  page 2: '));
      expect(r, contains('  page 6: ')); // the key page, outside the range
      expect(r, contains('KEY PAGE'));
      expect(r, isNot(contains('  page 3: ')));
      expect(r, isNot(contains('  page 5: ')));
      expect(r, contains('PAGES: 3'));
      expect(r, contains('page 2: '));
      expect(
        RegExp(r'#\d+ page (\d+):')
            .allMatches(r)
            .map((m) => m.group(1))
            .toSet(),
        {'1', '2'},
      );
    });
  });
}
