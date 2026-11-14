import 'package:material_ui/material_ui.dart';
import 'package:saber/grading/grade_range.dart';
import 'package:saber/grading/ui/grade_controller.dart';
import 'package:saber/grading/ui/grading_strings.dart';

/// Asks which pages to grade (starting from the pages after the last graded
/// range) and grades them. Returns false, grading nothing, when the dialog is
/// cancelled.
Future<bool> showGradeRangeDialog(
  BuildContext context,
  GradeController controller,
) async {
  final initial = await controller.suggestedRange();
  if (!context.mounted) return false;
  final range = await showDialog<GradeRange>(
    context: context,
    builder: (context) =>
        GradeRangeDialog(pageCount: controller.pageCount, initial: initial),
  );
  if (range == null) return false;
  await controller.grade(range: range);
  return true;
}

/// The "Grade pages" dialog: From and To (1-based note page numbers). Pops
/// the chosen [GradeRange] (0-based).
class GradeRangeDialog extends StatefulWidget {
  const new({super.key, required this.pageCount, required this.initial});

  final int pageCount;
  final GradeRange initial;

  @override
  State<GradeRangeDialog> createState() => _GradeRangeDialogState();
}

class _GradeRangeDialogState extends State<GradeRangeDialog> {
  late final TextEditingController from;
  late final TextEditingController to;
  String? error;

  @override
  void initState() {
    super.initState();
    from = TextEditingController(text: '${widget.initial.from + 1}');
    to = TextEditingController(text: '${widget.initial.to + 1}');
  }

  @override
  void dispose() {
    from.dispose();
    to.dispose();
    super.dispose();
  }

  void _submit() {
    final parsed = GradeRange.parse(
      from.text,
      to.text,
      pageCount: widget.pageCount,
    );
    if (parsed.range == null) {
      setState(() => error = parsed.error);
    } else {
      Navigator.pop(context, parsed.range);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget field(String label, TextEditingController c, Key key) => Expanded(
      child: TextField(
        key: key,
        controller: c,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label),
        onChanged: (_) => setState(() => error = null),
        onSubmitted: (_) => _submit(),
      ),
    );
    return AlertDialog(
      title: const Text(GradingStrings.gradePagesTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(GradingStrings.gradePagesHelp(widget.pageCount)),
          const SizedBox(height: 8),
          Row(
            children: [
              field(GradingStrings.from, from, const Key('grade_from')),
              const SizedBox(width: 16),
              field(GradingStrings.to, to, const Key('grade_to')),
            ],
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: () => setState(() {
                from.text = '1';
                to.text = '${widget.pageCount}';
                error = null;
              }),
              child: const Text(GradingStrings.allPages),
            ),
          ),
          if (error != null)
            Text(
              error!,
              key: const Key('grade_range_error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(GradingStrings.cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text(GradingStrings.grade),
        ),
      ],
    );
  }
}
