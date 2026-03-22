import 'dart:io';

import 'package:crypto/crypto.dart' as file_crypto;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'sync_metadata.dart';
import 'sync_service.dart';
import 'sync_state.dart';

/// Google Drive sync provider.
///
/// Stores `.udf` files in a dedicated "UDFtör" folder within the user's
/// Google Drive. Uses `google_sign_in` for OAuth 2.0 and `googleapis`
/// for Drive REST API.
class GoogleDriveSync implements SyncService {
  GoogleDriveSync({GoogleSignIn? googleSignIn})
      : _googleSignIn = googleSignIn ??
            GoogleSignIn(scopes: [drive.DriveApi.driveFileScope]);

  final GoogleSignIn _googleSignIn;

  /// Name of the app folder in the user's Drive root.
  static const _folderName = 'UDFtör';

  /// MIME type for Google Drive folders.
  static const _folderMime = 'application/vnd.google-apps.folder';

  drive.DriveApi? _driveApi;
  String? _folderId;

  @override
  String get name => 'Google Drive';

  @override
  String get iconAsset => 'google_drive';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> isAuthenticated() async {
    return _googleSignIn.currentUser != null ||
        await _googleSignIn.isSignedIn();
  }

  @override
  Future<void> signIn() async {
    var account = _googleSignIn.currentUser;
    account ??= await _googleSignIn.signInSilently();
    account ??= await _googleSignIn.signIn();

    if (account == null) {
      throw SyncException('Google oturum açma iptal edildi');
    }

    await _initDriveApi(account);
  }

  @override
  Future<void> signOut() async {
    await _googleSignIn.signOut();
    _driveApi = null;
    _folderId = null;
  }

  @override
  Future<SyncUserInfo?> getUserInfo() async {
    final account = _googleSignIn.currentUser;
    if (account == null) return null;
    return SyncUserInfo(
      displayName: account.displayName ?? account.email,
      email: account.email,
      photoUrl: account.photoUrl,
    );
  }

  @override
  Future<List<SyncFileInfo>> listRemoteFiles() async {
    final api = await _ensureApi();
    final folderId = await _ensureFolder(api);

    final fileList = await api.files.list(
      q: "'$folderId' in parents and trashed = false and name contains '.udf'",
      spaces: 'drive',
      $fields: 'files(id, name, modifiedTime, size, md5Checksum)',
      orderBy: 'modifiedTime desc',
      pageSize: 100,
    );

    return (fileList.files ?? []).map((f) => SyncFileInfo(
      remoteId: f.id!,
      fileName: f.name!,
      modifiedAt: f.modifiedTime ?? DateTime.now(),
      sizeBytes: int.tryParse(f.size ?? '0') ?? 0,
      md5Hash: f.md5Checksum,
    )).toList();
  }

  @override
  Future<SyncFileInfo> uploadFile(String localPath) async {
    final api = await _ensureApi();
    final folderId = await _ensureFolder(api);
    final file = File(localPath);
    final fileName = p.basename(localPath);

    // Check if file already exists remotely
    final existing = await _findRemoteFile(api, folderId, fileName);

    final media = drive.Media(file.openRead(), await file.length());

    drive.File result;
    if (existing != null) {
      // Update existing file
      result = await api.files.update(
        drive.File()..modifiedTime = await file.lastModified(),
        existing.id!,
        uploadMedia: media,
        $fields: 'id, name, modifiedTime, size, md5Checksum',
      );
    } else {
      // Create new file
      result = await api.files.create(
        drive.File()
          ..name = fileName
          ..parents = [folderId]
          ..modifiedTime = await file.lastModified(),
        uploadMedia: media,
        $fields: 'id, name, modifiedTime, size, md5Checksum',
      );
    }

    return SyncFileInfo(
      remoteId: result.id!,
      fileName: result.name!,
      modifiedAt: result.modifiedTime ?? DateTime.now(),
      sizeBytes: int.tryParse(result.size ?? '0') ?? 0,
      md5Hash: result.md5Checksum,
    );
  }

  @override
  Future<void> downloadFile(SyncFileInfo remote, String localPath) async {
    final api = await _ensureApi();

    final response = await api.files.get(
      remote.remoteId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;

    final file = File(localPath);
    final sink = file.openWrite();
    await for (final chunk in response.stream) {
      sink.add(chunk);
    }
    await sink.close();
  }

  @override
  Future<void> deleteRemoteFile(SyncFileInfo remote) async {
    final api = await _ensureApi();
    await api.files.delete(remote.remoteId);
  }

  @override
  Future<SyncReport> syncAll(String localDirectory) async {
    final api = await _ensureApi();
    await _ensureFolder(api);
    final syncState = await SyncState.load();

    final dir = Directory(localDirectory);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // Gather local and remote file lists
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

    // All known file names
    final allFiles = {...localMap.keys, ...remoteMap.keys};

    for (final fileName in allFiles) {
      try {
        final localFile = localMap[fileName];
        final remoteFile = remoteMap[fileName];
        final tracked = syncState.getEntry(fileName);

        if (localFile != null && remoteFile == null) {
          // Local only → upload
          final result = await uploadFile(localFile.path);
          syncState.updateEntry(fileName, SyncFileEntry(
            fileName: fileName,
            localHash: await _hashFile(localFile),
            remoteId: result.remoteId,
            lastSyncedAt: DateTime.now().toUtc(),
            localModifiedAt: await localFile.lastModified(),
            remoteModifiedAt: result.modifiedAt,
          ));
          uploaded++;
        } else if (localFile == null && remoteFile != null) {
          // Remote only → download
          final localPath = p.join(localDirectory, fileName);
          await downloadFile(remoteFile, localPath);
          final downloadedFile = File(localPath);
          syncState.updateEntry(fileName, SyncFileEntry(
            fileName: fileName,
            localHash: await _hashFile(downloadedFile),
            remoteId: remoteFile.remoteId,
            lastSyncedAt: DateTime.now().toUtc(),
            localModifiedAt: await downloadedFile.lastModified(),
            remoteModifiedAt: remoteFile.modifiedAt,
          ));
          downloaded++;
        } else if (localFile != null && remoteFile != null) {
          // Both exist → check for changes
          final localModified = await localFile.lastModified();
          final localHash = await _hashFile(localFile);

          final localChanged = tracked == null || localHash != tracked.localHash;
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
            // Local changed → upload
            final result = await uploadFile(localFile.path);
            syncState.updateEntry(fileName, SyncFileEntry(
              fileName: fileName,
              localHash: localHash,
              remoteId: result.remoteId,
              lastSyncedAt: DateTime.now().toUtc(),
              localModifiedAt: localModified,
              remoteModifiedAt: result.modifiedAt,
            ));
            uploaded++;
          } else if (remoteChanged) {
            // Remote changed → download
            await downloadFile(remoteFile, localFile.path);
            syncState.updateEntry(fileName, SyncFileEntry(
              fileName: fileName,
              localHash: await _hashFile(localFile),
              remoteId: remoteFile.remoteId,
              lastSyncedAt: DateTime.now().toUtc(),
              localModifiedAt: await localFile.lastModified(),
              remoteModifiedAt: remoteFile.modifiedAt,
            ));
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

  // ── Private helpers ───────────────────────────────────────────────

  Future<drive.DriveApi> _ensureApi() async {
    if (_driveApi != null) return _driveApi!;

    var account = _googleSignIn.currentUser;
    account ??= await _googleSignIn.signInSilently();

    if (account == null) {
      throw SyncException('Google oturumu açık değil');
    }

    await _initDriveApi(account);
    return _driveApi!;
  }

  Future<void> _initDriveApi(GoogleSignInAccount account) async {
    final authHeaders = await account.authHeaders;
    final client = _AuthClient(http.Client(), authHeaders);
    _driveApi = drive.DriveApi(client);
  }

  Future<String> _ensureFolder(drive.DriveApi api) async {
    if (_folderId != null) return _folderId!;

    // Search for existing folder
    final result = await api.files.list(
      q: "name = '$_folderName' and mimeType = '$_folderMime' and trashed = false",
      spaces: 'drive',
      $fields: 'files(id)',
      pageSize: 1,
    );

    if (result.files != null && result.files!.isNotEmpty) {
      _folderId = result.files!.first.id!;
      return _folderId!;
    }

    // Create folder
    final folder = await api.files.create(
      drive.File()
        ..name = _folderName
        ..mimeType = _folderMime,
      $fields: 'id',
    );
    _folderId = folder.id!;
    return _folderId!;
  }

  Future<drive.File?> _findRemoteFile(
    drive.DriveApi api,
    String folderId,
    String fileName,
  ) async {
    final result = await api.files.list(
      q: "'$folderId' in parents and name = '$fileName' and trashed = false",
      spaces: 'drive',
      $fields: 'files(id, name)',
      pageSize: 1,
    );
    return result.files?.firstOrNull;
  }

  Future<String> _hashFile(File file) async {
    final bytes = await file.readAsBytes();
    return file_crypto.md5.convert(bytes).toString();
  }
}

/// HTTP client wrapper that injects Google auth headers.
class _AuthClient extends http.BaseClient {
  _AuthClient(this._inner, this._headers);

  final http.Client _inner;
  final Map<String, String> _headers;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _inner.send(request);
  }
}

/// Exception thrown by sync operations.
class SyncException implements Exception {
  SyncException(this.message);
  final String message;

  @override
  String toString() => 'SyncException: $message';
}
