import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../../core/paywall/paywall_service.dart';

/// Reusable banner ad widget for UDFtör free tier.
///
/// Displays an adaptive banner ad at the bottom of the screen.
/// Uses test ad unit IDs in development.
///
/// Defers ad loading until a short delay after mount to avoid
/// blocking the main thread during initial rendering.
class AdBannerWidget extends StatefulWidget {
  const AdBannerWidget({super.key});

  @override
  State<AdBannerWidget> createState() => _AdBannerWidgetState();
}

class _AdBannerWidgetState extends State<AdBannerWidget> {
  BannerAd? _bannerAd;
  bool _isLoaded = false;

  static const _adUnitId = 'ca-app-pub-9106641442812067/4454343459';

  @override
  void initState() {
    super.initState();
    // Pro users don't see ads.
    if (PaywallService.instance.isPro) return;
    // Delay ad loading to avoid blocking the first frame render.
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) _loadAd();
    });
  }

  Future<void> _loadAd() async {
    try {
      final screenWidth = MediaQuery.of(context).size.width.truncate();
      final adSize = AdSize(width: screenWidth, height: 60);

      final bannerAd = BannerAd(
        adUnitId: _adUnitId,
        size: adSize,
        request: const AdRequest(),
        listener: BannerAdListener(
          onAdLoaded: (ad) {
            if (mounted) {
              setState(() {
                _bannerAd = ad as BannerAd;
                _isLoaded = true;
              });
            }
          },
          onAdFailedToLoad: (ad, error) {
            debugPrint('AdBanner failed to load: ${error.message}');
            ad.dispose();
          },
        ),
      );

      await bannerAd.load();
    } catch (e) {
      debugPrint('AdBanner error (non-fatal): $e');
    }
  }

  @override
  void dispose() {
    _bannerAd?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isLoaded || _bannerAd == null) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      width: _bannerAd!.size.width.toDouble(),
      height: _bannerAd!.size.height.toDouble(),
      child: AdWidget(ad: _bannerAd!),
    );
  }
}
