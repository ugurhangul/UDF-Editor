import 'dart:convert';
import 'dart:ui';

import 'package:xml/xml.dart';

import 'udf_document.dart';

/// Parses `content.xml` from a .udf archive into a [UdfDocument].
///
/// The UDF XML schema (format_id="1.7") uses an offset-based model:
/// - A single `<content>` CData block holds all text
/// - `<paragraph>` elements define paragraph-level formatting
/// - `<content>` child elements reference character ranges for inline styles
/// - `<styles>` define reusable named styles
class UdfParser {
  /// Parse a complete content.xml string into [UdfDocument].
  ///
  /// Throws [UdfParseException] on malformed XML or missing required elements.
  static UdfDocument parse(String xmlString) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xmlString);
    } on XmlException catch (e) {
      throw UdfParseException('Failed to parse content.xml: $e');
    }

    final root = doc.rootElement;
    final formatId = root.getAttribute('format_id') ?? 'unknown';

    // -- Extract CData text from <content> --
    final text = _extractCDataText(root);

    // -- Build byte→char offset map for UTF-8 byte offset conversion --
    final byteToChar = _buildByteToCharMap(text);

    // -- Parse <properties> --
    final pageFormat = _parsePageFormat(root);

    // -- Parse <styles> --
    final styles = _parseStyles(root);

    // -- Parse sections: <header>, <elements> (body), <footer> --
    final sections = <UdfSection>[];

    final headerEl = root.getElement('header');
    if (headerEl != null) {
      sections.add(UdfSection(
        type: UdfSectionType.header,
        paragraphs: _parseParagraphs(headerEl, byteToChar, text.length),
      ));
    }

    final elementsEl = root.getElement('elements');
    if (elementsEl != null) {
      sections.add(UdfSection(
        type: UdfSectionType.body,
        paragraphs: _parseParagraphs(elementsEl, byteToChar, text.length),
      ));
    }

    final footerEl = root.getElement('footer');
    if (footerEl != null) {
      sections.add(UdfSection(
        type: UdfSectionType.footer,
        paragraphs: _parseParagraphs(footerEl, byteToChar, text.length),
      ));
    }

    // If no <elements>, try to parse paragraphs from root directly
    if (sections.isEmpty ||
        sections.every((s) => s.type != UdfSectionType.body)) {
      final rootParagraphs = _parseParagraphs(root, byteToChar, text.length);
      if (rootParagraphs.isNotEmpty) {
        sections.add(UdfSection(
          type: UdfSectionType.body,
          paragraphs: rootParagraphs,
        ));
      }
    }

    return UdfDocument(
      formatId: formatId,
      text: text,
      pageFormat: pageFormat,
      sections: sections,
      styles: styles,
    );
  }

  // ---------------------------------------------------------------------------
  // CData extraction
  // ---------------------------------------------------------------------------

  static String _extractCDataText(XmlElement root) {
    // The text is in the first <content> element's CData child.
    // Walk all <content> elements and find one with CData.
    for (final el in root.descendants.whereType<XmlElement>()) {
      if (el.name.local == 'content') {
        for (final child in el.children) {
          if (child is XmlCDATA) {
            return child.value;
          }
        }
        // Also check for direct text content (fallback)
        final textContent = el.innerText;
        if (textContent.isNotEmpty) {
          return textContent;
        }
      }
    }

    // Fallback: try CData anywhere in document
    for (final node in root.descendants) {
      if (node is XmlCDATA && node.value.isNotEmpty) {
        return node.value;
      }
    }

    return '';
  }

  // ---------------------------------------------------------------------------
  // Page format
  // ---------------------------------------------------------------------------

  static UdfPageFormat _parsePageFormat(XmlElement root) {
    final propsEl = root.getElement('properties');
    if (propsEl == null) return const UdfPageFormat();

    return UdfPageFormat(
      leftMargin: _intAttr(propsEl, 'leftMargin', 70),
      rightMargin: _intAttr(propsEl, 'rightMargin', 70),
      topMargin: _intAttr(propsEl, 'topMargin', 20),
      bottomMargin: _intAttr(propsEl, 'bottomMargin', 20),
      headerOffset: _intAttr(propsEl, 'headerOffset', 35),
      footerOffset: _intAttr(propsEl, 'footerOffset', 35),
      orientation: propsEl.getAttribute('orientation') == 'landscape'
          ? UdfOrientation.landscape
          : UdfOrientation.portrait,
    );
  }

  // ---------------------------------------------------------------------------
  // Styles
  // ---------------------------------------------------------------------------

  static Map<String, UdfStyle> _parseStyles(XmlElement root) {
    final stylesEl = root.getElement('styles');
    if (stylesEl == null) return {};

    final result = <String, UdfStyle>{};

    for (final styleEl in stylesEl.findElements('style')) {
      final name = styleEl.getAttribute('name');
      if (name == null) continue;

      result[name] = UdfStyle(
        name: name,
        description: styleEl.getAttribute('description'),
        fontFamily: styleEl.getAttribute('family') ?? 'Times New Roman',
        fontSize: _intAttr(styleEl, 'size', 12),
        bold: _boolAttr(styleEl, 'bold'),
        italic: _boolAttr(styleEl, 'italic'),
        alignment: _parseAlignment(styleEl.getAttribute('Alignment')),
      );
    }

    return result;
  }

  // ---------------------------------------------------------------------------
  // Paragraphs
  // ---------------------------------------------------------------------------

  static List<UdfParagraph> _parseParagraphs(
    XmlElement parent,
    Map<int, int> byteToChar,
    int textLength,
  ) {
    final paragraphs = <UdfParagraph>[];

    for (final pEl in parent.findElements('paragraph')) {
      final runs = _parseTextRuns(pEl, byteToChar, textLength);

      paragraphs.add(UdfParagraph(
        runs: runs,
        alignment: _parseAlignment(pEl.getAttribute('Alignment')),
        lineSpacing: _doubleAttr(pEl, 'LineSpacing', 1.0),
        hangingIndent: _intAttr(pEl, 'HangingIndent', 0),
        firstLineIndent: _intAttr(pEl, 'FirstLineIndent', 0),
        leftIndent: _intAttr(pEl, 'LeftIndent', 0),
        rightIndent: _intAttr(pEl, 'RightIndent', 0),
        spaceBefore: _intAttr(pEl, 'SpaceBefore', 0),
        spaceAfter: _intAttr(pEl, 'SpaceAfter', 0),
        styleName: pEl.getAttribute('style'),
      ));
    }

    return paragraphs;
  }

  // ---------------------------------------------------------------------------
  // Text runs
  // ---------------------------------------------------------------------------

  static List<UdfTextRun> _parseTextRuns(
    XmlElement paragraph,
    Map<int, int> byteToChar,
    int textLength,
  ) {
    final runs = <UdfTextRun>[];

    for (final cEl in paragraph.findElements('content')) {
      final byteStart = _intAttr(cEl, 'startOffset', -1);
      final byteLength = _intAttr(cEl, 'length', -1);

      if (byteStart < 0 || byteLength < 0) continue;

      // Convert byte offsets to character offsets
      final charStart = _byteOffsetToChar(byteToChar, byteStart, textLength);
      final charEnd = _byteOffsetToChar(byteToChar, byteStart + byteLength, textLength);
      final charLength = charEnd - charStart;

      if (charLength <= 0) continue;

      runs.add(UdfTextRun(
        startOffset: charStart,
        length: charLength,
        bold: _boolAttr(cEl, 'bold'),
        italic: _boolAttr(cEl, 'italic'),
        underline: _boolAttr(cEl, 'underline'),
        strikethrough: _boolAttr(cEl, 'strikethrough'),
        superscript: _boolAttr(cEl, 'superscript'),
        subscript: _boolAttr(cEl, 'subscript'),
        fontSize: _intAttr(cEl, 'size', 12),
        fontFamily: cEl.getAttribute('family') ?? 'Times New Roman',
        foregroundColor: _parseColor(cEl.getAttribute('foreground')),
        backgroundColor: _parseColor(cEl.getAttribute('background')),
        styleName: cEl.getAttribute('style'),
      ));
    }

    return runs;
  }

  // ---------------------------------------------------------------------------
  // Byte↔Char offset conversion
  // ---------------------------------------------------------------------------

  /// Build a map from UTF-8 byte offset → Dart string character offset.
  ///
  /// UDF XML stores startOffset/length as UTF-8 byte positions.
  /// Dart strings use UTF-16 code units (characters). For text with
  /// multi-byte characters (İ, Ş, Ö, Ü, ğ, ç) the offsets diverge.
  static Map<int, int> _buildByteToCharMap(String text) {
    final bytes = utf8.encode(text);
    final map = <int, int>{};
    var byteIndex = 0;
    var charIndex = 0;

    // Map byte position 0
    map[0] = 0;

    while (charIndex < text.length && byteIndex < bytes.length) {
      final codeUnit = text.codeUnitAt(charIndex);
      int byteCount;

      if (codeUnit <= 0x7F) {
        byteCount = 1;
      } else if (codeUnit <= 0x7FF) {
        byteCount = 2;
      } else if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF) {
        // Surrogate pair (4-byte UTF-8)
        byteCount = 4;
        charIndex++; // skip low surrogate
      } else {
        byteCount = 3;
      }

      byteIndex += byteCount;
      charIndex++;
      map[byteIndex] = charIndex;
    }

    return map;
  }

  /// Convert a UTF-8 byte offset to a character offset using the prebuilt map.
  /// Falls back to nearest lower mapped byte offset if exact match not found.
  static int _byteOffsetToChar(
    Map<int, int> byteToChar,
    int byteOffset,
    int textLength,
  ) {
    if (byteOffset <= 0) return 0;

    // Exact match
    final exact = byteToChar[byteOffset];
    if (exact != null) return exact.clamp(0, textLength);

    // Find nearest lower byte offset (handles edge cases)
    var nearest = 0;
    for (final key in byteToChar.keys) {
      if (key <= byteOffset && key > nearest) {
        nearest = key;
      }
    }
    return (byteToChar[nearest] ?? 0).clamp(0, textLength);
  }

  // ---------------------------------------------------------------------------
  // Attribute helpers
  // ---------------------------------------------------------------------------

  static int _intAttr(XmlElement el, String name, int defaultValue) {
    final value = el.getAttribute(name);
    if (value == null) return defaultValue;
    return int.tryParse(value) ?? defaultValue;
  }

  static double _doubleAttr(XmlElement el, String name, double defaultValue) {
    final value = el.getAttribute(name);
    if (value == null) return defaultValue;
    return double.tryParse(value) ?? defaultValue;
  }

  static bool _boolAttr(XmlElement el, String name) {
    final value = el.getAttribute(name);
    if (value == null) return false;
    return value.toLowerCase() == 'true' || value == '1';
  }

  static UdfAlignment _parseAlignment(String? value) {
    if (value == null) return UdfAlignment.left;
    return switch (value.toLowerCase()) {
      'center' || '1' => UdfAlignment.center,
      'right' || '2' => UdfAlignment.right,
      'justify' || '3' => UdfAlignment.justify,
      _ => UdfAlignment.left,
    };
  }

  /// Parse a color string. Supports:
  /// - Hex format: "#RRGGBB" or "#AARRGGBB"
  /// - Decimal integer (Java Color int)
  static Color? _parseColor(String? value) {
    if (value == null || value.isEmpty) return null;

    if (value.startsWith('#')) {
      final hex = value.substring(1);
      final intValue = int.tryParse(hex, radix: 16);
      if (intValue == null) return null;
      if (hex.length == 6) {
        return Color(0xFF000000 | intValue);
      }
      return Color(intValue);
    }

    // Try parsing as integer (Java-style Color int)
    final intValue = int.tryParse(value);
    if (intValue != null) {
      return Color(0xFF000000 | (intValue & 0xFFFFFF));
    }

    return null;
  }
}

/// Exception thrown during UDF content parsing.
class UdfParseException implements Exception {
  UdfParseException(this.message);
  final String message;

  @override
  String toString() => 'UdfParseException: $message';
}
