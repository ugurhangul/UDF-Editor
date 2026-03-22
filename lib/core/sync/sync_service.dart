import 'sync_metadata.dart';

/// Abstract interface for cloud sync providers.
///
/// Implementors: [GoogleDriveSync], [ICloudSync].
///
/// All methods operate on `.udf` files within the app's local
/// `udf_files/` directory and a corresponding remote folder.
abstract class SyncService {
  /// Provider display name (e.g., "Google Drive", "iCloud").
  String get name;

  /// Provider icon identifier for UI.
  String get iconAsset;

  /// Whether this sync provider is available on the current platform.
  Future<bool> isAvailable();

  /// Whether the user is currently authenticated.
  Future<bool> isAuthenticated();

  /// Trigger sign-in flow (OAuth for Google, implicit for iCloud).
  Future<void> signIn();

  /// Sign out and clear local auth tokens.
  Future<void> signOut();

  /// Get the currently signed-in user's display info.
  Future<SyncUserInfo?> getUserInfo();

  /// List all `.udf` files in the remote sync folder.
  Future<List<SyncFileInfo>> listRemoteFiles();

  /// Upload a local `.udf` file to the remote sync folder.
  ///
  /// If the file already exists remotely, it is updated (overwritten).
  /// Returns the updated [SyncFileInfo] for the uploaded file.
  Future<SyncFileInfo> uploadFile(String localPath);

  /// Download a remote `.udf` file to the local path.
  Future<void> downloadFile(SyncFileInfo remote, String localPath);

  /// Delete a remote `.udf` file.
  Future<void> deleteRemoteFile(SyncFileInfo remote);

  /// Perform full bidirectional sync between local directory and remote.
  ///
  /// Compares modification timestamps and file hashes to determine
  /// which files need uploading, downloading, or conflict resolution.
  Future<SyncReport> syncAll(String localDirectory);
}
