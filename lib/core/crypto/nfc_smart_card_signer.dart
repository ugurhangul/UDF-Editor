import 'dart:async';
import 'dart:typed_data';

import 'cades_builder.dart';
import 'models.dart';
import 'nfc_bridge.dart';
import 'signing_service.dart';

import 'package:nfc_manager/nfc_manager.dart' show NfcAvailability;

/// Signs UDF documents using an AKIS (Akıllı Kart İşletim Sistemi)
/// qualified electronic signature smart card via NFC.
///
/// Compatible with AKIS e-İmza smart cards issued by Turkish
/// certificate authorities (TÜBİTAK BİLGEM, E-Güven, etc.).
///
/// Differs from [NfcIdCardSigner] in:
/// - Different AID (AKIS e-sign applet vs TC Kimlik applet)
/// - MSE SET uses PKCS#1 v1.5 via algorithm reference
/// - Card may require explicit MSE RESTORE before signing
class NfcSmartCardSigner implements SigningService {
  NfcSmartCardSigner({
    NfcBridge? nfcBridge,
    this.cadesBuilder,
  }) : _nfcBridge = nfcBridge ?? NfcBridge();

  final NfcBridge _nfcBridge;
  final CadesBuilder? cadesBuilder;

  /// AID for AKIS e-İmza applet.
  static const List<int> _akisAid = [
    0xA0, 0x00, 0x00, 0x00, 0x77, 0x01, 0x08, 0x01,
  ];

  /// Certificate EF for qualified signing certificate.
  static const List<int> _certFileId = [0xC0, 0x01];

  @override
  String get name => 'AKIS Akıllı Kart (NFC)';

  @override
  SigningMethod get method => SigningMethod.nfcSmartCard;

  @override
  Future<bool> isAvailable() async {
    final availability = await _nfcBridge.checkAvailability();
    return availability == NfcAvailability.enabled;
  }

  @override
  Future<SigningResult> sign(
    Uint8List contentXmlBytes, {
    required String pin,
  }) async {
    final completer = Completer<SigningResult>();

    await _nfcBridge.startSession(
      alertMessage: 'Akıllı kartınızı telefona yaklaştırın',
      onTagDiscovered: (session) async {
        try {
          final result = await _performSigning(session, contentXmlBytes, pin);
          await _nfcBridge.stopSession(successMessage: 'İmza başarılı');
          completer.complete(result);
        } catch (e) {
          await _nfcBridge.stopSession(errorMessage: 'İmza hatası: $e');
          if (!completer.isCompleted) completer.completeError(e);
        }
      },
      onError: (error) {
        if (!completer.isCompleted) {
          completer.completeError(
            SigningException(error, code: SigningErrorCode.nfcCommunicationError),
          );
        }
      },
    );

    return completer.future;
  }

  @override
  Future<Uint8List?> readCertificate() async {
    final completer = Completer<Uint8List?>();

    await _nfcBridge.startSession(
      alertMessage: 'Sertifika okumak için kartınızı yaklaştırın',
      onTagDiscovered: (session) async {
        try {
          final selectResp = await session.selectAid(_akisAid);
          if (!selectResp.isSuccess) {
            await _nfcBridge.stopSession(errorMessage: 'Kart tanınmadı');
            completer.complete(null);
            return;
          }

          await _selectCertFile(session);
          final certData = await _readCertificate(session);
          await _nfcBridge.stopSession(successMessage: 'Sertifika okundu');
          completer.complete(certData);
        } catch (e) {
          await _nfcBridge.stopSession(errorMessage: 'Okuma hatası');
          completer.complete(null);
        }
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete(null);
      },
    );

    return completer.future;
  }

  // ── Private methods ───────────────────────────────────────────────

  Future<SigningResult> _performSigning(
    NfcApduSession session,
    Uint8List contentXmlBytes,
    String pin,
  ) async {
    // 1. SELECT AKIS e-sign applet
    final selectResp = await session.selectAid(_akisAid);
    if (!selectResp.isSuccess) {
      throw SigningException(
        'AKIS kart tanınmadı: ${selectResp.statusDescription}',
        code: SigningErrorCode.cardNotSupported,
      );
    }

    // 2. VERIFY PIN
    final pinBytes = _encodePinBytes(pin);
    final pinResp = await session.verifyPin(pinBytes, p2: 0x81);
    if (!pinResp.isSuccess) {
      if (pinResp.statusWord == 0x6983) {
        throw SigningException(
          'PIN bloke edildi. Kart kilidini açtırmak için sertifika sağlayıcınıza başvurun.',
          code: SigningErrorCode.cardLocked,
        );
      }
      final remaining = _remainingPinAttempts(pinResp);
      throw SigningException(
        'PIN hatalı${remaining != null ? ' ($remaining deneme kaldı)' : ''}',
        code: SigningErrorCode.pinError,
      );
    }

    // 3. SELECT and READ certificate
    await _selectCertFile(session);
    final certData = await _readCertificate(session);

    // 4. MSE RESTORE → MSE SET for signing
    await session.transceive([0x00, 0x22, 0xF3, 0x00]);

    final mseResp = await session.mseSetCompute(
      algorithmRef: [0x02, 0x23],
      keyRef: [0x01],
    );
    if (!mseResp.isSuccess) {
      throw SigningException(
        'Güvenlik ortamı ayarlanamadı: ${mseResp.statusDescription}',
        code: SigningErrorCode.certificateError,
      );
    }

    // 5. Hash content
    final contentHash = CadesBuilder.hashContentXml(contentXmlBytes);

    // 6. Build DigestInfo + PSO COMPUTE DIGITAL SIGNATURE
    final digestInfo = _buildDigestInfo(contentHash);
    final sigResp = await session.computeDigitalSignature(digestInfo);

    Uint8List signatureBytes;
    if (sigResp.isSuccess) {
      signatureBytes = sigResp.data;
    } else if (sigResp.hasMoreData) {
      signatureBytes = await session.readAll(sigResp);
    } else {
      throw SigningException(
        'İmza hesaplanamadı: ${sigResp.statusDescription}',
        code: SigningErrorCode.signingFailed,
      );
    }

    return SigningResult(
      signature: signatureBytes,
      certificate: certData,
    );
  }

  Future<void> _selectCertFile(NfcApduSession session) async {
    final resp = await session.transceive([
      0x00, 0xA4, 0x02, 0x04,
      _certFileId.length,
      ..._certFileId,
    ]);
    if (!resp.isSuccess) {
      throw SigningException(
        'Sertifika dosyası bulunamadı: ${resp.statusDescription}',
        code: SigningErrorCode.certificateError,
      );
    }
  }

  Future<Uint8List> _readCertificate(NfcApduSession session) async {
    final buffer = <int>[];
    int offset = 0;
    const chunkSize = 0xD0;

    while (true) {
      final resp = await session.readBinary(offset: offset, length: chunkSize);

      if (resp.isSuccess) {
        buffer.addAll(resp.data);
        if (resp.data.length < chunkSize) break;
        offset += resp.data.length;
      } else if (resp.hasMoreData) {
        final remaining = await session.readAll(resp);
        buffer.addAll(remaining);
        break;
      } else if (resp.statusWord == 0x6B00 || resp.statusWord == 0x6282) {
        break;
      } else {
        throw SigningException(
          'Sertifika okunamadı: ${resp.statusDescription}',
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

  List<int> _encodePinBytes(String pin) {
    final digits = pin.codeUnits;
    final padded = List<int>.filled(8, 0xFF);
    for (var i = 0; i < digits.length && i < 8; i++) {
      padded[i] = digits[i];
    }
    return padded;
  }

  int? _remainingPinAttempts(ApduResponse resp) {
    if (resp.sw1 == 0x63 && (resp.sw2 & 0xF0) == 0xC0) {
      return resp.sw2 & 0x0F;
    }
    return null;
  }

  List<int> _buildDigestInfo(Uint8List hash) {
    const prefix = <int>[
      0x30, 0x31, 0x30, 0x0D, 0x06, 0x09,
      0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01,
      0x05, 0x00, 0x04, 0x20,
    ];
    return [...prefix, ...hash];
  }
}
