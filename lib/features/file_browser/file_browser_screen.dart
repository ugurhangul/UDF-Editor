import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/paywall/paywall_service.dart';
import '../../shared/draft_store.dart';
import '../../shared/version_store.dart';
import '../../shared/widgets/ad_banner_widget.dart';

/// Cached metadata for a file listed in the browser — avoids re-stat'ing
/// (sync or async) on every rebuild.
class _FileEntry {
  const _FileEntry({
    required this.path,
    required this.name,
    required this.modified,
    required this.size,
  });

  final String path;
  final String name;
  final DateTime modified;
  final int size;
}

enum _OverwriteAction { overwrite, keepBoth, cancel }

/// File browser screen — home screen of UDFtör.
///
/// Lists recently opened .udf files and provides a FAB to pick new files.
class FileBrowserScreen extends ConsumerStatefulWidget {
  const FileBrowserScreen({super.key});

  @override
  ConsumerState<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends ConsumerState<FileBrowserScreen> {
  List<_FileEntry> _recentFiles = [];
  bool _isLoading = true;
  bool _isImporting = false;

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
      final entries = <_FileEntry>[];
      if (await udfDir.exists()) {
        // C-03: async listing + stat — no sync I/O on the UI thread.
        await for (final entity in udfDir.list()) {
          if (entity is! File || !entity.path.toLowerCase().endsWith('.udf')) {
            continue;
          }
          final stat = await entity.stat();
          entries.add(
            _FileEntry(
              path: entity.path,
              name: entity.path.split(Platform.pathSeparator).last,
              modified: stat.modified,
              size: stat.size,
            ),
          );
        }
        entries.sort((a, b) => b.modified.compareTo(a.modified));
      }
      if (mounted) setState(() => _recentFiles = entries);
    } catch (e) {
      debugPrint('Failed to load recent files: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
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

    // UX-05: block the UI while the (possibly large) file is copied in.
    setState(() => _isImporting = true);
    try {
      // Copy to app documents for persistence
      final savedPath = await _saveToAppDir(name, bytes);
      if (savedPath == null) return; // UX-06: user cancelled the overwrite prompt.

      if (mounted) {
        // Refresh list BEFORE navigation to avoid setState on unmounted widget.
        await _loadRecentFiles();
        if (mounted) {
          context.pushNamed('reader', queryParameters: {'path': savedPath});
        }
      }
    } on ArgumentError {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Geçersiz dosya adı.')),
        );
      }
    } catch (e) {
      debugPrint('Import failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Dosya içe aktarılamadı.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  /// Returns the saved path, or `null` if the user cancelled an overwrite prompt.
  Future<String?> _saveToAppDir(String fileName, Uint8List bytes) async {
    final appDir = await getApplicationDocumentsDirectory();
    final udfDir = Directory('${appDir.path}/udf_files');
    if (!await udfDir.exists()) {
      await udfDir.create(recursive: true);
    }

    final safeName = _sanitizeUdfName(fileName);

    final targetPath = await _resolveSavePath(udfDir, safeName);
    if (targetPath == null) return null;

    // Version history: preserve existing content before an overwrite-import.
    await VersionStore.snapshot(targetPath);
    final targetFile = File(targetPath);
    await targetFile.writeAsBytes(bytes, flush: true);
    return targetFile.path;
  }

  /// SEC-03: Sanitize filename — strip directory separators to prevent
  /// path traversal (e.g. "../../etc/passwd.udf") — and ensure a .udf suffix.
  String _sanitizeUdfName(String fileName) {
    var safeName = fileName.split(RegExp(r'[/\\]')).last.trim();
    if (safeName.isEmpty || safeName.startsWith('.')) {
      throw ArgumentError('Invalid filename: $fileName');
    }
    if (!safeName.toLowerCase().endsWith('.udf')) {
      safeName = '$safeName.udf';
    }
    return safeName;
  }

  /// UX-06: if [safeName] already exists in [dir], ask the user how to
  /// proceed. Returns the resolved target path, or `null` if cancelled.
  Future<String?> _resolveSavePath(Directory dir, String safeName) async {
    final target = File('${dir.path}/$safeName');
    if (!await target.exists()) return target.path;

    final action = await _askOverwrite(safeName);
    if (action == null || action == _OverwriteAction.cancel) return null;
    if (action == _OverwriteAction.overwrite) return target.path;

    final dotIndex = safeName.lastIndexOf('.');
    final base = dotIndex > 0 ? safeName.substring(0, dotIndex) : safeName;
    final ext = dotIndex > 0 ? safeName.substring(dotIndex) : '';
    var i = 2;
    File candidate;
    do {
      candidate = File('${dir.path}/$base ($i)$ext');
      i++;
    } while (await candidate.exists());
    return candidate.path;
  }

  Future<_OverwriteAction?> _askOverwrite(String name) {
    return showDialog<_OverwriteAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dosya Zaten Var'),
        content: Text('"$name" adında bir dosya zaten mevcut. Ne yapmak istersiniz?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _OverwriteAction.cancel),
            child: const Text('İptal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _OverwriteAction.keepBoth),
            child: const Text('İkisini de Sakla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _OverwriteAction.overwrite),
            child: const Text('Üzerine Yaz'),
          ),
        ],
      ),
    );
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

  // M-04/UX-09: long-press actions for a file card.
  Future<void> _showFileActions(_FileEntry entry) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Yeniden Adlandır'),
              onTap: () {
                Navigator.pop(ctx);
                _renameFile(entry);
              },
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Sürüm Geçmişi'),
              onTap: () {
                Navigator.pop(ctx);
                _showVersionHistory(entry);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Sil'),
              onTap: () {
                Navigator.pop(ctx);
                _deleteFile(entry);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _renameFile(_FileEntry entry) async {
    final controller = TextEditingController(text: entry.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Yeniden Adlandır'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Dosya adı'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
    if (newName == null || newName.trim().isEmpty) return;

    String safeName;
    try {
      safeName = _sanitizeUdfName(newName.trim());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Geçersiz dosya adı.')),
        );
      }
      return;
    }

    if (safeName == entry.name) return; // No-op rename.

    final dir = File(entry.path).parent;
    final targetPath = await _resolveSavePath(dir, safeName);
    if (targetPath == null) return; // Cancelled.

    try {
      // Version history: if the rename overwrites an existing file, preserve
      // that file's content first; then re-key the renamed file's history.
      await VersionStore.snapshot(targetPath);
      await File(entry.path).rename(targetPath);
      await VersionStore.moveKey(entry.path, targetPath);
      // Editor drafts are keyed by source path — drop the old path's draft
      // so it can't resurface for an unrelated future file.
      await DraftStore.deleteFor(entry.path);
      await _loadRecentFiles();
    } catch (e) {
      debugPrint('Rename failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Yeniden adlandırma başarısız oldu.')),
        );
      }
    }
  }

  Future<void> _deleteFile(_FileEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dosyayı Sil'),
        content: Text('"${entry.name}" dosyasını silmek istediğinize emin misiniz?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await File(entry.path).delete();
      // Deleting the document must also delete its draft and version
      // history — content must not outlive the file the user removed.
      await DraftStore.deleteFor(entry.path);
      await VersionStore.deleteAllFor(entry.path);
      await _loadRecentFiles();
    } catch (e) {
      debugPrint('Delete failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Dosya silinemedi.')),
        );
      }
    }
  }

  // Version history (Pro): list, view, and restore document snapshots.
  Future<void> _showVersionHistory(_FileEntry entry) async {
    final allowed = await PaywallService.instance.requirePro();
    if (!allowed || !mounted) return;

    final versions = await VersionStore.list(entry.path);
    if (!mounted) return;

    if (versions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bu dosya için henüz sürüm geçmişi yok.')),
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Sürüm Geçmişi — ${entry.name}',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: versions.length,
                itemBuilder: (_, i) {
                  final v = versions[i];
                  return ListTile(
                    leading: const Icon(Icons.history),
                    title: Text(_formatVersionTime(v.savedAt)),
                    subtitle: Text('${(v.size / 1024).toStringAsFixed(1)} KB'),
                    trailing: IconButton(
                      icon: const Icon(Icons.restore),
                      tooltip: 'Geri Yükle',
                      onPressed: () {
                        Navigator.pop(ctx);
                        _restoreVersion(entry, v);
                      },
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      context.pushNamed('reader', queryParameters: {'path': v.path});
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _restoreVersion(_FileEntry entry, VersionEntry version) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sürümü Geri Yükle'),
        content: Text(
          '"${entry.name}" dosyası ${_formatVersionTime(version.savedAt)} '
          'tarihli sürüme geri yüklensin mi? Mevcut içerik de sürüm '
          'geçmişine kaydedilecek.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Geri Yükle'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final ok = await VersionStore.restore(entry.path, version);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Sürüm geri yüklendi.' : 'Geri yükleme başarısız oldu.'),
      ),
    );
    if (ok) await _loadRecentFiles();
  }

  String _formatVersionTime(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}.${two(dt.month)}.${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
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
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _recentFiles.isEmpty
                        ? _buildEmptyState(theme, colorScheme)
                        : _buildFileList(theme, colorScheme),
              ),
              // UX-08: only show the ad once the list has actually loaded.
              if (!_isLoading && !_isImporting) const AdBannerWidget(),
            ],
          ),
          // UX-05: blocking overlay while a picked file is being copied in.
          if (_isImporting)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.3),
                child: const Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isImporting ? null : _pickFile,
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
          final entry = _recentFiles[index];
          final sizeKb = (entry.size / 1024).toStringAsFixed(1);
          final modified = _formatDate(entry.modified);

          return Semantics(
            button: true,
            label: '${entry.name}, $sizeKb KB, $modified',
            child: Card(
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
                  entry.name,
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
                    queryParameters: {'path': entry.path},
                  );
                },
                onLongPress: () => _showFileActions(entry),
              ),
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

    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
  }
}
