Patches for Android/iOS permission edits

Usage:

1. Generate platform folders locally (run from project root):

```bash
flutter create .
```

2. Apply the Android and iOS patches (or edit files manually).

If you use git and the files exist, you can try:

```bash
git apply patches/android_manifest.patch
git apply patches/ios_info_plist.patch
```

If `git apply` fails, open the target files and add the snippets shown in the patch files manually.

Notes:
- Update the android placeholders (package, label) as appropriate in the Android patch.
- iOS keys must contain clear user-facing strings explaining why background location is needed.

After applying patches, rebuild and test on device/emulator:

```bash
flutter clean
flutter run -d <device>
```
