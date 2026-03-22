import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/crypto/models.dart';
import '../../core/crypto/signing_service.dart';
import '../../core/crypto/nfc_id_card_signer.dart';
import '../../core/crypto/nfc_smart_card_signer.dart';
import '../../core/crypto/mobil_imza_signer.dart';
import '../../core/crypto/usb_otg_signer.dart';
import '../../core/crypto/cades_builder.dart';

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

class _SigningScreenState extends State<SigningScreen> {
  final _pinController = TextEditingController();
  final _phoneController = TextEditingController();

  SigningMethod? _selectedMethod;
  _SigningState _state = _SigningState.selectMethod;
  String? _errorMessage;
  String? _statusMessage;
  bool _pinObscured = true;

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
    _checkAvailability();
  }

  @override
  void dispose() {
    _pinController.dispose();
    _phoneController.dispose();
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

    return Card(
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
            ? () {
                setState(() {
                  _selectedMethod = method;
                  _errorMessage = null;
                  _state = _SigningState.enterPin;
                });
              }
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
                      isAvailable ? subtitle : 'Bu cihazda kullanılamıyor',
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
    );
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
                  onPressed: () => setState(() {
                    _state = _SigningState.enterPin;
                    _errorMessage = null;
                  }),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Tekrar Dene'),
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

      // Read content.xml from the UDF archive
      // TODO: Integrate with UDF archive reader to extract content.xml bytes
      final contentXmlBytes = Uint8List.fromList(
        '<placeholder>Content will be loaded from ${widget.filePath}</placeholder>'.codeUnits,
      );

      if (method == SigningMethod.nfcIdCard || method == SigningMethod.nfcSmartCard) {
        setState(() => _statusMessage = 'Kartınızı telefona yaklaştırın...');
      } else if (method == SigningMethod.mobilImza) {
        setState(() => _statusMessage = 'Operatöre bağlanılıyor...');
      }

      final result = await signer.sign(contentXmlBytes, pin: credential);

      // Build CAdES envelope
      setState(() => _statusMessage = 'CAdES imza zarfı oluşturuluyor...');
      final builder = CadesBuilder();
      await builder.buildSignedData(
        contentXmlBytes: contentXmlBytes,
        signingResult: result,
      );

      // TODO: Write sign.sgn to the UDF archive

      if (mounted) {
        setState(() => _state = _SigningState.success);
      }
    } on SigningException catch (e) {
      if (mounted) {
        setState(() {
          _state = _SigningState.error;
          _errorMessage = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = _SigningState.error;
          _errorMessage = 'Beklenmeyen hata: $e';
        });
      }
    }
  }
}

enum _SigningState {
  selectMethod,
  enterPin,
  signing,
  success,
  error,
}
