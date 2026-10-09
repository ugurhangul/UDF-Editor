import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/sync/google_drive_sync.dart';
import '../../core/sync/icloud_sync.dart';
import '../../core/sync/sync_metadata.dart';
import '../../core/sync/sync_service.dart';
import '../../core/sync/sync_state.dart';

/// Cloud sync settings screen.
///
/// Shows available sync providers (Google Drive, iCloud),
/// sign-in/out controls, last sync time, and manual sync trigger.
class SyncSettingsScreen extends StatefulWidget {
  const SyncSettingsScreen({super.key});

  @override
  State<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends State<SyncSettingsScreen> {
  late final List<SyncService> _providers;
  final Map<String, bool> _authenticated = {};
  final Map<String, SyncUserInfo?> _userInfo = {};
  final Map<String, SyncStatus> _syncStatus = {};

  bool _loading = true;
  String? _syncMessage;

  @override
  void initState() {
    super.initState();
    _providers = [
      GoogleDriveSync(),
      ICloudSync(containerId: 'iCloud.com.udftor.udfeditor'),
    ];
    _initProviders();
  }

  Future<void> _initProviders() async {
    for (final provider in _providers) {
      try {
        final available = await provider.isAvailable();
        if (available) {
          _authenticated[provider.name] = await provider.isAuthenticated();
          if (_authenticated[provider.name] == true) {
            _userInfo[provider.name] = await provider.getUserInfo();
          }
        }
        _syncStatus[provider.name] = _authenticated[provider.name] == true
            ? SyncStatus.idle
            : SyncStatus.disabled;
      } catch (_) {
        _syncStatus[provider.name] = SyncStatus.disabled;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bulut Senkronizasyon'),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Header
                _buildHeader(colorScheme),
                const SizedBox(height: 24),

                // Provider cards
                // Provider cards
                for (final provider in _providers)
                  // CODE-10: Filter iCloud on non-Apple platforms before
                  // building, not inside the builder.
                  if (provider is! ICloudSync ||
                      Platform.isIOS ||
                      Platform.isMacOS) ...[
                    _buildProviderCard(provider, colorScheme),
                    const SizedBox(height: 12),
                  ],

                const SizedBox(height: 24),

                // Last sync info
                _buildLastSyncInfo(colorScheme),

                // Sync message
                if (_syncMessage != null) ...[
                  const SizedBox(height: 16),
                  _buildSyncMessage(colorScheme),
                ],
              ],
            ),
    );
  }

  Widget _buildHeader(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Bulut Depolama',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'UDF dosyalarınızı bulut depolama ile cihazlar arasında senkronize edin.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildProviderCard(SyncService provider, ColorScheme colorScheme) {
    final isAuthenticated = _authenticated[provider.name] ?? false;
    final userInfo = _userInfo[provider.name];
    final status = _syncStatus[provider.name] ?? SyncStatus.disabled;
    final isAvailable = status != SyncStatus.disabled ||
        _authenticated[provider.name] == true;

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Provider header
            Row(
              children: [
                Icon(
                  provider is GoogleDriveSync
                      ? Icons.add_to_drive
                      : Icons.cloud,
                  color: isAvailable
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        provider.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (isAuthenticated && userInfo != null)
                        Text(
                          // CODE-09: Prefer email, fall back to displayName.
                          userInfo.email ?? userInfo.displayName,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                // Status badge
                _buildStatusBadge(status, colorScheme),
              ],
            ),

            const SizedBox(height: 16),

            // Action buttons
            Row(
              children: [
                if (!isAuthenticated)
                  FilledButton.tonal(
                    onPressed: () => _signIn(provider),
                    child: Text('${provider.name} Bağla'),
                  )
                else ...[
                  FilledButton.icon(
                    onPressed: status == SyncStatus.syncing
                        ? null
                        : () => _syncNow(provider),
                    icon: status == SyncStatus.syncing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync),
                    label: Text(status == SyncStatus.syncing
                        ? 'Senkronize ediliyor...'
                        : 'Şimdi Senkronize Et'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => _signOut(provider),
                    child: const Text('Çıkış'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBadge(SyncStatus status, ColorScheme colorScheme) {
    final (icon, color, label) = switch (status) {
      SyncStatus.idle => (Icons.cloud_done, Colors.grey, 'Hazır'),
      SyncStatus.syncing => (Icons.sync, colorScheme.primary, 'Senkronize'),
      SyncStatus.error => (Icons.cloud_off, colorScheme.error, 'Hata'),
      SyncStatus.upToDate => (Icons.check_circle, Colors.green, 'Güncel'),
      SyncStatus.disabled => (Icons.cloud_off, Colors.grey, 'Kapalı'),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: color),
          ),
        ],
      ),
    );
  }

  Widget _buildLastSyncInfo(ColorScheme colorScheme) {
    return FutureBuilder<SyncState>(
      future: SyncState.load(),
      builder: (context, snapshot) {
        final lastSync = snapshot.data?.lastSyncTime;
        return Card(
          elevation: 0,
          color: colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.schedule, color: colorScheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Son Senkronizasyon',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      lastSync != null
                          ? _formatDateTime(lastSync)
                          : 'Henüz senkronize edilmedi',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSyncMessage(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: colorScheme.onPrimaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _syncMessage!,
              style: TextStyle(color: colorScheme.onPrimaryContainer),
            ),
          ),
        ],
      ),
    );
  }

  // ── Actions ───────────────────────────────────────────────────────

  Future<void> _signIn(SyncService provider) async {
    try {
      await provider.signIn();
      final userInfo = await provider.getUserInfo();
      if (mounted) {
        setState(() {
          _authenticated[provider.name] = true;
          _userInfo[provider.name] = userInfo;
          _syncStatus[provider.name] = SyncStatus.idle;
          _syncMessage = '${provider.name} bağlantısı başarılı';
        });
      }
    } catch (e) {
      debugPrint('Bağlantı hatası (${provider.name}): $e');
      if (mounted) {
        setState(() {
          _syncMessage = 'Bağlantı kurulamadı. Lütfen tekrar deneyin.';
        });
      }
    }
  }

  Future<void> _signOut(SyncService provider) async {
    await provider.signOut();
    if (mounted) {
      setState(() {
        _authenticated[provider.name] = false;
        _userInfo[provider.name] = null;
        _syncStatus[provider.name] = SyncStatus.disabled;
        _syncMessage = '${provider.name} bağlantısı kaldırıldı';
      });
    }
  }

  Future<void> _syncNow(SyncService provider) async {
    setState(() {
      _syncStatus[provider.name] = SyncStatus.syncing;
      _syncMessage = null;
    });

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final udfDir = '${appDir.path}/udf_files';

      final report = await provider.syncAll(udfDir);

      if (mounted) {
        setState(() {
          _syncStatus[provider.name] = report.isClean
              ? SyncStatus.upToDate
              : SyncStatus.error;
          _syncMessage = _formatReport(report);
        });
      }
    } catch (e) {
      debugPrint('Senkronizasyon hatası (${provider.name}): $e');
      if (mounted) {
        setState(() {
          _syncStatus[provider.name] = SyncStatus.error;
          _syncMessage = 'Senkronizasyon başarısız oldu. Lütfen tekrar deneyin.';
        });
      }
    }
  }

  String _formatReport(SyncReport report) {
    final parts = <String>[];
    if (report.uploaded > 0) parts.add('${report.uploaded} yüklendi');
    if (report.downloaded > 0) parts.add('${report.downloaded} indirildi');
    if (report.skipped > 0) parts.add('${report.skipped} değişmedi');
    if (report.conflicts.isNotEmpty) {
      parts.add('${report.conflicts.length} çakışma çözüldü');
    }
    if (report.errors.isNotEmpty) {
      parts.add('${report.errors.length} hata');
    }
    return parts.isEmpty ? 'Tüm dosyalar güncel' : parts.join(', ');
  }

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    final diff = now.difference(local);

    if (diff.inMinutes < 1) return 'Az önce';
    if (diff.inHours < 1) return '${diff.inMinutes} dakika önce';
    if (diff.inDays < 1) return '${diff.inHours} saat önce';
    return '${local.day}.${local.month}.${local.year} ${local.hour}:${local.minute.toString().padLeft(2, '0')}';
  }
}
