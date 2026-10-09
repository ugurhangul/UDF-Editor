---
name: verify
description: Build, launch and drive UDFtör on the Android emulator to verify changes end-to-end. Use when asked to verify/test app behavior on this repo.
---

# Verify UDFtör (Flutter, Android emulator)

No desktop/web scaffold — Android emulator is the only surface.

## Launch

```bash
flutter emulators --launch Pixel_9_Pro_XL
ADB="$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe"
"$ADB" wait-for-device   # poll sys.boot_completed == 1
flutter run -d emulator-5554 --debug   # background; ready on "Flutter run key commands"
```

## Drive + capture

- Screenshots: `"$ADB" exec-out screencap -p > shot.png` (1344x2992).
- Taps/text: `input tap X Y`, `input text 'a%sb'` (%s = space), `keyevent KEYCODE_BACK/HOME/MOVE_END/DEL`.
- Git Bash mangles `/sdcard` — use `MSYS_NO_PATHCONV=1`.
- Test fixture: push `knowledge/sample.udf` (gitignored, local only — contains personal data; real signed UDF, Turkish text, LineSpacing=0.5) to `/sdcard/Download/`, import via "Dosya Aç" FAB.
- App storage (debug): `adb shell run-as com.ugurhangul.udftor ls app_flutter/udf_files` (+ `udf_drafts`). Binary copy in: `adb push` to `/data/local/tmp` then `run-as ... cat`.

## Gotchas

- Editor + signing are Pro-gated; debug RevenueCat key fails → free tier. To drive editor: TEMP `isPro => true` in `paywall_service.dart`, REVERT after.
- Reader reloads automatically after returning from editor/signing (awaited pushNamed + _loadDocument).
- Flows worth driving: import (+re-import → overwrite dialog), reader render (check Turkish chars + line spacing + İmzalı badge), long-press rename/delete, editor edit → system-back (PopScope dialog) → Kaydet ve Çık → reopen, draft: edit → HOME → force-stop → relaunch → draft prompt, version history (Pro): long-press → Sürüm Geçmişi → view snapshot (read-only reader) / restore. Snapshots land in `app_flutter/udf_versions/<sha256>/<millis>.udf` — check sizes on disk to verify pre-write capture.
- Blind adb tap sequences can double-fire dialogs (BACK may dismiss instead of open) — screenshot between steps before trusting multi-tap choreography.
