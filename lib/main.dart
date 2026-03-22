import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'app/routes.dart';
import 'app/theme.dart';
import 'core/paywall/paywall_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Run the app FIRST — never block the first frame.
  runApp(const ProviderScope(child: UdfEditorApp()));

  // Defer heavy SDK initialization until AFTER the first frame renders.
  // This prevents AdMob's native module loading from blocking the splash.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _initializeSdks();
  });
}

/// Fire-and-forget SDK initialization.
/// Runs after the first frame — failures must never crash the app.
Future<void> _initializeSdks() async {
  try {
    await MobileAds.instance.initialize();
  } catch (e) {
    debugPrint('AdMob init error (non-fatal): $e');
  }

  try {
    await PaywallService.instance.initialize();
  } catch (e) {
    debugPrint('PaywallService init error (non-fatal): $e');
  }
}

class UdfEditorApp extends StatelessWidget {
  const UdfEditorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'UDFtör',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      routerConfig: appRouter,
    );
  }
}
