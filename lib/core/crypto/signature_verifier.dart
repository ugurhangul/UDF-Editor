import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:pointycastle/export.dart';

import 'models.dart';

/// Parses and verifies CMS SignedData from sign.sgn files.
class SignatureVerifier {
  /// Verify a sign.sgn against content.xml bytes.
  static SignatureInfo verify({
    required Uint8List signSgnBytes,
    required Uint8List contentXmlBytes,
  }) {
    try {
      final parsed = _parseSignedData(signSgnBytes);
      if (parsed == null) {
        return const SignatureInfo(status: SignatureStatus.unknown);
      }

      final expectedHash = SHA256Digest().process(contentXmlBytes);
      final hashMatches = _compareBytes(expectedHash, parsed.messageDigest);

      final now = DateTime.now().toUtc();
      final certExpired = parsed.validTo != null && now.isAfter(parsed.validTo!);

      SignatureStatus status;
      if (!hashMatches) {
        status = SignatureStatus.invalid;
      } else if (certExpired) {
        status = SignatureStatus.expired;
      } else {
        status = SignatureStatus.valid;
      }

      return SignatureInfo(
        status: status,
        signerName: parsed.signerName,
        issuerName: parsed.issuerName,
        signingTime: parsed.signingTime,
        validFrom: parsed.validFrom,
        validTo: parsed.validTo,
        serialNumber: parsed.serialNumber,
        digestAlgorithm: 'SHA-256',
        signatureAlgorithm: parsed.signatureAlgorithm,
        hasTimestamp: parsed.hasTimestamp,
        hasEmbeddedValidation: parsed.hasEmbeddedCerts,
      );
    } catch (_) {
      return const SignatureInfo(status: SignatureStatus.unknown);
    }
  }

  /// Parse basic info from sign.sgn without full verification.
  static SignatureInfo parseInfo(Uint8List signSgnBytes) {
    try {
      final parsed = _parseSignedData(signSgnBytes);
      if (parsed == null) {
        return const SignatureInfo(status: SignatureStatus.unknown);
      }

      return SignatureInfo(
        status: SignatureStatus.unknown,
        signerName: parsed.signerName,
        issuerName: parsed.issuerName,
        signingTime: parsed.signingTime,
        validFrom: parsed.validFrom,
        validTo: parsed.validTo,
        serialNumber: parsed.serialNumber,
        digestAlgorithm: 'SHA-256',
        signatureAlgorithm: parsed.signatureAlgorithm,
        hasTimestamp: parsed.hasTimestamp,
        hasEmbeddedValidation: parsed.hasEmbeddedCerts,
      );
    } catch (_) {
      return const SignatureInfo(status: SignatureStatus.unknown);
    }
  }

  // ── Private parsing ───────────────────────────────────────────────────

  static _ParsedSignedData? _parseSignedData(Uint8List derBytes) {
    final parser = ASN1Parser(derBytes);
    final contentInfo = parser.nextObject() as ASN1Sequence;
    final ciElements = contentInfo.elements.toList();

    if (ciElements.length < 2) return null;

    // ContentInfo → contentType + [0] content
    final contentElement = ciElements[1];
    ASN1Sequence signedData;

    if (contentElement is ASN1Sequence) {
      signedData = contentElement;
    } else {
      final innerParser = ASN1Parser(contentElement.valueBytes());
      signedData = innerParser.nextObject() as ASN1Sequence;
    }

    final sdElements = signedData.elements.toList();
    if (sdElements.length < 4) return null;

    // Extract certificates from [0] tag
    String? signerName;
    String? issuerName;
    String? serialNumber;
    String? signatureAlgorithm;
    DateTime? validFrom;
    DateTime? validTo;
    bool hasEmbeddedCerts = false;

    for (final el in sdElements) {
      if (el.tag == 0xA0) {
        hasEmbeddedCerts = true;
        try {
          final certsParser = ASN1Parser(el.valueBytes());
          final cert = certsParser.nextObject() as ASN1Sequence;
          final certElements = cert.elements.toList();
          final tbsCert = certElements[0] as ASN1Sequence;
          _extractCertInfo(
            tbsCert,
            onSubjectCN: (cn) => signerName = cn,
            onIssuerCN: (cn) => issuerName = cn,
            onSerial: (s) => serialNumber = s,
            onValidity: (from, to) {
              validFrom = from;
              validTo = to;
            },
          );
        } catch (_) {
          // Non-fatal
        }
      }
    }

    // Extract SignerInfos (last element)
    Uint8List messageDigest = Uint8List(0);
    DateTime? signingTime;
    bool hasTimestamp = false;

    final lastElement = sdElements.last;
    if (lastElement is ASN1Set && lastElement.elements.isNotEmpty) {
      final siElements = lastElement.elements.toList();
      final signerInfo = siElements[0] as ASN1Sequence;
      final siFields = signerInfo.elements.toList();

      for (final el in siFields) {
        if (el.tag == 0xA0) {
          // Signed attributes
          try {
            final attrsParser = ASN1Parser(el.valueBytes());
            while (attrsParser.hasNext()) {
              final attr = attrsParser.nextObject() as ASN1Sequence;
              final attrParts = attr.elements.toList();
              if (attrParts.length < 2) continue;

              final oid = attrParts[0] as ASN1ObjectIdentifier;
              final oidStr = oid.identifier ?? '';

              if (oidStr == '1.2.840.113549.1.9.4') {
                // message-digest
                final attrValues = attrParts[1] as ASN1Set;
                final avList = attrValues.elements.toList();
                if (avList.isNotEmpty) {
                  final octet = avList[0] as ASN1OctetString;
                  messageDigest = Uint8List.fromList(octet.valueBytes());
                }
              } else if (oidStr == '1.2.840.113549.1.9.5') {
                // signing-time
                final attrValues = attrParts[1] as ASN1Set;
                final avList = attrValues.elements.toList();
                if (avList.isNotEmpty) {
                  final timeObj = avList[0];
                  if (timeObj is ASN1UtcTime) {
                    signingTime = timeObj.dateTimeValue;
                  }
                }
              }
            }
          } catch (_) {
            // Non-fatal
          }
        } else if (el.tag == 0xA1) {
          hasTimestamp = true;
        }
      }

      // Detect signature algorithm
      for (final el in siFields) {
        if (el is ASN1Sequence && el.elements.isNotEmpty) {
          final firstChild = el.elements.first;
          if (firstChild is ASN1ObjectIdentifier) {
            final oidStr = firstChild.identifier ?? '';
            if (oidStr == '1.2.840.113549.1.1.11') {
              signatureAlgorithm = 'SHA256withRSA';
            } else if (oidStr == '1.2.840.113549.1.1.1') {
              signatureAlgorithm = 'RSA';
            } else if (oidStr.startsWith('1.2.840.10045')) {
              signatureAlgorithm = 'ECDSA';
            }
          }
        }
      }
    }

    return _ParsedSignedData(
      signerName: signerName,
      issuerName: issuerName,
      serialNumber: serialNumber,
      signatureAlgorithm: signatureAlgorithm,
      validFrom: validFrom,
      validTo: validTo,
      signingTime: signingTime,
      messageDigest: messageDigest,
      hasTimestamp: hasTimestamp,
      hasEmbeddedCerts: hasEmbeddedCerts,
    );
  }

  static void _extractCertInfo(
    ASN1Sequence tbsCert, {
    required void Function(String) onSubjectCN,
    required void Function(String) onIssuerCN,
    required void Function(String) onSerial,
    required void Function(DateTime, DateTime) onValidity,
  }) {
    final elements = tbsCert.elements.toList();
    int offset = 0;
    if (elements.isNotEmpty && elements[0].tag == 0xA0) {
      offset = 1;
    }

    // Serial number
    if (elements.length > offset) {
      final serial = elements[offset] as ASN1Integer;
      onSerial(serial.valueAsBigInteger.toRadixString(16).toUpperCase());
    }

    // Issuer (offset+2)
    if (elements.length > offset + 2) {
      final issuer = elements[offset + 2] as ASN1Sequence;
      final cn = _extractCommonName(issuer);
      if (cn != null) onIssuerCN(cn);
    }

    // Validity (offset+3)
    if (elements.length > offset + 3) {
      final validity = elements[offset + 3] as ASN1Sequence;
      final valElements = validity.elements.toList();
      if (valElements.length >= 2) {
        final notBefore = valElements[0];
        final notAfter = valElements[1];

        DateTime? from;
        DateTime? to;

        if (notBefore is ASN1UtcTime) from = notBefore.dateTimeValue;
        if (notAfter is ASN1UtcTime) to = notAfter.dateTimeValue;

        if (from != null && to != null) onValidity(from, to);
      }
    }

    // Subject (offset+4)
    if (elements.length > offset + 4) {
      final subject = elements[offset + 4] as ASN1Sequence;
      final cn = _extractCommonName(subject);
      if (cn != null) onSubjectCN(cn);
    }
  }

  static String? _extractCommonName(ASN1Sequence name) {
    for (final rdn in name.elements) {
      if (rdn is! ASN1Set) continue;
      for (final atv in rdn.elements) {
        if (atv is! ASN1Sequence) continue;
        final atvParts = atv.elements.toList();
        if (atvParts.length < 2) continue;
        final oid = atvParts[0];
        if (oid is ASN1ObjectIdentifier && oid.identifier == '2.5.4.3') {
          final value = atvParts[1];
          if (value is ASN1UTF8String) return value.utf8StringValue;
          if (value is ASN1PrintableString) return value.stringValue;
          return String.fromCharCodes(value.valueBytes());
        }
      }
    }
    return null;
  }

  static bool _compareBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _ParsedSignedData {
  const _ParsedSignedData({
    this.signerName,
    this.issuerName,
    this.serialNumber,
    this.signatureAlgorithm,
    this.validFrom,
    this.validTo,
    this.signingTime,
    required this.messageDigest,
    this.hasTimestamp = false,
    this.hasEmbeddedCerts = false,
  });

  final String? signerName;
  final String? issuerName;
  final String? serialNumber;
  final String? signatureAlgorithm;
  final DateTime? validFrom;
  final DateTime? validTo;
  final DateTime? signingTime;
  final Uint8List messageDigest;
  final bool hasTimestamp;
  final bool hasEmbeddedCerts;
}
