import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:saber/grading/grader.dart';
import 'package:saber/grading/models.dart';
import 'package:saber/grading/ui/grade_controller.dart';
import 'package:saber/grading/ui/grade_range_dialog.dart';
import 'package:saber/grading/ui/grading_strings.dart';
import 'package:saber/grading/ui/key_pages_dialog.dart';
import 'package:saber/grading/ui/question_detail_sheet.dart';
import 'package:share_plus/share_plus.dart';

/// The results sheet: summary, every question, key diagnostics and actions.
Future<void> showResultsSheet(
  BuildContext context,
  GradeController controller,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.7,
    minChildSize: 0.35,
    maxChildSize: 0.95,
    builder: (context, scroll) =>
        ResultsSheet(controller: controller, scrollController: scroll),
  ),
);

class ResultsSheet extends StatelessWidget {
  const new({
    super.key,
    required this.controller,
    required this.scrollController,
  });

  final GradeController controller;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final outcome = controller.outcome;
        if (outcome == null) {
          return const Center(child: Text(GradingStrings.noQuestions));
        }
        final result = controller.result!;
        final earlier = controller.earlierGrades;
        final analysis = outcome.analysis;
        final detection = analysis.detection;
        final t = controller.timings;
        final theme = Theme.of(context);
        return ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Text(GradingStrings.results, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              result.grades.isEmpty
                  ? GradingStrings.noQuestions
                  : GradingStrings.fullSummary(
                      result,
                      range: controller.latestRange,
                      pageCount: controller.pageCount,
                    ),
            ),
            if (t != null)
              Text(
                'Read the PDF text in ${t.extraction.inMilliseconds} ms, '
                'graded in ${t.grading.inMilliseconds} ms.',
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(height: 12),
            Text(GradingStrings.keyStatusText(result, analysis.pairingProblem)),
            if (detection.blocks.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  [
                    for (var i = 0; i < detection.blocks.length; i++)
                      'Key block ${i + 1}: '
                          '${detection.blocks[i].samePage ? 'key line on page ${detection.blocks[i].firstKeyPage + 1}' : 'pages ${detection.blocks[i].firstKeyPage + 1}-${detection.blocks[i].lastKeyPage + 1}'}, '
                          '${detection.blocks[i].answers.length} entries',
                  ].join('\n'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: controller.status == GradeStatus.running
                      ? null
                      : () => controller.grade(range: controller.latestRange),
                  child: const Text(GradingStrings.gradeAgain),
                ),
                FilledButton.tonal(
                  onPressed: controller.status == GradeStatus.running
                      ? null
                      : () => showGradeRangeDialog(context, controller),
                  child: const Text(GradingStrings.gradeMore),
                ),
                OutlinedButton(
                  onPressed: () =>
                      controller.setMarksVisible(!controller.marksVisible),
                  child: Text(
                    controller.marksVisible
                        ? GradingStrings.hideMarks
                        : GradingStrings.showMarks,
                  ),
                ),
                OutlinedButton(
                  onPressed: () => showKeyPagesDialog(context, controller),
                  child: const Text(GradingStrings.keyPages),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.share),
                  onPressed: () => SharePlus.instance.share(
                    ShareParams(
                      text: controller.report(),
                      subject: 'Grading report',
                    ),
                  ),
                  label: const Text(GradingStrings.shareReport),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy),
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: controller.report()),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        const SnackBar(
                          content: Text(GradingStrings.reportCopied),
                        ),
                      );
                    }
                  },
                  label: const Text(GradingStrings.copyReport),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(GradingStrings.debugOverlay),
              value: controller.debug,
              onChanged: controller.setDebug,
            ),
            const Divider(),
            Text(GradingStrings.questions, style: theme.textTheme.titleMedium),
            for (final g in result.grades) _tile(context, g, analysis),
            if (earlier.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  '${GradingStrings.earlierPages} '
                  '(${GradingStrings.summary(GradeResult(keyStatus: result.keyStatus, keyDetection: result.keyDetection, grades: earlier))})',
                ),
                children: [
                  for (final g in earlier) _tile(context, g, analysis),
                ],
              ),
          ],
        );
      },
    );
  }
}

extension on ResultsSheet {
  Widget _tile(
    BuildContext context,
    QuestionGrade g,
    DocumentAnalysis analysis,
  ) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: _VerdictIcon(g.verdict),
    title: Text(
      'Question ${g.number}'
      '${analysis.tests.length > 1 ? ' (test ${g.testIndex + 1})' : ''}'
      ' - ${GradingStrings.verdict(g.verdict)}'
      '${g.corrected ? ' (${GradingStrings.editedBadge})' : ''}',
    ),
    subtitle: Text(
      'read ${g.detectedLetter ?? '-'}, key ${g.keyAnswer ?? '-'}'
      ', page ${g.pageIndex + 1}',
    ),
    trailing: const Icon(Icons.chevron_right),
    onTap: () =>
        showQuestionDetail(context, controller, (g.testIndex, g.number)),
  );
}

class _VerdictIcon extends StatelessWidget {
  const new(this.verdict);

  final Verdict verdict;

  @override
  Widget build(BuildContext context) => switch (verdict) {
    Verdict.correct => const Icon(Icons.check_circle, color: Color(0xFF2E7D32)),
    Verdict.wrong => const Icon(Icons.cancel, color: Color(0xFFD32F2F)),
    Verdict.unsure => const Icon(Icons.help, color: Color(0xFFF9A825)),
    Verdict.unanswered => const Icon(Icons.circle_outlined, color: Colors.grey),
  };
}
