import 'dart:ui';

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'udf_document.dart';

/// Bidirectional converter between UDF offset-based model and Quill Delta.
///
/// **UDF → Delta** (for editing):
/// Walks paragraphs, slices text from CData, creates Delta insert operations.
///
/// **Delta → UDF** (for saving):
/// Walks Delta ops, rebuilds single CData string, generates offset-based runs.
class UdfDeltaConverter {
  UdfDeltaConverter._();

  // ---------------------------------------------------------------------------
  // UDF → Delta
  // ---------------------------------------------------------------------------

  /// Convert a [UdfDocument] to a Quill [Document] for editing.
  static Document toQuillDocument(UdfDocument udfDoc) {
    final delta = Delta();

    for (final section in udfDoc.sections) {
      for (int i = 0; i < section.paragraphs.length; i++) {
        final para = section.paragraphs[i];

        if (para.runs.isEmpty) {
          // Empty paragraph — just a newline
          delta.insert('\n', _paragraphAttributes(para));
          continue;
        }

        // Insert each run's text with inline attributes
        for (final run in para.runs) {
          final text = _safeSubstring(
            udfDoc.text,
            run.startOffset,
            run.endOffset,
          );
          if (text.isEmpty) continue;

          final attrs = _runToAttributes(run);
          if (attrs.isNotEmpty) {
            delta.insert(text, attrs);
          } else {
            delta.insert(text);
          }
        }

        // Paragraph terminator with block-level attributes
        final paraAttrs = _paragraphAttributes(para);
        if (paraAttrs.isNotEmpty) {
          delta.insert('\n', paraAttrs);
        } else {
          delta.insert('\n');
        }
      }
    }

    // Quill documents must end with a newline
    if (delta.isEmpty) {
      delta.insert('\n');
    }

    return Document.fromDelta(delta);
  }

  // ---------------------------------------------------------------------------
  // Delta → UDF
  // ---------------------------------------------------------------------------

  /// Convert a Quill [Document] back to a [UdfDocument].
  ///
  /// Preserves the original [template] document's format settings and styles.
  static UdfDocument fromQuillDocument(
    Document quillDoc, {
    UdfDocument? template,
  }) {
    final delta = quillDoc.toDelta();
    final textBuffer = StringBuffer();
    final paragraphs = <UdfParagraph>[];
    var currentRuns = <UdfTextRun>[];
    var currentOffset = 0;

    // Current paragraph attributes (set by newline ops)
    UdfAlignment currentAlignment = UdfAlignment.left;
    double currentLineSpacing = 0.0;

    for (final op in delta.toList()) {
      if (op.data is! String) continue;
      final text = op.data as String;
      final attrs = op.attributes ?? {};

      // Split by newlines — each \n terminates a paragraph
      final parts = text.split('\n');

      for (int i = 0; i < parts.length; i++) {
        final part = parts[i];

        if (part.isNotEmpty) {
          // Text content — create a run
          textBuffer.write(part);
          currentRuns.add(_attributesToRun(
            startOffset: currentOffset,
            length: part.length,
            attrs: attrs,
          ));
          currentOffset += part.length;
        }

        // If this isn't the last part, we hit a \n — close the paragraph
        if (i < parts.length - 1) {
          // Check for block-level attributes on the newline
          if (part.isEmpty && parts.length == 1) {
            // This is a newline-only op — the attrs are block-level
            currentAlignment = _attributesToAlignment(attrs);
            currentLineSpacing = _attributesToLineSpacing(attrs);
          } else if (part.isEmpty && i == parts.length - 2 && parts.last.isEmpty) {
            // Trailing newline with block attributes
            currentAlignment = _attributesToAlignment(attrs);
            currentLineSpacing = _attributesToLineSpacing(attrs);
          }

          paragraphs.add(UdfParagraph(
            runs: List.of(currentRuns),
            alignment: currentAlignment,
            lineSpacing: currentLineSpacing,
          ));
          currentRuns = [];
          currentAlignment = UdfAlignment.left;
          currentLineSpacing = 0.0;
        }
      }
    }

    // If there are leftover runs (no trailing newline), flush them
    if (currentRuns.isNotEmpty) {
      paragraphs.add(UdfParagraph(
        runs: List.of(currentRuns),
        alignment: currentAlignment,
        lineSpacing: currentLineSpacing,
      ));
    }

    final fullText = textBuffer.toString();

    return UdfDocument(
      formatId: template?.formatId ?? '1.7',
      text: fullText,
      pageFormat: template?.pageFormat ?? const UdfPageFormat(),
      sections: [
        UdfSection(type: UdfSectionType.body, paragraphs: paragraphs),
      ],
      styles: template?.styles ?? {},
      properties: template?.properties ?? {},
    );
  }

  // ---------------------------------------------------------------------------
  // UDF Run → Delta Attributes
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> _runToAttributes(UdfTextRun run) {
    final attrs = <String, dynamic>{};

    if (run.bold) attrs[Attribute.bold.key] = true;
    if (run.italic) attrs[Attribute.italic.key] = true;
    if (run.underline) attrs[Attribute.underline.key] = true;
    if (run.strikethrough) attrs[Attribute.strikeThrough.key] = true;

    // Font size — Quill uses named sizes, we store numeric
    if (run.fontSize != 12) {
      attrs['size'] = '${run.fontSize}px';
    }

    // Font family
    if (run.fontFamily != 'Times New Roman') {
      attrs['font'] = run.fontFamily;
    }

    // Colors
    if (run.foregroundColor != null) {
      attrs['color'] = _colorToHex(run.foregroundColor!);
    }
    if (run.backgroundColor != null) {
      attrs['background'] = _colorToHex(run.backgroundColor!);
    }

    return attrs;
  }

  // ---------------------------------------------------------------------------
  // Delta Attributes → UDF Run
  // ---------------------------------------------------------------------------

  static UdfTextRun _attributesToRun({
    required int startOffset,
    required int length,
    required Map<String, dynamic> attrs,
  }) {
    return UdfTextRun(
      startOffset: startOffset,
      length: length,
      bold: attrs[Attribute.bold.key] == true,
      italic: attrs[Attribute.italic.key] == true,
      underline: attrs[Attribute.underline.key] == true,
      strikethrough: attrs[Attribute.strikeThrough.key] == true,
      fontSize: _parseFontSize(attrs['size']),
      fontFamily: (attrs['font'] as String?) ?? 'Times New Roman',
      foregroundColor: _parseColor(attrs['color'] as String?),
      backgroundColor: _parseColor(attrs['background'] as String?),
    );
  }

  // ---------------------------------------------------------------------------
  // Paragraph-level attributes
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> _paragraphAttributes(UdfParagraph para) {
    final attrs = <String, dynamic>{};

    if (para.alignment != UdfAlignment.left) {
      attrs[Attribute.align.key] = switch (para.alignment) {
        UdfAlignment.center => 'center',
        UdfAlignment.right => 'right',
        UdfAlignment.justify => 'justify',
        UdfAlignment.left => 'left',
      };
    }

    // Line spacing is not natively in Quill — store as custom attribute
    // (Swing additive factor; 0 = single spacing = default, omitted).
    if (para.lineSpacing != 0.0) {
      attrs['line-height'] = para.lineSpacing;
    }

    return attrs;
  }

  static UdfAlignment _attributesToAlignment(Map<String, dynamic> attrs) {
    final align = attrs[Attribute.align.key];
    if (align == null) return UdfAlignment.left;
    return switch (align) {
      'center' => UdfAlignment.center,
      'right' => UdfAlignment.right,
      'justify' => UdfAlignment.justify,
      _ => UdfAlignment.left,
    };
  }

  static double _attributesToLineSpacing(Map<String, dynamic> attrs) {
    final spacing = attrs['line-height'];
    if (spacing == null) return 0.0;
    if (spacing is num) return spacing.toDouble();
    return double.tryParse(spacing.toString()) ?? 0.0;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static int _parseFontSize(dynamic size) {
    if (size == null) return 12;
    if (size is num) return size.toInt();
    final str = size.toString().replaceAll('px', '');
    return int.tryParse(str) ?? 12;
  }

  static Color? _parseColor(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    final clean = hex.replaceFirst('#', '');
    final intValue = int.tryParse(clean, radix: 16);
    if (intValue == null) return null;
    if (clean.length == 6) return Color(0xFF000000 | intValue);
    return Color(intValue);
  }

  static String _colorToHex(Color color) {
    // ignore: deprecated_member_use
    final value = color.value;
    return '#${(value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  }

  static String _safeSubstring(String text, int start, int end) {
    if (start < 0 || start >= text.length) return '';
    final safeEnd = end.clamp(start, text.length);
    return text.substring(start, safeEnd);
  }
}
