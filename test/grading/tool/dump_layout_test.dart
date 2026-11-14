// Real-PDF layout dump: shows what the grader core detects in a PDF, as a
// text report and annotated page images. Skipped unless GRADER_PDF is set.
// See PHASE2.md ("Real-PDF layout dump") for how to run it.
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/grading/diagnostics.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/ink/coordinate_mapper.dart';
import 'package:saber/grading/key/key_page_detector.dart';
import 'package:saber/grading/layout/text_extractor.dart';
import 'package:saber/grading/models.dart';

const _fontFamily = 'GraderDump';
const _fontAsset =
    'assets/google_fonts/Atkinson_Hyperlegible_Next/AtkinsonHyperlegibleNext-SemiBold.ttf';

/// Width of the note page the grader works on (EditorPage.defaultWidth).
const _noteWidth = 1000.0;

void main() {
  final env = Platform.environment;
  final pdfPath = env['GRADER_PDF'];

  test(
    'dump layout of GRADER_PDF',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final file = File(pdfPath!);
      if (!file.existsSync()) fail('GRADER_PDF does not exist: $pdfPath');
      final scale = double.tryParse(env['GRADER_SCALE'] ?? '') ?? 2;
      final base = file.uri.pathSegments.last.replaceFirst(
        RegExp(r'\.pdf$', caseSensitive: false),
        '',
      );
      final outDir = Directory(
        env['GRADER_OUT'] ??
            '${Directory.systemTemp.path}${Platform.pathSeparator}grader_dump_$base',
      )..createSync(recursive: true);

      final keyPages = <int>{
        for (final s in (env['GRADER_KEY_PAGES'] ?? '').split(','))
          if (int.tryParse(s.trim()) != null) int.parse(s.trim()) - 1,
      };
      final override = keyPages.isEmpty ? null : KeyOverride(keyPages);

      await _loadFont();
      final tmp = await Directory.systemTemp.createTemp('pdfrx_dump');
      await pdfrxInitialize(tmpPath: tmp.path);
      final document = await PdfDocument.openFile(file.path);
      addTearDown(document.dispose);
      await document.loadPagesProgressively();

      // The real pipeline: text extraction, then the pure grader with no ink.
      final texts = <PageText>[];
      final pages = <GradingPage>[];
      for (var i = 0; i < document.pages.length; i++) {
        final text = await extractPageText(document.pages[i]);
        texts.add(text);
        pages.add(
          GradingPage(
            pageIndex: i,
            text: text,
            noteSize: Size(
              _noteWidth,
              _noteWidth * text.pdfSize.height / text.pdfSize.width,
            ),
            strokes: const [],
          ),
        );
      }
      final analysis = analyzeDocument(pages, keyOverride: override);
      final result = gradeDocument(pages, keyOverride: override);

      final report = _report(
        document: document,
        texts: texts,
        analysis: analysis,
        result: result,
        override: override,
      );
      File('${outDir.path}${Platform.pathSeparator}report.txt')
          .writeAsStringSync(report);

      for (var i = 0; i < pages.length; i++) {
        final png = await _renderPage(
          page: document.pages[i],
          grading: pages[i],
          analysis: analysis,
          scale: scale,
        );
        final name = 'page_${(i + 1).toString().padLeft(3, '0')}.png';
        File('${outDir.path}${Platform.pathSeparator}$name')
            .writeAsBytesSync(png);
      }

      // ignore: avoid_print
      print(report);
      // ignore: avoid_print
      print('\nOutput folder: ${outDir.absolute.path}');
    },
    skip: pdfPath == null
        ? 'set GRADER_PDF=<path to a PDF> to run the layout dump (see PHASE2.md)'
        : null,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

Future<void> _loadFont() async {
  final bytes = File(_fontAsset).readAsBytesSync();
  final loader = FontLoader(_fontFamily)
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}

// ------------------------------------------------------------------ report

String _report({
  required PdfDocument document,
  required List<PageText> texts,
  required DocumentAnalysis analysis,
  required GradeResult result,
  required KeyOverride? override,
}) {
  final b = StringBuffer();
  final detection = analysis.detection;
  final keyPages = detection.keyPages;
  b.writeln('PAGES: ${texts.length}');
  for (var i = 0; i < texts.length; i++) {
    final t = texts[i];
    final glyphs = t.tokens.fold<int>(0, (n, x) => n + x.text.length);
    final p = document.pages[i];
    b.writeln(
      '  page ${i + 1}: ${t.hasText ? 'text layer, $glyphs chars' : 'NO text layer'}'
      ', ${t.pdfSize.width.toStringAsFixed(0)} x '
      '${t.pdfSize.height.toStringAsFixed(0)} pt, rotation ${p.rotation.index * 90}'
      '${keyPages.contains(i) ? ', KEY PAGE' : ''}',
    );
  }

  b.writeln();
  b.writeln(
    'KEY: ${override == null ? 'automatic detection' : 'override, pages ${(override.keyPages.toList()..sort()).map((p) => p + 1).join(', ')}'}',
  );
  b.writeln(
    '  status ${detection.status.name}, confidence '
    '${detection.confidence.toStringAsFixed(2)}, ${detection.blocks.length} block(s)',
  );
  for (var i = 0; i < detection.blocks.length; i++) {
    final k = detection.blocks[i];
    final numbers = k.answers.keys.toList()..sort();
    b.writeln(
      '  block ${i + 1}: pages ${k.firstKeyPage + 1}-${k.lastKeyPage + 1}, '
      '${k.answers.length} entries, numbers ${numbers.first}-${numbers.last}',
    );
  }
  if (detection.blocks.isEmpty) {
    b.writeln(
      '  no page looks like a key. Per page (entries / longest run / coverage):',
    );
    for (var i = 0; i < texts.length; i++) {
      final s = KeyPageDetector.analyze(i, texts[i]);
      if (s.entries.isNotEmpty) {
        b.writeln(
          '    page ${i + 1}: ${s.entries.length} entries, run ${s.longestRun}, '
          'coverage ${s.coverage.toStringAsFixed(2)}',
        );
      }
    }
  } else if (detection.status == KeyStatus.unknown) {
    b.writeln('  not accepted: confidence is below the acceptance threshold');
  }

  b.writeln();
  b.writeln(
    'PAIRING: ${analysis.pairedBlocks != null ? 'ok, ${analysis.tests.length} test(s)' : 'FAILED: ${analysis.pairingProblem}'}',
  );
  final blocks = analysis.pairedBlocks;
  for (var t = 0; t < analysis.tests.length; t++) {
    final pagesOf =
        analysis.tests[t].map((q) => q.pageIndex + 1).toSet().toList()..sort();
    b.writeln(
      '  test ${t + 1} (pages ${pagesOf.join(', ')}): '
      '${blocks != null ? 'key block ${t + 1} (pages ${blocks[t].firstKeyPage + 1}-${blocks[t].lastKeyPage + 1})' : 'no key'}',
    );
  }

  b.writeln();
  b.writeln('QUESTIONS:');
  for (var t = 0; t < analysis.tests.length; t++) {
    for (final q in analysis.tests[t]) {
      final key = blocks?[t].answers[q.number];
      b.writeln(
        '  test ${t + 1} #${q.number} page ${q.pageIndex + 1}: options '
        '${q.options.map((o) => o.letter).join()} key ${key ?? '-'}',
      );
    }
  }
  if (analysis.tests.isEmpty) b.writeln('  none located');

  b.writeln();
  b.writeln('SUSPICIOUS:');
  final findings = suspiciousFindings(analysis, {
    for (var i = 0; i < texts.length; i++) i: texts[i],
  });
  for (final f in findings) {
    b.writeln('  - $f');
  }
  if (findings.isEmpty) b.writeln('  nothing');
  return b.toString();
}

// ------------------------------------------------------------------ images

Future<Uint8List> _renderPage({
  required PdfPage page,
  required GradingPage grading,
  required DocumentAnalysis analysis,
  required double scale,
}) async {
  final note = grading.noteSize;
  final mapper = PageMapper(pdfSize: grading.text.pdfSize, noteSize: note);
  final w = (note.width * scale).round(), h = (note.height * scale).round();
  final rendered = (await page.render(
    fullWidth: grading.text.pdfSize.width * mapper.scale * scale,
    fullHeight: grading.text.pdfSize.height * mapper.scale * scale,
  ))!;
  final background = await rendered.createImage();
  rendered.dispose();

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)..scale(scale);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, note.width, note.height),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  final topLeft = mapper.offset;
  canvas.drawImageRect(
    background,
    ui.Rect.fromLTWH(
      0,
      0,
      background.width.toDouble(),
      background.height.toDouble(),
    ),
    ui.Rect.fromLTWH(
      topLeft.dx,
      topLeft.dy,
      grading.text.pdfSize.width * mapper.scale,
      grading.text.pdfSize.height * mapper.scale,
    ),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  background.dispose();

  ui.Paint stroke(ui.Color c, [double width = 1.5]) => ui.Paint()
    ..color = c
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = width;
  ui.Paint fill(ui.Color c) => ui.Paint()..color = c;

  void text(
    String s,
    ui.Offset at,
    ui.Color c,
    double size, {
    bool right = false,
  }) {
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(fontFamily: _fontFamily, fontSize: size),
          )
          ..pushStyle(
            ui.TextStyle(color: c, fontFamily: _fontFamily, fontSize: size),
          )
          ..addText(s);
    final p = builder.build()
      ..layout(const ui.ParagraphConstraints(width: 400));
    final x = right ? at.dx - p.longestLine : at.dx;
    // White halo so the text stays readable over the page.
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(
        ui.Rect.fromLTWH(x - 1, at.dy - 1, p.longestLine + 2, p.height + 2),
        const ui.Radius.circular(2),
      ),
      fill(const ui.Color(0xCCFFFFFF)),
    );
    canvas.drawParagraph(p, ui.Offset(x, at.dy));
  }

  const blue = ui.Color(0xFF1565C0),
      red = ui.Color(0xFFD32F2F),
      green = ui.Color(0xFF2E7D32),
      orange = ui.Color(0xFFEF6C00),
      magenta = ui.Color(0xFFAD1457),
      purple = ui.Color(0xFF6A1B9A);

  final keyPages = analysis.detection.keyPages;
  final isKey = keyPages.contains(grading.pageIndex);
  var label = 'p${grading.pageIndex + 1}';
  if (isKey) {
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, note.width, note.height),
      fill(const ui.Color(0x20FFC107)),
    );
    canvas.drawRect(
      ui.Rect.fromLTWH(2, 2, note.width - 4, note.height - 4),
      stroke(const ui.Color(0xFFFFA000), 4),
    );
    label += ' KEY PAGE';
    final entries = KeyPageDetector.analyze(
      grading.pageIndex,
      grading.text,
    ).entries;
    for (final e in entries) {
      if (e.rect == null) continue;
      final r = mapper.rectToNote(e.rect!).inflate(2);
      canvas.drawRect(r, stroke(purple, 1.5));
      text(
        '${e.number}=${e.letter}',
        ui.Offset(r.right + 4, r.top),
        purple,
        13,
      );
    }
  }
  final questions = analysis.questionsByPage[grading.pageIndex] ?? const [];
  if (!isKey && questions.isEmpty) {
    label += grading.text.hasText
        ? ' (text, no questions)'
        : ' (NO text layer)';
  }
  for (final q0 in questions) {
    final q = q0.mapRects(mapper.rectToNote);
    canvas.drawRect(q.region.inflate(3), stroke(blue, 1.5));
    canvas.drawRect(q.numberRect, fill(const ui.Color(0x40D32F2F)));
    canvas.drawRect(q.numberRect, stroke(red, 1.5));
    text('Q${q.number}', ui.Offset(q.region.left, q.region.top - 18), red, 14);
    for (final o in q.options) {
      canvas.drawRect(o.box, stroke(green, 1.2));
      canvas.drawRect(o.labelRect, fill(const ui.Color(0x55EF6C00)));
      canvas.drawRect(o.labelRect, stroke(orange, 1));
      text(
        o.letter,
        ui.Offset(max(0, o.box.left - 4), o.box.top - 2),
        magenta,
        15,
        right: true,
      );
    }
  }
  text(label, const ui.Offset(6, 4), const ui.Color(0xFF000000), 16);

  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}
