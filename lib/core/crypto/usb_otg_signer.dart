import 'dart:async';

import 'package:flutter/services.dart';

import 'cades_builder.dart';
import 'models.dart';
import 'signing_service.dart';

/// Signs UDF documents using an e-İmza smart card via USB OTG card reader.
///
/// **Android only** — iOS does not support USB OTG for smart card readers.
///
/// Uses platform channels to communicate with the Android USB host API.
/// The Kotlin side (`UsbOtgChannelHandler`) handles:
/// - USB device enumeration and permission requests
/// - CCID protocol (PC/SC) over USB bulk endpoints
/// - APDU exchange with the smart card
///
/// The Dart side orchestrates the same APDU flow as [NfcSmartCardSigner]:
/// SELECT → VERIFY PIN → READ CERT → MSE SET → PSO COMPUTE SIGNATURE
class UsbOtgSigner implements SigningService {
  UsbOtgSigner({this.cadesBuilder});

  final CadesBuilder? cadesBuilder;

  static const _channel = MethodChannel('com.udftor.usb_otg');

  /// AKIS e-İmza applet AID.
  static const _akisAid = 'A0000000770108010000';

  /// Certificate EF.
  static const _certFileId = 'C001';

  @override
  String get name => 'USB OTG Kart Okuyucu';

  @override
  SigningMethod get method => SigningMethod.usbOtg;

  @override
  Future<bool> isAvailable() async {
    try {
      final result = await _channel.invokeMethod<bool>('isAvailable');
      return result ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<SigningResult> sign(
    Uint8List contentXmlBytes, {
    required String pin,
  }) async {
    // 1. Connect to reader + card
    final connected = await _connect();
    if (!connected) {
      throw SigningException(
        'USB kart okuyucu bulunamadı veya kart takılı değil',
        code: SigningErrorCode.noReaderDetected,
      );
    }

    try {
      // 2. SELECT AID
      final selectResp = await _transceive(_buildSelectAid(_akisAid));
      _checkSuccess(selectResp, SigningErrorCode.cardNotSupported,
          'AKIS kart tanınmadı');

      // 3. VERIFY PIN
      final pinApdu = _buildVerifyPin(pin);
      final pinResp = await _transceive(pinApdu);
      if (!_isSuccess(pinResp)) {
        if (_getStatusWord(pinResp) == 0x6983) {
          throw SigningException(
            'PIN bloke edildi',
            code: SigningErrorCode.cardLocked,
          );
        }
        final remaining = _remainingPinAttempts(pinResp);
        throw SigningException(
          'PIN hatalı${remaining != null ? ' ($remaining deneme kaldı)' : ''}',
          code: SigningErrorCode.pinError,
        );
      }

      // 4. SELECT certificate EF + READ BINARY
      await _transceive(_buildSelectFile(_certFileId));
      final certData = await _readBinaryAll();

      // 5. MSE RESTORE + MSE SET
      await _transceive('0022F300');
      final mseApdu = _buildMseSet();
      final mseResp = await _transceive(mseApdu);
      _checkSuccess(mseResp, SigningErrorCode.certificateError,
          'Güvenlik ortamı ayarlanamadı');

      // 6. Build CMS SignedAttributes, hash, PSO COMPUTE DIGITAL SIGNATURE.
      // CRITICAL-02 companion: RFC 5652 §5.4 requires the signature over
      // DER(SET OF signedAttrs), not over the raw content.
      final signedAttrs = CadesBuilder.prepareSignedAttributes(
        contentXmlBytes: contentXmlBytes,
        signerCertDer: certData,
      );
      final attrsHash = CadesBuilder.hashContentXml(signedAttrs);
      final digestInfo = _buildDigestInfo(attrsHash);
      final sigApdu = _buildPsoComputeSignature(digestInfo);
      final sigResp = await _transceive(sigApdu);
      _checkSuccess(sigResp, SigningErrorCode.signingFailed,
          'İmza hesaplanamadı');

      final signatureBytes = _extractData(sigResp);

      return SigningResult(
        signature: signatureBytes,
        certificate: certData,
        signedAttributes: signedAttrs,
      );
    } finally {
      await _disconnect();
    }
  }

  @override
  Future<Uint8List?> readCertificate() async {
    final connected = await _connect();
    if (!connected) return null;

    try {
      final selectResp = await _transceive(_buildSelectAid(_akisAid));
      if (!_isSuccess(selectResp)) return null;

      await _transceive(_buildSelectFile(_certFileId));
      return _readBinaryAll();
    } catch (_) {
      return null;
    } finally {
      await _disconnect();
    }
  }

  // ── Platform channel methods ──────────────────────────────────────

  Future<bool> _connect() async {
    try {
      final result = await _channel.invokeMethod<bool>('connect');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> _disconnect() async {
    try {
      await _channel.invokeMethod<void>('disconnect');
    } on PlatformException {
      // Ignore disconnect errors
    }
  }

  /// Send hex-encoded APDU and receive hex-encoded response.
  Future<String> _transceive(String apduHex) async {
    try {
      final result = await _channel.invokeMethod<String>('transceive', {
        'apdu': apduHex,
      });
      if (result == null || result.length < 4) {
        throw SigningException(
          'Karttan geçersiz yanıt',
          code: SigningErrorCode.nfcCommunicationError,
        );
      }
      return result;
    } on PlatformException catch (e) {
      throw SigningException(
        'USB iletişim hatası: ${e.message}',
        code: SigningErrorCode.nfcCommunicationError,
        cause: e,
      );
    }
  }

  /// Read binary data from selected EF using READ BINARY.
  Future<Uint8List> _readBinaryAll() async {
    final buffer = <int>[];
    var offset = 0;
    const chunkSize = 0xD0;

    while (true) {
      final p1 = (offset >> 8) & 0xFF;
      final p2 = offset & 0xFF;
      final apdu = '00B0${_hex(p1)}${_hex(p2)}${_hex(chunkSize)}';
      final resp = await _transceive(apdu);

      final sw = _getStatusWord(resp);
      final data = _extractData(resp);

      if (sw == 0x9000) {
        buffer.addAll(data);
        if (data.length < chunkSize) break;
        offset += data.length;
      } else if ((sw >> 8) == 0x61) {
        // More data available
        final getResp = await _transceive('00C00000${_hex(sw & 0xFF)}');
        buffer.addAll(_extractData(getResp));
        break;
      } else if (sw == 0x6B00 || sw == 0x6282) {
        break;
      } else {
        throw SigningException(
          'Sertifika okunamadı',
          code: SigningErrorCode.certificateError,
        );
      }
    }

    if (buffer.isEmpty) {
      throw SigningException(
        'Kart üzerinde sertifika bulunamadı',
        code: SigningErrorCode.certificateError,
      );
    }

    return Uint8List.fromList(buffer);
  }

  // ── APDU builders (hex strings) ───────────────────────────────────

  String _buildSelectAid(String aidHex) {
    final lc = aidHex.length ~/ 2;
    return '00A40400${_hex(lc)}${aidHex}00';
  }

  String _buildSelectFile(String fileIdHex) {
    final lc = fileIdHex.length ~/ 2;
    return '00A40204${_hex(lc)}$fileIdHex';
  }

  String _buildVerifyPin(String pin) {
    final pinBytes = List<int>.filled(8, 0xFF);
    for (var i = 0; i < pin.length && i < 8; i++) {
      pinBytes[i] = pin.codeUnitAt(i);
    }
    final pinHex = pinBytes.map(_hex).join();
    return '00200081${_hex(pinBytes.length)}$pinHex';
  }

  String _buildMseSet() {
    // MSE SET for SHA-256 + RSA PKCS#1 v1.5
    const algRef = '80020223';
    const keyRef = '840101';
    const data = '$algRef$keyRef';
    final lc = data.length ~/ 2;
    return '002241B6${_hex(lc)}$data';
  }

  String _buildPsoComputeSignature(List<int> digestInfo) {
    final dataHex = digestInfo.map(_hex).join();
    final lc = digestInfo.length;
    return '002A9E9A${_hex(lc)}${dataHex}00';
  }

  List<int> _buildDigestInfo(Uint8List hash) {
    const prefix = <int>[
      0x30, 0x31, 0x30, 0x0D, 0x06, 0x09,
      0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01,
      0x05, 0x00, 0x04, 0x20,
    ];
    return [...prefix, ...hash];
  }

  // ── Utility methods ───────────────────────────────────────────────

  bool _isSuccess(String resp) => resp.endsWith('9000');

  int _getStatusWord(String resp) {
    if (resp.length < 4) return 0x6F00;
    final swHex = resp.substring(resp.length - 4);
    return int.parse(swHex, radix: 16);
  }

  Uint8List _extractData(String resp) {
    if (resp.length <= 4) return Uint8List(0);
    final dataHex = resp.substring(0, resp.length - 4);
    final bytes = <int>[];
    for (var i = 0; i < dataHex.length; i += 2) {
      bytes.add(int.parse(dataHex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  void _checkSuccess(String resp, SigningErrorCode code, String message) {
    if (!_isSuccess(resp)) {
      final sw = _getStatusWord(resp);
      throw SigningException(
        '$message (SW: ${sw.toRadixString(16).toUpperCase().padLeft(4, '0')})',
        code: code,
      );
    }
  }

  int? _remainingPinAttempts(String resp) {
    final sw = _getStatusWord(resp);
    final sw1 = (sw >> 8) & 0xFF;
    final sw2 = sw & 0xFF;
    if (sw1 == 0x63 && (sw2 & 0xF0) == 0xC0) {
      return sw2 & 0x0F;
    }
    return null;
  }

  String _hex(int byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase();
}
