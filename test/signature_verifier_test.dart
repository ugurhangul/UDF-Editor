import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:asn1lib/asn1lib.dart';

import 'package:udf_editor/core/crypto/cades_builder.dart';
import 'package:udf_editor/core/crypto/models.dart';
import 'package:udf_editor/core/crypto/signature_verifier.dart';
import 'package:udf_editor/core/crypto/trust_store.dart';

// ── Test PKI helpers (mirrors crypto_test.dart) ─────────────────────────

const _sha256DigestInfoHex = '0609608648016503040201';

SecureRandom _secureRandom() {
  final random = FortunaRandom();
  final seedSource = Random.secure();
  random.seed(KeyParameter(
    Uint8List.fromList(List.generate(32, (_) => seedSource.nextInt(256))),
  ));
  return random;
}

({RSAPublicKey publicKey, RSAPrivateKey privateKey}) _generateKeyPair() {
  final keyGen = RSAKeyGenerator()
    ..init(ParametersWithRandom(
      RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64),
      _secureRandom(),
    ));
  final keyPair = keyGen.generateKeyPair();
  return (
    publicKey: keyPair.publicKey as RSAPublicKey,
    privateKey: keyPair.privateKey as RSAPrivateKey,
  );
}

Uint8List _encodeRSAPublicKey(RSAPublicKey key) {
  final pubKeySeq = ASN1Sequence()
    ..add(ASN1Integer(key.modulus!))
    ..add(ASN1Integer(key.publicExponent!));

  final algorithmId = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.113549.1.1.1'))
    ..add(ASN1Null());

  final spki = ASN1Sequence()
    ..add(algorithmId)
    ..add(ASN1BitString(pubKeySeq.encodedBytes));

  return spki.encodedBytes;
}

Uint8List _derLength(int length) {
  if (length < 0x80) return Uint8List.fromList([length]);
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

ASN1Object _wrapExplicit(int tagNumber, ASN1Object content) {
  final inner = content.encodedBytes;
  final lengthBytes = _derLength(inner.length);
  final result = Uint8List(1 + lengthBytes.length + inner.length);
  result[0] = 0xA0 | tagNumber;
  result.setRange(1, 1 + lengthBytes.length, lengthBytes);
  result.setRange(1 + lengthBytes.length, result.length, inner);
  return ASN1Parser(result).nextObject();
}

ASN1Object _wrapImplicit(int tagNumber, ASN1Object content) {
  final encoded = Uint8List.fromList(content.encodedBytes);
  encoded[0] = 0xA0 | tagNumber;
  return ASN1Parser(encoded).nextObject();
}

Uint8List _buildSelfSignedCert({
  required RSAPublicKey publicKey,
  required RSAPrivateKey privateKey,
  required DateTime notBefore,
  required DateTime notAfter,
}) {
  final cn = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString('2.5.4.3'))
    ..add(ASN1UTF8String('Test Signer'));
  final rdn = ASN1Set()..add(cn);
  final name = ASN1Sequence()..add(rdn);

  final tbsCert = ASN1Sequence()
    ..add(_wrapExplicit(0, ASN1Integer.fromInt(2)))
    ..add(ASN1Integer.fromInt(1))
    ..add(ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.113549.1.1.11'))
      ..add(ASN1Null()))
    ..add(name)
    ..add(ASN1Sequence()
      ..add(ASN1UtcTime(notBefore))
      ..add(ASN1UtcTime(notAfter)))
    ..add(name)
    ..add(ASN1Parser(_encodeRSAPublicKey(publicKey)).nextObject());

  final sig = _rsaSign(tbsCert.encodedBytes, privateKey);

  final cert = ASN1Sequence()
    ..add(tbsCert)
    ..add(ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.113549.1.1.11'))
      ..add(ASN1Null()))
    ..add(ASN1BitString(sig));

  return cert.encodedBytes;
}

/// PKCS#1 v1.5 SHA-256 signature, left-padded to the modulus size so the
/// byte length is deterministic (tests locate the signature inside the
/// envelope to flip bytes).
Uint8List _rsaSign(Uint8List data, RSAPrivateKey privateKey) {
  final signer = RSASigner(SHA256Digest(), _sha256DigestInfoHex)
    ..init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey));
  final sig = signer.generateSignature(data).bytes;
  final keySize = (privateKey.modulus!.bitLength + 7) >> 3;
  if (sig.length >= keySize) return sig;
  final padded = Uint8List(keySize);
  padded.setRange(keySize - sig.length, keySize, sig);
  return padded;
}

int _indexOfSublist(Uint8List haystack, Uint8List needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Build an RFC 5652 compliant envelope via the production two-phase API:
/// prepareSignedAttributes → sign the SET OF DER → buildSignedData embeds
/// the identical attributes and the real signature.
Future<({Uint8List envelope, int signatureOffset})> _buildRfcEnvelope({
  required Uint8List contentXml,
  required Uint8List certDer,
  required RSAPrivateKey privateKey,
}) async {
  final signedAttrsDer = CadesBuilder.prepareSignedAttributes(
    contentXmlBytes: contentXml,
    signerCertDer: certDer,
  );
  final signature = _rsaSign(signedAttrsDer, privateKey);

  final builder = CadesBuilder();
  final envelope = await builder.buildSignedData(
    contentXmlBytes: contentXml,
    signingResult: SigningResult(
      signature: signature,
      certificate: certDer,
      signedAttributes: signedAttrsDer,
    ),
  );

  final offset = _indexOfSublist(envelope, signature);
  if (offset < 0) {
    throw StateError('signature not found in envelope');
  }
  return (envelope: envelope, signatureOffset: offset);
}

/// Build a CMS envelope with NO signed attributes: the signature covers the
/// content bytes directly.
Uint8List _buildNoSignedAttrsEnvelope({
  required Uint8List contentXml,
  required Uint8List certDer,
  required RSAPrivateKey privateKey,
  String signatureAlgorithmOid = '1.2.840.113549.1.1.11',
}) {
  final signature = _rsaSign(contentXml, privateKey);

  final certSeq = ASN1Parser(certDer).nextObject() as ASN1Sequence;
  final tbsElements = (certSeq.elements.first as ASN1Sequence).elements.toList();
  final off = tbsElements.first.tag == 0xA0 ? 1 : 0;
  final issuerAndSerial = ASN1Sequence()
    ..add(tbsElements[off + 2])
    ..add(tbsElements[off]);

  ASN1Sequence alg(String oid) => ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString(oid))
    ..add(ASN1Null());

  final signerInfo = ASN1Sequence()
    ..add(ASN1Integer.fromInt(1))
    ..add(issuerAndSerial)
    ..add(alg('2.16.840.1.101.3.4.2.1'))
    ..add(alg(signatureAlgorithmOid))
    ..add(ASN1OctetString(signature));

  final certificates = ASN1Set()..add(ASN1Parser(certDer).nextObject());

  final signedData = ASN1Sequence()
    ..add(ASN1Integer.fromInt(1))
    ..add(ASN1Set()..add(alg('2.16.840.1.101.3.4.2.1')))
    ..add(ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.113549.1.7.1')))
    ..add(_wrapImplicit(0, certificates))
    ..add(ASN1Set()..add(signerInfo));

  final contentInfo = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.113549.1.7.2'))
    ..add(_wrapExplicit(0, signedData));

  return contentInfo.encodedBytes;
}

// ── ECDSA (P-256) test PKI ──────────────────────────────────────────────

AsymmetricKeyPair<PublicKey, PrivateKey> _generateEcKeyPair() {
  final gen = ECKeyGenerator()
    ..init(ParametersWithRandom(
      ECKeyGeneratorParameters(ECCurve_secp256r1()),
      _secureRandom(),
    ));
  return gen.generateKeyPair();
}

Uint8List _ecSpki(ECPublicKey pub) {
  final algId = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.10045.2.1'))
    ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.10045.3.1.7'));
  final point = pub.Q!.getEncoded(false); // uncompressed 0x04||X||Y
  final spki = ASN1Sequence()
    ..add(algId)
    ..add(ASN1BitString(point));
  return spki.encodedBytes;
}

Uint8List _ecdsaSignDer(Uint8List data, ECPrivateKey priv) {
  final signer = ECDSASigner(SHA256Digest())
    ..init(true, ParametersWithRandom(
      PrivateKeyParameter<ECPrivateKey>(priv),
      _secureRandom(),
    ));
  final sig = signer.generateSignature(data) as ECSignature;
  final seq = ASN1Sequence()
    ..add(ASN1Integer(sig.r))
    ..add(ASN1Integer(sig.s));
  return seq.encodedBytes;
}

Uint8List _buildEcSelfSignedCert(ECPublicKey pub, ECPrivateKey priv) {
  final cn = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString('2.5.4.3'))
    ..add(ASN1UTF8String('EC Test Signer'));
  final name = ASN1Sequence()..add(ASN1Set()..add(cn));
  final now = DateTime.now().toUtc();
  final ecdsaSha256 = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.10045.4.3.2'));
  final tbs = ASN1Sequence()
    ..add(_wrapExplicit(0, ASN1Integer.fromInt(2)))
    ..add(ASN1Integer.fromInt(7))
    ..add(ecdsaSha256)
    ..add(name)
    ..add(ASN1Sequence()
      ..add(ASN1UtcTime(now))
      ..add(ASN1UtcTime(now.add(const Duration(days: 365)))))
    ..add(name)
    ..add(ASN1Parser(_ecSpki(pub)).nextObject());
  final sig = _ecdsaSignDer(tbs.encodedBytes, priv);
  final cert = ASN1Sequence()
    ..add(tbs)
    ..add(ecdsaSha256)
    ..add(ASN1BitString(sig));
  return cert.encodedBytes;
}

Uint8List _buildEcNoAttrsEnvelope({
  required Uint8List contentXml,
  required Uint8List certDer,
  required ECPrivateKey priv,
}) {
  final signature = _ecdsaSignDer(contentXml, priv);
  final certSeq = ASN1Parser(certDer).nextObject() as ASN1Sequence;
  final tbsElements = (certSeq.elements.first as ASN1Sequence).elements.toList();
  final off = tbsElements.first.tag == 0xA0 ? 1 : 0;
  final issuerAndSerial = ASN1Sequence()
    ..add(tbsElements[off + 2])
    ..add(tbsElements[off]);
  ASN1Sequence alg(String oid) => ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString(oid));
  final signerInfo = ASN1Sequence()
    ..add(ASN1Integer.fromInt(1))
    ..add(issuerAndSerial)
    ..add(ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString('2.16.840.1.101.3.4.2.1'))
      ..add(ASN1Null()))
    ..add(alg('1.2.840.10045.4.3.2')) // ecdsa-with-SHA256
    ..add(ASN1OctetString(signature));
  final certificates = ASN1Set()..add(ASN1Parser(certDer).nextObject());
  final signedData = ASN1Sequence()
    ..add(ASN1Integer.fromInt(1))
    ..add(ASN1Set()
      ..add(ASN1Sequence()
        ..add(ASN1ObjectIdentifier.fromComponentString(
            '2.16.840.1.101.3.4.2.1'))
        ..add(ASN1Null())))
    ..add(ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.113549.1.7.1')))
    ..add(_wrapImplicit(0, certificates))
    ..add(ASN1Set()..add(signerInfo));
  final contentInfo = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.113549.1.7.2'))
    ..add(_wrapExplicit(0, signedData));
  return contentInfo.encodedBytes;
}

void main() {
  late RSAPrivateKey privateKey;
  late Uint8List certDer;
  late Uint8List expiredCertDer;

  setUpAll(() {
    final keys = _generateKeyPair();
    privateKey = keys.privateKey;
    final now = DateTime.now().toUtc();
    certDer = _buildSelfSignedCert(
      publicKey: keys.publicKey,
      privateKey: privateKey,
      notBefore: now,
      notAfter: now.add(const Duration(days: 365)),
    );
    expiredCertDer = _buildSelfSignedCert(
      publicKey: keys.publicKey,
      privateKey: privateKey,
      notBefore: now.subtract(const Duration(days: 2)),
      notAfter: now.subtract(const Duration(days: 1)),
    );
  });

  group('SignatureVerifier CRITICAL-02', () {
    test('RFC 5652 envelope with real signature verifies as valid', () async {
      final contentXml = Uint8List.fromList('<content>Legal Document</content>'.codeUnits);
      final built = await _buildRfcEnvelope(
        contentXml: contentXml,
        certDer: certDer,
        privateKey: privateKey,
      );

      final info = SignatureVerifier.verify(
        signSgnBytes: built.envelope,
        contentXmlBytes: contentXml,
      );

      expect(info.status, SignatureStatus.valid);
      expect(info.signerName, 'Test Signer');
      expect(info.digestAlgorithm, 'SHA-256');
      expect(info.signatureAlgorithm, 'SHA256withRSA');
    });

    test('tampered content is invalid', () async {
      final contentXml = Uint8List.fromList('<content>Original</content>'.codeUnits);
      final built = await _buildRfcEnvelope(
        contentXml: contentXml,
        certDer: certDer,
        privateKey: privateKey,
      );

      final tampered = Uint8List.fromList('<content>Tampered</content>'.codeUnits);
      final info = SignatureVerifier.verify(
        signSgnBytes: built.envelope,
        contentXmlBytes: tampered,
      );

      expect(info.status, SignatureStatus.invalid);
    });

    test('tampered signature bytes are invalid (CRITICAL-02 regression)', () async {
      final contentXml = Uint8List.fromList('<content>Legal Document</content>'.codeUnits);
      final built = await _buildRfcEnvelope(
        contentXml: contentXml,
        certDer: certDer,
        privateKey: privateKey,
      );

      // messageDigest still matches the content — only the signature is broken.
      // The pre-fix verifier reported this forgery as valid.
      final forged = Uint8List.fromList(built.envelope);
      forged[built.signatureOffset + 10] ^= 0x01;

      final info = SignatureVerifier.verify(
        signSgnBytes: forged,
        contentXmlBytes: contentXml,
      );

      expect(info.status, SignatureStatus.invalid);
    });

    test('forged messageDigest attribute is invalid (CRITICAL-02 regression)', () async {
      final originalContent = Uint8List.fromList('<content>Original</content>'.codeUnits);
      final forgedContent = Uint8List.fromList('<content>Forged!!</content>'.codeUnits);
      final built = await _buildRfcEnvelope(
        contentXml: originalContent,
        certDer: certDer,
        privateKey: privateKey,
      );

      // Attacker swaps the messageDigest attribute to match the forged content
      // while keeping the original signature. Digest compare alone passes —
      // only signature verification over signedAttrs catches it.
      final originalHash = CadesBuilder.hashContentXml(originalContent);
      final forgedHash = CadesBuilder.hashContentXml(forgedContent);
      final forgedEnvelope = Uint8List.fromList(built.envelope);
      final hashOffset = _indexOfSublist(forgedEnvelope, originalHash);
      expect(hashOffset, greaterThanOrEqualTo(0));
      forgedEnvelope.setRange(hashOffset, hashOffset + forgedHash.length, forgedHash);

      final info = SignatureVerifier.verify(
        signSgnBytes: forgedEnvelope,
        contentXmlBytes: forgedContent,
      );

      expect(info.status, SignatureStatus.invalid);
    });

    test('envelope without signed attributes verifies signature over content', () {
      final contentXml = Uint8List.fromList('<content>No Attrs</content>'.codeUnits);
      final envelope = _buildNoSignedAttrsEnvelope(
        contentXml: contentXml,
        certDer: certDer,
        privateKey: privateKey,
      );

      final info = SignatureVerifier.verify(
        signSgnBytes: envelope,
        contentXmlBytes: contentXml,
      );

      expect(info.status, SignatureStatus.valid);
    });

    test('envelope without signed attributes is invalid for different content', () {
      final contentXml = Uint8List.fromList('<content>No Attrs</content>'.codeUnits);
      final envelope = _buildNoSignedAttrsEnvelope(
        contentXml: contentXml,
        certDer: certDer,
        privateKey: privateKey,
      );

      final tampered = Uint8List.fromList('<content>Changed!</content>'.codeUnits);
      final info = SignatureVerifier.verify(
        signSgnBytes: envelope,
        contentXmlBytes: tampered,
      );

      expect(info.status, SignatureStatus.invalid);
    });

    test('non-RSA signature algorithm is never reported valid', () {
      final contentXml = Uint8List.fromList('<content>ECDSA</content>'.codeUnits);
      final envelope = _buildNoSignedAttrsEnvelope(
        contentXml: contentXml,
        certDer: certDer,
        privateKey: privateKey,
        signatureAlgorithmOid: '1.2.840.10045.4.3.2', // ecdsa-with-SHA256
      );

      final info = SignatureVerifier.verify(
        signSgnBytes: envelope,
        contentXmlBytes: contentXml,
      );

      expect(info.status, SignatureStatus.unknown);
      expect(info.status, isNot(SignatureStatus.valid));
    });

    test('expired certificate with valid crypto reports expired', () async {
      final contentXml = Uint8List.fromList('<content>Old</content>'.codeUnits);
      final built = await _buildRfcEnvelope(
        contentXml: contentXml,
        certDer: expiredCertDer,
        privateKey: privateKey,
      );

      final info = SignatureVerifier.verify(
        signSgnBytes: built.envelope,
        contentXmlBytes: contentXml,
      );

      expect(info.status, SignatureStatus.expired);
    });

    test('expired certificate with tampered signature is invalid, not expired', () async {
      final contentXml = Uint8List.fromList('<content>Old</content>'.codeUnits);
      final built = await _buildRfcEnvelope(
        contentXml: contentXml,
        certDer: expiredCertDer,
        privateKey: privateKey,
      );

      final forged = Uint8List.fromList(built.envelope);
      forged[built.signatureOffset + 10] ^= 0x01;

      final info = SignatureVerifier.verify(
        signSgnBytes: forged,
        contentXmlBytes: contentXml,
      );

      expect(info.status, SignatureStatus.invalid);
    });
  });

  group('SignatureVerifier ECDSA', () {
    test('ECDSA-signed envelope verifies as valid', () {
      final keys = _generateEcKeyPair();
      final pub = keys.publicKey as ECPublicKey;
      final priv = keys.privateKey as ECPrivateKey;
      final ecCert = _buildEcSelfSignedCert(pub, priv);
      final content = Uint8List.fromList('<content>ECDSA belge</content>'.codeUnits);

      final envelope = _buildEcNoAttrsEnvelope(
        contentXml: content,
        certDer: ecCert,
        priv: priv,
      );

      final info = SignatureVerifier.verify(
        signSgnBytes: envelope,
        contentXmlBytes: content,
      );

      expect(info.status, SignatureStatus.valid);
      expect(info.signatureAlgorithm, 'SHA256withECDSA');
    });

    test('ECDSA envelope invalid for tampered content', () {
      final keys = _generateEcKeyPair();
      final pub = keys.publicKey as ECPublicKey;
      final priv = keys.privateKey as ECPrivateKey;
      final ecCert = _buildEcSelfSignedCert(pub, priv);
      final content = Uint8List.fromList('<content>Original</content>'.codeUnits);
      final envelope = _buildEcNoAttrsEnvelope(
        contentXml: content,
        certDer: ecCert,
        priv: priv,
      );

      final info = SignatureVerifier.verify(
        signSgnBytes: envelope,
        contentXmlBytes: Uint8List.fromList('<content>Tampered</content>'.codeUnits),
      );

      expect(info.status, SignatureStatus.invalid);
    });
  });

  group('TrustStore', () {
    test('bundled anchors parse and match their declared fingerprints', () {
      expect(TrustStore.anchors, isNotEmpty);
      for (final a in TrustStore.anchors) {
        final fp = SHA256Digest().process(a.der);
        final hex = fp
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join()
            .toUpperCase();
        expect(hex, a.sha256Fingerprint, reason: a.name);
      }
    });

    test('self-signed non-anchor signer is valid but untrusted', () async {
      final content = Uint8List.fromList('<content>x</content>'.codeUnits);
      final built = await _buildRfcEnvelope(
        contentXml: content,
        certDer: certDer,
        privateKey: privateKey,
      );
      final info = SignatureVerifier.verify(
        signSgnBytes: built.envelope,
        contentXmlBytes: content,
      );
      expect(info.status, SignatureStatus.valid);
      expect(info.trustLevel, TrustLevel.untrustedAnchor);
      expect(info.anchorName, isNull);
    });
  });
}
