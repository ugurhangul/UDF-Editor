import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/crypto/models.dart';
import '../../core/crypto/signing_service.dart';
import '../../core/crypto/nfc_id_card_signer.dart';
import '../../core/crypto/nfc_bridge.dart';
import '../../core/crypto/nfc_smart_card_signer.dart';
import '../../core/crypto/mobil_imza_signer.dart';
import '../../core/crypto/usb_otg_signer.dart';
import '../../core/crypto/cades_builder.dart';
import '../../core/udf/udf_archive.dart';
import '../../shared/version_store.dart';

/// Signing method selection and execution screen.
///
/// Displays available signing methods and guides the user through
/// the PIN entry → sign → result flow.
class SigningScreen extends StatefulWidget {
  const SigningScreen({super.key, required this.filePath});

  /// Path to the UDF file being signed.
  final String filePath;

  @override
  State<SigningScreen> createState() => _SigningScreenState();
}

// MEDIUM-01: lockout state lives at process scope, not widget scope —
// otherwise popping and re-pushing the screen resets the throttle and the
// backoff provides no real brute-force delay.
int _pinFailureCount = 0;
DateTime? _pinLockoutUntil;

class _SigningScreenState extends State<SigningScreen> {
  final _pinController = TextEditingController();
  final _phoneController = TextEditingController();

  SigningMethod? _selectedMethod;
  _SigningState _state = _SigningState.selectMethod;
  String? _errorMessage;
  String? _statusMessage;
  bool _pinObscured = true;

  // MEDIUM-01: exponential backoff throttling after failed PIN attempts.
  Timer? _retryTimer;
  int _retryCountdownSeconds = 0;

  // Availability cache
  final Map<SigningMethod, bool> _availability = {};
  bool _checkingAvailability = true;

  // Signers
  late final Map<SigningMethod, SigningService> _signers;

  @override
  void initState() {
    super.initState();
    _signers = {
      SigningMethod.nfcIdCard: NfcIdCardSigner(),
      SigningMethod.nfcSmartCard: NfcSmartCardSigner(),
      SigningMethod.mobilImza: MobilImzaSigner(),
      SigningMethod.usbOtg: UsbOtgSigner(),
    };
    // A re-pushed screen inherits any active lockout.
    final lockout = _pinLockoutUntil;
    if (lockout != null && lockout.isAfter(DateTime.now())) {
      _startRetryCountdown(lockout.difference(DateTime.now()).inSeconds + 1);
    }
    _checkAvailability();
  }

  @override
  void dispose() {
    // SEC-02: Clear sensitive credentials from memory before disposal.
    _pinController.clear();
    _phoneController.clear();
    _pinController.dispose();
    _phoneController.dispose();
    _retryTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkAvailability() async {
    for (final entry in _signers.entries) {
      try {
        _availability[entry.key] = await entry.value.isAvailable();
      } catch (_) {
        _availability[entry.key] = false;
      }
    }
    if (mounted) {
      setState(() => _checkingAvailability = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Belge İmzala'),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: switch (_state) {
            _SigningState.selectMethod => _buildMethodSelector(colorScheme),
            _SigningState.checkingPin => _buildCheckingPin(colorScheme),
            _SigningState.enterPin => _buildPinEntry(colorScheme),
            _SigningState.signing => _buildSigningProgress(colorScheme),
            _SigningState.success => _buildSuccess(colorScheme),
            _SigningState.error => _buildError(colorScheme),
          },
        ),
      ),
    );
  }

  // ── Method selector ───────────────────────────────────────────────

  Widget _buildMethodSelector(ColorScheme colorScheme) {
    return Padding(
      key: const ValueKey('selector'),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'İmzalama Yöntemi Seçin',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Nitelikli elektronik imza için bir yöntem seçin.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          if (_checkingAvailability)
            const Center(child: CircularProgressIndicator())
          else
            Expanded(
              child: ListView(
                children: [
                  _buildMethodCard(
                    method: SigningMethod.nfcIdCard,
                    icon: Icons.credit_card,
                    title: 'TC Kimlik Kartı (NFC)',
                    subtitle: 'Kimlik kartınızı telefona yaklaştırarak imzalayın',
                    colorScheme: colorScheme,
                  ),
                  const SizedBox(height: 12),
                  _buildMethodCard(
                    method: SigningMethod.nfcSmartCard,
                    icon: Icons.nfc,
                    title: 'Akıllı Kart (NFC)',
                    subtitle: 'AKIS e-İmza kartınızı kullanarak imzalayın',
                    colorScheme: colorScheme,
                  ),
                  const SizedBox(height: 12),
                  _buildMethodCard(
                    method: SigningMethod.mobilImza,
                    icon: Icons.phone_android,
                    title: 'Mobil İmza',
                    subtitle: 'GSM operatörünüz üzerinden imzalayın',
                    colorScheme: colorScheme,
                  ),
                  const SizedBox(height: 12),
                  _buildMethodCard(
                    method: SigningMethod.usbOtg,
                    icon: Icons.usb,
                    title: 'USB OTG Kart Okuyucu',
                    subtitle: 'USB kart okuyucu ile imzalayın (Android)',
                    colorScheme: colorScheme,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMethodCard({
    required SigningMethod method,
    required IconData icon,
    required String title,
    required String subtitle,
    required ColorScheme colorScheme,
  }) {
    final isAvailable = _availability[method] ?? false;
    final isSelected = _selectedMethod == method;
    final statusText = isAvailable ? subtitle : _unavailableReason(method);

    return Semantics(
      button: true,
      enabled: isAvailable,
      label: '$title. $statusText',
      excludeSemantics: true,
      child: Card(
        elevation: isSelected ? 4 : 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: isSelected
              ? BorderSide(color: colorScheme.primary, width: 2)
              : BorderSide.none,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: isAvailable
              ? () => _onMethodSelected(method)
              : null,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: isAvailable
                        ? colorScheme.primaryContainer
                        : colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    icon,
                    color: isAvailable
                        ? colorScheme.onPrimaryContainer
                        : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: isAvailable ? null : colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        statusText,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isAvailable)
                  Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // M-09: actionable per-method reason instead of a generic "unavailable".
  String _unavailableReason(SigningMethod method) {
    switch (method) {
      case SigningMethod.nfcIdCard:
      case SigningMethod.nfcSmartCard:
        return "NFC kapalı veya desteklenmiyor. Ayarlardan NFC'yi açın.";
      case SigningMethod.usbOtg:
        return 'USB OTG okuyucu bağlı değil.';
      case SigningMethod.mobilImza:
        return 'Bu cihazda kullanılamıyor';
    }
  }

  // ── PIN entry ─────────────────────────────────────────────────────

  Widget _buildPinEntry(ColorScheme colorScheme) {
    final isMobilImza = _selectedMethod == SigningMethod.mobilImza;

    return Padding(
      key: const ValueKey('pin'),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            isMobilImza ? 'Telefon Numarası' : 'PIN Girin',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isMobilImza
                ? 'Mobil İmza için telefon numaranızı girin'
                : 'Kartınızın PIN kodunu girin',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 32),
          if (isMobilImza)
            TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: 'Telefon Numarası',
                hintText: '05XX XXX XX XX',
                prefixIcon: const Icon(Icons.phone),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            )
          else
            TextField(
              controller: _pinController,
              keyboardType: TextInputType.number,
              obscureText: _pinObscured,
              maxLength: 8,
              decoration: InputDecoration(
                labelText: 'PIN',
                hintText: '••••••',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_pinObscured ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _pinObscured = !_pinObscured),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: colorScheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(color: colorScheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const Spacer(),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() {
                    _state = _SigningState.selectMethod;
                    _errorMessage = null;
                  }),
                  child: const Text('Geri'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: _startSigning,
                  icon: const Icon(Icons.draw),
                  label: const Text('İmzala'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Signing progress ──────────────────────────────────────────────

  Widget _buildSigningProgress(ColorScheme colorScheme) {
    final isMobilImza = _selectedMethod == SigningMethod.mobilImza;

    return Center(
      key: const ValueKey('progress'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 80,
              height: 80,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 32),
            Text(
              'İmzalanıyor...',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _statusMessage ?? (isMobilImza
                  ? 'Telefonunuza gelen PIN isteğini onaylayın'
                  : 'Kartınızı telefona yakın tutun'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // ── Success ───────────────────────────────────────────────────────

  Widget _buildSuccess(ColorScheme colorScheme) {
    return Center(
      key: const ValueKey('success'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.check_circle, size: 48, color: Colors.green.shade600),
            ),
            const SizedBox(height: 24),
            Text(
              'İmza Başarılı',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Belge başarıyla imzalandı ve sign.sgn dosyası oluşturuldu.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.done),
              label: const Text('Tamam'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Error ─────────────────────────────────────────────────────────

  Widget _buildError(ColorScheme colorScheme) {
    return Center(
      key: const ValueKey('error'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: colorScheme.errorContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.error_outline, size: 48, color: colorScheme.error),
            ),
            const SizedBox(height: 24),
            Text(
              'İmza Başarısız',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _errorMessage ?? 'Bilinmeyen bir hata oluştu',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Kapat'),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _retryCountdownSeconds > 0
                      ? null
                      : () => setState(() {
                          _state = _SigningState.enterPin;
                          _errorMessage = null;
                        }),
                  icon: const Icon(Icons.refresh),
                  label: Text(
                    _retryCountdownSeconds > 0
                        ? 'Tekrar Dene ($_retryCountdownSeconds)'
                        : 'Tekrar Dene',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  // ── Method selection with PIN check ────────────────────────────────

  void _onMethodSelected(SigningMethod method) {
    setState(() {
      _selectedMethod = method;
      _errorMessage = null;
    });

    // NFC methods: check PIN status before showing PIN entry
    if (method == SigningMethod.nfcIdCard) {
      setState(() => _state = _SigningState.checkingPin);
      _checkPinForNfc();
    } else {
      setState(() => _state = _SigningState.enterPin);
    }
  }

  Future<void> _checkPinForNfc() async {
    try {
      final signer = _signers[SigningMethod.nfcIdCard]! as NfcIdCardSigner;
      final status = await signer.checkPinStatus().timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw TimeoutException('NFC zaman aşımı');
        },
      );

      if (!mounted || _state != _SigningState.checkingPin) return;

      switch (status.state) {
        case PinState.active:
          // UX-07: PIN check advanced past card detection to a usable state.
          HapticFeedback.mediumImpact();
          final remaining = status.remainingAttempts;
          setState(() {
            _state = _SigningState.enterPin;
            if (remaining != null && remaining < 3) {
              _errorMessage = 'Dikkat: $remaining PIN denemesi kaldı';
            }
          });
        case PinState.blocked:
          _enterErrorState(
            'PIN bloke edilmiş.\n'
            'Nüfus Müdürlüğü\'ne başvurarak PIN\'inizi sıfırlatın.',
          );
        case PinState.notActivated:
          _enterErrorState(
            'E-imza PIN\'iniz aktif değil.\n'
            'Nüfus Müdürlüğü\'ne başvurarak PIN\'inizi aktifleştirin.',
          );
        case PinState.notFound:
          _enterErrorState(
            'Bu kartta e-imza uygulaması bulunamadı.\n'
            'Lütfen TC Kimlik kartınızı kullandığınızdan emin olun.',
          );
        case PinState.unknown:
          _enterErrorState(
            'Kart okunamadı.\n'
            'Kartınızı telefona yaklaştırıp tekrar deneyin.',
          );
      }
    } on TimeoutException {
      if (mounted && _state == _SigningState.checkingPin) {
        _cancelPinCheck();
        _enterErrorState(
          'Kart algılanamadı — süre doldu.\n'
          'Kartınızı telefonun NFC antenine yaklaştırıp tekrar deneyin.',
        );
      }
    } catch (e) {
      if (mounted && _state == _SigningState.checkingPin) {
        // LOW-01: don't leak raw exception detail into the UI.
        debugPrint('NFC iletişim hatası: $e');
        _enterErrorState('Beklenmeyen bir hata oluştu. Lütfen tekrar deneyin.');
      }
    }
  }

  // UX-07/M-07: centralizes the error-state transition so every error path
  // gets consistent haptic feedback.
  void _enterErrorState(String message, {bool countAsPinFailure = false}) {
    HapticFeedback.lightImpact();
    if (countAsPinFailure) {
      _registerPinFailure();
    }
    setState(() {
      _state = _SigningState.error;
      _errorMessage = message;
    });
  }

  // MEDIUM-01: exponential backoff (5s -> 15s -> 60s cap) after consecutive
  // failed PIN/signing attempts, to slow down brute-force PIN guessing.
  void _registerPinFailure() {
    _pinFailureCount++;
    const delaysSeconds = [5, 15, 60];
    final index = (_pinFailureCount - 1).clamp(0, delaysSeconds.length - 1).toInt();
    final delay = delaysSeconds[index];
    _pinLockoutUntil = DateTime.now().add(Duration(seconds: delay));
    _startRetryCountdown(delay);
  }

  void _resetPinFailures() {
    _pinFailureCount = 0;
    _pinLockoutUntil = null;
    _retryTimer?.cancel();
    _retryCountdownSeconds = 0;
  }

  void _startRetryCountdown(int seconds) {
    _retryTimer?.cancel();
    _retryCountdownSeconds = seconds;
    _retryTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _retryCountdownSeconds--;
        if (_retryCountdownSeconds <= 0) {
          _retryCountdownSeconds = 0;
          timer.cancel();
        }
      });
    });
  }

  void _cancelPinCheck() {
    // CODE-06: Stop the NFC session via the bridge — but avoid creating
    // orphan instances. Use a single shared bridge or stop the signer directly.
    try {
      // stopSession is async — catchError handles the Future's failure,
      // the outer try the synchronous one.
      NfcBridge().stopSession().catchError((_) {});
    } catch (_) {
      // Best-effort — NFC may already be stopped.
    }
    setState(() {
      _state = _SigningState.selectMethod;
    });
  }

  Widget _buildCheckingPin(ColorScheme colorScheme) {
    return Center(
      key: const ValueKey('checkingPin'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 80,
              height: 80,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 32),
            Text(
              'PIN Durumu Kontrol Ediliyor...',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Kartınızı telefona yaklaştırın',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: _cancelPinCheck,
                  child: const Text('İptal'),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: () {
                    // Skip PIN check, go directly to PIN entry
                    _cancelPinCheck();
                    setState(() {
                      _state = _SigningState.enterPin;
                    });
                  },
                  child: const Text('Kontrolü Atla'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Signing logic ─────────────────────────────────────────────────

  void _startSigning() {
    final method = _selectedMethod;
    if (method == null) return;

    // MEDIUM-01: gate the signing entry point itself, not just the retry
    // button — otherwise the lockout is decorative.
    final lockout = _pinLockoutUntil;
    if (lockout != null && lockout.isAfter(DateTime.now())) {
      final remaining = lockout.difference(DateTime.now()).inSeconds + 1;
      setState(() {
        _errorMessage =
            'Çok fazla başarısız deneme. $remaining saniye sonra tekrar deneyin.';
      });
      return;
    }

    final isMobilImza = method == SigningMethod.mobilImza;
    final credential = isMobilImza ? _phoneController.text : _pinController.text;

    if (credential.isEmpty) {
      setState(() {
        _errorMessage = isMobilImza
            ? 'Telefon numarası boş olamaz'
            : 'PIN boş olamaz';
      });
      return;
    }

    setState(() {
      _state = _SigningState.signing;
      _errorMessage = null;
      _statusMessage = null;
    });

    _performSigning(method, credential);
  }

  Future<void> _performSigning(SigningMethod method, String credential) async {
    try {
      final signer = _signers[method]!;

      // Read UDF archive and extract content.xml as UTF-8 bytes
      setState(() => _statusMessage = 'Belge okunuyor...');
      final file = File(widget.filePath);
      final fileBytes = await file.readAsBytes();
      final archive = UdfArchive.fromBytes(fileBytes);
      final contentXmlBytes = Uint8List.fromList(utf8.encode(archive.contentXml));

      if (method == SigningMethod.nfcIdCard || method == SigningMethod.nfcSmartCard) {
        setState(() => _statusMessage = 'Kartınızı telefona yaklaştırın...');
      } else if (method == SigningMethod.mobilImza) {
        setState(() => _statusMessage = 'Operatöre bağlanılıyor...');
      }

      final result = await signer.sign(contentXmlBytes, pin: credential);

      // Build CAdES envelope
      setState(() => _statusMessage = 'CAdES imza zarfı oluşturuluyor...');
      final builder = CadesBuilder();
      final signatureBytes = await builder.buildSignedData(
        contentXmlBytes: contentXmlBytes,
        signingResult: result,
      );

      // Write sign.sgn into the UDF archive and save
      setState(() => _statusMessage = 'İmza dosyaya yazılıyor...');
      final signedArchiveBytes = UdfArchive.toBytes(
        contentXml: archive.contentXml,
        signatureBytes: signatureBytes,
        propertiesXml: archive.propertiesXml,
        otherFiles: archive.otherFiles,
      );
      // Version history: preserve the unsigned document before overwriting.
      await VersionStore.snapshot(widget.filePath);
      await file.writeAsBytes(signedArchiveBytes, flush: true);

      // SEC-02: Clear credentials from memory after successful signing.
      _pinController.clear();
      _phoneController.clear();

      if (mounted) {
        // UX-07/M-07: success haptic; MEDIUM-01 reset backoff on success.
        HapticFeedback.heavyImpact();
        _resetPinFailures();
        setState(() => _state = _SigningState.success);
      }
    } on UdfArchiveException catch (e) {
      if (mounted) {
        _enterErrorState('Belge okunamadı: ${e.message}', countAsPinFailure: true);
      }
    } on SigningException catch (e) {
      if (mounted) {
        _enterErrorState(e.message, countAsPinFailure: true);
      }
    } catch (e) {
      if (mounted) {
        // LOW-01: don't leak raw exception detail into the UI.
        debugPrint('Beklenmeyen imzalama hatası: $e');
        _enterErrorState(
          'Beklenmeyen bir hata oluştu. Lütfen tekrar deneyin.',
          countAsPinFailure: true,
        );
      }
    }
  }
}

enum _SigningState {
  selectMethod,
  checkingPin,
  enterPin,
  signing,
  success,
  error,
}
