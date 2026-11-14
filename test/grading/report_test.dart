import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/grading_config.dart';
import 'package:saber/grading/models.dart';
import 'package:saber/grading/report.dart';

import 'fixtures/pdf_fixtures.dart';
import 'fixtures/stroke_fixtures.dart';

const secrets = [
  'Zanzibar',
  'photosynthesis',
  'Mitochondria',
  'Beethoven',
  'confidential_exam',
  'Ludwigshafen',
];

void main() {
  setUpAll(initPdfrx);

  Future<(FxDoc, String)> reportFor({bool withInk = true}) async {
    final qs = [
      for (var i = 0; i < 4; i++)
        QSpec(i + 1, 'Where is Zanzibar number ${i + 1}?', [
          'photosynthesis',
          'Beethoven',
          'Mitochondria',
          'Ludwigshafen',
        ]),
    ];
    final doc = await FxDoc.open([
      questionPage(qs),
      keyPageFromLines([
        '1) B because Mitochondria are the powerhouse',
        '2) C Beethoven wrote nine symphonies',
        '3) A photosynthesis happens in leaves',
        '4) D Zanzibar is an island',
        '5) B Ludwigshafen',
      ]),
    ], name: 'confidential_exam.pdf');
    addTearDown(doc.dispose);
    final strokes = withInk
        ? {
            0: [
              ink(circleAround(doc.labelRect(0, 1, 'B'))),
              ink(circleAround(doc.labelRect(0, 2, 'A'))),
              ink(tickBeside(doc.labelRect(0, 3, 'A'))),
              ink(circleAround(const Rect.fromLTWH(850, 40, 30, 30))),
            ],
          }
        : <int, List<InkStroke>>{};
    final pages = doc.gradingPages(strokes);
    const override = KeyOverride({1});
    final outcome = gradeDetailed(pages, keyOverride: override);
    final report = buildGradingReport(
      pages: pages,
      outcome: outcome,
      timings: const GradingTimings(
        extraction: Duration(milliseconds: 12),
        grading: Duration(milliseconds: 34),
      ),
      keyOverride: override,
      buildInfo: 'Saber 1.37.2 (test)',
    );
    return (doc, report);
  }

  test('the report has the expected sections and numbers', () async {
    final (_, report) = await reportFor();
    printOnFailure(report);
    expect(report, contains('build: Saber 1.37.2 (test)'));
    expect(
      report,
      contains('text extraction 12 ms, grading 34 ms, total 46 ms'),
    );
    expect(report, contains('PAGES: 2'));
    expect(report, contains('page 1: text layer'));
    expect(report, contains('4 question(s)'));
    expect(report, contains('page 2: text layer'));
    expect(report, contains('KEY PAGE'));
    expect(report, contains('rotation 0'));
    expect(report, contains('strokes 4 (gradable 4, ignored 0, unassigned 1)'));
    expect(report, contains('KEY: chosen by the user'));
    expect(report, contains('status found'));
    expect(report, contains('PAIRING: ok'));
    expect(report, contains('test 1 #1 page 1: options ABCD, read B (ring'));
    expect(report, contains('key B, correct'));
    expect(report, contains('test 1 #2 page 1: options ABCD, read A'));
    expect(report, contains('key C, wrong'));
    expect(report, contains('read A (tick'));
    expect(
      report,
      contains('totals: correct 2, wrong 1, unsure 0, unanswered 1'),
    );
    expect(report, contains('SUSPICIOUS:'));
    expect(
      report,
      contains('key block 1: entries with no located question: 5'),
    );
    expect(report, contains('CONFIG:'));
    expect(
      report,
      contains('ringMinCoverage = ${GradingConfig.ringMinCoverage}'),
    );
  });

  test('PRIVACY: no document text, file names or coordinates', () async {
    final (_, report) = await reportFor();
    for (final secret in secrets) {
      expect(
        report.toLowerCase(),
        isNot(contains(secret.toLowerCase())),
        reason: secret,
      );
    }
    expect(report, isNot(contains('.pdf')));
    expect(report, isNot(contains('/')), reason: 'no paths');
    expect(report, isNot(contains('Rect')));
    expect(report, isNot(contains('Offset')));
    // Every line holds only fixed words, numbers, letters and enum names:
    // no sentence of the document (stems have "Where is" in them).
    expect(report, isNot(contains('Where')));
    // No stroke coordinates: the circle around option B of question 1 is
    // centred where the located label is; none of its coordinates (rounded)
    // appear as "x, y" pairs.
    expect(RegExp(r'\d+\.\d+, \d+\.\d+').hasMatch(report), isFalse);
  });

  test('a document without a text layer or key still reports', () async {
    final doc = await FxDoc.open([blankPage()]);
    addTearDown(doc.dispose);
    final pages = doc.gradingPages({});
    final report = buildGradingReport(
      pages: pages,
      outcome: gradeDetailed(pages),
      timings: const GradingTimings(
        extraction: Duration.zero,
        grading: Duration.zero,
      ),
    );
    expect(report, contains('NO text layer'));
    expect(report, contains('PAIRING: FAILED: no key pages found'));
    expect(report, contains('none located'));
  });

  test('every GradingConfig constant is in the report', () {
    final source = File('lib/grading/grading_config.dart').readAsStringSync();
    final declared = RegExp(r'static const (?:[\w<>]+ )?\w+ =')
        .allMatches(source)
        .length;
    expect(GradingConfig.all, hasLength(declared));
  });
}
