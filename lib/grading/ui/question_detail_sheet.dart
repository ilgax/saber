import 'package:material_ui/material_ui.dart';
import 'package:saber/grading/corrections.dart';
import 'package:saber/grading/ui/grade_controller.dart';
import 'package:saber/grading/ui/grading_strings.dart';

/// Shows what the grader read for question [id], with buttons to correct it.
Future<void> showQuestionDetail(
  BuildContext context,
  GradeController controller,
  QuestionId id,
) async {
  controller.select(id);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => QuestionDetailSheet(controller: controller, id: id),
  );
  if (controller.selected == id) controller.select(null);
}

class QuestionDetailSheet extends StatelessWidget {
  const new({super.key, required this.controller, required this.id});

  final GradeController controller;
  final QuestionId id;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final outcome = controller.outcome;
        final grade = outcome?.result.grade(id.$2, testIndex: id.$1);
        final q = outcome?.questions[id];
        if (grade == null || q == null) {
          return const SafeArea(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('This question is no longer in the results.'),
            ),
          );
        }
        final tests = outcome!.analysis.tests.length;
        final theme = Theme.of(context);
        final read = grade.detectedLetter;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Question ${grade.number}',
                  style: theme.textTheme.titleLarge,
                ),
                Text(
                  'Page ${grade.pageIndex + 1}'
                  '${tests > 1 ? ', test ${grade.testIndex + 1}' : ''}'
                  '${q.question.continuedFromPage == null ? '' : ' (question text on page ${q.question.continuedFromPage! + 1})'}',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                _row('Result', GradingStrings.verdict(grade.verdict)),
                _row(
                  'What I read',
                  read == null
                      ? 'no answer'
                      : grade.corrected
                      ? '$read (set by you)'
                      : '$read, ${GradingStrings.inkKind(grade.readKind)}, '
                            '${GradingStrings.confidence(grade.confidence)} confidence',
                ),
                _row('Answer key', grade.keyAnswer ?? 'not known'),
                _row(
                  'Ink',
                  '${q.strokeCount} stroke${q.strokeCount == 1 ? '' : 's'} in this question',
                ),
                if (grade.reason != null) ...[
                  const SizedBox(height: 8),
                  Text(GradingStrings.reason(grade.reason)),
                ],
                const SizedBox(height: 16),
                Text('Set my answer to', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final o in q.question.options)
                      FilledButton.tonal(
                        onPressed: () => controller.setCorrection(id, o.letter),
                        child: Text('Set my answer to ${o.letter}'),
                      ),
                    if (grade.corrected)
                      OutlinedButton(
                        onPressed: () => controller.clearCorrection(id),
                        child: const Text(GradingStrings.clearCorrection),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );
}
