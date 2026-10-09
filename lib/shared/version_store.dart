import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// A single snapshot of a document.
class VersionEntry {
  const VersionEntry({
    required this.path,
    required this.savedAt,
    required this.size,
  });

  final String path;
  final DateTime savedAt;
  final int size;
}

/// Full-file version snapshots for .udf documents.
///
/// Layout: `udf_versions/<sha256(sourcePath)>/<millisSinceEpoch>.udf`.
/// Snapshots are taken before every destructive write (editor save,
/// import/rename overwrite, signing) and capped at [maxVersionsPerFile]
/// per document. All operations are best-effort — a failed snapshot must
/// never block the write it precedes.
class VersionStore {
  static const maxVersionsPerFile = 20;

  static String _keyFor(String sourcePath) =>
      sha256.convert(utf8.encode(sourcePath)).toString();

  static Future<Directory> _dirFor(String sourcePath, {bool create = false}) async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/udf_versions/${_keyFor(sourcePath)}');
    if (create && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Snapshot the current on-disk content of [sourcePath], if it exists.
  static Future<void> snapshot(String sourcePath) async {
    try {
      final source = File(sourcePath);
      if (!await source.exists()) return;

      final dir = await _dirFor(sourcePath, create: true);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      await source.copy('${dir.path}/$stamp.udf');
      await _prune(dir);
    } catch (_) {
      // Best-effort — never block the write this snapshot precedes.
    }
  }

  /// All snapshots for [sourcePath], newest first.
  static Future<List<VersionEntry>> list(String sourcePath) async {
    try {
      final dir = await _dirFor(sourcePath);
      if (!await dir.exists()) return const [];

      final entries = <VersionEntry>[];
      await for (final f in dir.list()) {
        if (f is! File) continue;
        final stamp = _stampOf(f.path);
        if (stamp == null) continue;
        final stat = await f.stat();
        entries.add(VersionEntry(
          path: f.path,
          savedAt: DateTime.fromMillisecondsSinceEpoch(stamp),
          size: stat.size,
        ));
      }
      entries.sort((a, b) => b.savedAt.compareTo(a.savedAt));
      return entries;
    } catch (_) {
      return const [];
    }
  }

  /// Overwrite [sourcePath] with [version]'s content. The current content
  /// is snapshotted first, so a restore can itself be undone.
  static Future<bool> restore(String sourcePath, VersionEntry version) async {
    try {
      final versionFile = File(version.path);
      if (!await versionFile.exists()) return false;

      await snapshot(sourcePath);
      await versionFile.copy(sourcePath);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Re-key snapshots when a document is renamed, so its history follows it.
  static Future<void> moveKey(String oldPath, String newPath) async {
    try {
      final oldDir = await _dirFor(oldPath);
      if (!await oldDir.exists()) return;
      final newDir = await _dirFor(newPath);
      if (await newDir.exists()) {
        // Target had its own history (overwrite-rename) — merge by moving
        // files across, letting prune enforce the cap.
        await for (final f in oldDir.list()) {
          if (f is File) {
            await f.rename('${newDir.path}/${f.uri.pathSegments.last}');
          }
        }
        await oldDir.delete(recursive: true);
        await _prune(newDir);
      } else {
        await oldDir.rename(newDir.path);
      }
    } catch (_) {
      // Best-effort.
    }
  }

  /// Drop all history when the document is deleted — content must not
  /// outlive the file the user believes is gone.
  static Future<void> deleteAllFor(String sourcePath) async {
    try {
      final dir = await _dirFor(sourcePath);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // Best-effort.
    }
  }

  static int? _stampOf(String path) {
    final name = path.split(Platform.pathSeparator).last.split('/').last;
    if (!name.endsWith('.udf')) return null;
    return int.tryParse(name.substring(0, name.length - 4));
  }

  static Future<void> _prune(Directory dir) async {
    final stamped = <(int, File)>[];
    await for (final f in dir.list()) {
      if (f is! File) continue;
      final stamp = _stampOf(f.path);
      if (stamp != null) stamped.add((stamp, f));
    }
    if (stamped.length <= maxVersionsPerFile) return;
    stamped.sort((a, b) => b.$1.compareTo(a.$1)); // newest first
    for (final (_, f) in stamped.skip(maxVersionsPerFile)) {
      try {
        await f.delete();
      } catch (_) {}
    }
  }
}
