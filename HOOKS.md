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
