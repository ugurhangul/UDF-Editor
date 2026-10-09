import 'dart:math';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:http/http.dart' as http;

/// RFC 3161 Timestamp Authority client.
///
/// Requests a timestamp token from a TSA server and returns the
/// TimeStampToken (TSTInfo wrapped in CMS) for embedding in a
/// CAdES-T or CAdES-X-LONG signature.
class TsaClient {
  TsaClient({
    required this.tsaUrl,
    this.httpClient,
    this.timeoutDuration = const Duration(seconds: 15),
  });

  /// URL of the TSA endpoint (HTTP POST).
  final String tsaUrl;

  /// Optional HTTP client for testing/injection.
  final http.Client? httpClient;

  /// Timeout for TSA requests.
  final Duration timeoutDuration;

  // OIDs
  static const _oidSha256 = '2.16.840.1.101.3.4.2.1';

  /// Request a timestamp token for the given message imprint (hash).
  ///
  /// [messageHash] — SHA-256 hash of the data to timestamp.
  /// Returns DER-encoded TimeStampToken (CMS ContentInfo).
  /// Throws [TsaException] on failure.
  Future<Uint8List> requestTimestamp(Uint8List messageHash) async {
    final request = _buildTimestampRequest(messageHash);
    final client = httpClient ?? http.Client();

    try {
      final response = await client
          .post(
            Uri.parse(tsaUrl),
            headers: {
              'Content-Type': 'application/timestamp-query',
              'Accept': 'application/timestamp-reply',
            },
            body: request,
          )
          .timeout(timeoutDuration);

      if (response.statusCode != 200) {
        throw TsaException(
          'TSA returned HTTP ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }

      return _parseTimestampResponse(Uint8List.fromList(response.bodyBytes));
    } on http.ClientException catch (e) {
      throw TsaException('TSA request failed: $e', cause: e);
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Build an RFC 3161 TimeStampReq ASN.1 structure.
  Uint8List _buildTimestampRequest(Uint8List messageHash) {
    // AlgorithmIdentifier for SHA-256
    final algorithmIdentifier = ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString(_oidSha256))
      ..add(ASN1Null());

    // MessageImprint
    final messageImprint = ASN1Sequence()
      ..add(algorithmIdentifier)
      ..add(ASN1OctetString(messageHash));

    // Nonce (random 8 bytes for replay protection)
    // CRITICAL-01: CSPRNG nonce — predictable seeds enable TSA replay.
    final rng = Random.secure();
    final nonceBytes = Uint8List.fromList(List.generate(8, (_) => rng.nextInt(256)));

    // TimeStampReq
    final tsReq = ASN1Sequence()
      ..add(ASN1Integer.fromInt(1)) // version v1
      ..add(messageImprint)
      ..add(ASN1Integer(BigInt.from(nonceBytes.buffer.asByteData().getInt64(0)).abs())) // nonce
      ..add(ASN1Boolean(true)); // certReq: request TSA cert in response

    return tsReq.encodedBytes;
  }

  /// Parse an RFC 3161 TimeStampResp and extract the TimeStampToken.
  Uint8List _parseTimestampResponse(Uint8List responseBytes) {
    final parser = ASN1Parser(responseBytes);
    final responseSeq = parser.nextObject() as ASN1Sequence;
    final respElements = responseSeq.elements.toList();

    if (respElements.isEmpty) {
      throw const TsaException('Empty TimeStampResp');
    }

    // PKIStatusInfo
    final statusInfo = respElements[0] as ASN1Sequence;
    final statusInfoElements = statusInfo.elements.toList();
    final status = statusInfoElements[0] as ASN1Integer;
    final statusValue = status.intValue;

    // 0 = granted, 1 = grantedWithMods
    if (statusValue != 0 && statusValue != 1) {
      final statusText = switch (statusValue) {
        2 => 'rejection',
        3 => 'waiting',
        4 => 'revocationWarning',
        5 => 'revocationNotification',
        _ => 'unknown($statusValue)',
      };
      throw TsaException('TSA rejected request: $statusText');
    }

    // TimeStampToken (second element)
    if (respElements.length < 2) {
      throw const TsaException('TimeStampResp missing TimeStampToken');
    }

    // The TimeStampToken is a ContentInfo (CMS) — return its DER encoding
    return respElements[1].encodedBytes;
  }
}

/// Exception thrown during TSA operations.
class TsaException implements Exception {
  const TsaException(this.message, {this.statusCode, this.cause});

  final String message;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() => 'TsaException: $message';
}
