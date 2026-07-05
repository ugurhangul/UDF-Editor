/// Domain model for the UYAP Document Format (.udf)
///
/// Based on reverse-engineered content.xml schema (format_id="1.7").
/// The UDF format uses an offset-based paragraph model:
/// - A single CData block holds all text
/// - XML elements reference character ranges (startOffset, length) for formatting
library;

import 'dart:ui';

// ---------------------------------------------------------------------------
// Root document
// ---------------------------------------------------------------------------

/// Complete representation of a parsed .udf file.
class UdfDocument {
  UdfDocument({
    required this.formatId,
    required this.text,
    required this.pageFormat,
    required this.sections,
    required this.styles,
    this.properties = const {},
  });

  /// Format version string, e.g. "1.7".
  final String formatId;

  /// The entire CData text content.
  final String text;

  /// Page-level formatting (margins, orientation).
  final UdfPageFormat pageFormat;

  /// Ordered list of document sections (header, body, footer).
  final List<UdfSection> sections;

  /// Named style definitions.
  final Map<String, UdfStyle> styles;

  /// Optional document properties from documentproperties.xml.
  final Map<String, String> properties;

  /// Convenience: all paragraphs across all sections, in order.
  List<UdfParagraph> get allParagraphs =>
      sections.expand((s) => s.paragraphs).toList();

  UdfDocument copyWith({
    String? formatId,
    String? text,
    UdfPageFormat? pageFormat,
    List<UdfSection>? sections,
    Map<String, UdfStyle>? styles,
    Map<String, String>? properties,
  }) {
    return UdfDocument(
      formatId: formatId ?? this.formatId,
      text: text ?? this.text,
      pageFormat: pageFormat ?? this.pageFormat,
      sections: sections ?? this.sections,
      styles: styles ?? this.styles,
      properties: properties ?? this.properties,
    );
  }
}

// ---------------------------------------------------------------------------
// Page format
// ---------------------------------------------------------------------------

class UdfPageFormat {
  const UdfPageFormat({
    this.leftMargin = 70,
    this.rightMargin = 70,
    this.topMargin = 20,
    this.bottomMargin = 20,
    this.headerOffset = 35,
    this.footerOffset = 35,
    this.orientation = UdfOrientation.portrait,
  });

  final int leftMargin;
  final int rightMargin;
  final int topMargin;
  final int bottomMargin;
  final int headerOffset;
  final int footerOffset;
  final UdfOrientation orientation;
}

enum UdfOrientation { portrait, landscape }

// ---------------------------------------------------------------------------
// Section
// ---------------------------------------------------------------------------

enum UdfSectionType { header, body, footer }

class UdfSection {
  const UdfSection({
    required this.type,
    required this.paragraphs,
  });

  final UdfSectionType type;
  final List<UdfParagraph> paragraphs;
}

// ---------------------------------------------------------------------------
// Paragraph
// ---------------------------------------------------------------------------

enum UdfAlignment { left, center, right, justify }

class UdfParagraph {
  const UdfParagraph({
    required this.runs,
    this.alignment = UdfAlignment.left,
    // Java Swing additive line-spacing factor: 0 = single, 0.5 = 1.5-line,
    // 1.0 = double. NOT a total line-height multiplier.
    this.lineSpacing = 0.0,
    this.hangingIndent = 0,
    this.firstLineIndent = 0,
    this.leftIndent = 0,
    this.rightIndent = 0,
    this.spaceBefore = 0,
    this.spaceAfter = 0,
    this.styleName,
  });

  /// Inline text runs within this paragraph.
  final List<UdfTextRun> runs;

  final UdfAlignment alignment;
  final double lineSpacing;
  final int hangingIndent;
  final int firstLineIndent;
  final int leftIndent;
  final int rightIndent;
  final int spaceBefore;
  final int spaceAfter;

  /// Reference to a named style from [UdfDocument.styles].
  final String? styleName;

  /// Reconstruct the plain text of this paragraph from its runs.
  String plainText(String sourceText) {
    final buffer = StringBuffer();
    for (final run in runs) {
      buffer.write(
        sourceText.substring(
          run.startOffset,
          run.startOffset + run.length,
        ),
      );
    }
    return buffer.toString();
  }
}

// ---------------------------------------------------------------------------
// Text Run
// ---------------------------------------------------------------------------

class UdfTextRun {
  const UdfTextRun({
    required this.startOffset,
    required this.length,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
    this.superscript = false,
    this.subscript = false,
    this.fontSize = 12,
    this.fontFamily = 'Times New Roman',
    this.foregroundColor,
    this.backgroundColor,
    this.styleName,
  });

  /// Character offset into the CData text.
  final int startOffset;

  /// Number of characters this run spans.
  final int length;

  // -- Character formatting --
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strikethrough;
  final bool superscript;
  final bool subscript;
  final int fontSize;
  final String fontFamily;
  final Color? foregroundColor;
  final Color? backgroundColor;

  /// Reference to a named style.
  final String? styleName;

  /// End offset (exclusive).
  int get endOffset => startOffset + length;
}

// ---------------------------------------------------------------------------
// Named Style
// ---------------------------------------------------------------------------

class UdfStyle {
  const UdfStyle({
    required this.name,
    this.description,
    this.fontFamily = 'Times New Roman',
    this.fontSize = 12,
    this.bold = false,
    this.italic = false,
    this.alignment = UdfAlignment.left,
  });

  final String name;
  final String? description;
  final String fontFamily;
  final int fontSize;
  final bool bold;
  final bool italic;
  final UdfAlignment alignment;
}
