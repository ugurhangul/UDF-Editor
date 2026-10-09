import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:pointycastle/export.dart';

import 'models.dart';
import 'tsa_client.dart';

/// Builds CAdES-X-LONG compliant CMS SignedData envelopes.
///
/// The output is a DER-encoded `sign.sgn` file compatible with UYAP's
/// expected format: CMS v3, SHA-256, with embedded timestamp and
/// validation data (certificates + CRL/OCSP responses).
class CadesBuilder {
  CadesBuilder({
    this.tsaClient,
  });

  /// Optional TSA client for CAdES-T/X-LONG.
  /// If null, falls back to CAdES-BES.
  final TsaClient? tsaClient;

  // ── OIDs ──────────────────────────────────────────────────────────────
  static const _oidSignedData = '1.2.840.113549.1.7.2';
  static const _oidData = '1.2.840.113549.1.7.1';
  static const _oidSha256 = '2.16.840.1.101.3.4.2.1';
  static const _oidSha256WithRsa = '1.2.840.113549.1.1.11';
  static const _oidContentType = '1.2.840.113549.1.9.3';
  static const _oidMessageDigest = '1.2.840.113549.1.9.4';
  static const _oidSigningTime = '1.2.840.113549.1.9.5';
  static const _oidSigningCertificateV2 = '1.2.840.113549.1.9.16.2.47';
  static const _oidTimestampToken = '1.2.840.113549.1.9.16.2.14';

  /// Compute SHA-256 hash of content.xml bytes.
  static Uint8List hashContentXml(Uint8List contentXmlBytes) {
    final digest = SHA256Digest();
    return digest.process(contentXmlBytes);
  }

  /// Phase 1 of RFC 5652 §5.4 signing: build the SignedAttributes the
  /// device must sign. Returns the DER-encoded SET OF Attribute (tag 0x31);
  /// the signing device signs SHA-256 over exactly these bytes.
  ///
  /// Pass the result back via [SigningResult.signedAttributes] so
  /// [buildSignedData] embeds the identical attributes (the signing-time
  /// inside must match what was signed).
  static Uint8List prepareSignedAttributes({
    required Uint8List contentXmlBytes,
    required Uint8List signerCertDer,
    DateTime? signingTime,
  }) {
    final attrs = _buildSignedAttributes(
      contentHash: hashContentXml(contentXmlBytes),
      signingTime: signingTime ?? DateTime.now().toUtc(),
      signerCertDer: signerCertDer,
    );
    return attrs.encodedBytes;
  }

  /// Build a complete CAdES CMS SignedData envelope.
  ///
  /// [contentXmlBytes] — Raw bytes of content.xml (the data being signed).
  /// [signingResult] — Signature + certificate from the signing device.
  ///
  /// CRITICAL-02 companion: when [SigningResult.signedAttributes] is set,
  /// those exact bytes are embedded as signedAttrs [0] IMPLICIT (the
  /// signature must cover them per RFC 5652 §5.4). When null (Mobil İmza:
  /// device signed the content directly), signedAttrs are omitted so the
  /// envelope stays cryptographically consistent.
  ///
  /// Returns DER-encoded CMS ContentInfo wrapping SignedData.
  Future<Uint8List> buildSignedData({
    required Uint8List contentXmlBytes,
    required SigningResult signingResult,
  }) async {
    final certificate = signingResult.certificate;
    if (certificate == null) {
      throw ArgumentError('SigningResult.certificate is required for CMS envelope');
    }

    // ── 2. Build UnsignedAttributes (timestamp) ─────────────────────────
    ASN1Set? unsignedAttrs;
    if (tsaClient != null) {
      try {
        final signatureHash = hashContentXml(signingResult.signature);
        final timestampToken = await tsaClient!.requestTimestamp(signatureHash);
        unsignedAttrs = _buildUnsignedAttributes(timestampToken);
      } on TsaException {
        // TSA failure is non-fatal — fall back to CAdES-BES
      }
    }

    // ── 3. Parse signer certificate for IssuerAndSerialNumber ────────────
    final certParser = ASN1Parser(certificate);
    final certSeq = certParser.nextObject() as ASN1Sequence;
    final certElements = certSeq.elements.toList();
    final tbsCert = certElements[0] as ASN1Sequence;
    final issuerAndSerial = _extractIssuerAndSerial(tbsCert);

    // ── 4. Build SignerInfo ──────────────────────────────────────────────
    final signedAttrsDer = signingResult.signedAttributes;
    final signerInfo = ASN1Sequence()
      ..add(ASN1Integer.fromInt(1)) // version
      ..add(issuerAndSerial) // issuerAndSerialNumber
      ..add(_sha256AlgorithmIdentifier()); // digestAlgorithm
    if (signedAttrsDer != null) {
      // signedAttrs [0] IMPLICIT — exact bytes the device signed
      signerInfo.add(
        _wrapImplicit(0, ASN1Parser(signedAttrsDer).nextObject()),
      );
    }
    signerInfo
      ..add(_rsaSha256AlgorithmIdentifier()) // signatureAlgorithm
      ..add(ASN1OctetString(signingResult.signature)); // signature

    if (unsignedAttrs != null) {
      signerInfo.add(_wrapImplicit(1, unsignedAttrs));
    }

    // ── 5. Build Certificates SET ───────────────────────────────────────
    final certificates = ASN1Set();
    certificates.add(ASN1Parser(certificate).nextObject());
    for (final chainCert in signingResult.certificateChain) {
      certificates.add(ASN1Parser(chainCert).nextObject());
    }

    // ── 6. Build SignedData ──────────────────────────────────────────────
    final signedData = ASN1Sequence()
      ..add(ASN1Integer.fromInt(3)) // version v3
      ..add(ASN1Set()..add(_sha256AlgorithmIdentifier())) // digestAlgorithms
      ..add(ASN1Sequence()
        ..add(ASN1ObjectIdentifier.fromComponentString(_oidData))) // encapContentInfo (detached)
      ..add(_wrapImplicit(0, certificates)) // certificates [0]
      ..add(ASN1Set()..add(signerInfo)); // signerInfos

    // ── 7. Wrap in ContentInfo ───────────────────────────────────────────
    final contentInfo = ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString(_oidSignedData))
      ..add(_wrapExplicit(0, signedData));

    return contentInfo.encodedBytes;
  }

  // ── Private helpers ───────────────────────────────────────────────────

  static ASN1Set _buildSignedAttributes({
    required Uint8List contentHash,
    required DateTime signingTime,
    required Uint8List signerCertDer,
  }) {
    final attrs = ASN1Set();

    // content-type
    attrs.add(ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString(_oidContentType))
      ..add(ASN1Set()
        ..add(ASN1ObjectIdentifier.fromComponentString(_oidData))));

    // signing-time
    attrs.add(ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString(_oidSigningTime))
      ..add(ASN1Set()..add(ASN1UtcTime(signingTime))));

    // message-digest
    attrs.add(ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString(_oidMessageDigest))
      ..add(ASN1Set()..add(ASN1OctetString(contentHash))));

    // signing-certificate-v2 (CAdES mandatory)
    final certHash = SHA256Digest().process(signerCertDer);
    final essCertIdV2 = ASN1Sequence()
      ..add(_sha256AlgorithmIdentifier())
      ..add(ASN1OctetString(certHash));

    attrs.add(ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString(_oidSigningCertificateV2))
      ..add(ASN1Set()
        ..add(ASN1Sequence()
          ..add(ASN1Sequence()..add(essCertIdV2)))));

    return attrs;
  }

  ASN1Set _buildUnsignedAttributes(Uint8List timestampTokenDer) {
    final attrs = ASN1Set();
    attrs.add(ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString(_oidTimestampToken))
      ..add(ASN1Set()..add(ASN1Parser(timestampTokenDer).nextObject())));
    return attrs;
  }

  ASN1Sequence _extractIssuerAndSerial(ASN1Sequence tbsCert) {
    final elements = tbsCert.elements.toList();
    int offset = 0;
    if (elements.isNotEmpty && elements[0].tag == 0xA0) {
      offset = 1;
    }
    final serialNumber = elements[offset];
    final issuer = elements[offset + 2];
    return ASN1Sequence()
      ..add(issuer)
      ..add(serialNumber);
  }

  static ASN1Sequence _sha256AlgorithmIdentifier() {
    return ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString(_oidSha256))
      ..add(ASN1Null());
  }

  static ASN1Sequence _rsaSha256AlgorithmIdentifier() {
    return ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString(_oidSha256WithRsa))
      ..add(ASN1Null());
  }

  /// Wrap an ASN1Object with an IMPLICIT context-specific tag [tagNumber].
  ASN1Object _wrapImplicit(int tagNumber, ASN1Object content) {
    final encoded = content.encodedBytes;
    final tag = 0xA0 | tagNumber;
    final result = Uint8List.fromList(encoded);
    result[0] = tag;
    return ASN1Parser(result).nextObject();
  }

  /// Wrap an ASN1Object with an EXPLICIT context-specific tag [tagNumber].
  ASN1Object _wrapExplicit(int tagNumber, ASN1Object content) {
    final inner = content.encodedBytes;
    final tag = 0xA0 | tagNumber;
    final lengthBytes = _encodeLength(inner.length);
    final result = Uint8List(1 + lengthBytes.length + inner.length);
    result[0] = tag;
    result.setRange(1, 1 + lengthBytes.length, lengthBytes);
    result.setRange(1 + lengthBytes.length, result.length, inner);
    return ASN1Parser(result).nextObject();
  }

  /// Encode ASN.1 length bytes (DER definite form).
  static Uint8List _encodeLength(int length) {
    if (length < 0x80) {
      return Uint8List.fromList([length]);
    }
    // Count bytes needed
    int temp = length;
    int byteCount = 0;
    while (temp > 0) {
      byteCount++;
      temp >>= 8;
    }
    final result = Uint8List(1 + byteCount);
    result[0] = 0x80 | byteCount;
    for (int i = byteCount; i > 0; i--) {
      result[i] = length & 0xFF;
      length >>= 8;
    }
    return result;
  }
}
