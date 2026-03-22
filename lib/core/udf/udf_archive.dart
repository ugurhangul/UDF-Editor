import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Handles extraction and creation of .udf ZIP archives.
///
/// A .udf file is a ZIP archive containing:
/// - `content.xml` — formatted document content
/// - `sign.sgn`    — CAdES digital signature (optional)
/// - `documentproperties.xml` — metadata (optional)
class UdfArchive {
  UdfArchive._({
    required this.contentXml,
    this.signatureBytes,
    this.propertiesXml,
    this.otherFiles = const {},
  });

  /// Raw UTF-8 string of content.xml.
  final String contentXml;

  /// Raw bytes of sign.sgn (DER-encoded PKCS#7/CMS).
  final Uint8List? signatureBytes;

  /// Raw UTF-8 string of documentproperties.xml.
  final String? propertiesXml;

  /// Any unrecognized files inside the archive, preserved for roundtrip.
  final Map<String, Uint8List> otherFiles;

  /// Whether this document has a digital signature.
  bool get isSigned => signatureBytes != null && signatureBytes!.isNotEmpty;

  // ---------------------------------------------------------------------------
  // Extraction
  // ---------------------------------------------------------------------------

  /// Extract a .udf file from raw ZIP bytes.
  ///
  /// Throws [UdfArchiveException] if `content.xml` is missing.
  static UdfArchive fromBytes(Uint8List zipBytes) {
    final archive = ZipDecoder().decodeBytes(zipBytes);

    String? contentXml;
    Uint8List? signatureBytes;
    String? propertiesXml;
    final otherFiles = <String, Uint8List>{};

    for (final file in archive) {
      if (file.isFile) {
        final name = file.name.toLowerCase();
        final bytes = file.readBytes();
        if (bytes == null) continue;

        if (name == 'content.xml') {
          contentXml = utf8.decode(bytes, allowMalformed: true);
        } else if (name == 'sign.sgn') {
          signatureBytes = Uint8List.fromList(bytes);
        } else if (name == 'documentproperties.xml') {
          propertiesXml = utf8.decode(bytes, allowMalformed: true);
        } else {
          otherFiles[file.name] = Uint8List.fromList(bytes);
        }
      }
    }

    if (contentXml == null) {
      throw UdfArchiveException(
        'Invalid .udf file: content.xml not found in archive.',
      );
    }

    return UdfArchive._(
      contentXml: contentXml,
      signatureBytes: signatureBytes,
      propertiesXml: propertiesXml,
      otherFiles: otherFiles,
    );
  }

  // ---------------------------------------------------------------------------
  // Packing
  // ---------------------------------------------------------------------------

  /// Pack a .udf file back into ZIP bytes.
  ///
  /// [contentXml] is required. [signatureBytes] and [propertiesXml] are
  /// optional. Any files in [otherFiles] are preserved.
  static Uint8List toBytes({
    required String contentXml,
    Uint8List? signatureBytes,
    String? propertiesXml,
    Map<String, Uint8List> otherFiles = const {},
  }) {
    final archive = Archive();

    // content.xml — always present
    final contentBytes = Uint8List.fromList(utf8.encode(contentXml));
    archive.addFile(
      ArchiveFile.bytes('content.xml', contentBytes),
    );

    // sign.sgn — optional
    if (signatureBytes != null && signatureBytes.isNotEmpty) {
      archive.addFile(
        ArchiveFile.bytes('sign.sgn', signatureBytes),
      );
    }

    // documentproperties.xml — optional
    if (propertiesXml != null) {
      final propBytes = Uint8List.fromList(utf8.encode(propertiesXml));
      archive.addFile(
        ArchiveFile.bytes('documentproperties.xml', propBytes),
      );
    }

    // Preserve any other files for roundtrip fidelity
    for (final entry in otherFiles.entries) {
      archive.addFile(
        ArchiveFile.bytes(entry.key, entry.value),
      );
    }

    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  /// Convenience: repack this archive with updated content XML.
  Uint8List repack({String? updatedContentXml}) {
    return toBytes(
      contentXml: updatedContentXml ?? contentXml,
      signatureBytes: updatedContentXml != null ? null : signatureBytes,
      propertiesXml: propertiesXml,
      otherFiles: otherFiles,
    );
  }
}

/// Exception thrown by [UdfArchive] operations.
class UdfArchiveException implements Exception {
  UdfArchiveException(this.message);
  final String message;

  @override
  String toString() => 'UdfArchiveException: $message';
}
