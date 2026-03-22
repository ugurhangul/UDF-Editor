import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Persistent local state for tracking sync history per file.
///
/// Stores a JSON file at `{appDir}/sync_state.json` mapping each
/// `.udf` filename to its last known sync state (hash + timestamps).
///
/// Used by sync providers to determine which files need uploading,
/// downloading, or conflict resolution.
class SyncState {
  SyncState._(this._entries);

  final Map<String, SyncFileEntry> _entries;

  static SyncState? _instance;

  /// Load or create the sync state from disk.
  static Future<SyncState> load() async {
    if (_instance != null) return _instance!;

    final file = await _stateFile();
    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final entries = json.map((key, value) => MapEntry(
          key,
          SyncFileEntry.fromJson(value as Map<String, dynamic>),
        ));
        _instance = SyncState._(entries);
      } catch (_) {
        _instance = SyncState._({});
      }
    } else {
      _instance = SyncState._({});
    }
    return _instance!;
  }

  /// Get the tracked state for a specific file.
  SyncFileEntry? getEntry(String fileName) => _entries[fileName];

  /// Update the tracked state for a file after successful sync.
  void updateEntry(String fileName, SyncFileEntry entry) {
    _entries[fileName] = entry;
  }

  /// Remove tracking for a deleted file.
  void removeEntry(String fileName) {
    _entries.remove(fileName);
  }

  /// Get all tracked file names.
  Iterable<String> get trackedFiles => _entries.keys;

  /// Get the most recent sync time across all files.
  DateTime? get lastSyncTime {
    DateTime? latest;
    for (final entry in _entries.values) {
      if (latest == null || entry.lastSyncedAt.isAfter(latest)) {
        latest = entry.lastSyncedAt;
      }
    }
    return latest;
  }

  /// Persist current state to disk.
  Future<void> save() async {
    final file = await _stateFile();
    final json = _entries.map((key, value) => MapEntry(key, value.toJson()));
    await file.writeAsString(jsonEncode(json));
  }

  /// Clear all tracked state.
  Future<void> clear() async {
    _entries.clear();
    final file = await _stateFile();
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Invalidate cached instance (for testing).
  static void resetInstance() => _instance = null;

  static Future<File> _stateFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/sync_state.json');
  }
}

/// Tracked state for a single synced file.
class SyncFileEntry {
  const SyncFileEntry({
    required this.fileName,
    required this.localHash,
    required this.remoteId,
    required this.lastSyncedAt,
    required this.localModifiedAt,
    required this.remoteModifiedAt,
  });

  /// File name (e.g., "belge.udf").
  final String fileName;

  /// MD5 hash of the local file at last sync.
  final String localHash;

  /// Provider-specific remote file ID.
  final String remoteId;

  /// When this file was last synced.
  final DateTime lastSyncedAt;

  /// Local file modification time at last sync.
  final DateTime localModifiedAt;

  /// Remote file modification time at last sync.
  final DateTime remoteModifiedAt;

  factory SyncFileEntry.fromJson(Map<String, dynamic> json) {
    return SyncFileEntry(
      fileName: json['fileName'] as String,
      localHash: json['localHash'] as String,
      remoteId: json['remoteId'] as String,
      lastSyncedAt: DateTime.parse(json['lastSyncedAt'] as String),
      localModifiedAt: DateTime.parse(json['localModifiedAt'] as String),
      remoteModifiedAt: DateTime.parse(json['remoteModifiedAt'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'fileName': fileName,
    'localHash': localHash,
    'remoteId': remoteId,
    'lastSyncedAt': lastSyncedAt.toIso8601String(),
    'localModifiedAt': localModifiedAt.toIso8601String(),
    'remoteModifiedAt': remoteModifiedAt.toIso8601String(),
  };
}
