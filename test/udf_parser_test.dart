import 'package:flutter_test/flutter_test.dart';

import 'package:udf_editor/core/udf/udf_document.dart';
import 'package:udf_editor/core/udf/udf_parser.dart';
import 'package:udf_editor/core/udf/udf_serializer.dart';

/// Sample content.xml based on reverse-engineered format_id="1.7"
const _sampleXml = '''<?xml version="1.0" encoding="UTF-8"?>
<document format_id="1.7">
  <properties leftMargin="70" rightMargin="70" topMargin="20" bottomMargin="20" headerOffset="35" footerOffset="35" orientation="portrait"/>
  <content><![CDATA[    YETKİ BELGESİBu belge ile aşağıda adı geçen avukata yetki verilmiştir.]]></content>
  <styles>
    <style name="Başlık" description="Başlık stili" family="Times New Roman" size="16" bold="true" Alignment="1"/>
    <style name="Normal" description="Normal metin" family="Times New Roman" size="12"/>
  </styles>
  <elements>
    <paragraph Alignment="1" LineSpacing="1.5">
      <content startOffset="4" length="13" bold="true" size="16" family="Times New Roman"/>
    </paragraph>
    <paragraph Alignment="0" LineSpacing="1.0">
      <content startOffset="17" length="57" bold="false" size="12" family="Times New Roman"/>
    </paragraph>
  </elements>
</document>''';

void main() {
  group('UdfParser', () {
    late UdfDocument doc;

    setUp(() {
      doc = UdfParser.parse(_sampleXml);
    });

    test('parses format_id correctly', () {
      expect(doc.formatId, '1.7');
    });

    test('extracts CData text content', () {
      expect(doc.text, contains('YETKİ BELGESİ'));
      expect(doc.text, contains('avukata yetki verilmiştir'));
    });

    test('parses page format properties', () {
      expect(doc.pageFormat.leftMargin, 70);
      expect(doc.pageFormat.rightMargin, 70);
      expect(doc.pageFormat.topMargin, 20);
      expect(doc.pageFormat.bottomMargin, 20);
      expect(doc.pageFormat.headerOffset, 35);
      expect(doc.pageFormat.footerOffset, 35);
      expect(doc.pageFormat.orientation, UdfOrientation.portrait);
    });

    test('parses named styles', () {
      expect(doc.styles, hasLength(2));
      expect(doc.styles['Başlık'], isNotNull);
      expect(doc.styles['Başlık']!.bold, isTrue);
      expect(doc.styles['Başlık']!.fontSize, 16);
      expect(doc.styles['Başlık']!.alignment, UdfAlignment.center);
      expect(doc.styles['Normal']!.fontSize, 12);
    });

    test('parses body section with paragraphs', () {
      expect(doc.sections, isNotEmpty);
      final body = doc.sections.firstWhere(
        (s) => s.type == UdfSectionType.body,
      );
      expect(body.paragraphs, hasLength(2));
    });

    test('parses first bold paragraph run', () {
      final body = doc.sections.firstWhere(
        (s) => s.type == UdfSectionType.body,
      );
      final firstPara = body.paragraphs[0];
      expect(firstPara.alignment, UdfAlignment.center);
      expect(firstPara.lineSpacing, 1.5);

      final run = firstPara.runs[0];
      expect(run.startOffset, 4);
      expect(run.length, 13);
      expect(run.bold, isTrue);
      expect(run.fontSize, 16);
    });

    test('parses second normal paragraph run', () {
      final body = doc.sections.firstWhere(
        (s) => s.type == UdfSectionType.body,
      );
      final secondPara = body.paragraphs[1];
      expect(secondPara.alignment, UdfAlignment.left);

      final run = secondPara.runs[0];
      expect(run.startOffset, 17);
      expect(run.length, 57);
      expect(run.bold, isFalse);
      expect(run.fontSize, 12);
    });

    test('extracts plain text from paragraph runs', () {
      final body = doc.sections.firstWhere(
        (s) => s.type == UdfSectionType.body,
      );
      final firstPara = body.paragraphs[0];
      final text = firstPara.plainText(doc.text);
      expect(text, 'YETKİ BELGESİ');
    });

    test('handles Turkish characters correctly', () {
      final body = doc.sections.firstWhere(
        (s) => s.type == UdfSectionType.body,
      );
      final text = body.paragraphs[0].plainText(doc.text);
      // Verify İ, Ş, Ğ, Ü, Ö, Ç handling
      expect(text, contains('İ'));
    });

    test('handles missing optional elements gracefully', () {
      const minimal = '''<?xml version="1.0" encoding="UTF-8"?>
<document format_id="1.7">
  <content><![CDATA[Minimal test content.]]></content>
  <elements>
    <paragraph>
      <content startOffset="0" length="21" size="12" family="Times New Roman"/>
    </paragraph>
  </elements>
</document>''';

      final minDoc = UdfParser.parse(minimal);
      expect(minDoc.formatId, '1.7');
      expect(minDoc.text, 'Minimal test content.');
      expect(minDoc.styles, isEmpty);
      expect(minDoc.pageFormat.leftMargin, 70); // defaults
      expect(minDoc.allParagraphs, hasLength(1));
    });

    test('throws UdfParseException on invalid XML', () {
      expect(
        () => UdfParser.parse('<not valid xml'),
        throwsA(isA<UdfParseException>()),
      );
    });
  });

  group('UdfSerializer', () {
    test('roundtrip: parse → serialize → parse preserves structure', () {
      final original = UdfParser.parse(_sampleXml);
      final serialized = UdfSerializer.serialize(original);
      final reparsed = UdfParser.parse(serialized);

      expect(reparsed.formatId, original.formatId);
      expect(reparsed.text, original.text);
      expect(reparsed.styles.length, original.styles.length);
      expect(reparsed.allParagraphs.length, original.allParagraphs.length);

      // Verify first run's offset data
      final origRun = original.allParagraphs[0].runs[0];
      final reparsedRun = reparsed.allParagraphs[0].runs[0];
      expect(reparsedRun.startOffset, origRun.startOffset);
      expect(reparsedRun.length, origRun.length);
      expect(reparsedRun.bold, origRun.bold);
      expect(reparsedRun.fontSize, origRun.fontSize);
    });

    test('serialized XML contains CData block', () {
      final doc = UdfParser.parse(_sampleXml);
      final xml = UdfSerializer.serialize(doc);
      expect(xml, contains('<![CDATA['));
      expect(xml, contains('YETKİ BELGESİ'));
    });
  });
}
