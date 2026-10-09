import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:asn1lib/asn1lib.dart';

import 'package:udf_editor/core/crypto/cades_builder.dart';
import 'package:udf_editor/core/crypto/models.dart';
import 'package:udf_editor/core/crypto/signature_verifier.dart';

/// Generate a self-signed X.509 certificate + RSA key pair for testing.
/// Returns (certificate DER, private key).
({Uint8List certDer, RSAPrivateKey privateKey, RSAPublicKey publicKey}) _generateTestCert() {
  // Generate RSA key pair
  final keyGen = RSAKeyGenerator()
    ..init(ParametersWithRandom(
      RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64),
      _secureRandom(),
    ));
  final keyPair = keyGen.generateKeyPair();
  final publicKey = keyPair.publicKey as RSAPublicKey;
  final privateKey = keyPair.privateKey as RSAPrivateKey;

  // Build a minimal self-signed X.509 v3 certificate in ASN.1
  final now = DateTime.now().toUtc();
  final notAfter = now.add(const Duration(days: 365));

  // Subject/Issuer: CN=Test Signer
  final cn = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString('2.5.4.3'))
    ..add(ASN1UTF8String('Test Signer'));
  final rdn = ASN1Set()..add(cn);
  final name = ASN1Sequence()..add(rdn);

  // SubjectPublicKeyInfo
  final pubKeyDer = _encodeRSAPublicKey(publicKey);

  // TBSCertificate
  final tbsCert = ASN1Sequence()
    // version [0] EXPLICIT v3
    ..add(_wrapExplicit(0, ASN1Integer.fromInt(2)))
    // serialNumber
    ..add(ASN1Integer.fromInt(1))
    // signature algorithm (SHA-256 with RSA)
    ..add(ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.113549.1.1.11'))
      ..add(ASN1Null()))
    // issuer
    ..add(name)
    // validity
    ..add(ASN1Sequence()
      ..add(ASN1UtcTime(now))
      ..add(ASN1UtcTime(notAfter)))
    // subject (same as issuer — self-signed)
    ..add(name)
    // subjectPublicKeyInfo
    ..add(ASN1Parser(pubKeyDer).nextObject());

  // Sign TBSCertificate
  final tbsBytes = tbsCert.encodedBytes;
  final signer = RSASigner(SHA256Digest(), '0609608648016503040201');
  signer.init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey));
  final sig = signer.generateSignature(tbsBytes);

  // Build Certificate
  final cert = ASN1Sequence()
    ..add(tbsCert)
    ..add(ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.113549.1.1.11'))
      ..add(ASN1Null()))
    ..add(ASN1BitString(sig.bytes));

  return (certDer: cert.encodedBytes, privateKey: privateKey, publicKey: publicKey);
}

Uint8List _encodeRSAPublicKey(RSAPublicKey key) {
  final modulus = ASN1Integer(key.modulus!);
  final exponent = ASN1Integer(key.publicExponent!);
  final pubKeySeq = ASN1Sequence()
    ..add(modulus)
    ..add(exponent);

  final algorithmId = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.113549.1.1.1'))
    ..add(ASN1Null());

  final spki = ASN1Sequence()
    ..add(algorithmId)
    ..add(ASN1BitString(pubKeySeq.encodedBytes));

  return spki.encodedBytes;
}

ASN1Object _wrapExplicit(int tagNumber, ASN1Object content) {
  final inner = content.encodedBytes;
  final tag = 0xA0 | tagNumber;
  // Simple length encoding for small payloads
  final result = Uint8List(1 + 1 + inner.length);
  result[0] = tag;
  result[1] = inner.length;
  result.setRange(2, result.length, inner);
  return ASN1Parser(result).nextObject();
}

SecureRandom _secureRandom() {
  final random = FortunaRandom();
  final seedSource = Random.secure();
  random.seed(KeyParameter(
    Uint8List.fromList(List.generate(32, (_) => seedSource.nextInt(256))),
  ));
  return random;
}

/// Two-phase RFC 5652 signing: sign the DER-encoded SignedAttributes,
/// exactly like the card/USB signers do in production.
SigningResult _signRfc5652({
  required Uint8List contentXml,
  required ({Uint8List certDer, RSAPrivateKey privateKey, RSAPublicKey publicKey}) testCert,
}) {
  final signedAttrs = CadesBuilder.prepareSignedAttributes(
    contentXmlBytes: contentXml,
    signerCertDer: testCert.certDer,
  );
  final signer = RSASigner(SHA256Digest(), '0609608648016503040201');
  signer.init(true, PrivateKeyParameter<RSAPrivateKey>(testCert.privateKey));
  final sig = signer.generateSignature(signedAttrs);
  return SigningResult(
    signature: sig.bytes,
    certificate: testCert.certDer,
    signedAttributes: signedAttrs,
  );
}

void main() {
  group('CadesBuilder', () {
    test('hashContentXml produces 32-byte SHA-256 hash', () {
      final data = Uint8List.fromList('Hello, UYAP!'.codeUnits);
      final hash = CadesBuilder.hashContentXml(data);
      expect(hash.length, 32);
    });

    test('hashContentXml is deterministic', () {
      final data = Uint8List.fromList('Test content'.codeUnits);
      final hash1 = CadesBuilder.hashContentXml(data);
      final hash2 = CadesBuilder.hashContentXml(data);
      expect(hash1, equals(hash2));
    });

    test('hashContentXml differs for different input', () {
      final data1 = Uint8List.fromList('Content A'.codeUnits);
      final data2 = Uint8List.fromList('Content B'.codeUnits);
      final hash1 = CadesBuilder.hashContentXml(data1);
      final hash2 = CadesBuilder.hashContentXml(data2);
      expect(hash1, isNot(equals(hash2)));
    });

    test('buildSignedData produces valid CMS ContentInfo', () async {
      final testCert = _generateTestCert();
      final contentXml = Uint8List.fromList('<content>Test</content>'.codeUnits);

      final signingResult = _signRfc5652(contentXml: contentXml, testCert: testCert);

      final builder = CadesBuilder();
      final signedDataDer = await builder.buildSignedData(
        contentXmlBytes: contentXml,
        signingResult: signingResult,
      );

      // Verify it's valid ASN.1
      expect(signedDataDer.isNotEmpty, true);

      // Parse and verify structure
      final parser = ASN1Parser(signedDataDer);
      final contentInfo = parser.nextObject() as ASN1Sequence;
      final ciElements = contentInfo.elements.toList();

      // ContentInfo has contentType + [0] content
      expect(ciElements.length, 2);

      // contentType should be signedData OID
      final contentType = ciElements[0] as ASN1ObjectIdentifier;
      expect(contentType.identifier, '1.2.840.113549.1.7.2');
    });
  });

  group('SignatureVerifier', () {
    test('verify returns valid for matching content', () async {
      final testCert = _generateTestCert();
      final contentXml = Uint8List.fromList('<content>Legal Document</content>'.codeUnits);

      final signingResult = _signRfc5652(contentXml: contentXml, testCert: testCert);

      final builder = CadesBuilder();
      final signedDataDer = await builder.buildSignedData(
        contentXmlBytes: contentXml,
        signingResult: signingResult,
      );

      final info = SignatureVerifier.verify(
        signSgnBytes: signedDataDer,
        contentXmlBytes: contentXml,
      );

      expect(info.status, SignatureStatus.valid);
      expect(info.signerName, 'Test Signer');
      expect(info.hasTimestamp, false);
      // Embedded certs present → hasEmbeddedValidation = true → reports X-LONG
      expect(info.hasEmbeddedValidation, true);
    });

    test('verify returns invalid for tampered content', () async {
      final testCert = _generateTestCert();
      final contentXml = Uint8List.fromList('<content>Original</content>'.codeUnits);

      final signingResult = _signRfc5652(contentXml: contentXml, testCert: testCert);

      final builder = CadesBuilder();
      final signedDataDer = await builder.buildSignedData(
        contentXmlBytes: contentXml,
        signingResult: signingResult,
      );

      // Verify with DIFFERENT content → should be invalid
      final tamperedContent = Uint8List.fromList('<content>Tampered</content>'.codeUnits);
      final info = SignatureVerifier.verify(
        signSgnBytes: signedDataDer,
        contentXmlBytes: tamperedContent,
      );

      expect(info.status, SignatureStatus.invalid);
    });

    test('verify returns unknown for garbage bytes', () {
      final garbage = Uint8List.fromList([0x00, 0x01, 0x02, 0x03]);
      final content = Uint8List.fromList('test'.codeUnits);

      final info = SignatureVerifier.verify(
        signSgnBytes: garbage,
        contentXmlBytes: content,
      );

      expect(info.status, SignatureStatus.unknown);
    });

    test('parseInfo extracts signer name from CMS envelope', () async {
      final testCert = _generateTestCert();
      final contentXml = Uint8List.fromList('<content>Test</content>'.codeUnits);

      final signingResult = _signRfc5652(contentXml: contentXml, testCert: testCert);

      final builder = CadesBuilder();
      final signedDataDer = await builder.buildSignedData(
        contentXmlBytes: contentXml,
        signingResult: signingResult,
      );

      final info = SignatureVerifier.parseInfo(signedDataDer);

      expect(info.signerName, 'Test Signer');
      expect(info.status, SignatureStatus.unknown); // parseInfo doesn't verify
    });
  });

  group('Models', () {
    test('MobilOperator.fromPhoneNumber detects Turkcell', () {
      expect(MobilOperator.fromPhoneNumber('+905321234567'), MobilOperator.turkcell);
      expect(MobilOperator.fromPhoneNumber('05351234567'), MobilOperator.turkcell);
    });

    test('MobilOperator.fromPhoneNumber detects Vodafone', () {
      expect(MobilOperator.fromPhoneNumber('+905421234567'), MobilOperator.vodafone);
    });

    test('MobilOperator.fromPhoneNumber detects Türk Telekom', () {
      expect(MobilOperator.fromPhoneNumber('+905551234567'), MobilOperator.turkTelekom);
    });

    test('MobilOperator.fromPhoneNumber returns null for unknown', () {
      expect(MobilOperator.fromPhoneNumber('+905001234567'), isNull);
      expect(MobilOperator.fromPhoneNumber('123'), isNull);
    });

    test('SignatureInfo.unsigned has correct defaults', () {
      const info = SignatureInfo.unsigned();
      expect(info.status, SignatureStatus.unsigned);
      expect(info.signerName, isNull);
      expect(info.cadesProfile, 'CAdES-BES');
    });

    test('SignatureInfo.cadesProfile reports correctly', () {
      const bes = SignatureInfo(status: SignatureStatus.valid);
      expect(bes.cadesProfile, 'CAdES-BES');

      const t = SignatureInfo(status: SignatureStatus.valid, hasTimestamp: true);
      expect(t.cadesProfile, 'CAdES-T');

      const xlong = SignatureInfo(
        status: SignatureStatus.valid,
        hasTimestamp: true,
        hasEmbeddedValidation: true,
      );
      expect(xlong.cadesProfile, 'CAdES-X-LONG');
    });
  });
}
