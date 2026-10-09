import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Locates plain-text editor draft files.
///
/// Keys are SHA-256 of the full source path so documents whose names differ
/// only in characters outside [A-Za-z0-9] (e.g. "dava 1.udf" vs "dava_1.udf")
/// can never collide onto the same draft.
class DraftStore {
  static Future<File> fileFor(String? sourcePath) async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/udf_drafts');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final key = sourcePath == null
        ? 'new_document'
        : sha256.convert(utf8.encode(sourcePath)).toString();
    return File('${dir.path}/$key.txt');
  }

  static Future<void> deleteFor(String? sourcePath) async {
    try {
      final file = await fileFor(sourcePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best-effort.
    }
  }
}
