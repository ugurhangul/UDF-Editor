# 🔍 UDFtör — Multi-Specialist Audit Report

> **Project:** UDFtör — UYAP .udf file reader, editor, and signer for mobile  
> **Stack:** Flutter 3.11 · Riverpod · GoRouter · RevenueCat · AdMob · NFC  
> **Date:** 2026-04-05  
> **Auditors:** `@security-auditor` · `@frontend-specialist` · `@mobile-developer` · `@backend-specialist` · `@debugger`

---

## Executive Summary

| Severity | Count | Domains |
|----------|-------|---------|
| 🔴 **Critical** | 5 | Security, UX |
| 🟠 **High** | 8 | Code Quality, UX, Architecture |
| 🟡 **Medium** | 10 | UX, Code, Architecture |
| 🔵 **Low** | 5 | Polish, Testing |

**Verdict:** The app has solid core file-parsing logic, but ships with **critical security exposures** (hardcoded API key, PIN in memory), **fake UI controls** (formatting toolbar does nothing), and **major dark mode rendering failures**. These must be fixed before any public release.

---

## 🔴 CRITICAL — Fix Before Release

---

### SEC-01: Hardcoded Production API Keys in Source

**Files:** [paywall_service.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/core/paywall/paywall_service.dart#L19), [ad_banner_widget.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/shared/widgets/ad_banner_widget.dart#L24)

```dart
// paywall_service.dart:19
static const _apiKey = 'REVENUECAT_TEST_KEY_REMOVED';

// ad_banner_widget.dart:24
static const _adUnitId = 'ca-app-pub-9106641442812067/4454343459';
```

> [!CAUTION]
> Production API keys and AdMob unit IDs are committed to git in plain text. Anyone who decompiles the APK or reads the repo can extract these. The RevenueCat key allows subscription fraud; the AdMob key allows ad revenue theft.

**Fix:** Use `--dart-define` or `.env` files loaded at build time. Never commit secrets.

---

### SEC-02: PIN Stored in TextEditingController — Never Cleared

**File:** [signing_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/signing/signing_screen.dart#L33-L34)

```dart
final _pinController = TextEditingController();
final _phoneController = TextEditingController();
```

The PIN and phone number remain in memory via `TextEditingController.text` after signing completes. The `dispose()` at line 63 calls `_pinController.dispose()` but does NOT clear the value first. On Android, this string can persist in heap dumps, crash reports, or process memory.

**Fix:**
```dart
@override
void dispose() {
  _pinController.clear();   // ← add
  _phoneController.clear(); // ← add
  _pinController.dispose();
  _phoneController.dispose();
  super.dispose();
}
```
Also clear after successful/failed signing in `_performSigning`.

---

### SEC-03: Arbitrary File Overwrite via File Name Injection

**File:** [file_browser_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/file_browser/file_browser_screen.dart#L91)

```dart
final targetFile = File('${udfDir.path}/$fileName');
await targetFile.writeAsBytes(bytes, flush: true);
```

The `fileName` comes directly from `file.name` (user-selected file). A crafted filename like `../../etc/passwd` or `../../../shared_prefs/data.xml` could escape the `udf_files/` sandbox and overwrite other app data. While Android SAF mitigates some risk, the path traversal is still dangerous.

**Fix:** Sanitize the filename — strip directory separators and `..` segments:
```dart
final safeName = fileName.split(RegExp(r'[/\\]')).last;
if (safeName.isEmpty || safeName.startsWith('.')) {
  throw ArgumentError('Invalid filename');
}
```

---

### UX-01: Editor Formatting Toolbar is Completely Fake

**File:** [editor_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/editor/editor_screen.dart#L558-L640)

> [!WARNING]
> The Bold/Italic/Underline/Alignment toolbar buttons toggle state variables (`_isBold`, `_isItalic`, etc.) but these are applied **globally to the entire TextField**, not to selected text. A `TextField` widget cannot render mixed formatting within a single string. Users will think they're formatting specific words but they're actually:
> 1. Changing the style of ALL text in the editor
> 2. Those changes are NOT persisted — `_rebuildDocument()` ignores `_isBold`/`_isItalic`/`_isUnderline` entirely

**Impact:** Users believe they're applying rich formatting, but the saved `.udf` file will not contain any of those changes. This is **data loss** and a trust violation.

**Fix options:**
1. **Remove the toolbar entirely** and label the editor as "Plain Text Editor"
2. **Switch to a proper rich text editor** (flutter_quill was removed due to bugs; consider `super_editor` or `appflowy_editor`)
3. Mark toolbar buttons as disabled with a "Coming Soon" label

---

### UX-02: Undo/Redo Buttons Are Dead — Always Disabled

**File:** [editor_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/editor/editor_screen.dart#L624-L637)

```dart
IconButton(
  icon: const Icon(Icons.undo, size: 20),
  onPressed: _textController.value.composing.isValid ? null : null, // ← ALWAYS null
  tooltip: 'Geri Al',
),
IconButton(
  icon: const Icon(Icons.redo, size: 20),
  onPressed: null, // ← hardcoded null
  tooltip: 'Yinele',
),
```

Both buttons are permanently disabled. The undo button's condition evaluates to `null` regardless of composing state (`null : null`). Users see undo/redo icons but cannot use them.

**Fix:** Either implement undo/redo stack or remove the buttons entirely.

---

## 🟠 HIGH — Significant Issues

---

### UX-03: Dark Mode Completely Broken for Document Rendering

**File:** [reader_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/reader/reader_screen.dart#L207-L240)

```dart
Container(
  color: const Color(0xFFE8E8E8), // hardcoded light grey
  // ...
  decoration: BoxDecoration(
    color: Colors.white, // hardcoded white paper
  ),
)
```

And text color defaults at line 292:
```dart
color: run.foregroundColor ?? Colors.black,
```

**Result:** In dark mode, the document canvas is a jarring light grey box with white paper and black text — completely ignoring the dark theme. The paper metaphor is acceptable, but the outer canvas (`0xFFE8E8E8`) clashes with dark theme surfaces.

Also at line 368:
```dart
color: Colors.black, // fallback text color — broken in dark mode
```

---

### UX-04: Signature Badge Uses Hardcoded Colors — Broken in Dark Mode

**File:** [reader_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/reader/reader_screen.dart#L127-L153)

```dart
color: isSigned ? Colors.green.shade700 : colorScheme.outline,
backgroundColor: isSigned ? Colors.green.shade50 : colorScheme.surfaceContainerHighest,
```

`Colors.green.shade50` is nearly invisible in dark mode. Should use `colorScheme` consistently.

---

### CODE-01: `_formatDate` Has Wrong Month Padding Logic

**File:** [file_browser_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/file_browser/file_browser_screen.dart#L302)

```dart
return '${date.day}.${date.month.toString().padLeft(2, '0')}.${date.year}';
```

The day is NOT padded but the month IS. Turkish date format expects both padded: `05.04.2026`. Should be:
```dart
return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
```

---

### CODE-02: `_generateSavePath` Fails for New Documents

**File:** [editor_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/editor/editor_screen.dart#L406-L411)

```dart
String _generateSavePath() {
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final defaultName = 'belge_$timestamp.udf';
  final dir = File(widget.filePath ?? '').parent;
  return '${dir.path}/$defaultName';
}
```

When `widget.filePath` is `null` (new document), `File('').parent` resolves to `.` (current directory), which on mobile is unpredictable — likely the app's root directory, NOT the `udf_files/` directory. New documents could be saved to a wrong location and never appear in the file browser.

**Fix:** Always use `getApplicationDocumentsDirectory()/udf_files/` as the base.

---

### CODE-03: Synchronous `statSync()` Calls on UI Thread

**File:** [file_browser_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/file_browser/file_browser_screen.dart#L43)

```dart
..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
```

And line 246:
```dart
final stat = file.statSync();
```

`statSync()` performs blocking I/O on the main isolate. With 50+ files, this will cause visible jank on older devices.

**Fix:** Use `file.stat()` (async) or perform the entire load in a `compute()` isolate.

---

### CODE-04: Empty Catch Block Swallows Critical Errors

**File:** [file_browser_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/file_browser/file_browser_screen.dart#L46)

```dart
} catch (_) {
  // Silently handle — empty list is fine for first launch
}
```

If file listing fails due to permissions, disk errors, or corruption, the user sees an empty state with no indication anything went wrong. At minimum, log the error.

---

### ARCH-01: God-Widget Screens — Single Files Exceeding 700+ Lines

| File | Lines | Responsibilities |
|------|-------|-----------------|
| [editor_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/editor/editor_screen.dart) | 715 | UI, document loading, text extraction, document rebuild, serialization, save logic, toolbar, exit confirmation |
| [signing_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/signing/signing_screen.dart) | 762 | UI for 6 states, method selection, PIN verification, NFC bridge, CAdES building, file I/O |

These violate SRP. Consider extracting:
- **Controllers/Notifiers** for business logic (Riverpod)
- **Use case classes** for signing, document editing
- **Smaller widget components** for each screen section

---

### ARCH-02: PaywallService is a Global Singleton — Untestable

**File:** [paywall_service.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/core/paywall/paywall_service.dart#L16-L17)

```dart
static final PaywallService instance = PaywallService._();
```

Used directly throughout the app (`PaywallService.instance.isPro`). This makes it impossible to mock for testing and creates tight coupling. Since the app already uses Riverpod, expose it as a `Provider`:

```dart
final paywallProvider = Provider<PaywallService>((ref) => PaywallService.instance);
```

---

## 🟡 MEDIUM — Should Fix

---

### UX-05: No Loading/Progress Indicator When Picking Files

**File:** [file_browser_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/file_browser/file_browser_screen.dart#L53-L82)

After `_pickFile` returns a file, there's a `_saveToAppDir` call that could take seconds for large `.udf` files. During this time, there's no spinner or progress indicator — the UI appears frozen.

---

### UX-06: No Confirmation Before Overwriting Existing Files

**File:** [file_browser_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/file_browser/file_browser_screen.dart#L91-L93)

If a user picks a file with the same name as an existing one in `udf_files/`, it's silently overwritten. No dialog, no warning.

---

### UX-07: No Visual Feedback for NFC "Card Detected" Event

**File:** [signing_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/signing/signing_screen.dart#L604-L660)

The "PIN Durumu Kontrol Ediliyor" state shows a spinner with "Kartınızı telefona yaklaştırın" but provides zero haptic/visual feedback when the card IS detected. Users have no way to know if the card was read.

---

### UX-08: Ad Banner Appears Even When Loading or Error State

**Files:** [reader_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/reader/reader_screen.dart#L121), [file_browser_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/file_browser/file_browser_screen.dart#L194)

The `AdBannerWidget` is unconditionally rendered at the bottom of every screen, including error states and loading states. This is visually jarring and pushes content up when the error message should be centered.

---

### UX-09: File Browser Has No Delete/Rename Actions

The file browser lists files but provides no way to delete, rename, or organize them. Long-press should show a context menu with these options.

---

### CODE-05: Riverpod Used in FileBrowser but Nowhere Else

The `FileBrowserScreen` extends `ConsumerStatefulWidget` and uses `ref` in its type definition, but the `ref` variable is never actually used in the widget. Meanwhile, other screens that SHOULD use Riverpod (for shared state like paywall status, sync state) use raw `StatefulWidget`.

---

### CODE-06: `_cancelPinCheck` Creates New NfcBridge Instance — Violates Single Session Principle

**File:** [signing_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/signing/signing_screen.dart#L591-L602)

```dart
void _cancelPinCheck() {
  final signer = _signers[SigningMethod.nfcIdCard];
  if (signer is NfcIdCardSigner) {
    NfcBridge().stopSession().catchError((_) {}); // NEW instance
  }
}
```

Creates a **new** `NfcBridge()` instance instead of stopping the existing signer's session. The original `NfcBridge` inside `NfcIdCardSigner` is still running its session. This may leave the NFC radio in an active state, draining battery.

---

### CODE-07: `_loadRecentFiles` Called After Navigation — Race Condition

**File:** [file_browser_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/file_browser/file_browser_screen.dart#L80-L81)

```dart
context.pushNamed('reader', queryParameters: {'path': savedPath});
_loadRecentFiles(); // ← runs AFTER navigation, on a potentially unmounted widget
```

`_loadRecentFiles` calls `setState` which will throw if the widget is already disposed after navigation. The `mounted` check at line 78 only guards the `pushNamed`, not the subsequent `_loadRecentFiles`.

---

### ARCH-03: SyncService Instantiated Fresh in SyncSettingsScreen

**File:** [sync_settings_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/sync/sync_settings_screen.dart#L35-L38)

```dart
_providers = [
  GoogleDriveSync(),
  ICloudSync(containerId: 'iCloud.com.udftor.udfeditor'),
];
```

New instances are created every time the screen is opened. Auth state, tokens, and connections should be managed by a service locator or Riverpod provider — not by the screen.

---

### ARCH-04: No Router Redirect — Deep Links Navigate to Broken States

**File:** [routes.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/app/routes.dart)

Routes like `/reader?path=`, `/editor?path=`, and `/signing?path=` are accessible via deep links. If `path` is empty or points to a non-existent file, the screens will crash or show cryptic errors. GoRouter's `redirect` guard should validate paths before navigation.

---

## 🔵 LOW — Polish Items

---

### TEST-01: Zero Widget Tests, Zero Integration Tests

The `test/` directory contains only 3 unit test files:
- `crypto_test.dart` (11KB)
- `udf_delta_converter_test.dart` (6KB)
- `udf_parser_test.dart` (6KB)

There are **no widget tests** for any screen, **no golden tests** for visual regression, and **no integration tests**. The editor's `_rebuildDocument` and `_reflowRuns` are particularly complex and undertested.

---

### CODE-08: Unused Import in EditorScreen

**File:** [editor_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/editor/editor_screen.dart#L4)

```dart
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';
```

This import provides `PaywallResult` but it's already available via `paywall_service.dart` re-export. The direct dependency on `purchases_ui_flutter` in a screen file is unnecessary coupling.

---

### CODE-09: `SyncUserInfo.email` Used Without Null Check

**File:** [sync_settings_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/sync/sync_settings_screen.dart#L166)

```dart
userInfo.email ?? userInfo.displayName,
```

If both `email` and `displayName` are null, this renders `null` as text. Should have a fallback like `'Bilinmeyen Kullanıcı'`.

---

### CODE-10: `iCloud` Provider Visibility Check Is Incomplete  

**File:** [sync_settings_screen.dart](file:///c:/repos/ugurhangul/UDF-Editor/lib/features/sync/sync_settings_screen.dart#L131)

```dart
if (provider is ICloudSync && !Platform.isIOS && !Platform.isMacOS) {
  return const SizedBox.shrink();
}
```

This returns `SizedBox.shrink()` inside a `ListView`, which creates an invisible 0×0 space and an unnecessary gap. Should be filtered BEFORE building the list, not inside the builder.

---

### UX-10: No Haptic Feedback on Critical Actions

Signing, saving, and file operations provide no haptic feedback (`HapticFeedback.mediumImpact()`). For a professional mobile app dealing with legal documents, tactile confirmation is important.

---

## 📊 Priority Action Matrix

| Priority | ID | Action | Effort |
|----------|----|--------|--------|
| 1 | SEC-01 | Move API keys to env/build config | 1h |
| 2 | SEC-02 | Clear PIN from memory after use | 30m |
| 3 | SEC-03 | Sanitize file names from picker | 30m |
| 4 | UX-01 | Remove or replace fake formatting toolbar | 2-4h |
| 5 | UX-02 | Remove dead undo/redo buttons | 15m |
| 6 | UX-03 | Fix dark mode document rendering | 1h |
| 7 | CODE-02 | Fix save path for new documents | 30m |
| 8 | CODE-03 | Move file I/O off main thread | 1h |
| 9 | ARCH-01 | Extract business logic from screens | 4-8h |
| 10 | TEST-01 | Add widget tests for critical flows | 4h |

---

## 🛡️ Security Posture Summary

| Check | Status |
|-------|--------|
| API key security | ❌ Hardcoded in source |
| PIN handling | ❌ Not cleared from memory |
| Path traversal | ❌ No filename sanitization |
| Input validation | ⚠️ Partial (file extension only) |
| Network security | ✅ HTTPS via RevenueCat/Mobil İmza |
| Data at rest | ✅ App sandbox + flutter_secure_storage |
| Certificate pinning | ⚠️ Not implemented for TSA/Mobil İmza |

---

> **Next steps:** Select which findings to address and I'll implement the fixes. I recommend starting with **SEC-01 → SEC-03 → UX-01** as the critical path.
