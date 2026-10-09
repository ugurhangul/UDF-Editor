Do exactly three file tasks in this Flutter repo (UDFtör — a Turkish UDF/UYAP legal document editor with freemium RevenueCat licensing). Touch ONLY the files named below. Do not run shell commands, do not commit, do not reformat unrelated code.

TASK 1 — Defense-in-depth paywall gate in lib/features/signing/signing_screen.dart:
At the top of the async init that runs in initState (mirror the pattern used in lib/features/editor/editor_screen.dart around line 80), add a Pro check BEFORE any signing setup:

// Paywall check — signing is a Pro feature (defense in depth;
// primary gate lives on the reader's sign button).
if (PaywallService.instance.isFree) {
  setState(() { _error = 'Bu özellik Pro abonelik gerektirir.'; _isLoading = false; });
  return;
}

Add the import '../../core/paywall/paywall_service.dart'. If the screen's actual error/loading field names differ from _error/_isLoading, adapt to the real ones. Keep the change minimal — nothing else in the file.

TASK 2 — Replace README.md (currently Flutter boilerplate) with a real project README in English: what UDFtör is (UDF/UYAP document editor for Turkish legal professionals), feature list (read/edit UDF, create documents, version history, 4 e-signature paths: NFC Turkish ID card, NFC smartcard, USB token via OTG, Mobil İmza; signature verification free), freemium model (free = read/verify with ads; Pro subscription via RevenueCat entitlement "UDFtor Pro" unlocks edit/create/versions/sign, no ads), tech stack (Flutter, go_router, flutter_quill, purchases_flutter, AdMob, pointycastle/CAdES), build instructions: flutter build appbundle --release --dart-define=REVENUECAT_API_KEY=goog_xxx (placeholder only, never a real key), project structure overview of lib/ (app, core, features, shared). Professional tone, no emoji spam.

TASK 3 — Create docs/legal/terms.html and docs/legal/privacy.html: two standalone self-contained Turkish HTML pages (inline CSS, clean readable professional styling, mobile friendly) for hosting at ugurhangul.xyz/udftor/terms and /privacy.
- terms.html "Kullanım Koşulları": operator Uğurhan Gül (şahıs), contact ugurhangul@gmail.com; license to use the app; Pro subscription terms (billed via Google Play, auto-renews, cancel anytime in Play aboneliklerinden, no refund beyond Play policy); the app is a document TOOL and provides no legal advice; user is responsible for documents they sign; e-signature operations run locally on device with the user's own certificates; disclaimer of warranties within legal limits; Turkish law + Kocaeli courts jurisdiction; last-updated date 21 Temmuz 2026.
- privacy.html "Gizlilik Politikası" (KVKK-aware): data controller Uğurhan Gül, contact ugurhangul@gmail.com; documents and signing certificates NEVER leave the device (processed locally); third-party SDKs: RevenueCat (purchase/subscription state, pseudonymous app user id), Google Play Billing (payments — card data never seen by the app), Google AdMob for free tier (ad identifiers; personalized/non-personalized per consent), crash/diagnostic data if any; no sale of personal data; KVKK madde 11 rights (erişim, düzeltme, silme, itiraz) exercised via the contact email; retention limited to subscription lifecycle; children not targeted (18+ professional tool); last-updated 21 Temmuz 2026.
Cross-link the two pages in their footers.

When done, print a one-line summary per task.
