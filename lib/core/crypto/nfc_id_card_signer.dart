import 'dart:async';
import 'dart:typed_data';

import 'cades_builder.dart';
import 'models.dart';
import 'nfc_bridge.dart';
import 'signing_service.dart';

import 'package:nfc_manager/nfc_manager.dart' show NfcAvailability;

/// Signs UDF documents using the e-signature applet on
/// a Turkish national ID card (TC Kimlik Kartı) via NFC.
///
/// APDU flow (ISO 7816-4):
/// 1. SELECT AID (e-sign applet on the card)
/// 2. VERIFY PIN (user-provided 6-digit PIN)
/// 3. READ BINARY (extract X.509 signer certificate)
/// 4. MSE SET (set up security environment for SHA-256 + RSA)
/// 5. PSO: COMPUTE DIGITAL SIGNATURE (send hash → receive raw signature)
///
/// The raw signature + certificate are then passed to [CadesBuilder]
/// to construct a CAdES-X-LONG envelope.
class NfcIdCardSigner implements SigningService {
  NfcIdCardSigner({
    NfcBridge? nfcBridge,
    this.cadesBuilder,
  }) : _nfcBridge = nfcBridge ?? NfcBridge();

  final NfcBridge _nfcBridge;
  final CadesBuilder? cadesBuilder;

  /// AID for TC Kimlik Kartı e-signature applet.
  ///
  /// Note: This is a best-effort AID based on ISO 7816-4 conventions for
  /// Turkish eID cards. Real cards may use a different AID — adjust
  /// after physical testing.
  static const List<int> _tcKimlikAid = [
    0xA0, 0x00, 0x00, 0x00, 0x77, 0x01, 0x08, 0x00,
  ];

  /// Certificate EF (Elementary File) identifier for the signing certificate.
  static const List<int> _certFileId = [0x00, 0x01];

  @override
  String get name => 'TC Kimlik Kartı (NFC)';

  @override
  SigningMethod get method => SigningMethod.nfcIdCard;

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
      alertMessage: 'TC Kimlik kartınızı telefona yaklaştırın',
      onTagDiscovered: (session) async {
        try {
          final result = await _performSigning(session, contentXmlBytes, pin);
          await _nfcBridge.stopSession(successMessage: 'İmza başarılı');
          completer.complete(result);
        } catch (e) {
          await _nfcBridge.stopSession(errorMessage: 'İmza hatası: $e');
          if (!completer.isCompleted) {
            completer.completeError(e);
          }
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

  /// Probe the PIN status on the card without attempting verification.
  ///
  /// Sends an empty VERIFY command after selecting the applet.
  /// The card responds with a status word indicating:
  /// - `63CX` → PIN active, X attempts remaining
  /// - `6983` → PIN blocked
  /// - `6985` → PIN not activated / not initialized
  /// - `6A88` → PIN reference not found
  Future<PinStatus> checkPinStatus() async {
    final completer = Completer<PinStatus>();

    await _nfcBridge.startSession(
      alertMessage: 'PIN durumunu kontrol etmek için kartınızı yaklaştırın',
      onTagDiscovered: (session) async {
        try {
          // SELECT e-sign applet
          final selectResp = await session.selectAid(_tcKimlikAid);
          if (!selectResp.isSuccess) {
            await _nfcBridge.stopSession(errorMessage: 'Kart tanınmadı');
            completer.complete(const PinStatus.notFound());
            return;
          }

          // Empty VERIFY to probe PIN state (no PIN data sent)
          final probeResp = await session.transceive([
            0x00, // CLA
            0x20, // INS: VERIFY
            0x00, // P1
            0x00, // P2: PIN reference
          ]);

          final status = _parsePinStatus(probeResp);
          final message = switch (status.state) {
            PinState.active => 'PIN aktif',
            PinState.blocked => 'PIN bloke',
            PinState.notActivated => 'PIN aktif değil',
            PinState.notFound => 'PIN bulunamadı',
            PinState.unknown => 'Durum bilinmiyor',
          };
          await _nfcBridge.stopSession(successMessage: message);
          completer.complete(status);
        } catch (e) {
          await _nfcBridge.stopSession(errorMessage: 'Kontrol hatası');
          if (!completer.isCompleted) {
            completer.complete(const PinStatus.unknown());
          }
        }
      },
      onError: (error) {
        if (!completer.isCompleted) {
          completer.complete(const PinStatus.unknown());
        }
      },
    );

    return completer.future;
  }

  PinStatus _parsePinStatus(ApduResponse resp) {
    // 0x9000 → PIN already verified (session still active)
    if (resp.isSuccess) {
      return const PinStatus.active();
    }
    // 0x63CX → PIN active, X attempts remaining
    if (resp.sw1 == 0x63 && (resp.sw2 & 0xF0) == 0xC0) {
      final remaining = resp.sw2 & 0x0F;
      return PinStatus.active(remainingAttempts: remaining);
    }
    // 0x6983 → PIN blocked
    if (resp.statusWord == 0x6983) {
      return const PinStatus.blocked();
    }
    // 0x6985 → Conditions not satisfied (PIN not activated)
    if (resp.statusWord == 0x6985) {
      return const PinStatus.notActivated();
    }
    // 0x6A88 → Referenced data not found (no PIN on applet)
    if (resp.statusWord == 0x6A88) {
      return const PinStatus.notFound();
    }
    return const PinStatus.unknown();
  }

  @override
  Future<Uint8List?> readCertificate() async {
    final completer = Completer<Uint8List?>();

    await _nfcBridge.startSession(
      alertMessage: 'Sertifika okumak için kartınızı yaklaştırın',
      onTagDiscovered: (session) async {
        try {
          final selectResp = await session.selectAid(_tcKimlikAid);
          if (!selectResp.isSuccess) {
            await _nfcBridge.stopSession(errorMessage: 'Kart tanınmadı');
            completer.complete(null);
            return;
          }

          await session.transceive([
            0x00, 0xA4, 0x02, 0x04,
            _certFileId.length,
            ..._certFileId,
          ]);
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
    // 1. SELECT e-sign applet
    final selectResp = await session.selectAid(_tcKimlikAid);
    if (!selectResp.isSuccess) {
      throw SigningException(
        'Kart tanınmadı: ${selectResp.statusDescription}',
        code: SigningErrorCode.cardNotSupported,
      );
    }

    // 2. VERIFY PIN
    final pinBytes = _encodePinBytes(pin);
    final pinResp = await session.verifyPin(pinBytes);
    if (!pinResp.isSuccess) {
      if (pinResp.statusWord == 0x6983) {
        throw SigningException(
          'PIN bloke edildi. Lütfen kartınızı sıfırlatın.',
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
    await session.transceive([
      0x00, 0xA4, 0x02, 0x04,
      _certFileId.length,
      ..._certFileId,
    ]);
    final certData = await _readCertificate(session);

    // 4. MSE SET: configure for SHA-256 + RSA PKCS#1 v1.5
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

    // 5. Hash content.xml
    final contentHash = CadesBuilder.hashContentXml(contentXmlBytes);

    // 6. PSO: COMPUTE DIGITAL SIGNATURE
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

  /// Read X.509 certificate from the card via READ BINARY.
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

  /// Encode user PIN to padded bytes (8 bytes, 0xFF padded).
  List<int> _encodePinBytes(String pin) {
    final digits = pin.codeUnits;
    final padded = List<int>.filled(8, 0xFF);
    for (var i = 0; i < digits.length && i < 8; i++) {
      padded[i] = digits[i];
    }
    return padded;
  }

  /// Extract remaining PIN attempts from SW 0x63CX.
  int? _remainingPinAttempts(ApduResponse resp) {
    if (resp.sw1 == 0x63 && (resp.sw2 & 0xF0) == 0xC0) {
      return resp.sw2 & 0x0F;
    }
    return null;
  }

  /// Build PKCS#1 v1.5 DigestInfo for SHA-256.
  List<int> _buildDigestInfo(Uint8List hash) {
    const prefix = <int>[
      0x30, 0x31, 0x30, 0x0D, 0x06, 0x09,
      0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01,
      0x05, 0x00, 0x04, 0x20,
    ];
    return [...prefix, ...hash];
  }
}
