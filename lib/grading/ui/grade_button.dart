import 'package:material_ui/material_ui.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/grading/ui/grade_controller.dart';
import 'package:saber/grading/ui/grading_strings.dart';
import 'package:saber/grading/ui/results_sheet.dart';

/// App bar button: grades the open note; afterwards a chip with the summary
/// that opens the results sheet. Long-press toggles the debug overlay.
class GradeButton extends StatelessWidget {
  const new({super.key, required this.coreInfo});

  final EditorCoreInfo coreInfo;

  @override
  Widget build(BuildContext context) {
    final controller = GradeController.of(coreInfo);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        switch (controller.status) {
          case GradeStatus.running:
            final total = controller.totalCount;
            return Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  value: total == 0 ? null : controller.doneCount / total,
                ),
              ),
            );
          case GradeStatus.done:
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: GestureDetector(
                onLongPress: () => controller.setDebug(!controller.debug),
                child: ActionChip(
                  avatar: Icon(
                    controller.debug ? Icons.bug_report : Icons.grading,
                    size: 18,
                  ),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(
                      GradingStrings.summary(controller.result!),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  onPressed: () => showResultsSheet(context, controller),
                ),
              ),
            );
          case GradeStatus.idle:
          case GradeStatus.error:
            final failed = controller.status == GradeStatus.error;
            return Tooltip(
              message: failed
                  ? controller.error ?? GradingStrings.gradeTooltip
                  : GradingStrings.gradeTooltip,
              // The long press is ours (debug overlay), not the tooltip's.
              triggerMode: TooltipTriggerMode.manual,
              child: Semantics(
                button: true,
                label: GradingStrings.grade,
                child: InkResponse(
                  radius: 24,
                  onLongPress: () => controller.setDebug(!controller.debug),
                  onTap: () async {
                    await controller.grade();
                    if (!context.mounted) return;
                    if (controller.status == GradeStatus.error) {
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        SnackBar(content: Text(controller.error ?? '')),
                      );
                    } else if (controller.hasResults) {
                      showResultsSheet(context, controller);
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Icon(failed ? Icons.error_outline : Icons.grading),
                  ),
                ),
              ),
            );
        }
      },
    );
  }
}
