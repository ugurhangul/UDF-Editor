// Models for cloud sync metadata and state tracking.

/// Information about a file stored in the remote sync folder.
class SyncFileInfo {
  const SyncFileInfo({
    required this.remoteId,
    required this.fileName,
    required this.modifiedAt,
    required this.sizeBytes,
    this.md5Hash,
  });

  /// Provider-specific remote file identifier.
  ///
  /// Google Drive: file ID string.
  /// iCloud: relative cloud path.
  final String remoteId;

  /// File name (e.g., "belge.udf").
  final String fileName;

  /// Last modification timestamp (UTC).
  final DateTime modifiedAt;

  /// File size in bytes.
  final int sizeBytes;

  /// MD5 hash of file content (if available from provider).
  final String? md5Hash;

  @override
  String toString() => 'SyncFileInfo($fileName, $remoteId)';
}

/// Sync user info for display in settings.
class SyncUserInfo {
  const SyncUserInfo({
    required this.displayName,
    this.email,
    this.photoUrl,
  });

  final String displayName;
  final String? email;
  final String? photoUrl;
}

/// Report produced after a full sync operation.
class SyncReport {
  const SyncReport({
    this.uploaded = 0,
    this.downloaded = 0,
    this.deleted = 0,
    this.skipped = 0,
    this.conflicts = const [],
    this.errors = const [],
    required this.syncedAt,
  });

  /// Number of files uploaded to remote.
  final int uploaded;

  /// Number of files downloaded from remote.
  final int downloaded;

  /// Number of files deleted (local or remote).
  final int deleted;

  /// Number of files unchanged (already in sync).
  final int skipped;

  /// Files that had conflicting changes on both sides.
  final List<SyncConflict> conflicts;

  /// Errors encountered during sync.
  final List<SyncError> errors;

  /// When this sync completed.
  final DateTime syncedAt;

  /// Total files processed.
  int get total => uploaded + downloaded + deleted + skipped;

  /// Whether sync completed without errors.
  bool get isClean => errors.isEmpty && conflicts.isEmpty;
}

/// A conflict where both local and remote versions were modified.
class SyncConflict {
  const SyncConflict({
    required this.fileName,
    required this.localModified,
    required this.remoteModified,
    required this.resolution,
  });

  final String fileName;
  final DateTime localModified;
  final DateTime remoteModified;

  /// How the conflict was resolved.
  final ConflictResolution resolution;
}

/// How a sync conflict was resolved.
enum ConflictResolution {
  /// Remote version was kept (remote was newer).
  keptRemote,

  /// Local version was kept (local was newer).
  keptLocal,

  /// User chose which version to keep.
  userChoice,

  /// Both versions were kept (renamed).
  keptBoth,

  /// Conflict was not resolved.
  unresolved,
}

/// An error that occurred during sync.
class SyncError {
  const SyncError({
    required this.fileName,
    required this.message,
    this.cause,
  });

  final String fileName;
  final String message;
  final Object? cause;
}

/// Overall sync status for UI display.
enum SyncStatus {
  /// No sync in progress, nothing pending.
  idle,

  /// Sync is currently running.
  syncing,

  /// Last sync encountered errors.
  error,

  /// All files are in sync.
  upToDate,

  /// Not configured / not signed in.
  disabled,
}
