# UDFtör

UDFtör is a mobile UDF/UYAP document editor for Turkish legal professionals. It reads, edits, creates, and electronically signs UDF files — the document format used by UYAP (Ulusal Yargı Ağı Bilişim Sistemi), Turkey's national judiciary information system — directly on an Android device.

## Features

- **Read UDF documents** — open and render `.udf` files with their original formatting.
- **Edit and create documents** — modify existing UDF files or author new ones from scratch.
- **Version history** — keep and restore previous versions of a document.
- **Electronic signing** with four signature paths:
  - **NFC Turkish ID card** — sign with the new-generation Turkish identity card over NFC.
  - **NFC smartcard** — sign with an e-signature smartcard over NFC.
  - **USB token** — sign with a USB e-signature token connected via OTG.
  - **Mobil İmza** — sign through the mobile-signature service of your GSM operator.
- **Signature verification** — verify CAdES signatures on UDF documents; available to all users free of charge.

All signing operations run locally on the device with the user's own certificates. Documents never leave the device.

## Freemium model

| Tier | Capabilities |
| --- | --- |
| **Free** | Read documents, verify signatures. Ad-supported (AdMob). |
| **Pro** | Everything in Free, plus edit, create, version history, and e-signing. No ads. |

Pro is a subscription managed through RevenueCat; access is controlled by the `UDFtor Pro` entitlement.

## Tech stack

- [Flutter](https://flutter.dev/) — application framework
- [go_router](https://pub.dev/packages/go_router) — navigation
- [flutter_quill](https://pub.dev/packages/flutter_quill) — rich text editing
- [purchases_flutter](https://pub.dev/packages/purchases_flutter) — RevenueCat subscriptions
- Google AdMob — ads for the free tier
- [pointycastle](https://pub.dev/packages/pointycastle) — cryptography for CAdES signature creation and verification

## Building

Release builds require the RevenueCat public API key passed as a compile-time define:

```sh
flutter build appbundle --release --dart-define=REVENUECAT_API_KEY=goog_xxx
```

Replace `goog_xxx` with your RevenueCat Google Play API key. Never commit a real key to the repository.

## Project structure

```
lib/
├── app/        # App shell: routing, theming, top-level configuration
├── core/       # Core services: UDF parsing, cryptography/signing, paywall, ads
├── features/   # Feature screens: reader, editor, signing, verification, settings
└── shared/     # Shared widgets and utilities used across features
```
