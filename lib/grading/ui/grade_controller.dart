import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/version.dart';
import 'package:saber/grading/corrections.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/grader_service.dart';
import 'package:saber/grading/ink/coordinate_mapper.dart';
import 'package:saber/grading/key/key_page_detector.dart';
import 'package:saber/grading/models.dart';
import 'package:saber/grading/report.dart';
import 'package:saber/grading/sidecar_store.dart';
import 'package:saber/grading/ui/grading_strings.dart';

enum GradeStatus { idle, running, done, error }

/// Everything one grading run needs; plain data, so it can be sent to an
/// isolate.
class GradeJob {
  const new({
    required this.pages,
    required this.keyOverride,
    required this.corrections,
  });

  final List<GradingPage> pages;
  final KeyOverride? keyOverride;
  final List<Correction> corrections;
}

/// Runs [job]; the default runs it on another isolate.
typedef GradeJobRunner = Future<GradingOutcome> Function(GradeJob job);

Future<GradingOutcome> runJobInIsolate(GradeJob job) => Isolate.run(
  () => gradeDetailed(
    job.pages,
    keyOverride: job.keyOverride,
    corrections: job.corrections,
  ),
);

/// Maps note page indices to the page indices stored in the sidecar and back.
/// For a note with one PDF the stored index is the PDF's own page number, so
/// the choice survives inserting pages in the note and applies to a fresh
/// note of the same PDF; otherwise note indices are used as they are.
class PageIndexMap {
  const new(this.refs, {required this.single});

  final List<PdfPageRef> refs;

  /// All PDF pages come from one PDF.
  final bool single;

  int? toStored(int notePage) {
    if (!single) return notePage;
    for (final r in refs) {
      if (r.notePage == notePage) return r.pdfPage;
    }
    return null;
  }

  int? fromStored(int stored) {
    if (!single) return stored;
    for (final r in refs) {
      if (r.pdfPage == stored) return r.notePage;
    }
    return null;
  }
}

/// Note-space geometry for the debug overlay of one page.
class PageDebug {
  const new({
    required this.badge,
    required this.isKey,
    required this.keyEntries,
  });

  final String badge;
  final bool isKey;

  /// Parsed key entries (note coordinates) on a key page.
  final List<({Rect rect, String text})> keyEntries;
}

/// The grading state of one open note, shared by the app bar button and the
/// per-page overlays through [GradeController.of]. It is dropped with the
/// note (it hangs off the [EditorCoreInfo] instance), so marks vanish when the
/// note closes.
class GradeController extends ChangeNotifier {
  new(
    this.coreInfo, {
    GraderService? service,
    this._store,
    GradeJobRunner? runJob,
    String? buildInfo,
  }) : service = service ?? GraderService(),
       _runJob = runJob ?? runJobInIsolate,
       buildInfo = buildInfo ?? _defaultBuildInfo();

  static final _controllers = Expando<GradeController>('GradeController');

  /// The controller of the note [coreInfo], created on first use.
  // ignore: prefer_constructors_over_static_methods
  static GradeController of(EditorCoreInfo coreInfo) =>
      _controllers[coreInfo] ??= GradeController(coreInfo);

  /// Use [controller] for [coreInfo] (tests).
  static void register(EditorCoreInfo coreInfo, GradeController controller) =>
      _controllers[coreInfo] = controller;

  static String _defaultBuildInfo() =>
      'Saber $buildName ($buildNumber), ${defaultTargetPlatform.name}, '
      '${kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug'}';

  final EditorCoreInfo coreInfo;
  final GraderService service;
  final String buildInfo;
  final GradeJobRunner _runJob;
  SidecarStore? _store;
  var _storeFailed = false;

  GradeStatus status = GradeStatus.idle;

  /// Pages whose text was read so far, and in total, while running.
  var doneCount = 0, totalCount = 0;
  String? error;

  GradingOutcome? outcome;
  List<GradingPage> pages = const [];
  GradingTimings? timings;

  /// The user's key choice, in note page indices.
  KeyOverride? keyOverride;
  List<Correction> corrections = const [];

  /// Marks are drawn on the pages (the sheet can hide them).
  var marksVisible = true;
  var debug = false;
  QuestionId? selected;

  String? _docId;
  var _indexMap = const PageIndexMap([], single: false);
  final _debugCache = <int, PageDebug>{};

  bool get hasResults => outcome != null;
  GradeResult? get result => outcome?.result;

  /// Whether the overlay has anything to draw.
  bool get overlayActive =>
      outcome != null && (marksVisible || debug || selected != null);

  Future<SidecarStore?> _getStore() async {
    if (_store != null || _storeFailed) return _store;
    try {
      _store = await SidecarStore.appDefault();
    } catch (_) {
      _storeFailed = true;
    }
    return _store;
  }

  /// Reads the note and grades it. Never throws: failures end up in
  /// [error].
  Future<void> grade() async {
    if (status == GradeStatus.running) return;
    status = GradeStatus.running;
    error = null;
    doneCount = 0;
    totalCount = 0;
    notifyListeners();
    try {
      final notePages = coreInfo.pages;
      final refs = GraderService.pdfPages(notePages);
      if (refs.isEmpty) {
        throw StateError(GradingStrings.noPdfPages);
      }

      final extraction = Stopwatch()..start();
      final collected = await service.collectPages(
        notePages,
        onProgress: (done, total) {
          doneCount = done;
          totalCount = total;
          notifyListeners();
        },
      );
      final doc = await service.documentId(notePages);
      _indexMap = PageIndexMap(refs, single: doc.single);
      await _loadSidecar(doc.id);
      extraction.stop();

      final run = Stopwatch()..start();
      final job = GradeJob(
        pages: collected,
        keyOverride: keyOverride,
        corrections: corrections,
      );
      final out = await _runJob(job);
      run.stop();

      pages = collected;
      outcome = out;
      timings = GradingTimings(
        extraction: extraction.elapsed,
        grading: run.elapsed,
      );
      _debugCache.clear();
      selected = null;
      status = GradeStatus.done;
    } catch (e) {
      error = GradingStrings.errorText(e);
      status = GradeStatus.error;
    }
    notifyListeners();
  }

  Future<void> _loadSidecar(String? id) async {
    if (id == null || id == _docId) return;
    _docId = id;
    final store = await _getStore();
    if (store == null) return;
    final data = await store.load(id);
    keyOverride = data.keyOverride?.mapPages(_indexMap.fromStored);
    corrections = data.corrections;
  }

  Future<void> _regrade() async {
    if (pages.isEmpty) return;
    final run = Stopwatch()..start();
    try {
      outcome = await _runJob(
        GradeJob(
          pages: pages,
          keyOverride: keyOverride,
          corrections: corrections,
        ),
      );
      run.stop();
      timings = GradingTimings(
        extraction: timings?.extraction ?? Duration.zero,
        grading: run.elapsed,
      );
      _debugCache.clear();
    } catch (e) {
      error = GradingStrings.errorText(e);
    }
    notifyListeners();
  }

  /// Sets (or with null resets) the key pages and grades again.
  Future<void> setKeyOverride(KeyOverride? override) async {
    keyOverride = override;
    final id = _docId;
    final store = await _getStore();
    if (id != null && store != null) {
      await store.saveKeyOverride(id, override?.mapPages(_indexMap.toStored));
    }
    await _regrade();
  }

  /// The user says question [id] was answered with [letter].
  Future<void> setCorrection(QuestionId id, String letter) async {
    final q = outcome?.questions[id];
    if (q == null) return;
    final c = Correction(
      testIndex: id.$1,
      number: id.$2,
      letter: letter,
      signature: q.signature,
    );
    corrections = [
      for (final x in corrections)
        if (x.id != id) x,
      c,
    ];
    final docId = _docId;
    final store = await _getStore();
    if (docId != null && store != null) await store.setCorrection(docId, c);
    await _regrade();
  }

  Future<void> clearCorrection(QuestionId id) async {
    corrections = [
      for (final x in corrections)
        if (x.id != id) x,
    ];
    final docId = _docId;
    final store = await _getStore();
    if (docId != null && store != null) await store.clearCorrection(docId, id);
    await _regrade();
  }

  void select(QuestionId? id) {
    selected = id;
    notifyListeners();
  }

  void setDebug(bool value) {
    debug = value;
    notifyListeners();
  }

  void setMarksVisible(bool value) {
    marksVisible = value;
    notifyListeners();
  }

  /// Diagnostics of [pageIndex] for the debug overlay.
  PageDebug debugFor(int pageIndex) =>
      _debugCache[pageIndex] ??= _buildDebug(pageIndex);

  PageDebug _buildDebug(int pageIndex) {
    final out = outcome!;
    final page = pages.where((p) => p.pageIndex == pageIndex).firstOrNull;
    final label = 'p${pageIndex + 1}';
    if (page == null)
      return PageDebug(
        badge: '$label: no PDF',
        isKey: false,
        keyEntries: const [],
      );
    final detection = out.analysis.detection;
    if (detection.keyPages.contains(pageIndex)) {
      final block = [
        for (var i = 0; i < detection.blocks.length; i++)
          if (pageIndex >= detection.blocks[i].firstKeyPage &&
              pageIndex <= detection.blocks[i].lastKeyPage)
            i + 1,
      ];
      final mapper = PageMapper(
        pdfSize: page.text.pdfSize,
        noteSize: page.noteSize,
      );
      final stats = KeyPageDetector.analyze(
        pageIndex,
        page.text,
        lenient: keyOverride?.keyPages.contains(pageIndex) ?? false,
      );
      return PageDebug(
        badge:
            '$label: key page, block ${block.join('+')}, '
            'conf ${detection.confidence.toStringAsFixed(2)}',
        isKey: true,
        keyEntries: [
          for (final e in stats.entries)
            if (e.rect != null)
              (
                rect: mapper.rectToNote(e.rect!),
                text: '${e.number}=${e.letter}',
              ),
        ],
      );
    }
    final n = out.analysis.questionsByPage[pageIndex]?.length ?? 0;
    return PageDebug(
      badge: !page.text.hasText
          ? '$label: no text layer'
          : '$label: $n question${n == 1 ? '' : 's'}',
      isKey: false,
      keyEntries: const [],
    );
  }

  /// The grading report text (see [buildGradingReport]).
  String report() {
    final out = outcome;
    final t = timings;
    if (out == null || t == null) return '';
    return buildGradingReport(
      pages: pages,
      outcome: out,
      timings: t,
      keyOverride: keyOverride,
      buildInfo: buildInfo,
    );
  }
}
