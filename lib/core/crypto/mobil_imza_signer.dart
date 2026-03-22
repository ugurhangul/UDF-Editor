import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'cades_builder.dart';
import 'models.dart';
import 'signing_service.dart';

/// Signs UDF documents via Mobil İmza (Mobile Signature) —
/// Turkey's GSM-based qualified electronic signature service.
///
/// Flow:
/// 1. User provides MSISDN (phone number)
/// 2. Client sends SHA-256 hash + MSISDN to operator gateway
/// 3. Operator pushes STK PIN prompt to user's SIM
/// 4. User enters PIN on their phone
/// 5. Operator returns CMS SignedData in gateway response
/// 6. Client writes response as sign.sgn
///
/// Supports all 3 Turkish mobile operators:
/// - Turkcell
/// - Vodafone
/// - Türk Telekom
///
/// > **Note**: Actual operator gateway endpoints require commercial
/// > integration contracts. This implementation provides the full
/// > HTTP scaffolding — wire in real endpoints once contracts
/// > are obtained.
class MobilImzaSigner implements SigningService {
  MobilImzaSigner({
    http.Client? httpClient,
    this.gatewayUrl,
    this.pollIntervalSeconds = 3,
    this.timeoutSeconds = 120,
  }) : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;

  /// Gateway URL for the Mobil İmza operator API.
  ///
  /// Each operator has a different endpoint:
  /// - Turkcell: (commercial endpoint — TBD)
  /// - Vodafone: (commercial endpoint — TBD)
  /// - Türk Telekom: (commercial endpoint — TBD)
  ///
  /// Set this via configuration once contracts are obtained.
  /// When null, uses placeholder operator URLs.
  final String? gatewayUrl;

  /// Polling interval in seconds while waiting for user's PIN response.
  final int pollIntervalSeconds;

  /// Timeout in seconds for the signing operation.
  final int timeoutSeconds;

  @override
  String get name => 'Mobil İmza';

  @override
  SigningMethod get method => SigningMethod.mobilImza;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<SigningResult> sign(
    Uint8List contentXmlBytes, {
    required String pin, // Carries MSISDN for Mobil İmza
  }) async {
    final msisdn = pin;

    // 1. Detect operator
    final operator_ = MobilOperator.fromPhoneNumber(msisdn);
    if (operator_ == null) {
      throw SigningException(
        'Bilinmeyen operatör. Lütfen geçerli bir Türk cep telefonu numarası girin.',
        code: SigningErrorCode.unknownOperator,
      );
    }

    // 2. Hash content.xml
    final contentHash = CadesBuilder.hashContentXml(contentXmlBytes);
    final hashBase64 = base64Encode(contentHash);

    // 3. Submit signing request
    final transactionId = await _submitSigningRequest(
      msisdn: msisdn,
      hashBase64: hashBase64,
      operator_: operator_,
    );

    // 4. Poll for result (user enters PIN on SIM STK)
    return _pollForResult(
      transactionId: transactionId,
      operator_: operator_,
    );
  }

  @override
  Future<Uint8List?> readCertificate() async => null;

  // ── Private methods ───────────────────────────────────────────────

  /// Submit signing request to operator's Mobil İmza gateway.
  Future<String> _submitSigningRequest({
    required String msisdn,
    required String hashBase64,
    required MobilOperator operator_,
  }) async {
    final url = gatewayUrl ?? _getOperatorUrl(operator_);
    final normalizedMsisdn = _normalizeMsisdn(msisdn);

    final requestBody = jsonEncode({
      'msisdn': normalizedMsisdn,
      'hash': hashBase64,
      'hashAlgorithm': 'SHA-256',
      'signatureType': 'CMS',
      'displayText': 'UDFtör belge imzalama',
      'operator': operator_.name,
    });

    try {
      final response = await _httpClient.post(
        Uri.parse('$url/sign'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: requestBody,
      ).timeout(Duration(seconds: timeoutSeconds));

      if (response.statusCode == 200 || response.statusCode == 202) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final transactionId = body['transactionId'] as String?;
        if (transactionId == null) {
          throw SigningException(
            'Operatör geçersiz yanıt döndü (transactionId eksik)',
            code: SigningErrorCode.operatorUnavailable,
          );
        }
        return transactionId;
      } else if (response.statusCode == 503) {
        throw SigningException(
          '${operator_.displayName} Mobil İmza servisi şu anda kullanılamıyor',
          code: SigningErrorCode.operatorUnavailable,
        );
      } else {
        throw SigningException(
          'Operatör API hatası: ${response.statusCode}',
          code: SigningErrorCode.operatorUnavailable,
        );
      }
    } on TimeoutException {
      throw SigningException(
        'Operatör API yanıt vermedi (${timeoutSeconds}s timeout)',
        code: SigningErrorCode.mobilImzaTimeout,
      );
    } on http.ClientException catch (e) {
      throw SigningException(
        'Ağ hatası: ${e.message}',
        code: SigningErrorCode.operatorUnavailable,
        cause: e,
      );
    }
  }

  /// Poll operator gateway for signing result.
  Future<SigningResult> _pollForResult({
    required String transactionId,
    required MobilOperator operator_,
  }) async {
    final url = gatewayUrl ?? _getOperatorUrl(operator_);
    final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds));

    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(Duration(seconds: pollIntervalSeconds));

      try {
        final response = await _httpClient.get(
          Uri.parse('$url/status/$transactionId'),
          headers: {'Accept': 'application/json'},
        );

        if (response.statusCode == 200) {
          final body = jsonDecode(response.body) as Map<String, dynamic>;
          final status = body['status'] as String?;

          switch (status) {
            case 'completed':
              final signatureB64 = body['signature'] as String?;
              final certificateB64 = body['certificate'] as String?;

              if (signatureB64 == null) {
                throw SigningException(
                  'Operatör imza verisi döndüremedi',
                  code: SigningErrorCode.signingFailed,
                );
              }

              return SigningResult(
                signature: base64Decode(signatureB64),
                certificate: certificateB64 != null
                    ? base64Decode(certificateB64)
                    : null,
              );

            case 'pending':
              continue;

            case 'rejected':
              throw SigningException(
                'İmza isteği reddedildi',
                code: SigningErrorCode.mobilImzaRejected,
              );

            case 'pin_error':
              throw SigningException(
                'PIN hatalı girildi',
                code: SigningErrorCode.pinError,
              );

            case 'timeout':
              throw SigningException(
                'PIN giriş süresi doldu',
                code: SigningErrorCode.mobilImzaTimeout,
              );

            default:
              throw SigningException(
                'Bilinmeyen durum: $status',
                code: SigningErrorCode.unknown,
              );
          }
        }
      } on SigningException {
        rethrow;
      } catch (_) {
        continue; // Network error during poll — retry
      }
    }

    throw SigningException(
      'İmza süresi doldu (${timeoutSeconds}s). Lütfen tekrar deneyin.',
      code: SigningErrorCode.mobilImzaTimeout,
    );
  }

  /// Normalize MSISDN to +90XXXXXXXXXX format.
  String _normalizeMsisdn(String msisdn) {
    var normalized = msisdn.replaceAll(RegExp(r'[\s\-\(\)]'), '');
    if (normalized.startsWith('0')) {
      normalized = '+90${normalized.substring(1)}';
    } else if (!normalized.startsWith('+')) {
      normalized = '+90$normalized';
    }
    return normalized;
  }

  /// Placeholder operator gateway URLs.
  /// Replace with real endpoints once commercial contracts are obtained.
  String _getOperatorUrl(MobilOperator operator_) {
    return switch (operator_) {
      MobilOperator.turkcell => 'https://mobilimza.turkcell.com.tr/api/v1',
      MobilOperator.vodafone => 'https://mobilimza.vodafone.com.tr/api/v1',
      MobilOperator.turkTelekom => 'https://mobilimza.turktelekom.com.tr/api/v1',
    };
  }
}
