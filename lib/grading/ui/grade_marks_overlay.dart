import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/grading/corrections.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/models.dart';
import 'package:saber/grading/ui/grade_controller.dart';
import 'package:saber/grading/ui/mark_placement.dart';
import 'package:saber/grading/ui/question_detail_sheet.dart';

/// The marks of one page, drawn over it (put it in a [Stack] above the
/// page's canvas; it sits inside the page's box, so it follows zoom and
/// scroll).
///
/// While nothing has been graded (or marks are hidden) it builds to
/// [SizedBox.shrink] and adds no hit-testable area: normal writing is
/// unaffected.
///
/// POINTER SAFETY: everything painted is under [IgnorePointer]. The only
/// widgets that take pointers are the small tap targets over the marks, and
/// they accept finger and mouse only, so a stylus never enters their gesture
/// arena and pen strokes pass over marks unaffected.
class GradeMarksOverlay extends StatelessWidget {
  const new({super.key, required this.coreInfo, required this.pageIndex});

  final EditorCoreInfo coreInfo;
  final int pageIndex;

  @override
  Widget build(BuildContext context) {
    final controller = GradeController.of(coreInfo);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.overlayActive) return const SizedBox.shrink();
        return _PageOverlay(controller: controller, pageIndex: pageIndex);
      },
    );
  }
}

/// Puts the marks overlay of a page above [this] (the page's canvas) in a
/// [Stack]. Used as `InnerCanvas(...).withGradeMarks(...)` in `canvas.dart`,
/// so that upstream's code stays as it was apart from this one call.
extension GradeMarksOnCanvas on Widget {
  Widget withGradeMarks({
    required EditorCoreInfo coreInfo,
    required int pageIndex,
  }) => Stack(
    children: [
      this,
      GradeMarksOverlay(coreInfo: coreInfo, pageIndex: pageIndex),
    ],
  );
}

/// Devices that may tap a mark. Not the stylus.
const markTapDevices = {PointerDeviceKind.touch, PointerDeviceKind.mouse};

class _PageOverlay extends StatelessWidget {
  const new({required this.controller, required this.pageIndex});

  final GradeController controller;
  final int pageIndex;

  @override
  Widget build(BuildContext context) {
    final outcome = controller.outcome!;
    final page = controller.pages.where((p) => p.pageIndex == pageIndex);
    if (page.isEmpty) return const SizedBox.shrink();
    final pageSize = page.first.noteSize;
    final grades = [
      for (final g in outcome.result.grades)
        if (g.pageIndex == pageIndex) g,
    ];
    final selected = controller.selected;
    return Positioned.fill(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (controller.marksVisible || selected != null)
            IgnorePointer(
              child: CustomPaint(
                size: Size.infinite,
                painter: MarksPainter(
                  grades: controller.marksVisible ? grades : const [],
                  outcome: outcome,
                  pageSize: pageSize,
                  selected: selected,
                  pageIndex: pageIndex,
                ),
              ),
            ),
          if (controller.debug)
            IgnorePointer(
              child: CustomPaint(
                size: Size.infinite,
                painter: DebugPainter(
                  outcome: outcome,
                  pageIndex: pageIndex,
                  debug: controller.debugFor(pageIndex),
                ),
              ),
            ),
          if (controller.marksVisible)
            for (final g in grades)
              Positioned.fromRect(
                rect: markRect(
                  pageSize: pageSize,
                  anchor: g.anchorInNote,
                ).inflate(6),
                child: GestureDetector(
                  supportedDevices: markTapDevices,
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    final id = (g.testIndex, g.number);
                    controller.select(id);
                    showQuestionDetail(context, controller, id);
                  },
                ),
              ),
        ],
      ),
    );
  }
}

const _green = Color(0xFF2E7D32);
const _red = Color(0xFFD32F2F);
const _amber = Color(0xFFF9A825);
const _gray = Color(0xFF757575);
const _blue = Color(0xFF1565C0);

void _paintText(
  Canvas canvas,
  String text,
  Offset at, {
  required Color color,
  required double size,
  bool bold = false,
  bool rightAligned = false,
  Color? background,
}) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: size,
        fontWeight: bold ? FontWeight.bold : FontWeight.w500,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final origin = rightAligned ? at - Offset(tp.width, 0) : at;
  if (background != null) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        (origin & tp.size).inflate(1.5),
        const Radius.circular(3),
      ),
      Paint()..color = background,
    );
  }
  tp.paint(canvas, origin);
}

/// Draws the check, cross, "?" or dot beside each question, and the
/// highlight of the selected question.
class MarksPainter extends CustomPainter {
  new({
    required this.grades,
    required this.outcome,
    required this.pageSize,
    required this.selected,
    required this.pageIndex,
  });

  final List<QuestionGrade> grades;
  final GradingOutcome outcome;
  final Size pageSize;
  final QuestionId? selected;
  final int pageIndex;

  @override
  void paint(Canvas canvas, Size size) {
    for (final g in grades) {
      final r = markRect(pageSize: pageSize, anchor: g.anchorInNote);
      _paintMark(canvas, r, g);
    }
    final id = selected;
    if (id != null) {
      final q = outcome.questions[id];
      if (q != null && q.question.pageIndex == pageIndex) {
        final grade = outcome.result.grade(id.$2, testIndex: id.$1);
        canvas.drawRect(
          q.question.region.inflate(4),
          Paint()
            ..color = _blue
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5,
        );
        final letter = grade?.detectedLetter;
        final option = letter == null ? null : q.question.option(letter);
        if (option != null) {
          canvas.drawRect(
            option.box.inflate(3),
            Paint()..color = _blue.withValues(alpha: 0.18),
          );
          canvas.drawRect(
            option.box.inflate(3),
            Paint()
              ..color = _blue
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2,
          );
        }
      }
    }
  }

  void _paintMark(Canvas canvas, Rect r, QuestionGrade g) {
    final c = r.center;
    final radius = r.width / 2;
    final fill = Paint();
    final line = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = r.width * 0.11
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (g.verdict) {
      case Verdict.correct:
        canvas.drawCircle(c, radius, fill..color = _green);
        canvas.drawPath(
          Path()
            ..moveTo(c.dx - radius * 0.45, c.dy + radius * 0.02)
            ..lineTo(c.dx - radius * 0.12, c.dy + radius * 0.35)
            ..lineTo(c.dx + radius * 0.5, c.dy - radius * 0.35),
          line,
        );
      case Verdict.wrong:
        canvas.drawCircle(c, radius, fill..color = _red);
        final d = radius * 0.4;
        canvas
          ..drawLine(c + Offset(-d, -d), c + Offset(d, d), line)
          ..drawLine(c + Offset(-d, d), c + Offset(d, -d), line);
        final key = g.keyAnswer;
        if (key != null) {
          // The correct letter, under the cross.
          _paintText(
            canvas,
            key,
            Offset(c.dx, r.bottom + 1),
            color: _red,
            size: r.width * 0.7,
            bold: true,
            background: Colors.white.withValues(alpha: 0.85),
          );
        }
      case Verdict.unsure:
        canvas.drawCircle(c, radius, fill..color = _amber);
        final tp = TextPainter(
          text: TextSpan(
            text: '?',
            style: TextStyle(
              color: Colors.white,
              fontSize: r.width * 0.8,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
      case Verdict.unanswered:
        canvas.drawCircle(c, radius * 0.3, fill..color = _gray);
    }
    if (g.corrected) {
      // A small blue dot: edited by the user.
      final dot = Offset(r.right - radius * 0.15, r.top + radius * 0.15);
      canvas
        ..drawCircle(dot, radius * 0.3, Paint()..color = Colors.white)
        ..drawCircle(dot, radius * 0.2, Paint()..color = _blue);
    }
  }

  @override
  bool shouldRepaint(MarksPainter old) =>
      old.outcome != outcome ||
      old.selected != selected ||
      old.pageSize != pageSize ||
      old.grades.length != grades.length;
}

/// The debug overlay: what the grader found on the page and what it did with
/// each stroke.
class DebugPainter extends CustomPainter {
  new({required this.outcome, required this.pageIndex, required this.debug});

  final GradingOutcome outcome;
  final int pageIndex;
  final PageDebug debug;

  static const palette = [
    Color(0xFFE53935),
    Color(0xFF8E24AA),
    Color(0xFF1E88E5),
    Color(0xFF00897B),
    Color(0xFFF4511E),
    Color(0xFF6D4C41),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    Paint stroke(Color c, [double w = 1.5]) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = w;

    // Page badge.
    _paintText(
      canvas,
      debug.badge,
      const Offset(6, 4),
      color: Colors.black,
      size: 16,
      bold: true,
      background: Colors.white.withValues(alpha: 0.85),
    );

    if (debug.isKey) {
      canvas
        ..drawRect(
          Offset.zero & size,
          Paint()..color = _amber.withValues(alpha: 0.1),
        )
        ..drawRect(Offset.zero & size, stroke(_amber, 5));
    }
    // Key entries of a key page, or of the key line on a question page.
    for (final e in debug.keyEntries) {
      final r = e.rect.inflate(2);
      canvas.drawRect(r, stroke(const Color(0xFF6A1B9A)));
      _paintText(
        canvas,
        e.text,
        Offset(r.right + 4, r.top),
        color: const Color(0xFF6A1B9A),
        size: 13,
        bold: true,
        background: Colors.white.withValues(alpha: 0.8),
      );
    }

    final ink = outcome.pages[pageIndex];
    if (ink == null) return;
    for (var i = 0; i < ink.questions.length; i++) {
      final q = ink.questions[i];
      final colour = palette[i % palette.length];
      canvas
        ..drawRect(q.region.inflate(3), stroke(colour))
        ..drawRect(
          q.numberRect,
          Paint()..color = colour.withValues(alpha: 0.25),
        )
        ..drawRect(q.numberRect, stroke(colour));
      _paintText(
        canvas,
        'Q${q.number}${q.continuedFromPage == null ? '' : ' (from p${q.continuedFromPage! + 1})'}',
        Offset(q.region.left, q.region.top - 17),
        color: colour,
        size: 13,
        bold: true,
        background: Colors.white.withValues(alpha: 0.8),
      );
      for (final o in q.options) {
        canvas
          ..drawRect(o.box, stroke(_green, 1.2))
          ..drawRect(
            o.labelRect,
            Paint()..color = _amber.withValues(alpha: 0.35),
          )
          ..drawRect(o.labelRect, stroke(const Color(0xFFEF6C00), 1));
        _paintText(
          canvas,
          o.letter,
          Offset(max(0, o.box.left - 4), o.box.top - 1),
          color: const Color(0xFFAD1457),
          size: 14,
          bold: true,
          rightAligned: true,
          background: Colors.white.withValues(alpha: 0.8),
        );
      }
    }
    for (var s = 0; s < ink.strokes.length; s++) {
      final stroke0 = ink.strokes[s];
      final c = ink.classes[s];
      final qi = c.questionIndex;
      final colour = qi == null ? _gray : palette[qi % palette.length];
      final bounds = stroke0.bounds;
      canvas
        ..drawRect(bounds, Paint()..color = colour.withValues(alpha: 0.12))
        ..drawRect(bounds, stroke(colour, 1));
      final qn = qi == null ? '-' : 'Q${ink.questions[qi].number}';
      _paintText(
        canvas,
        '$qn ${c.kind.name}',
        bounds.bottomLeft + const Offset(0, 1),
        color: colour,
        size: 11,
        bold: true,
        background: Colors.white.withValues(alpha: 0.8),
      );
    }
  }

  @override
  bool shouldRepaint(DebugPainter old) =>
      old.outcome != outcome ||
      old.pageIndex != pageIndex ||
      old.debug != debug;
}
