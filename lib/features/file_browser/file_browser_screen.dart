import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/paywall/paywall_service.dart';
import '../../shared/widgets/ad_banner_widget.dart';

/// File browser screen — home screen of UDFtör.
///
/// Lists recently opened .udf files and provides a FAB to pick new files.
class FileBrowserScreen extends ConsumerStatefulWidget {
  const FileBrowserScreen({super.key});

  @override
  ConsumerState<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends ConsumerState<FileBrowserScreen> {
  List<FileSystemEntity> _recentFiles = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRecentFiles();
  }

  Future<void> _loadRecentFiles() async {
    setState(() => _isLoading = true);
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final udfDir = Directory('${appDir.path}/udf_files');
      if (await udfDir.exists()) {
        final files = udfDir
            .listSync()
            .where((f) => f.path.toLowerCase().endsWith('.udf'))
            .toList()
          ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
        setState(() => _recentFiles = files);
      }
    } catch (_) {
      // Silently handle — empty list is fine for first launch
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: true,
    );

    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final bytes = file.bytes;
    final name = file.name;

    if (bytes == null || !name.toLowerCase().endsWith('.udf')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Lütfen geçerli bir .udf dosyası seçin.')),
        );
      }
      return;
    }

    // Copy to app documents for persistence
    final savedPath = await _saveToAppDir(name, bytes);

    if (mounted) {
      context.pushNamed('reader', queryParameters: {'path': savedPath});
      _loadRecentFiles(); // Refresh list on return
    }
  }

  Future<String> _saveToAppDir(String fileName, Uint8List bytes) async {
    final appDir = await getApplicationDocumentsDirectory();
    final udfDir = Directory('${appDir.path}/udf_files');
    if (!await udfDir.exists()) {
      await udfDir.create(recursive: true);
    }

    final targetFile = File('${udfDir.path}/$fileName');
    await targetFile.writeAsBytes(bytes, flush: true);
    return targetFile.path;
  }

  Future<void> _restorePurchases() async {
    final restored = await PaywallService.instance.restorePurchases();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            restored
                ? 'Pro abonelik geri yüklendi!'
                : 'Aktif abonelik bulunamadı.',
          ),
        ),
      );
      setState(() {}); // Refresh UI to reflect new state.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'UDFtör',
          style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () async {
              final router = GoRouter.of(context);
              final allowed = await PaywallService.instance.requirePro();
              if (allowed && mounted) {
                router.pushNamed('editor', queryParameters: {'new': 'true'});
              }
            },
            tooltip: 'Yeni Belge (Pro)',
          ),
          IconButton(
            icon: const Icon(Icons.cloud_outlined),
            onPressed: () {
              context.pushNamed('syncSettings');
            },
            tooltip: 'Bulut Senkronizasyon',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              switch (value) {
                case 'subscription':
                  PaywallService.instance.presentCustomerCenter();
                case 'restore':
                  _restorePurchases();
                case 'upgrade':
                  PaywallService.instance.presentPaywall();
              }
            },
            itemBuilder: (context) => [
              if (PaywallService.instance.isPro)
                const PopupMenuItem(
                  value: 'subscription',
                  child: ListTile(
                    leading: Icon(Icons.card_membership),
                    title: Text('Abonelik Yönetimi'),
                    dense: true,
                  ),
                )
              else
                const PopupMenuItem(
                  value: 'upgrade',
                  child: ListTile(
                    leading: Icon(Icons.workspace_premium),
                    title: Text('Pro\'ya Yükselt'),
                    dense: true,
                  ),
                ),
              const PopupMenuItem(
                value: 'restore',
                child: ListTile(
                  leading: Icon(Icons.restore),
                  title: Text('Satın Alımları Geri Yükle'),
                  dense: true,
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _recentFiles.isEmpty
                    ? _buildEmptyState(theme, colorScheme)
                    : _buildFileList(theme, colorScheme),
          ),
          const AdBannerWidget(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _pickFile,
        icon: const Icon(Icons.folder_open),
        label: const Text('Dosya Aç'),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.description_outlined,
              size: 80,
              color: colorScheme.primary.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 24),
            Text(
              'Henüz açılmış dosya yok',
              style: theme.textTheme.headlineSmall?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '.udf dosyalarını açmak için aşağıdaki butona tıklayın.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileList(ThemeData theme, ColorScheme colorScheme) {
    return RefreshIndicator(
      onRefresh: _loadRecentFiles,
      child: ListView.builder(
        itemCount: _recentFiles.length,
        padding: const EdgeInsets.only(top: 8, bottom: 88), // FAB clearance
        itemBuilder: (context, index) {
          final file = _recentFiles[index];
          final stat = file.statSync();
          final name = file.path.split(Platform.pathSeparator).last;
          final sizeKb = (stat.size / 1024).toStringAsFixed(1);
          final modified = _formatDate(stat.modified);

          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              leading: CircleAvatar(
                backgroundColor: colorScheme.primaryContainer,
                child: Icon(
                  Icons.description,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
              title: Text(
                name,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '$sizeKb KB · $modified',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                context.pushNamed(
                  'reader',
                  queryParameters: {'path': file.path},
                );
              },
            ),
          );
        },
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inMinutes < 1) return 'Az önce';
    if (diff.inHours < 1) return '${diff.inMinutes} dk önce';
    if (diff.inDays < 1) return '${diff.inHours} saat önce';
    if (diff.inDays < 7) return '${diff.inDays} gün önce';

    return '${date.day}.${date.month.toString().padLeft(2, '0')}.${date.year}';
  }
}
