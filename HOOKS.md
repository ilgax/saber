# Upstream files edited by this fork

Everything else the fork adds lives in new files (`lib/grading/`,
`test/grading/`, `.github/workflows/grader-debug-apk.yml`, `*.md` notes).
When an upstream merge conflicts, it will be in one of the places below:
re-apply the edit described here on top of upstream's version.

## Android packaging (so the fork installs next to official Saber)

| File | Edit | Why |
| --- | --- | --- |
| `android/app/build.gradle.kts` | `applicationId = "dev.ilgax.saber"` (was `com.adilhanney.saber`). `namespace` and the Kotlin package are unchanged. | A different app id lets the fork be installed beside the Play/F-Droid Saber without touching its data. |
| `android/app/src/main/AndroidManifest.xml` | `android:label="Saber Grader"` on `<application>` (was `Saber`). | Tell the two apps apart on the home screen. |
| `android/app/src/main/AndroidManifest.xml` | `SuperClipboardDataProvider` authority is `${applicationId}.SuperClipboardDataProvider` (was hard-coded `com.adilhanney.saber....`). | Two installed apps may not declare the same provider authority; Android refuses the install otherwise. |

Nothing else depends on the old id: no Dart code references the package name,
and the intent filters use MIME types and file patterns only. The `nc://`
login callback scheme is shared with official Saber, so if both apps are
installed Android may ask which one should open a Nextcloud login link.

## Grading UI hooks (Dart, two upstream files)

Both hooks are one added call plus its import line. All logic is in
`lib/grading/ui/`.

### 1. `lib/components/canvas/canvas.dart` (likeliest merge conflict)

Wrap the page's `InnerCanvas` in a `Stack` whose second child is the marks
overlay. This is done with an extension method so that upstream's
`InnerCanvas(...)` arguments are not re-indented (a literal `Stack(children:
[InnerCanvas(...), ...])` would change about twenty lines):

```diff
+import 'package:saber/grading/ui/grade_marks_overlay.dart';
 ...
                       currentToolIsSelect: currentTool.toolId == ToolId.select,
                       currentScale: currentScale,
-                    ),
+                    ).withGradeMarks(coreInfo: coreInfo, pageIndex: pageIndex),
                   ),
                 )
```

`withGradeMarks` (in `grade_marks_overlay.dart`) returns
`Stack(children: [this, GradeMarksOverlay(coreInfo:, pageIndex:)])`. It is only
applied in the `!placeholder` branch, inside `OnyxSdkPenArea`, so the overlay
sits in the page box and follows zoom and scroll.

Why: marks and the debug overlay must be drawn over each page in note
coordinates. Without grading results the overlay builds to
`SizedBox.shrink()`.

Re-apply after a merge: find the `InnerCanvas(...)` that is the `child` of
`OnyxSdkPenArea` in `Canvas.build`, append `.withGradeMarks(coreInfo:
coreInfo, pageIndex: pageIndex)` to it, and add the import. If upstream
renames `InnerCanvas` or moves the page box, keep the idea: the overlay must be
a child of a `Stack` inside the page-sized box, above the canvas, and must not
be built for placeholder pages.

### 2. `lib/pages/editor/editor.dart`

Add the grade button as the first entry of the app bar `actions` (the list that
starts with the insert-page `IconButton`):

```diff
+import 'package:saber/grading/ui/grade_button.dart';
 ...
                 actions: [
+                  GradeButton(coreInfo: coreInfo),
                   IconButton(
                     icon: const AdaptiveIcon(
                       icon: Icons.insert_page_break,
```

Re-apply after a merge: put `GradeButton(coreInfo: coreInfo)` first in the
editor app bar's `actions` and add the import. `coreInfo` is the editor's
`EditorCoreInfo`; the button finds the note's grading state through it (an
`Expando`), so no other hook is needed.

### Other upstream-facing facts

- UI strings are English constants in `lib/grading/ui/grading_strings.dart`;
  no i18n/slang file is touched.
- Grading data is stored only in `<app support dir>/grading/` (see
  `PHASE2.md`), never in the notes folder and never in the note file.
