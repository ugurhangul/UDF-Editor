import 'dart:typed_data';

import 'models.dart';

/// Abstract interface for all signing methods.
///
/// All 4 qualified signing paths implement this interface:
/// - [NfcIdCardSigner] — NFC via Turkish national ID card
/// - [NfcSmartCardSigner] — NFC via e-İmza smart card (AKIS)
/// - [MobilImzaSigner] — Mobil İmza via GSM operator
/// - [UsbOtgSigner] — USB OTG card reader (Android only)
///
/// The signing workflow is:
/// 1. Check [isAvailable] — can this method be used on this device?
/// 2. Call [sign] with content.xml bytes and user PIN
/// 3. Receive [SigningResult] with raw signature + certificate
/// 4. Pass to [CadesBuilder] to create sign.sgn
abstract class SigningService {
  /// Human-readable display name (e.g., "NFC Kimlik Kartı").
  String get name;

  /// Which signing method this service implements.
  SigningMethod get method;

  /// Check if this signing method is available on the current device.
  ///
  /// For NFC: checks NFC hardware presence.
  /// For USB OTG: checks USB host support (Android only).
  /// For Mobil İmza: always true (requires network at sign time).
  Future<bool> isAvailable();

  /// Perform the signing operation.
  ///
  /// [contentXmlBytes] — The raw bytes of content.xml to be signed.
  /// [pin] — User's PIN for smart card authentication, or phone number for Mobil İmza.
  ///
  /// Returns [SigningResult] with raw signature bytes and signer certificate.
  /// Throws [SigningException] on failure.
  Future<SigningResult> sign(
    Uint8List contentXmlBytes, {
    required String pin,
  });

  /// Attempt to read the signer's certificate from the device.
  ///
  /// For NFC/USB: reads certificate from smart card.
  /// For Mobil İmza: returns null (certificate comes with signature response).
  Future<Uint8List?> readCertificate();
}

/// Exception thrown during signing operations.
class SigningException implements Exception {
  const SigningException(this.message, {this.code, this.cause});

  /// Human-readable error description.
  final String message;

  /// Machine-readable error code for programmatic handling.
  final SigningErrorCode? code;

  /// Underlying exception, if any.
  final Object? cause;

  @override
  String toString() => 'SigningException($code): $message';
}

/// Machine-readable error codes for signing failures.
enum SigningErrorCode {
  /// NFC hardware not available on this device.
  nfcNotAvailable,

  /// NFC tag was lost during communication (user moved card too early).
  nfcTagLost,

  /// NFC communication error (transceive failed, timeout, etc.).
  nfcCommunicationError,

  /// Smart card AID not recognized (unsupported card type).
  unsupportedCard,

  /// Smart card AID not recognized (alias).
  cardNotSupported,

  /// Smart card rejected the PIN (wrong PIN).
  pinRejected,

  /// PIN verification failed (wrong PIN or card-specific error).
  pinError,

  /// Smart card is locked (too many wrong PIN attempts).
  cardLocked,

  /// Certificate on the card has expired or could not be read.
  certificateExpired,

  /// Certificate read/parse error.
  certificateError,

  /// The signing operation itself failed.
  signingFailed,

  /// USB OTG not supported on this platform (iOS).
  usbNotSupported,

  /// No USB card reader detected.
  noReaderDetected,

  /// Mobil İmza: operator API unreachable.
  operatorUnavailable,

  /// Mobil İmza: user did not respond to PIN prompt (timeout).
  mobilImzaTimeout,

  /// Mobil İmza: user rejected the signing request.
  mobilImzaRejected,

  /// Mobil İmza: unknown phone number or operator.
  unknownOperator,

  /// TSA server unreachable (cannot obtain timestamp).
  tsaUnavailable,

  /// Generic/unknown failure.
  unknown,
}
