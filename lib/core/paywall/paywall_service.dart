import 'package:flutter/material.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';

/// PaywallService — RevenueCat integration for UDFtör.
///
/// Manages subscription state, entitlement checks, and paywall presentation.
///
/// Products configured in RevenueCat Dashboard:
///   weekly, monthly, two_month, three_month, six_month, yearly, lifetime
///
/// Entitlement: "UDFtor Pro"
class PaywallService {
  PaywallService._();

  static final PaywallService instance = PaywallService._();

  /// RevenueCat public SDK API key.
  static const _apiKey = 'REVENUECAT_TEST_KEY_REMOVED';

  /// Entitlement identifier matching RevenueCat Dashboard.
  static const proEntitlement = 'UDFtor Pro';

  bool _initialized = false;
  bool _isPro = false;
  CustomerInfo? _customerInfo;

  /// Whether the user has the Pro entitlement.
  bool get isPro => _isPro;

  /// Whether the user is on the free tier.
  bool get isFree => !_isPro;

  /// Current customer info (null until initialized).
  CustomerInfo? get customerInfo => _customerInfo;

  /// Initialize RevenueCat SDK.
  ///
  /// Must be called after `WidgetsFlutterBinding.ensureInitialized()`.
  /// Safe to call multiple times — subsequent calls are no-ops.
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      await Purchases.setLogLevel(LogLevel.debug);

      final config = PurchasesConfiguration(_apiKey);
      await Purchases.configure(config);

      _initialized = true;

      // Listen for customer info changes (e.g., subscription renewal/expiry).
      Purchases.addCustomerInfoUpdateListener((info) {
        _customerInfo = info;
        _isPro = info.entitlements.active.containsKey(proEntitlement);
      });

      await refreshStatus();
    } catch (e) {
      debugPrint('PaywallService init error: $e');
      // Fail open — app remains usable without paywall.
      _initialized = true;
    }
  }

  /// Refresh subscription status from RevenueCat.
  Future<void> refreshStatus() async {
    if (!_initialized) return;

    try {
      _customerInfo = await Purchases.getCustomerInfo();
      _isPro = _customerInfo!.entitlements.active.containsKey(proEntitlement);
    } catch (e) {
      debugPrint('PaywallService refresh error: $e');
    }
  }

  /// Get available offerings for purchase.
  Future<Offerings?> getOfferings() async {
    if (!_initialized) return null;

    try {
      return await Purchases.getOfferings();
    } catch (e) {
      debugPrint('PaywallService offerings error: $e');
      return null;
    }
  }

  /// Present the RevenueCat native paywall.
  ///
  /// Uses `RevenueCatUI.presentPaywall()` to show the remotely-configured
  /// paywall from the RevenueCat Dashboard.
  ///
  /// Returns the [PaywallResult] indicating what happened.
  Future<PaywallResult> presentPaywall() async {
    if (!_initialized) {
      await initialize();
    }

    try {
      final result = await RevenueCatUI.presentPaywall();
      await refreshStatus(); // Sync state after paywall closes.
      return result;
    } catch (e) {
      debugPrint('PaywallService presentPaywall error: $e');
      return PaywallResult.error;
    }
  }

  /// Present the paywall only if the user does NOT have the Pro entitlement.
  ///
  /// Returns the [PaywallResult]. If the user is already Pro,
  /// returns [PaywallResult.notPresented].
  Future<PaywallResult> presentPaywallIfNeeded() async {
    if (!_initialized) {
      await initialize();
    }

    if (_isPro) return PaywallResult.notPresented;

    try {
      final result = await RevenueCatUI.presentPaywallIfNeeded(proEntitlement);
      await refreshStatus();
      return result;
    } catch (e) {
      debugPrint('PaywallService presentPaywallIfNeeded error: $e');
      return PaywallResult.error;
    }
  }

  /// Present the Customer Center for subscription management.
  ///
  /// Allows users to manage, cancel, or restore subscriptions.
  Future<void> presentCustomerCenter() async {
    if (!_initialized) {
      await initialize();
    }

    try {
      await RevenueCatUI.presentCustomerCenter();
      await refreshStatus();
    } catch (e) {
      debugPrint('PaywallService customerCenter error: $e');
    }
  }

  /// Restore previous purchases.
  ///
  /// Useful when a user reinstalls the app or switches devices.
  Future<bool> restorePurchases() async {
    try {
      _customerInfo = await Purchases.restorePurchases();
      _isPro = _customerInfo!.entitlements.active.containsKey(proEntitlement);
      return _isPro;
    } catch (e) {
      debugPrint('PaywallService restore error: $e');
      return false;
    }
  }

  /// Check if a specific feature requires Pro and gate it.
  ///
  /// If the user is Pro, returns `true` immediately.
  /// Otherwise, presents the paywall and returns `true` only if
  /// the user subscribes.
  Future<bool> requirePro() async {
    if (_isPro) return true;

    final result = await presentPaywallIfNeeded();
    return result == PaywallResult.purchased || _isPro;
  }
}
