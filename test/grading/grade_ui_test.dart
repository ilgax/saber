// Widget tests of the grading UI: the marks overlay (pointer safety), the
// grade button and the sheets.
import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/models.dart';
import 'package:saber/grading/sidecar_store.dart';
import 'package:saber/grading/ui/grade_button.dart';
import 'package:saber/grading/ui/grade_controller.dart';
import 'package:saber/grading/ui/grade_marks_overlay.dart';
import 'package:saber/grading/ui/grading_strings.dart';
import 'package:saber/grading/ui/mark_placement.dart';
import 'package:saber/grading/ui/results_sheet.dart';

import 'fixtures/note_fixture.dart';
import 'fixtures/pdf_fixtures.dart';

/// Runs the grading job inline (no isolate), so widget tests need no real
/// async beyond reading the PDF.
Future<GradingOutcome> inlineRunner(GradeJob job) async => gradeDetailed(
  job.pages,
  keyOverride: job.keyOverride,
  corrections: job.corrections,
);

const key6 = 'BCADBC';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late SidecarStore store;
  setUpAll(() async {
    FlavorConfig.setup();
    await initPdfrx();
  });
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('grade_ui_test');
    store = SidecarStore(Directory('${tmp.path}/grading'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<(NoteFixture, GradeController)> note(
    WidgetTester tester, {
    bool graded = true,
    void Function(NoteFixture)? ink,
    GradeJobRunner? runner,
  }) async {
    late NoteFixture n;
    late GradeController c;
    await tester.runAsync(() async {
      n = await NoteFixture.create([
        questionPage(questions()),
        keyPage(key6.split('')),
      ]);
      ink?.call(n);
      c = GradeController(
        n.coreInfo,
        store: store,
        runJob: runner ?? inlineRunner,
        buildInfo: 'test',
      );
      GradeController.register(n.coreInfo, c);
      if (graded) await c.grade();
    });
    addTearDown(() => n.dispose());
    return (n, c);
  }

  /// Lets real async work (PDF reading, isolates) finish while widgets
  /// pump, until [done] holds.
  Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 50));
  }

  void bigScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// A page-sized box with the overlay over a recording ancestor Listener and
  /// scale detector, like the editor's canvas.
  Widget page(
    NoteFixture n, {
    List<PointerEvent>? events,
    List<String>? scales,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: Listener(
            onPointerDown: events?.add,
            onPointerMove: events?.add,
            onPointerUp: events?.add,
            child: GestureDetector(
              onScaleStart: (_) => scales?.add('start'),
              onScaleUpdate: (_) {},
              onScaleEnd: (_) => scales?.add('end'),
              child: SizedBox(
                width: n.coreInfo.pages[0].size.width,
                height: n.coreInfo.pages[0].size.height,
                child: Stack(
                  children: [
                    const Positioned.fill(
                      child: ColoredBox(color: Colors.white),
                    ),
                    GradeMarksOverlay(coreInfo: n.coreInfo, pageIndex: 0),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Offset markCentre(GradeController c, int number) {
    final g = c.result!.grade(number)!;
    return markRect(
      pageSize: c.pages.first.noteSize,
      anchor: g.anchorInNote,
    ).center;
  }

  group('overlay', () {
    testWidgets('(c) nothing graded: no size, no hit-testable area', (
      tester,
    ) async {
      bigScreen(tester);
      final (n, _) = await note(tester, graded: false);
      final events = <PointerEvent>[];
      await tester.pumpWidget(page(n, events: events));
      expect(tester.getSize(find.byType(GradeMarksOverlay)), Size.zero);
      final overlay = find.byType(GradeMarksOverlay);
      expect(
        find.descendant(of: overlay, matching: find.byType(GestureDetector)),
        findsNothing,
      );
      expect(
        find.descendant(of: overlay, matching: find.byType(IgnorePointer)),
        findsNothing,
      );
      expect(
        find.descendant(of: overlay, matching: find.byType(CustomPaint)),
        findsNothing,
      );
      // A tap anywhere reaches only what is behind.
      final tap = await tester.startGesture(const Offset(120, 200));
      await tap.up();
      expect(events, hasLength(2));
    });

    testWidgets('marks are painted but not hit-testable themselves', (
      tester,
    ) async {
      bigScreen(tester);
      final (n, c) = await note(tester, ink: (n) => n.circle(0, 1, 'B'));
      await tester.pumpWidget(page(n));
      final overlay = find.byType(GradeMarksOverlay);
      // Every CustomPaint in the overlay is under an IgnorePointer.
      final paints = find.descendant(
        of: overlay,
        matching: find.byType(CustomPaint),
      );
      expect(paints, findsWidgets);
      for (final element in paints.evaluate()) {
        var ignored = false;
        element.visitAncestorElements((a) {
          if (a.widget is IgnorePointer) ignored = true;
          return !ignored && a.widget != overlay.evaluate().first.widget;
        });
        expect(ignored, isTrue);
      }
      // One tap target per question, nothing else takes pointers.
      expect(
        find.descendant(of: overlay, matching: find.byType(GestureDetector)),
        findsNWidgets(c.result!.grades.length),
      );
    });

    testWidgets('(a) a stylus over a mark reaches the ancestors, no tap', (
      tester,
    ) async {
      bigScreen(tester);
      final (n, c) = await note(tester, ink: (n) => n.circle(0, 1, 'B'));
      final events = <PointerEvent>[];
      final scales = <String>[];
      await tester.pumpWidget(page(n, events: events, scales: scales));
      final at = markCentre(c, 1);
      final g = await tester.startGesture(at, kind: PointerDeviceKind.stylus);
      await g.moveBy(const Offset(40, 10));
      await g.moveBy(const Offset(40, 10));
      await g.up();
      await tester.pumpAndSettle();

      expect(events, hasLength(4));
      expect(events[0], isA<PointerDownEvent>());
      expect(events[1], isA<PointerMoveEvent>());
      expect(events[2], isA<PointerMoveEvent>());
      expect(events[3], isA<PointerUpEvent>());
      expect(events.every((e) => e.kind == PointerDeviceKind.stylus), isTrue);
      // The ancestor's scale gesture (how the canvas draws) still starts.
      expect(scales, contains('start'));
      // The mark's tap did not fire.
      expect(find.text('Question 1'), findsNothing);
      expect(c.selected, isNull);
    });

    testWidgets('(a) a stylus tap on a mark does not open the detail', (
      tester,
    ) async {
      bigScreen(tester);
      final (n, c) = await note(tester, ink: (n) => n.circle(0, 1, 'B'));
      final events = <PointerEvent>[];
      await tester.pumpWidget(page(n, events: events));
      final g = await tester.startGesture(
        markCentre(c, 1),
        kind: PointerDeviceKind.stylus,
      );
      await g.up();
      await tester.pumpAndSettle();
      expect(events, hasLength(2));
      expect(find.text('Question 1'), findsNothing);
    });

    testWidgets('(b) a finger tap on a mark opens the question detail', (
      tester,
    ) async {
      bigScreen(tester);
      final (n, c) = await note(tester, ink: (n) => n.circle(0, 2, 'A'));
      await tester.pumpWidget(page(n));
      await tester.tapAt(markCentre(c, 2));
      await tester.pumpAndSettle();
      expect(find.text('Question 2'), findsOneWidget);
      expect(find.text('Wrong'), findsOneWidget);
      expect(find.textContaining('A, circle'), findsOneWidget);
      expect(find.text('Set my answer to C'), findsOneWidget);
      expect(c.selected, (0, 2));
    });

    testWidgets('a mouse click also opens it', (tester) async {
      bigScreen(tester);
      final (n, c) = await note(tester, ink: (n) => n.circle(0, 2, 'A'));
      await tester.pumpWidget(page(n));
      final g = await tester.startGesture(
        markCentre(c, 2),
        kind: PointerDeviceKind.mouse,
      );
      await g.up();
      await tester.pumpAndSettle();
      expect(find.text('Question 2'), findsOneWidget);
    });

    testWidgets('hiding the marks removes them and the tap targets', (
      tester,
    ) async {
      bigScreen(tester);
      final (n, c) = await note(tester, ink: (n) => n.circle(0, 1, 'B'));
      await tester.pumpWidget(page(n));
      expect(
        find.descendant(
          of: find.byType(GradeMarksOverlay),
          matching: find.byType(GestureDetector),
        ),
        findsWidgets,
      );
      c.setMarksVisible(false);
      await tester.pump();
      expect(tester.getSize(find.byType(GradeMarksOverlay)), Size.zero);
    });

    testWidgets('the debug overlay is painted under IgnorePointer, no taps', (
      tester,
    ) async {
      bigScreen(tester);
      final (n, c) = await note(tester, ink: (n) => n.circle(0, 1, 'B'));
      c.setMarksVisible(false);
      c.setDebug(true);
      await tester.pumpWidget(page(n));
      final overlay = find.byType(GradeMarksOverlay);
      expect(
        find.descendant(of: overlay, matching: find.byType(CustomPaint)),
        findsWidgets,
      );
      expect(
        find.descendant(of: overlay, matching: find.byType(GestureDetector)),
        findsNothing,
      );
    });

    testWidgets('selecting a question highlights it without taps', (
      tester,
    ) async {
      bigScreen(tester);
      final (n, c) = await note(tester, ink: (n) => n.circle(0, 1, 'B'));
      c.setMarksVisible(false);
      c.select((0, 1));
      await tester.pumpWidget(page(n));
      expect(
        find.descendant(
          of: find.byType(GradeMarksOverlay),
          matching: find.byType(CustomPaint),
        ),
        findsWidgets,
      );
    });
  });

  group('grade button', () {
    Widget host(NoteFixture n) => MaterialApp(
      home: Scaffold(
        appBar: AppBar(actions: [GradeButton(coreInfo: n.coreInfo)]),
        body: Stack(
          children: [GradeMarksOverlay(coreInfo: n.coreInfo, pageIndex: 0)],
        ),
      ),
    );

    testWidgets('idle: an icon; tap grades, shows chip and sheet', (
      tester,
    ) async {
      bigScreen(tester);
      final (n, c) = await note(
        tester,
        graded: false,
        ink: (n) {
          n.circle(0, 1, 'B');
          n.circle(0, 2, 'A');
        },
      );
      await tester.pumpWidget(host(n));
      expect(find.byIcon(Icons.grading), findsOneWidget);
      expect(find.byType(ActionChip), findsNothing);

      await tester.tap(find.byIcon(Icons.grading));
      await settleUntil(
        tester,
        () => c.status != GradeStatus.running && c.hasResults,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(c.status, GradeStatus.done, reason: c.error);
      // Q1 B correct, Q2 A wrong, four unanswered.
      expect(find.text('1/6 correct, 4 unanswered'), findsWidgets);
      expect(find.text(GradingStrings.results), findsOneWidget);
      expect(find.textContaining('1 correct, 1 wrong'), findsOneWidget);
    });

    testWidgets('running: a progress indicator while grading', (tester) async {
      bigScreen(tester);
      final gate = Completer<void>();
      final (n, c) = await note(
        tester,
        graded: false,
        runner: (job) async {
          await gate.future;
          return inlineRunner(job);
        },
      );
      await tester.pumpWidget(host(n));
      await tester.tap(find.byIcon(Icons.grading));
      await settleUntil(
        tester,
        () =>
            c.status == GradeStatus.running &&
            c.doneCount == c.totalCount &&
            c.totalCount > 0,
      );
      expect(c.status, GradeStatus.running);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.grading), findsNothing);
      gate.complete();
      await settleUntil(tester, () => c.status == GradeStatus.done);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ActionChip), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a failure shows a readable message, no crash', (tester) async {
      bigScreen(tester);
      final (n, c) = await note(
        tester,
        graded: false,
        runner: (_) async => throw StateError('boom'),
      );
      await tester.pumpWidget(host(n));
      await tester.tap(find.byIcon(Icons.grading));
      await settleUntil(tester, () => c.status == GradeStatus.error);
      await tester.pump(const Duration(seconds: 1));
      expect(c.status, GradeStatus.error);
      expect(find.text('Grading failed: Bad state: boom'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('long-press toggles the debug overlay', (tester) async {
      bigScreen(tester);
      final (n, c) = await note(tester, graded: false);
      await tester.pumpWidget(host(n));
      expect(c.debug, isFalse);
      await tester.longPress(find.byIcon(Icons.grading));
      expect(c.debug, isTrue);
      await tester.longPress(find.byIcon(Icons.grading));
      expect(c.debug, isFalse);
    });
  });

  group('sheets', () {
    Widget sheetHost(GradeController c) => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showResultsSheet(context, c),
            child: const Text('open'),
          ),
        ),
      ),
    );

    testWidgets('results sheet lists questions and opens the detail', (
      tester,
    ) async {
      bigScreen(tester);
      final (_, c) = await note(tester, ink: (n) => n.circle(0, 1, 'B'));
      await tester.pumpWidget(sheetHost(c));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(GradingStrings.questions), findsOneWidget);
      expect(find.text('Question 1 - Correct'), findsOneWidget);
      expect(find.text('read B, key B, page 1'), findsOneWidget);
      expect(find.text(GradingStrings.gradeAgain), findsOneWidget);
      expect(find.text(GradingStrings.hideMarks), findsOneWidget);
      expect(find.text(GradingStrings.keyPages), findsOneWidget);
      expect(find.text(GradingStrings.shareReport), findsOneWidget);
      expect(find.text(GradingStrings.copyReport), findsOneWidget);
      expect(find.text(GradingStrings.debugOverlay), findsOneWidget);
      expect(find.textContaining('Answer key found'), findsOneWidget);

      await tester.tap(find.text('Question 1 - Correct'));
      await tester.pumpAndSettle();
      expect(find.text('Question 1'), findsOneWidget);
      expect(find.text('B, circle, high confidence'), findsOneWidget);
    });

    testWidgets('hide marks and the debug switch', (tester) async {
      bigScreen(tester);
      final (_, c) = await note(tester);
      await tester.pumpWidget(sheetHost(c));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(GradingStrings.hideMarks));
      await tester.pump();
      expect(c.marksVisible, isFalse);
      expect(find.text(GradingStrings.showMarks), findsOneWidget);
      await tester.ensureVisible(find.byType(Switch));
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(c.debug, isTrue);
    });

    testWidgets('copy report puts the report on the clipboard', (tester) async {
      bigScreen(tester);
      final (_, c) = await note(tester);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(sheetHost(c));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(GradingStrings.copyReport));
      await tester.tap(find.text(GradingStrings.copyReport));
      await tester.pump();
      expect(copied, startsWith('GRADING REPORT'));
      expect(copied, c.report());
    });

    testWidgets('unknown key: plain words and the key pages action', (
      tester,
    ) async {
      bigScreen(tester);
      late NoteFixture n;
      late GradeController c;
      await tester.runAsync(() async {
        n = await NoteFixture.create([questionPage(questions())]);
        n.circle(0, 1, 'B');
        c = GradeController(n.coreInfo, store: store, runJob: inlineRunner);
        await c.grade();
      });
      addTearDown(() => n.dispose());
      await tester.pumpWidget(sheetHost(c));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('no page looks like an answer key'),
        findsOneWidget,
      );
      expect(find.text(GradingStrings.keyPages), findsOneWidget);
      expect(find.text('Question 1 - Unsure'), findsOneWidget);
    });

    testWidgets('a correction from the detail sheet changes the verdict', (
      tester,
    ) async {
      bigScreen(tester);
      final (_, c) = await note(tester, ink: (n) => n.circle(0, 1, 'A'));
      expect(c.result!.grade(1)!.verdict, Verdict.wrong);
      await tester.pumpWidget(sheetHost(c));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Question 1 - Wrong'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set my answer to B'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pumpAndSettle();
      expect(c.result!.grade(1)!.verdict, Verdict.correct);
      expect(find.text('B (set by you)'), findsOneWidget);
      expect(find.text(GradingStrings.clearCorrection), findsOneWidget);
      await tester.tap(find.text(GradingStrings.clearCorrection));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pumpAndSettle();
      expect(c.result!.grade(1)!.verdict, Verdict.wrong);
    });

    testWidgets('the key pages dialog applies a choice and resets', (
      tester,
    ) async {
      bigScreen(tester);
      late NoteFixture n;
      late GradeController c;
      await tester.runAsync(() async {
        n = await NoteFixture.create([
          questionPage(questions(count: 3)),
          keyPage('BCA'.split('')),
        ]);
        n.circle(0, 3, 'A');
        c = GradeController(n.coreInfo, store: store, runJob: inlineRunner);
        await c.grade();
      });
      addTearDown(() => n.dispose());
      expect(c.result!.keyStatus, KeyStatus.unknown);
      await tester.pumpWidget(sheetHost(c));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(GradingStrings.keyPages));
      await tester.tap(find.text(GradingStrings.keyPages));
      await tester.pumpAndSettle();
      expect(find.text(GradingStrings.keyPagesTitle), findsOneWidget);
      expect(find.text('Page 2'), findsOneWidget);
      await tester.tap(find.text('Page 2'));
      await tester.pump();
      await tester.tap(find.text(GradingStrings.apply));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pumpAndSettle();
      expect(c.keyOverride, const KeyOverride({1}));
      expect(c.result!.keyStatus, KeyStatus.found);
      expect(c.result!.grade(3)!.verdict, Verdict.correct);

      // Reset to automatic.
      await tester.ensureVisible(find.text(GradingStrings.keyPages));
      await tester.tap(find.text(GradingStrings.keyPages));
      await tester.pumpAndSettle();
      await tester.tap(find.text(GradingStrings.resetToAutomatic));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pumpAndSettle();
      expect(c.keyOverride, isNull);
      expect(c.result!.keyStatus, KeyStatus.unknown);
    });
  });

  test('summary text', () {
    GradeResult r(List<Verdict> v) => GradeResult(
      keyStatus: KeyStatus.found,
      keyDetection: const KeyDetection.unknown(),
      grades: [
        for (var i = 0; i < v.length; i++)
          QuestionGrade(
            testIndex: 0,
            number: i + 1,
            pageIndex: 0,
            verdict: v[i],
            confidence: Confidence.high,
            anchorInNote: Rect.zero,
          ),
      ],
    );
    const v = Verdict.values;
    expect(
      GradingStrings.summary(
        r([for (var i = 0; i < 17; i++) v[0], v[1], v[2], v[2], v[3]]),
      ),
      '17/21 correct, 2 unsure, 1 unanswered',
    );
    expect(GradingStrings.summary(r([v[0], v[0]])), '2/2 correct');
    expect(GradingStrings.summary(r([])), '0/0 correct');
  });
}
