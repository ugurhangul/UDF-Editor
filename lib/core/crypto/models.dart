import 'dart:typed_data';

/// Status of a digital signature on a UDF document.
enum SignatureStatus {
  /// Signature is valid — hash matches and certificate is trusted.
  valid,

  /// Signature hash does not match content — document was tampered with.
  invalid,

  /// Signature was valid but the certificate has expired.
  expired,

  /// Document has no signature (no sign.sgn file).
  unsigned,

  /// Signature could not be parsed or verified (malformed CMS).
  unknown,
}

/// How far the signer certificate could be validated against the bundled
/// Turkish qualified-ESHS trust anchors. Independent of [SignatureStatus]:
/// a cryptographically valid signature can still lack a trusted anchor when
/// the CMS omits the intermediate certificates.
enum TrustLevel {
  /// Signer chained (cryptographically) to a bundled Turkish qualified root.
  trustedChain,

  /// Signature verified, but the chain could not be built to a bundled root
  /// (missing intermediates or an unrecognised CA).
  untrustedAnchor,

  /// Trust was not evaluated (e.g. the signature itself did not verify).
  notEvaluated,
}

/// Information extracted from a sign.sgn CMS SignedData envelope.
class SignatureInfo {
  const SignatureInfo({
    required this.status,
    this.signerName,
    this.issuerName,
    this.signingTime,
    this.validFrom,
    this.validTo,
    this.serialNumber,
    this.digestAlgorithm,
    this.signatureAlgorithm,
    this.hasTimestamp = false,
    this.hasEmbeddedValidation = false,
    this.trustLevel = TrustLevel.notEvaluated,
    this.anchorName,
  });

  /// Overall verification result.
  final SignatureStatus status;

  /// Common Name (CN) of the signer's certificate.
  final String? signerName;

  /// Common Name (CN) of the certificate issuer (CA).
  final String? issuerName;

  /// When the document was signed (from signed attributes, not system clock).
  final DateTime? signingTime;

  /// Certificate validity start.
  final DateTime? validFrom;

  /// Certificate validity end.
  final DateTime? validTo;

  /// Certificate serial number (hex string).
  final String? serialNumber;

  /// Hash algorithm used (e.g., "SHA-256").
  final String? digestAlgorithm;

  /// Signature algorithm (e.g., "RSA", "ECDSA").
  final String? signatureAlgorithm;

  /// Whether a TSA timestamp token is present (CAdES-T or higher).
  final bool hasTimestamp;

  /// Whether CRL/OCSP validation data is embedded (CAdES-X-LONG).
  final bool hasEmbeddedValidation;

  /// Result of chaining the signer certificate to a bundled trust anchor.
  final TrustLevel trustLevel;

  /// Name of the trusted root/CA the chain terminated at, when trusted.
  final String? anchorName;

  /// Human-readable CAdES profile based on embedded data.
  String get cadesProfile {
    if (hasEmbeddedValidation) return 'CAdES-X-LONG';
    if (hasTimestamp) return 'CAdES-T';
    return 'CAdES-BES';
  }

  /// Convenience constructor for unsigned documents.
  const SignatureInfo.unsigned()
      : status = SignatureStatus.unsigned,
        signerName = null,
        issuerName = null,
        signingTime = null,
        validFrom = null,
        validTo = null,
        serialNumber = null,
        digestAlgorithm = null,
        signatureAlgorithm = null,
        hasTimestamp = false,
        hasEmbeddedValidation = false,
        trustLevel = TrustLevel.notEvaluated,
        anchorName = null;
}

/// Raw signing result from a signing device (NFC card, Mobil İmza, etc.).
class SigningResult {
  const SigningResult({
    required this.signature,
    this.certificate,
    this.certificateChain = const [],
    this.signedAttributes,
  });

  /// Raw signature bytes (PKCS#1 v1.5 or similar).
  final Uint8List signature;

  /// Signer's X.509 certificate (DER-encoded).
  /// May be null for Mobil İmza (certificate is embedded in CMS response).
  final Uint8List? certificate;

  /// Full certificate chain (DER-encoded), from signer to root CA.
  /// May be empty if the signing device only provides the signer cert.
  final List<Uint8List> certificateChain;

  /// DER-encoded SignedAttributes (SET OF Attribute, tag 0x31) that
  /// [signature] was computed over, per RFC 5652 §5.4.
  /// Null when the device signed the content bytes directly (Mobil İmza) —
  /// the CMS envelope must then omit signedAttrs entirely.
  final Uint8List? signedAttributes;
}

/// Signing method identifier for UI and routing.
enum SigningMethod {
  /// NFC via Turkish national ID card (kimlik kartı).
  nfcIdCard,

  /// NFC via e-İmza smart card (AKIS token).
  nfcSmartCard,

  /// Mobil İmza via GSM operator SIM card.
  mobilImza,

  /// USB OTG card reader (Android only).
  usbOtg,
}

/// PIN activation status on a smart card.
class PinStatus {
  const PinStatus._({
    required this.state,
    this.remainingAttempts,
  });

  final PinState state;

  /// Remaining PIN attempts before lockout (only available for [PinState.active]).
  final int? remainingAttempts;

  /// PIN is active and ready for verification.
  const PinStatus.active({int? remainingAttempts})
      : this._(state: PinState.active, remainingAttempts: remainingAttempts);

  /// PIN is blocked due to too many wrong attempts.
  const PinStatus.blocked() : this._(state: PinState.blocked);

  /// PIN has not been activated on this card.
  const PinStatus.notActivated() : this._(state: PinState.notActivated);

  /// PIN reference not found (e-sign applet may not exist).
  const PinStatus.notFound() : this._(state: PinState.notFound);

  /// Could not determine PIN status.
  const PinStatus.unknown() : this._(state: PinState.unknown);
}

/// PIN state on a smart card.
enum PinState {
  /// PIN is active and can be verified.
  active,

  /// PIN is blocked (too many wrong attempts).
  blocked,

  /// PIN has not been activated / initialized.
  notActivated,

  /// PIN reference not found on card.
  notFound,

  /// Unknown state.
  unknown,
}

/// Turkish GSM operator for Mobil İmza.
enum MobilOperator {
  turkcell('Turkcell', ['530', '531', '532', '533', '534', '535', '536', '537', '538', '539']),
  vodafone('Vodafone', ['540', '541', '542', '543', '544', '545', '546', '547', '548', '549']),
  turkTelekom('Türk Telekom', ['550', '551', '552', '553', '554', '555', '556', '557', '558', '559']);

  const MobilOperator(this.displayName, this.prefixes);

  final String displayName;
  final List<String> prefixes;

  /// Auto-detect operator from phone number.
  /// Returns null if prefix doesn't match any known operator.
  static MobilOperator? fromPhoneNumber(String phoneNumber) {
    // Normalize: strip +90, leading 0, spaces, dashes
    var digits = phoneNumber.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.startsWith('90') && digits.length > 10) {
      digits = digits.substring(2);
    }
    if (digits.startsWith('0') && digits.length > 10) {
      digits = digits.substring(1);
    }
    if (digits.length < 3) return null;

    final prefix = digits.substring(0, 3);
    for (final op in MobilOperator.values) {
      if (op.prefixes.contains(prefix)) return op;
    }
    return null;
  }
}
