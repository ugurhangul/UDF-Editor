import 'dart:ui';

import 'package:xml/xml.dart';

import 'udf_document.dart';

/// Serializes a [UdfDocument] back to content.xml format.
///
/// Used in Phase 2 (Editor) for saving edited documents.
/// Offsets are UTF-16 code-unit positions, matching UYAP's Java string
/// semantics — written as-is, no byte conversion.
class UdfSerializer {
  /// Serialize a [UdfDocument] to content.xml XML string.
  static String serialize(UdfDocument document) {
    final builder = XmlBuilder();

    builder.processing('xml', 'version="1.0" encoding="UTF-8"');

    builder.element('document', attributes: {
      'format_id': document.formatId,
    }, nest: () {
      // -- Properties --
      _serializePageFormat(builder, document.pageFormat);

      // -- Styles --
      _serializeStyles(builder, document.styles);

      // -- Content CData --
      builder.element('content', nest: () {
        builder.cdata(document.text);
      });

      // -- Sections --
      for (final section in document.sections) {
        final tagName = switch (section.type) {
          UdfSectionType.header => 'header',
          UdfSectionType.body => 'elements',
          UdfSectionType.footer => 'footer',
        };

        builder.element(tagName, nest: () {
          for (final para in section.paragraphs) {
            _serializeParagraph(builder, para);
          }
        });
      }
    });

    return builder.buildDocument().toXmlString(pretty: true);
  }

  static void _serializePageFormat(XmlBuilder builder, UdfPageFormat fmt) {
    builder.element('properties', attributes: {
      'leftMargin': fmt.leftMargin.toString(),
      'rightMargin': fmt.rightMargin.toString(),
      'topMargin': fmt.topMargin.toString(),
      'bottomMargin': fmt.bottomMargin.toString(),
      'headerOffset': fmt.headerOffset.toString(),
      'footerOffset': fmt.footerOffset.toString(),
      'orientation':
          fmt.orientation == UdfOrientation.landscape ? 'landscape' : 'portrait',
    });
  }

  static void _serializeStyles(
    XmlBuilder builder,
    Map<String, UdfStyle> styles,
  ) {
    if (styles.isEmpty) return;

    builder.element('styles', nest: () {
      for (final style in styles.values) {
        final attrs = <String, String>{
          'name': style.name,
          'family': style.fontFamily,
          'size': style.fontSize.toString(),
        };
        if (style.description != null) {
          attrs['description'] = style.description!;
        }
        if (style.bold) attrs['bold'] = 'true';
        if (style.italic) attrs['italic'] = 'true';
        if (style.alignment != UdfAlignment.left) {
          attrs['Alignment'] = _alignmentToString(style.alignment);
        }
        builder.element('style', attributes: attrs);
      }
    });
  }

  static void _serializeParagraph(
    XmlBuilder builder,
    UdfParagraph para,
  ) {
    final attrs = <String, String>{};

    if (para.alignment != UdfAlignment.left) {
      attrs['Alignment'] = _alignmentToString(para.alignment);
    }
    if (para.lineSpacing != 0.0) {
      attrs['LineSpacing'] = para.lineSpacing.toString();
    }
    if (para.hangingIndent != 0) {
      attrs['HangingIndent'] = para.hangingIndent.toString();
    }
    if (para.firstLineIndent != 0) {
      attrs['FirstLineIndent'] = para.firstLineIndent.toString();
    }
    if (para.leftIndent != 0) {
      attrs['LeftIndent'] = para.leftIndent.toString();
    }
    if (para.rightIndent != 0) {
      attrs['RightIndent'] = para.rightIndent.toString();
    }
    if (para.spaceBefore != 0) {
      attrs['SpaceBefore'] = para.spaceBefore.toString();
    }
    if (para.spaceAfter != 0) {
      attrs['SpaceAfter'] = para.spaceAfter.toString();
    }
    if (para.styleName != null) {
      attrs['style'] = para.styleName!;
    }

    builder.element('paragraph', attributes: attrs, nest: () {
      for (final run in para.runs) {
        _serializeTextRun(builder, run);
      }
    });
  }

  static void _serializeTextRun(
    XmlBuilder builder,
    UdfTextRun run,
  ) {
    final attrs = <String, String>{
      'startOffset': run.startOffset.toString(),
      'length': run.length.toString(),
      'size': run.fontSize.toString(),
      'family': run.fontFamily,
    };

    if (run.bold) attrs['bold'] = 'true';
    if (run.italic) attrs['italic'] = 'true';
    if (run.underline) attrs['underline'] = 'true';
    if (run.strikethrough) attrs['strikethrough'] = 'true';
    if (run.superscript) attrs['superscript'] = 'true';
    if (run.subscript) attrs['subscript'] = 'true';
    if (run.foregroundColor != null) {
      attrs['foreground'] = _colorToHex(run.foregroundColor!);
    }
    if (run.backgroundColor != null) {
      attrs['background'] = _colorToHex(run.backgroundColor!);
    }
    if (run.styleName != null) {
      attrs['style'] = run.styleName!;
    }

    builder.element('content', attributes: attrs);
  }

  static String _alignmentToString(UdfAlignment alignment) {
    return switch (alignment) {
      UdfAlignment.left => '0',
      UdfAlignment.center => '1',
      UdfAlignment.right => '2',
      UdfAlignment.justify => '3',
    };
  }

  static String _colorToHex(Color color) {
    // ignore: deprecated_member_use
    final value = color.value;
    return '#${(value & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }
}
