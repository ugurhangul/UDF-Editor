import 'dart:io';

import 'package:crypto/crypto.dart' as file_crypto;
import 'package:icloud_storage/icloud_storage.dart';
import 'package:path/path.dart' as p;

import 'sync_metadata.dart';
import 'sync_service.dart';
import 'sync_state.dart';
import 'google_drive_sync.dart' show SyncException;

/// iCloud sync provider.
///
/// Uses `icloud_storage` package for iCloud Document Container.
/// Syncs `.udf` files between the app's local `udf_files/` directory
/// and the iCloud container.
///
/// **iOS/macOS only** — returns `isAvailable() = false` on Android.
class ICloudSync implements SyncService {
  ICloudSync({required this.containerId});

  /// iCloud container ID (e.g., "iCloud.com.udftor.udfeditor").
  final String containerId;

  @override
  String get name => 'iCloud';

  @override
  String get iconAsset => 'icloud';

  @override
  Future<bool> isAvailable() async {
    if (!Platform.isIOS && !Platform.isMacOS) return false;
    try {
      await ICloudStorage.gather(containerId: containerId);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isAuthenticated() async {
    // iCloud auth is implicit — if available, user is authenticated.
    return await isAvailable();
  }

  @override
  Future<void> signIn() async {
    if (!await isAvailable()) {
      throw SyncException('iCloud bu cihazda kullanılamıyor');
    }
  }

  @override
  Future<void> signOut() async {
    final state = await SyncState.load();
    await state.clear();
  }

  @override
  Future<SyncUserInfo?> getUserInfo() async {
    if (!await isAvailable()) return null;
    return const SyncUserInfo(displayName: 'iCloud');
  }

  @override
  Future<List<SyncFileInfo>> listRemoteFiles() async {
    final cloudFiles = await ICloudStorage.gather(containerId: containerId);

    return cloudFiles
        .where((f) => f.relativePath.toLowerCase().endsWith('.udf'))
        .map((f) => SyncFileInfo(
              remoteId: f.relativePath,
              fileName: p.basename(f.relativePath),
              modifiedAt: f.contentChangeDate,
              sizeBytes: f.sizeInBytes,
            ))
        .toList();
  }

  @override
  Future<SyncFileInfo> uploadFile(String localPath) async {
    final fileName = p.basename(localPath);

    await ICloudStorage.upload(
      containerId: containerId,
      filePath: localPath,
      destinationRelativePath: fileName,
    );

    final localFile = File(localPath);
    final stat = await localFile.stat();

    return SyncFileInfo(
      remoteId: fileName,
      fileName: fileName,
      modifiedAt: stat.modified,
      sizeBytes: stat.size,
    );
  }

  @override
  Future<void> downloadFile(SyncFileInfo remote, String localPath) async {
    await ICloudStorage.download(
      containerId: containerId,
      relativePath: remote.remoteId,
      destinationFilePath: localPath,
    );
  }

  @override
  Future<void> deleteRemoteFile(SyncFileInfo remote) async {
    await ICloudStorage.delete(
      containerId: containerId,
      relativePath: remote.remoteId,
    );
  }

  @override
  Future<SyncReport> syncAll(String localDirectory) async {
    final syncState = await SyncState.load();

    final dir = Directory(localDirectory);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final localFiles = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.udf'))
        .toList();

    final remoteFiles = await listRemoteFiles();

    final localMap = <String, File>{};
    for (final f in localFiles) {
      localMap[p.basename(f.path)] = f;
    }

    final remoteMap = <String, SyncFileInfo>{};
    for (final f in remoteFiles) {
      remoteMap[f.fileName] = f;
    }

    var uploaded = 0;
    var downloaded = 0;
    var skipped = 0;
    final conflicts = <SyncConflict>[];
    final errors = <SyncError>[];

    final allFiles = {...localMap.keys, ...remoteMap.keys};

    for (final fileName in allFiles) {
      try {
        final localFile = localMap[fileName];
        final remoteFile = remoteMap[fileName];
        final tracked = syncState.getEntry(fileName);

        if (localFile != null && remoteFile == null) {
          // Local only → upload
          final result = await uploadFile(localFile.path);
          syncState.updateEntry(
            fileName,
            SyncFileEntry(
              fileName: fileName,
              localHash: await _hashFile(localFile),
              remoteId: result.remoteId,
              lastSyncedAt: DateTime.now().toUtc(),
              localModifiedAt: await localFile.lastModified(),
              remoteModifiedAt: result.modifiedAt,
            ),
          );
          uploaded++;
        } else if (localFile == null && remoteFile != null) {
          // Remote only → download
          final localPath = p.join(localDirectory, fileName);
          await downloadFile(remoteFile, localPath);
          final downloadedFile = File(localPath);
          syncState.updateEntry(
            fileName,
            SyncFileEntry(
              fileName: fileName,
              localHash: await _hashFile(downloadedFile),
              remoteId: remoteFile.remoteId,
              lastSyncedAt: DateTime.now().toUtc(),
              localModifiedAt: await downloadedFile.lastModified(),
              remoteModifiedAt: remoteFile.modifiedAt,
            ),
          );
          downloaded++;
        } else if (localFile != null && remoteFile != null) {
          final localModified = await localFile.lastModified();
          final localHash = await _hashFile(localFile);

          final localChanged =
              tracked == null || localHash != tracked.localHash;
          final remoteChanged = tracked == null ||
              remoteFile.modifiedAt.isAfter(tracked.remoteModifiedAt);

          if (localChanged && remoteChanged) {
            // Conflict — last-writer-wins
            ConflictResolution resolution;
            if (localModified.isAfter(remoteFile.modifiedAt)) {
              await uploadFile(localFile.path);
              resolution = ConflictResolution.keptLocal;
            } else {
              await downloadFile(remoteFile, localFile.path);
              resolution = ConflictResolution.keptRemote;
            }
            conflicts.add(SyncConflict(
              fileName: fileName,
              localModified: localModified,
              remoteModified: remoteFile.modifiedAt,
              resolution: resolution,
            ));
          } else if (localChanged) {
            final result = await uploadFile(localFile.path);
            syncState.updateEntry(
              fileName,
              SyncFileEntry(
                fileName: fileName,
                localHash: localHash,
                remoteId: result.remoteId,
                lastSyncedAt: DateTime.now().toUtc(),
                localModifiedAt: localModified,
                remoteModifiedAt: result.modifiedAt,
              ),
            );
            uploaded++;
          } else if (remoteChanged) {
            await downloadFile(remoteFile, localFile.path);
            syncState.updateEntry(
              fileName,
              SyncFileEntry(
                fileName: fileName,
                localHash: await _hashFile(localFile),
                remoteId: remoteFile.remoteId,
                lastSyncedAt: DateTime.now().toUtc(),
                localModifiedAt: await localFile.lastModified(),
                remoteModifiedAt: remoteFile.modifiedAt,
              ),
            );
            downloaded++;
          } else {
            skipped++;
          }
        }
      } catch (e) {
        errors.add(SyncError(
          fileName: fileName,
          message: e.toString(),
          cause: e,
        ));
      }
    }

    await syncState.save();

    return SyncReport(
      uploaded: uploaded,
      downloaded: downloaded,
      skipped: skipped,
      conflicts: conflicts,
      errors: errors,
      syncedAt: DateTime.now().toUtc(),
    );
  }

  Future<String> _hashFile(File file) async {
    final bytes = await file.readAsBytes();
    return file_crypto.md5.convert(bytes).toString();
  }
}
