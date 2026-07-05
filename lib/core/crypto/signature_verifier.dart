import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:pointycastle/export.dart';

import 'models.dart';

/// Parses and verifies CMS SignedData from sign.sgn files.
class SignatureVerifier {
  static const _oidSha256 = '2.16.840.1.101.3.4.2.1';
  static const _oidRsaEncryption = '1.2.840.113549.1.1.1';
  static const _oidSha256WithRsa = '1.2.840.113549.1.1.11';
  static const _oidMessageDigest = '1.2.840.113549.1.9.4';
  static const _oidSigningTime = '1.2.840.113549.1.9.5';
  static const _oidCommonName = '2.5.4.3';
  static const _sha256DigestInfoHex = '0609608648016503040201';

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
      final hasSignedAttrs = parsed.signedAttrsRaw != null;
      final digestMatches =
          !hasSignedAttrs || _compareBytes(expectedHash, parsed.messageDigest);

      final now = DateTime.now().toUtc();
      final certExpired = parsed.validTo != null && now.isAfter(parsed.validTo!);

      // CRITICAL-02: best-effort chain check — informational only (SignatureInfo
      // has no chain field); the signer-signature verification below is the gate.
      if (parsed.certificates.length > 1) {
        _verifyCertChain(parsed);
      }

      SignatureStatus status;
      if (!digestMatches) {
        status = SignatureStatus.invalid;
      } else if (!_isRsaSha256Verifiable(parsed)) {
        // CRITICAL-02 fail closed: non-RSA algorithm or missing public key —
        // cannot prove validity, so never report valid.
        status = SignatureStatus.unknown;
      } else {
        // CRITICAL-02: verify RSA signature over signed attributes — hash
        // compare alone is forgeable.
        final signedBytes = hasSignedAttrs
            ? _signedAttrsSetDer(parsed.signedAttrsRaw!)
            : contentXmlBytes;
        final signatureOk = _verifyRsaSha256(
          signedBytes,
          parsed.signatureBytes!,
          parsed.signerCert!.modulus!,
          parsed.signerCert!.exponent!,
        );
        if (!signatureOk) {
          status = SignatureStatus.invalid;
        } else if (certExpired) {
          status = SignatureStatus.expired;
        } else {
          status = SignatureStatus.valid;
        }
      }

      return SignatureInfo(
        status: status,
        signerName: parsed.signerName,
        issuerName: parsed.issuerName,
        signingTime: parsed.signingTime,
        validFrom: parsed.validFrom,
        validTo: parsed.validTo,
        serialNumber: parsed.serialNumber,
        digestAlgorithm:
            parsed.digestAlgorithmOid == _oidSha256 ? 'SHA-256' : null,
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
        digestAlgorithm:
            parsed.digestAlgorithmOid == _oidSha256 ? 'SHA-256' : null,
        signatureAlgorithm: parsed.signatureAlgorithm,
        hasTimestamp: parsed.hasTimestamp,
        hasEmbeddedValidation: parsed.hasEmbeddedCerts,
      );
    } catch (_) {
      return const SignatureInfo(status: SignatureStatus.unknown);
    }
  }

  // ── Cryptographic verification ────────────────────────────────────────

  static bool _isRsaSha256Verifiable(_ParsedSignedData parsed) {
    final cert = parsed.signerCert;
    final sigAlg = parsed.signatureAlgorithmOid;
    return parsed.signatureBytes != null &&
        parsed.signatureBytes!.isNotEmpty &&
        cert != null &&
        cert.modulus != null &&
        cert.exponent != null &&
        (sigAlg == _oidSha256WithRsa || sigAlg == _oidRsaEncryption) &&
        parsed.digestAlgorithmOid == _oidSha256;
  }

  static bool _verifyRsaSha256(
    Uint8List data,
    Uint8List signature,
    BigInt modulus,
    BigInt exponent,
  ) {
    try {
      final verifier = RSASigner(SHA256Digest(), _sha256DigestInfoHex);
      verifier.init(
        false,
        PublicKeyParameter<RSAPublicKey>(RSAPublicKey(modulus, exponent)),
      );
      return verifier.verifySignature(data, RSASignature(signature));
    } catch (_) {
      // CRITICAL-02 fail closed: any decode/crypto error is a verification failure.
      return false;
    }
  }

  /// Try to verify the signer cert's TBSCertificate against the other
  /// embedded certs' public keys. Best effort — result is informational.
  static bool _verifyCertChain(_ParsedSignedData parsed) {
    final signer = parsed.signerCert;
    if (signer == null || signer.signature == null) return false;
    for (final issuerCert in parsed.certificates) {
      if (identical(issuerCert, signer)) continue;
      final modulus = issuerCert.modulus;
      final exponent = issuerCert.exponent;
      if (modulus == null || exponent == null) continue;
      if (_verifyRsaSha256(signer.tbsDer, signer.signature!, modulus, exponent)) {
        return true;
      }
    }
    return false;
  }

  /// RFC 5652 §5.4: the signature input is the DER encoding of
  /// SignedAttributes under the EXPLICIT SET OF tag (0x31), not the
  /// [0] IMPLICIT tag used inside SignerInfo.
  static Uint8List _signedAttrsSetDer(Uint8List implicitValueBytes) {
    final lengthBytes = _encodeDerLength(implicitValueBytes.length);
    final out = Uint8List(1 + lengthBytes.length + implicitValueBytes.length);
    out[0] = 0x31;
    out.setRange(1, 1 + lengthBytes.length, lengthBytes);
    out.setRange(1 + lengthBytes.length, out.length, implicitValueBytes);
    return out;
  }

  static Uint8List _encodeDerLength(int length) {
    if (length < 0x80) {
      return Uint8List.fromList([length]);
    }
    var temp = length;
    var byteCount = 0;
    while (temp > 0) {
      byteCount++;
      temp >>= 8;
    }
    final result = Uint8List(1 + byteCount);
    result[0] = 0x80 | byteCount;
    var remaining = length;
    for (var i = byteCount; i > 0; i--) {
      result[i] = remaining & 0xFF;
      remaining >>= 8;
    }
    return result;
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
    final certificates = <_ParsedCert>[];
    var hasEmbeddedCerts = false;

    for (final el in sdElements) {
      if (el.tag == 0xA0) {
        hasEmbeddedCerts = true;
        try {
          final certsParser = ASN1Parser(el.valueBytes());
          while (certsParser.hasNext()) {
            final certObj = certsParser.nextObject();
            if (certObj is! ASN1Sequence) continue;
            final cert = _parseCert(certObj);
            if (cert != null) certificates.add(cert);
          }
        } catch (_) {
          // Non-fatal
        }
      }
    }

    // Extract SignerInfo (last element):
    // version, sid, digestAlgorithm, [0] signedAttrs?, signatureAlgorithm,
    // signature, [1] unsignedAttrs?
    var messageDigest = Uint8List(0);
    DateTime? signingTime;
    DateTime? timestampTime;
    var hasTimestamp = false;
    Uint8List? signedAttrsRaw;
    Uint8List? signatureBytes;
    String? digestAlgorithmOid;
    String? signatureAlgorithmOid;
    Uint8List? sidIssuerDer;
    BigInt? sidSerial;

    final lastElement = sdElements.last;
    if (lastElement is ASN1Set && lastElement.elements.isNotEmpty) {
      final signerInfo = lastElement.elements.first as ASN1Sequence;
      final siFields = signerInfo.elements.toList();

      if (siFields.length > 1 && siFields[1] is ASN1Sequence) {
        // SignerIdentifier as issuerAndSerialNumber
        for (final part in (siFields[1] as ASN1Sequence).elements) {
          if (part is ASN1Integer) sidSerial = part.valueAsBigInteger;
          if (part is ASN1Sequence) {
            sidIssuerDer = Uint8List.fromList(part.encodedBytes);
          }
        }
      }
      if (siFields.length > 2) {
        digestAlgorithmOid = _algorithmOid(siFields[2]);
      }

      var idx = 3;
      if (siFields.length > idx && siFields[idx].tag == 0xA0) {
        signedAttrsRaw = Uint8List.fromList(siFields[idx].valueBytes());
        try {
          final attrsParser = ASN1Parser(signedAttrsRaw);
          while (attrsParser.hasNext()) {
            final attr = attrsParser.nextObject() as ASN1Sequence;
            final attrParts = attr.elements.toList();
            if (attrParts.length < 2) continue;

            final oid = attrParts[0] as ASN1ObjectIdentifier;
            final oidStr = oid.identifier ?? '';

            if (oidStr == _oidMessageDigest) {
              final avList = (attrParts[1] as ASN1Set).elements.toList();
              if (avList.isNotEmpty) {
                final octet = avList[0] as ASN1OctetString;
                messageDigest = Uint8List.fromList(octet.valueBytes());
              }
            } else if (oidStr == _oidSigningTime) {
              final avList = (attrParts[1] as ASN1Set).elements.toList();
              if (avList.isNotEmpty) {
                // UYAP envelopes use GeneralizedTime here, not UTCTime.
                signingTime = _readTime(avList[0]);
              }
            }
          }
        } catch (_) {
          // Non-fatal — an empty messageDigest fails the compare (closed).
        }
        idx++;
      }
      if (siFields.length > idx && siFields[idx] is ASN1Sequence) {
        signatureAlgorithmOid = _algorithmOid(siFields[idx]);
        idx++;
      }
      if (siFields.length > idx && siFields[idx] is ASN1OctetString) {
        signatureBytes =
            Uint8List.fromList((siFields[idx] as ASN1OctetString).valueBytes());
        idx++;
      }
      final unsignedAttrs = siFields.skip(idx).where((el) => el.tag == 0xA1);
      hasTimestamp = unsignedAttrs.isNotEmpty;
      // No signed signing-time attribute (common in UYAP CAdES-T envelopes) —
      // fall back to the TSA timestamp token's genTime so the UI can still
      // show a signing date.
      if (signingTime == null && hasTimestamp) {
        for (final ua in unsignedAttrs) {
          timestampTime = _extractTimestampGenTime(ua.valueBytes());
          if (timestampTime != null) break;
        }
      }
    }

    // Pick the signer cert by issuer+serial; fall back to the first cert.
    _ParsedCert? signerCert;
    if (sidIssuerDer != null && sidSerial != null) {
      for (final cert in certificates) {
        if (cert.serial == sidSerial &&
            _compareBytes(cert.issuerDer, sidIssuerDer)) {
          signerCert = cert;
          break;
        }
      }
    }
    signerCert ??= certificates.isNotEmpty ? certificates.first : null;

    return _ParsedSignedData(
      signerCert: signerCert,
      certificates: certificates,
      signatureAlgorithm: _describeSignatureAlgorithm(signatureAlgorithmOid),
      signatureAlgorithmOid: signatureAlgorithmOid,
      digestAlgorithmOid: digestAlgorithmOid,
      signingTime: signingTime ?? timestampTime,
      messageDigest: messageDigest,
      signedAttrsRaw: signedAttrsRaw,
      signatureBytes: signatureBytes,
      hasTimestamp: hasTimestamp,
      hasEmbeddedCerts: hasEmbeddedCerts,
    );
  }

  static _ParsedCert? _parseCert(ASN1Sequence cert) {
    try {
      final certElements = cert.elements.toList();
      if (certElements.isEmpty) return null;
      final tbsCert = certElements[0] as ASN1Sequence;
      final tbsElements = tbsCert.elements.toList();

      var offset = 0;
      if (tbsElements.isNotEmpty && tbsElements[0].tag == 0xA0) {
        offset = 1;
      }
      if (tbsElements.length < offset + 6) return null;

      final serial = (tbsElements[offset] as ASN1Integer).valueAsBigInteger;
      final issuer = tbsElements[offset + 2] as ASN1Sequence;
      final validity = tbsElements[offset + 3] as ASN1Sequence;
      final subject = tbsElements[offset + 4] as ASN1Sequence;

      DateTime? validFrom;
      DateTime? validTo;
      final valElements = validity.elements.toList();
      if (valElements.length >= 2) {
        validFrom = _readTime(valElements[0]);
        validTo = _readTime(valElements[1]);
      }

      // SubjectPublicKeyInfo → RSAPublicKey { modulus, publicExponent }
      BigInt? modulus;
      BigInt? exponent;
      final spki = tbsElements[offset + 5];
      if (spki is ASN1Sequence && spki.elements.length >= 2) {
        final spkiElements = spki.elements.toList();
        final keyAlgOid = _algorithmOid(spkiElements[0]);
        final keyBits = spkiElements[1];
        if (keyAlgOid == _oidRsaEncryption && keyBits is ASN1BitString) {
          final rsaKey = ASN1Parser(Uint8List.fromList(keyBits.stringValue))
              .nextObject();
          if (rsaKey is ASN1Sequence && rsaKey.elements.length >= 2) {
            final rkElements = rsaKey.elements.toList();
            final m = rkElements[0];
            final e = rkElements[1];
            if (m is ASN1Integer && e is ASN1Integer) {
              modulus = m.valueAsBigInteger;
              exponent = e.valueAsBigInteger;
            }
          }
        }
      }

      Uint8List? signature;
      if (certElements.length >= 3) {
        final sigBits = certElements[2];
        if (sigBits is ASN1BitString) {
          signature = Uint8List.fromList(sigBits.stringValue);
        }
      }

      return _ParsedCert(
        tbsDer: Uint8List.fromList(tbsCert.encodedBytes),
        serial: serial,
        issuerDer: Uint8List.fromList(issuer.encodedBytes),
        subjectCN: _extractCommonName(subject),
        issuerCN: _extractCommonName(issuer),
        validFrom: validFrom,
        validTo: validTo,
        modulus: modulus,
        exponent: exponent,
        signature: signature,
      );
    } catch (_) {
      return null;
    }
  }

  /// Best-effort scan for the first GeneralizedTime (tag 0x18) inside a TSA
  /// timestamp token — that's the TSTInfo genTime. Avoids fully decoding the
  /// nested CMS/TSTInfo structure; the token contains exactly one genTime.
  static DateTime? _extractTimestampGenTime(List<int> tokenBytes) {
    for (var i = 0; i + 1 < tokenBytes.length; i++) {
      if (tokenBytes[i] != 0x18) continue; // GeneralizedTime
      final len = tokenBytes[i + 1];
      // genTime is short-form DER: 13–19 ASCII chars (YYYYMMDDHHMMSS[.fff]Z).
      if (len < 13 || len > 20 || i + 2 + len > tokenBytes.length) continue;
      final s = String.fromCharCodes(tokenBytes.sublist(i + 2, i + 2 + len));
      if (!RegExp(r'^\d{14}').hasMatch(s)) continue;
      final dt = _parseAsn1TimeString(s, twoDigitYear: false);
      if (dt != null) return dt;
    }
    return null;
  }

  static DateTime? _readTime(ASN1Object obj) {
    if (obj is ASN1UtcTime) return obj.dateTimeValue;
    if (obj is ASN1GeneralizedTime) return obj.dateTimeValue;
    // Inside a SET (e.g. the signing-time attribute) asn1lib hands back a
    // generic ASN1Object with the time tag rather than a typed instance —
    // decode the ASCII time string directly.
    if (obj.tag == 0x17 || obj.tag == 0x18) {
      return _parseAsn1TimeString(
        String.fromCharCodes(obj.valueBytes()),
        twoDigitYear: obj.tag == 0x17,
      );
    }
    return null;
  }

  /// Parse UTCTime (YYMMDDHHMMSSZ) / GeneralizedTime (YYYYMMDDHHMMSSZ).
  static DateTime? _parseAsn1TimeString(String s, {required bool twoDigitYear}) {
    try {
      var str = s.trim();
      final zulu = str.endsWith('Z');
      if (zulu) str = str.substring(0, str.length - 1);
      var i = 0;
      int take(int n) {
        final v = int.parse(str.substring(i, i + n));
        i += n;
        return v;
      }

      int year;
      if (twoDigitYear) {
        final yy = take(2);
        year = yy >= 50 ? 1900 + yy : 2000 + yy; // RFC 5280 sliding window
      } else {
        year = take(4);
      }
      final month = take(2);
      final day = take(2);
      final hour = take(2);
      final minute = i + 2 <= str.length ? take(2) : 0;
      final second = i + 2 <= str.length ? take(2) : 0;
      return DateTime.utc(year, month, day, hour, minute, second);
    } catch (_) {
      return null;
    }
  }

  static String? _algorithmOid(ASN1Object obj) {
    if (obj is! ASN1Sequence || obj.elements.isEmpty) return null;
    final first = obj.elements.first;
    return first is ASN1ObjectIdentifier ? first.identifier : null;
  }

  static String? _describeSignatureAlgorithm(String? oid) {
    if (oid == null) return null;
    if (oid == _oidSha256WithRsa) return 'SHA256withRSA';
    if (oid == _oidRsaEncryption) return 'RSA';
    if (oid.startsWith('1.2.840.10045')) return 'ECDSA';
    return null;
  }

  static String? _extractCommonName(ASN1Sequence name) {
    for (final rdn in name.elements) {
      if (rdn is! ASN1Set) continue;
      for (final atv in rdn.elements) {
        if (atv is! ASN1Sequence) continue;
        final atvParts = atv.elements.toList();
        if (atvParts.length < 2) continue;
        final oid = atvParts[0];
        if (oid is ASN1ObjectIdentifier && oid.identifier == _oidCommonName) {
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
    this.signerCert,
    required this.certificates,
    this.signatureAlgorithm,
    this.signatureAlgorithmOid,
    this.digestAlgorithmOid,
    this.signingTime,
    required this.messageDigest,
    this.signedAttrsRaw,
    this.signatureBytes,
    this.hasTimestamp = false,
    this.hasEmbeddedCerts = false,
  });

  final _ParsedCert? signerCert;
  final List<_ParsedCert> certificates;
  final String? signatureAlgorithm;
  final String? signatureAlgorithmOid;
  final String? digestAlgorithmOid;
  final DateTime? signingTime;
  final Uint8List messageDigest;

  /// Raw content octets of the signedAttrs [0] IMPLICIT block.
  final Uint8List? signedAttrsRaw;
  final Uint8List? signatureBytes;
  final bool hasTimestamp;
  final bool hasEmbeddedCerts;

  String? get signerName => signerCert?.subjectCN;
  String? get issuerName => signerCert?.issuerCN;
  String? get serialNumber =>
      signerCert?.serial.toRadixString(16).toUpperCase();
  DateTime? get validFrom => signerCert?.validFrom;
  DateTime? get validTo => signerCert?.validTo;
}

class _ParsedCert {
  const _ParsedCert({
    required this.tbsDer,
    required this.serial,
    required this.issuerDer,
    this.subjectCN,
    this.issuerCN,
    this.validFrom,
    this.validTo,
    this.modulus,
    this.exponent,
    this.signature,
  });

  final Uint8List tbsDer;
  final BigInt serial;
  final Uint8List issuerDer;
  final String? subjectCN;
  final String? issuerCN;
  final DateTime? validFrom;
  final DateTime? validTo;
  final BigInt? modulus;
  final BigInt? exponent;
  final Uint8List? signature;
}
