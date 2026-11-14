import 'package:material_ui/material_ui.dart';
import 'package:saber/grading/key/key_page_detector.dart';
import 'package:saber/grading/ui/grade_controller.dart';
import 'package:saber/grading/ui/grading_strings.dart';

/// What the user chose in the key pages dialog.
class KeyPagesChoice {
  const new(this.override);

  /// Null resets to automatic detection.
  final KeyOverride? override;
}

class _Row {
  new(this.firstKey, this.lastKey, [this.firstQuestion, this.lastQuestion]);

  int firstKey, lastKey;
  int? firstQuestion, lastQuestion;
}

/// Lets the user pick the key pages and, per key block, the question pages of
/// its test.
Future<void> showKeyPagesDialog(
  BuildContext context,
  GradeController controller,
) async {
  final choice = await showDialog<KeyPagesChoice>(
    context: context,
    builder: (context) => KeyPagesDialog(controller: controller),
  );
  if (choice != null) await controller.setKeyOverride(choice.override);
}

class KeyPagesDialog extends StatefulWidget {
  const new({super.key, required this.controller});

  final GradeController controller;

  @override
  State<KeyPagesDialog> createState() => _KeyPagesDialogState();
}

class _KeyPagesDialogState extends State<KeyPagesDialog> {
  late final List<int> pageIndices;
  late final Map<int, KeyPageStats> stats;
  late Set<int> selected;
  late List<_Row> rows;

  @override
  void initState() {
    super.initState();
    final c = widget.controller;
    pageIndices = [for (final p in c.pages) p.pageIndex]..sort();
    stats = {
      for (final p in c.pages)
        p.pageIndex: KeyPageDetector.analyze(p.pageIndex, p.text),
    };
    final current = c.keyOverride;
    if (current != null) {
      selected = {...current.keyPages};
      rows = current.blocks.isEmpty
          ? _runs(selected)
          : [
              for (final b in current.blocks)
                _Row(
                  b.firstKeyPage,
                  b.lastKeyPage,
                  b.firstQuestionPage,
                  b.lastQuestionPage,
                ),
            ];
    } else {
      selected = {...c.outcome?.analysis.detection.keyPages ?? const <int>{}};
      rows = _runs(selected);
    }
  }

  /// One row per run of consecutive selected pages.
  List<_Row> _runs(Set<int> pages) {
    final sorted = pages.toList()..sort();
    final rows = <_Row>[];
    for (final p in sorted) {
      if (rows.isNotEmpty && rows.last.lastKey == p - 1) {
        rows.last.lastKey = p;
      } else {
        rows.add(_Row(p, p));
      }
    }
    return rows;
  }

  void _toggle(int page, bool on) {
    setState(() {
      on ? selected.add(page) : selected.remove(page);
      // Keep the rows (and their ranges) that still cover the same pages.
      final next = <_Row>[];
      for (final f in _runs(selected)) {
        final same = rows
            .where((o) => o.firstKey == f.firstKey && o.lastKey == f.lastKey)
            .toList();
        next.addAll(same.isEmpty ? [f] : same);
      }
      rows = next;
    });
  }

  KeyOverride? _result() {
    if (rows.isEmpty) return null;
    final anyRange = rows.any((r) => r.firstQuestion != null);
    final shared = rows.length > _runs(selected).length;
    if (!anyRange && !shared) return KeyOverride(selected);
    return KeyOverride.fromBlocks([
      for (final r in rows)
        KeyBlockOverride(
          firstKeyPage: r.firstKey,
          lastKeyPage: r.lastKey,
          firstQuestionPage: r.firstQuestion != null && r.lastQuestion != null
              ? r.firstQuestion
              : null,
          lastQuestionPage: r.firstQuestion != null && r.lastQuestion != null
              ? r.lastQuestion
              : null,
        ),
    ]);
  }

  Widget _pageDropdown(
    int? value,
    ValueChanged<int?> onChanged, {
    required bool allowAuto,
  }) {
    return DropdownButton<int?>(
      value: value,
      isDense: true,
      items: [
        if (allowAuto)
          const DropdownMenuItem<int?>(
            value: null,
            child: Text(GradingStrings.keyPagesAuto),
          ),
        for (final p in pageIndices)
          DropdownMenuItem<int?>(value: p, child: Text('${p + 1}')),
      ],
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(GradingStrings.keyPagesTitle),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(GradingStrings.keyPagesHelp),
              const SizedBox(height: 8),
              for (final p in pageIndices)
                CheckboxListTile(
                  dense: true,
                  value: selected.contains(p),
                  onChanged: (v) => _toggle(p, v ?? false),
                  title: Text('Page ${p + 1}'),
                  subtitle: Text(
                    '${stats[p]!.isKeyPage ? 'looks like a key' : 'does not look like a key'}'
                    ', ${stats[p]!.entries.length} entries',
                  ),
                ),
              if (rows.isNotEmpty) const Divider(),
              for (var i = 0; i < rows.length; i++) _blockRow(i, rows[i]),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, const KeyPagesChoice(null)),
          child: const Text(GradingStrings.resetToAutomatic),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(GradingStrings.cancel),
        ),
        FilledButton(
          onPressed: selected.isEmpty
              ? null
              : () => Navigator.pop(context, KeyPagesChoice(_result())),
          child: const Text(GradingStrings.apply),
        ),
      ],
    );
  }

  Widget _blockRow(int i, _Row r) {
    final keyText = r.firstKey == r.lastKey
        ? 'Key page ${r.firstKey + 1}'
        : 'Key pages ${r.firstKey + 1}-${r.lastKey + 1}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          Text('$keyText: questions on pages'),
          _pageDropdown(
            r.firstQuestion,
            (v) => setState(() {
              r.firstQuestion = v;
              if (v == null) r.lastQuestion = null;
              r.lastQuestion ??= v;
            }),
            allowAuto: true,
          ),
          const Text('to'),
          _pageDropdown(
            r.lastQuestion,
            (v) => setState(() => r.lastQuestion = v),
            allowAuto: true,
          ),
          IconButton(
            tooltip: GradingStrings.splitBlock,
            icon: const Icon(Icons.add),
            onPressed: () =>
                setState(() => rows.insert(i + 1, _Row(r.firstKey, r.lastKey))),
          ),
          if (rows
                  .where(
                    (o) => o.firstKey == r.firstKey && o.lastKey == r.lastKey,
                  )
                  .length >
              1)
            IconButton(
              tooltip: GradingStrings.removeBlock,
              icon: const Icon(Icons.remove),
              onPressed: () => setState(() => rows.removeAt(i)),
            ),
        ],
      ),
    );
  }
}
