import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';

/// Cross-platform NFC APDU bridge.
///
/// Abstracts Android IsoDep and iOS ISO 7816 into a single
/// `transceive(List<int> apdu)` → `ApduResponse` interface.
///
/// Usage:
/// ```dart
/// final bridge = NfcBridge();
/// await bridge.startSession(
///   onTagDiscovered: (session) async {
///     final resp = await session.transceive([0x00, 0xA4, 0x04, 0x00, ...]);
///     // ...
///     await bridge.stopSession();
///   },
/// );
/// ```
class NfcBridge {
  NfcBridge({NfcManager? manager}) : _manager = manager ?? NfcManager.instance;

  final NfcManager _manager;

  /// Check if NFC is available and enabled.
  Future<NfcAvailability> checkAvailability() {
    return _manager.checkAvailability();
  }

  /// Start an NFC polling session.
  ///
  /// [onTagDiscovered] is called with an [NfcApduSession] once a
  /// compatible ISO 14443-4 tag is found. Use the session to
  /// exchange APDU commands.
  ///
  /// [alertMessage] is shown on iOS NFC sheet.
  ///
  /// [onError] is called if the session errors (iOS only).
  Future<void> startSession({
    required Future<void> Function(NfcApduSession session) onTagDiscovered,
    String alertMessage = 'Kartınızı telefona yaklaştırın',
    void Function(String error)? onError,
  }) async {
    await _manager.startSession(
      pollingOptions: {NfcPollingOption.iso14443},
      alertMessageIos: alertMessage,
      invalidateAfterFirstReadIos: false,
      onDiscovered: (NfcTag tag) async {
        NfcApduSession? session;

        if (Platform.isAndroid) {
          final isoDep = IsoDepAndroid.from(tag);
          if (isoDep != null) {
            // Increase timeout for crypto operations
            await isoDep.setTimeout(30000);
            session = _AndroidApduSession(isoDep);
          }
        } else if (Platform.isIOS) {
          final iso7816 = Iso7816Ios.from(tag);
          if (iso7816 != null) {
            session = _IosApduSession(iso7816);
          }
        }

        if (session == null) {
          onError?.call('Kart ISO 14443-4 desteklemiyor');
          return;
        }

        try {
          await onTagDiscovered(session);
        } catch (e) {
          onError?.call(e.toString());
        }
      },
      onSessionErrorIos: (error) {
        onError?.call(error.toString());
      },
    );
  }

  /// Stop the current NFC session.
  Future<void> stopSession({String? successMessage, String? errorMessage}) {
    return _manager.stopSession(
      alertMessageIos: successMessage,
      errorMessageIos: errorMessage,
    );
  }
}

/// Platform-agnostic APDU session.
///
/// Provides `transceive` for raw byte exchange and
/// `selectAid` / `verifyPin` / `readBinary` / `computeSignature`
/// convenience methods.
abstract class NfcApduSession {
  /// Send raw APDU bytes and receive response.
  Future<ApduResponse> transceive(List<int> apdu);

  /// SELECT application by AID (ISO 7816-4).
  Future<ApduResponse> selectAid(List<int> aid) {
    return transceive([
      0x00, // CLA
      0xA4, // INS: SELECT
      0x04, // P1: Select by DF name
      0x00, // P2: First or only occurrence
      aid.length, // Lc
      ...aid,
      0x00, // Le: max response
    ]);
  }

  /// VERIFY PIN (ISO 7816-4).
  Future<ApduResponse> verifyPin(List<int> pinBytes, {int p2 = 0x00}) {
    return transceive([
      0x00, // CLA
      0x20, // INS: VERIFY
      0x00, // P1
      p2, // P2: PIN reference
      pinBytes.length, // Lc
      ...pinBytes,
    ]);
  }

  /// READ BINARY (ISO 7816-4).
  ///
  /// Reads [length] bytes from [offset].
  Future<ApduResponse> readBinary({int offset = 0, int length = 0x00}) {
    return transceive([
      0x00, // CLA
      0xB0, // INS: READ BINARY
      (offset >> 8) & 0xFF, // P1: offset high
      offset & 0xFF, // P2: offset low
      length, // Le
    ]);
  }

  /// GET RESPONSE (ISO 7816-4).
  ///
  /// Used to retrieve remaining data after SW 0x61XX.
  Future<ApduResponse> getResponse(int length) {
    return transceive([
      0x00, // CLA
      0xC0, // INS: GET RESPONSE
      0x00, // P1
      0x00, // P2
      length, // Le
    ]);
  }

  /// MANAGE SECURITY ENVIRONMENT: SET for computation (ISO 7816-4).
  Future<ApduResponse> mseSetCompute({
    required List<int> algorithmRef,
    required List<int> keyRef,
  }) {
    final data = <int>[
      0x80, algorithmRef.length, ...algorithmRef, // Algorithm reference
      0x84, keyRef.length, ...keyRef, // Key reference
    ];
    return transceive([
      0x00, // CLA
      0x22, // INS: MSE
      0x41, // P1: SET for computation
      0xB6, // P2: Digital signature template
      data.length, // Lc
      ...data,
    ]);
  }

  /// PSO: COMPUTE DIGITAL SIGNATURE (ISO 7816-4).
  Future<ApduResponse> computeDigitalSignature(List<int> hash) {
    return transceive([
      0x00, // CLA
      0x2A, // INS: PSO
      0x9E, // P1: COMPUTE DIGITAL SIGNATURE
      0x9A, // P2: Input is hash
      hash.length, // Lc
      ...hash,
      0x00, // Le: max response
    ]);
  }

  /// Read all data, handling 0x61XX (more data) status.
  Future<Uint8List> readAll(ApduResponse initial) async {
    var response = initial;
    final buffer = <int>[...response.data];

    while (response.sw1 == 0x61) {
      response = await getResponse(response.sw2);
      if (response.isSuccess || response.sw1 == 0x61) {
        buffer.addAll(response.data);
      } else {
        break;
      }
    }

    return Uint8List.fromList(buffer);
  }
}

/// APDU response with status word parsing.
class ApduResponse {
  ApduResponse(Uint8List raw) {
    if (raw.length < 2) {
      data = Uint8List(0);
      sw1 = 0x6F;
      sw2 = 0x00;
    } else {
      data = Uint8List.sublistView(raw, 0, raw.length - 2);
      sw1 = raw[raw.length - 2];
      sw2 = raw[raw.length - 1];
    }
  }

  ApduResponse.fromParts({
    required this.data,
    required this.sw1,
    required this.sw2,
  });

  late final Uint8List data;
  late final int sw1;
  late final int sw2;

  /// Status word as 16-bit value.
  int get statusWord => (sw1 << 8) | sw2;

  /// Whether the command succeeded (0x9000).
  bool get isSuccess => sw1 == 0x90 && sw2 == 0x00;

  /// Whether more data is available (0x61XX).
  bool get hasMoreData => sw1 == 0x61;

  /// Human-readable status description.
  String get statusDescription {
    if (isSuccess) return 'OK';
    if (hasMoreData) return '$sw2 bytes remaining';
    return switch (statusWord) {
      0x6300 => 'Authentication failed',
      0x6982 => 'Security status not satisfied',
      0x6983 => 'PIN blocked',
      0x6984 => 'Referenced data invalid',
      0x6985 => 'Conditions of use not satisfied',
      0x6986 => 'Command not allowed',
      0x6A82 => 'File not found',
      0x6A86 => 'Incorrect P1-P2',
      0x6D00 => 'Instruction not supported',
      0x6E00 => 'Class not supported',
      _ => 'Error: ${statusWord.toRadixString(16).toUpperCase().padLeft(4, '0')}',
    };
  }

  @override
  String toString() =>
      'APDU[${statusWord.toRadixString(16).toUpperCase().padLeft(4, '0')}] '
      '${data.length} bytes';
}

// ── Platform-specific implementations ───────────────────────────────

class _AndroidApduSession extends NfcApduSession {
  _AndroidApduSession(this._isoDep);
  final IsoDepAndroid _isoDep;

  @override
  Future<ApduResponse> transceive(List<int> apdu) async {
    final response = await _isoDep.transceive(Uint8List.fromList(apdu));
    return ApduResponse(response);
  }
}

class _IosApduSession extends NfcApduSession {
  _IosApduSession(this._iso7816);
  final Iso7816Ios _iso7816;

  @override
  Future<ApduResponse> transceive(List<int> apdu) async {
    // Use sendCommandRaw for maximum control over APDU bytes
    final response = await _iso7816.sendCommandRaw(
      data: Uint8List.fromList(apdu),
    );
    // Reconstruct raw response: payload + SW1 + SW2
    final raw = Uint8List(response.payload.length + 2);
    raw.setRange(0, response.payload.length, response.payload);
    raw[raw.length - 2] = response.statusWord1;
    raw[raw.length - 1] = response.statusWord2;
    return ApduResponse(raw);
  }
}
