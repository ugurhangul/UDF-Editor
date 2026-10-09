import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:pointycastle/export.dart';

import 'models.dart';
import 'trust_store.dart';

/// Parses and verifies CMS SignedData from sign.sgn files.
class SignatureVerifier {
  static const _oidSha256 = '2.16.840.1.101.3.4.2.1';
  static const _oidRsaEncryption = '1.2.840.113549.1.1.1';
  static const _oidSha256WithRsa = '1.2.840.113549.1.1.11';
  static const _oidSha384WithRsa = '1.2.840.113549.1.1.12';
  static const _oidSha512WithRsa = '1.2.840.113549.1.1.13';
  static const _oidSha1WithRsa = '1.2.840.113549.1.1.5';
  static const _oidEcPublicKey = '1.2.840.10045.2.1';
  static const _oidEcdsaSha256 = '1.2.840.10045.4.3.2';
  static const _oidEcdsaSha384 = '1.2.840.10045.4.3.3';
  static const _oidEcdsaSha512 = '1.2.840.10045.4.3.4';
  static const _oidCurveP256 = '1.2.840.10045.3.1.7';
  static const _oidCurveP384 = '1.3.132.0.34';
  static const _oidCurveP521 = '1.3.132.0.35';
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

      SignatureStatus status;
      var signatureOk = false;
      if (!digestMatches) {
        status = SignatureStatus.invalid;
      } else if (!_isDocumentVerifiable(parsed)) {
        // CRITICAL-02 fail closed: unsupported algorithm or missing public key —
        // cannot prove validity, so never report valid.
        status = SignatureStatus.unknown;
      } else {
        // CRITICAL-02: verify the signature over the signed attributes (or the
        // content when no signed attrs) — a hash compare alone is forgeable.
        final signedBytes = hasSignedAttrs
            ? _signedAttrsSetDer(parsed.signedAttrsRaw!)
            : contentXmlBytes;
        signatureOk = _verifyDocumentSignature(parsed, signedBytes);
        if (!signatureOk) {
          status = SignatureStatus.invalid;
        } else if (certExpired) {
          status = SignatureStatus.expired;
        } else {
          status = SignatureStatus.valid;
        }
      }

      // Trust anchoring is only meaningful once the signature itself verified.
      var trustLevel = TrustLevel.notEvaluated;
      String? anchorName;
      if (signatureOk) {
        anchorName = _buildTrustChain(parsed);
        trustLevel = anchorName != null
            ? TrustLevel.trustedChain
            : TrustLevel.untrustedAnchor;
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
        trustLevel: trustLevel,
        anchorName: anchorName,
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

  /// True when [bytes] is already a CMS ContentInfo wrapping SignedData —
  /// i.e. a complete sign.sgn. Used to detect a Mobil İmza operator that
  /// returns a full envelope instead of a raw signature, so it can be used
  /// as-is rather than re-wrapped.
  static bool isCmsSignedData(Uint8List bytes) {
    try {
      final ci = ASN1Parser(bytes).nextObject();
      if (ci is! ASN1Sequence || ci.elements.isEmpty) return false;
      final oid = ci.elements.first;
      return oid is ASN1ObjectIdentifier &&
          oid.identifier == '1.2.840.113549.1.7.2';
    } catch (_) {
      return false;
    }
  }

  // ── Cryptographic verification ────────────────────────────────────────

  /// The document signature is verifiable when we have a signer public key
  /// (RSA or EC), signature bytes, an RSA/ECDSA signature algorithm, and the
  /// SHA-256 message digest CMS uses.
  static bool _isDocumentVerifiable(_ParsedSignedData parsed) {
    final cert = parsed.signerCert;
    final sigAlg = parsed.signatureAlgorithmOid;
    if (parsed.signatureBytes == null ||
        parsed.signatureBytes!.isEmpty ||
        cert == null ||
        parsed.digestAlgorithmOid != _oidSha256) {
      return false;
    }
    final isRsa = (sigAlg == _oidSha256WithRsa || sigAlg == _oidRsaEncryption) &&
        cert.modulus != null &&
        cert.exponent != null;
    final isEcdsa = sigAlg == _oidEcdsaSha256 && cert.ecPoint != null;
    return isRsa || isEcdsa;
  }

  /// Verify the document signature (RSA or ECDSA, SHA-256) over [data].
  static bool _verifyDocumentSignature(_ParsedSignedData parsed, Uint8List data) {
    final cert = parsed.signerCert!;
    final sig = parsed.signatureBytes!;
    final sigAlg = parsed.signatureAlgorithmOid;
    if (sigAlg == _oidEcdsaSha256) {
      return _verifyEcdsa(data, sig, cert, SHA256Digest());
    }
    return _verifyRsa(data, sig, cert.modulus!, cert.exponent!, SHA256Digest(),
        _sha256DigestInfoHex);
  }

  static bool _verifyRsa(
    Uint8List data,
    Uint8List signature,
    BigInt modulus,
    BigInt exponent,
    Digest digest,
    String digestInfoHex,
  ) {
    try {
      final verifier = RSASigner(digest, digestInfoHex);
      verifier.init(
        false,
        PublicKeyParameter<RSAPublicKey>(RSAPublicKey(modulus, exponent)),
      );
      return verifier.verifySignature(data, RSASignature(signature));
    } catch (_) {
      // CRITICAL-02 fail closed: any decode/crypto error is a failure.
      return false;
    }
  }

  static bool _verifyEcdsa(
    Uint8List data,
    Uint8List derSignature,
    _ParsedCert cert,
    Digest digest,
  ) {
    try {
      if (cert.ecPoint == null || cert.ecCurveOid == null) return false;
      final domain = _ecDomain(cert.ecCurveOid!);
      if (domain == null) return false;
      final q = domain.curve.decodePoint(cert.ecPoint!);
      if (q == null) return false;

      // ECDSA signature is SEQUENCE { r INTEGER, s INTEGER }.
      final seq = ASN1Parser(derSignature).nextObject();
      if (seq is! ASN1Sequence || seq.elements.length < 2) return false;
      final r = (seq.elements[0] as ASN1Integer).valueAsBigInteger;
      final s = (seq.elements[1] as ASN1Integer).valueAsBigInteger;

      final signer = ECDSASigner(digest);
      signer.init(false, PublicKeyParameter<ECPublicKey>(ECPublicKey(q, domain)));
      return signer.verifySignature(data, ECSignature(r, s));
    } catch (_) {
      return false;
    }
  }

  static ECDomainParameters? _ecDomain(String curveOid) {
    switch (curveOid) {
      case _oidCurveP256:
        return ECCurve_secp256r1();
      case _oidCurveP384:
        return ECCurve_secp384r1();
      case _oidCurveP521:
        return ECCurve_secp521r1();
      default:
        return null;
    }
  }

  /// Verify [child]'s TBSCertificate signature against [issuer]'s public key,
  /// using the algorithm named in [child.signatureAlgOid] (RSA or ECDSA,
  /// SHA-1/256/384/512). Proves the issuance link.
  static bool _verifyCertLink(_ParsedCert child, _ParsedCert issuer) {
    final alg = child.signatureAlgOid;
    final sig = child.signature;
    if (alg == null || sig == null) return false;
    switch (alg) {
      case _oidSha256WithRsa:
        return _rsaLink(child, issuer, SHA256Digest(), _sha256DigestInfoHex);
      case _oidSha384WithRsa:
        return _rsaLink(child, issuer, SHA384Digest(),
            '06096086480165030402020500');
      case _oidSha512WithRsa:
        return _rsaLink(child, issuer, SHA512Digest(),
            '06096086480165030402030500');
      case _oidSha1WithRsa:
        return _rsaLink(child, issuer, SHA1Digest(), '06052b0e03021a0500');
      case _oidEcdsaSha256:
        return issuer.ecPoint != null &&
            _verifyEcdsa(child.tbsDer, sig, issuer, SHA256Digest());
      case _oidEcdsaSha384:
        return issuer.ecPoint != null &&
            _verifyEcdsa(child.tbsDer, sig, issuer, SHA384Digest());
      case _oidEcdsaSha512:
        return issuer.ecPoint != null &&
            _verifyEcdsa(child.tbsDer, sig, issuer, SHA512Digest());
      default:
        return false;
    }
  }

  static bool _rsaLink(
    _ParsedCert child,
    _ParsedCert issuer,
    Digest digest,
    String digestInfoHex,
  ) {
    if (issuer.modulus == null || issuer.exponent == null) return false;
    return _verifyRsa(child.tbsDer, child.signature!, issuer.modulus!,
        issuer.exponent!, digest, digestInfoHex);
  }

  /// Build a trust path from the signer certificate to a bundled anchor.
  /// Candidate issuers are the embedded certs plus the bundled trust anchors;
  /// each link is verified cryptographically. Returns the trusted anchor name,
  /// or null when no chain to a bundled anchor could be built.
  static String? _buildTrustChain(_ParsedSignedData parsed) {
    final signer = parsed.signerCert;
    if (signer == null) return null;

    final anchors = _trustAnchorCerts();
    // A directly-embedded anchor (signer IS a pinned CA) is trusted as-is.
    final signerAnchor = _matchAnchor(signer, anchors);
    if (signerAnchor != null) return signerAnchor.subjectCN ?? 'Güvenilir kök';

    final candidates = <_ParsedCert>[
      ...parsed.certificates,
      ...anchors.map((a) => a.cert),
    ];

    var current = signer;
    final seen = <String>{}; // subjectDer hex, to stop loops
    for (var depth = 0; depth < 10; depth++) {
      seen.add(_hex(current.subjectDer));
      // Find an issuer whose subject matches current.issuer and that signed it.
      _ParsedCert? issuer;
      for (final c in candidates) {
        if (!_ParsedCert._bytesEqual(c.subjectDer, current.issuerDer)) continue;
        if (seen.contains(_hex(c.subjectDer)) && !c.isSelfSigned) continue;
        if (_verifyCertLink(current, c)) {
          issuer = c;
          break;
        }
      }
      if (issuer == null) return null; // chain broken / incomplete

      final anchor = _matchAnchor(issuer, anchors);
      if (anchor != null) return anchor.name;
      if (issuer.isSelfSigned) return null; // self-signed but not pinned
      current = issuer;
    }
    return null;
  }

  static _TrustAnchorCert? _matchAnchor(
    _ParsedCert cert,
    List<_TrustAnchorCert> anchors,
  ) {
    final fp = _sha256Hex(cert.der);
    for (final a in anchors) {
      if (a.fingerprint == fp) return a;
    }
    return null;
  }

  static List<_TrustAnchorCert>? _cachedAnchors;
  static List<_TrustAnchorCert> _trustAnchorCerts() {
    final cached = _cachedAnchors;
    if (cached != null) return cached;
    final list = <_TrustAnchorCert>[];
    for (final a in TrustStore.anchors) {
      try {
        final seq = ASN1Parser(a.der).nextObject();
        if (seq is! ASN1Sequence) continue;
        final cert = _parseCert(seq);
        if (cert != null) {
          list.add(_TrustAnchorCert(a.name, a.sha256Fingerprint, cert));
        }
      } catch (_) {
        // Skip a malformed bundled anchor rather than fail all verification.
      }
    }
    return _cachedAnchors = list;
  }

  static String _sha256Hex(Uint8List data) =>
      _hex(SHA256Digest().process(data));

  static String _hex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString().toUpperCase();
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

      // SubjectPublicKeyInfo → RSA { modulus, exponent } or EC { point, curve }
      BigInt? modulus;
      BigInt? exponent;
      Uint8List? ecPoint;
      String? ecCurveOid;
      final spki = tbsElements[offset + 5];
      if (spki is ASN1Sequence && spki.elements.length >= 2) {
        final spkiElements = spki.elements.toList();
        final algSeq = spkiElements[0];
        final keyAlgOid = _algorithmOid(algSeq);
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
        } else if (keyAlgOid == _oidEcPublicKey && keyBits is ASN1BitString) {
          ecPoint = Uint8List.fromList(keyBits.stringValue);
          // AlgorithmIdentifier parameters carry the named-curve OID.
          if (algSeq is ASN1Sequence && algSeq.elements.length >= 2) {
            final param = algSeq.elements.toList()[1];
            if (param is ASN1ObjectIdentifier) ecCurveOid = param.identifier;
          }
        }
      }

      // signatureAlgorithm (Certificate SEQ element [1]) + signature BIT STRING [2]
      String? signatureAlgOid;
      if (certElements.length >= 2) {
        signatureAlgOid = _algorithmOid(certElements[1]);
      }
      Uint8List? signature;
      if (certElements.length >= 3) {
        final sigBits = certElements[2];
        if (sigBits is ASN1BitString) {
          signature = Uint8List.fromList(sigBits.stringValue);
        }
      }

      return _ParsedCert(
        der: Uint8List.fromList(cert.encodedBytes),
        tbsDer: Uint8List.fromList(tbsCert.encodedBytes),
        serial: serial,
        issuerDer: Uint8List.fromList(issuer.encodedBytes),
        subjectDer: Uint8List.fromList(subject.encodedBytes),
        subjectCN: _extractCommonName(subject),
        issuerCN: _extractCommonName(issuer),
        validFrom: validFrom,
        validTo: validTo,
        modulus: modulus,
        exponent: exponent,
        ecPoint: ecPoint,
        ecCurveOid: ecCurveOid,
        signature: signature,
        signatureAlgOid: signatureAlgOid,
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
    if (oid == _oidSha384WithRsa) return 'SHA384withRSA';
    if (oid == _oidSha512WithRsa) return 'SHA512withRSA';
    if (oid == _oidRsaEncryption) return 'RSA';
    if (oid == _oidEcdsaSha256) return 'SHA256withECDSA';
    if (oid == _oidEcdsaSha384) return 'SHA384withECDSA';
    if (oid == _oidEcdsaSha512) return 'SHA512withECDSA';
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
    required this.der,
    required this.tbsDer,
    required this.serial,
    required this.issuerDer,
    required this.subjectDer,
    this.subjectCN,
    this.issuerCN,
    this.validFrom,
    this.validTo,
    this.modulus,
    this.exponent,
    this.ecPoint,
    this.ecCurveOid,
    this.signature,
    this.signatureAlgOid,
  });

  /// Full DER of the certificate (for SHA-256 anchor fingerprinting).
  final Uint8List der;
  final Uint8List tbsDer;
  final BigInt serial;
  final Uint8List issuerDer;
  final Uint8List subjectDer;
  final String? subjectCN;
  final String? issuerCN;
  final DateTime? validFrom;
  final DateTime? validTo;

  /// RSA public key components (null for EC keys).
  final BigInt? modulus;
  final BigInt? exponent;

  /// EC public key: uncompressed point (0x04||X||Y) and named-curve OID.
  final Uint8List? ecPoint;
  final String? ecCurveOid;

  /// This certificate's signature and the algorithm the issuer used to sign
  /// its TBSCertificate (used to verify the child→issuer link).
  final Uint8List? signature;
  final String? signatureAlgOid;

  bool get isSelfSigned => _bytesEqual(issuerDer, subjectDer);

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _TrustAnchorCert {
  const _TrustAnchorCert(this.name, this.fingerprint, this.cert);
  final String name;
  final String fingerprint;
  final _ParsedCert cert;
  String? get subjectCN => cert.subjectCN;
}
