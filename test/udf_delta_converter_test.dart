import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:udf_editor/core/udf/udf_delta_converter.dart';
import 'package:udf_editor/core/udf/udf_document.dart';
import 'package:udf_editor/core/udf/udf_parser.dart';
import 'package:udf_editor/core/udf/udf_serializer.dart';

void main() {
  const sampleXml = '''<?xml version="1.0" encoding="UTF-8"?>
<document format_id="1.7">
  <properties leftMargin="1134" rightMargin="1134" topMargin="1134" bottomMargin="1134" headerOffset="35" footerOffset="35" orientation="portrait"/>
  <content><![CDATA[YETKİ BELGESİBu belge, ilgili merciler tarafından düzenlenmiştir.]]></content>
  <styles>
    <style name="Normal" family="Times New Roman" size="12" bold="false" italic="false"/>
  </styles>
  <elements>
    <paragraph Alignment="1" LineSpacing="1.5">
      <content startOffset="0" length="13" bold="true" italic="false" size="16" family="Times New Roman"/>
    </paragraph>
    <paragraph Alignment="0" LineSpacing="1.0">
      <content startOffset="13" length="53" bold="false" italic="false" size="12" family="Times New Roman"/>
    </paragraph>
  </elements>
</document>''';

  late UdfDocument originalDoc;

  setUp(() {
    originalDoc = UdfParser.parse(sampleXml);
  });

  group('UdfDeltaConverter', () {
    test('toQuillDocument creates valid Document', () {
      final quillDoc = UdfDeltaConverter.toQuillDocument(originalDoc);
      expect(quillDoc, isA<Document>());
      expect(quillDoc.length, greaterThan(0));
    });

    test('toQuillDocument preserves text content', () {
      final quillDoc = UdfDeltaConverter.toQuillDocument(originalDoc);
      final plainText = quillDoc.toPlainText();
      expect(plainText, contains('YETKİ BELGESİ'));
      expect(plainText, contains('Bu belge'));
    });

    test('toQuillDocument preserves bold formatting', () {
      final quillDoc = UdfDeltaConverter.toQuillDocument(originalDoc);
      final delta = quillDoc.toDelta();
      final ops = delta.toList();

      // First op should be the bold title text
      final firstOp = ops.first;
      expect(firstOp.data, contains('YETKİ BELGESİ'));
      expect(firstOp.attributes?['bold'], isTrue);
    });

    test('toQuillDocument preserves alignment', () {
      final quillDoc = UdfDeltaConverter.toQuillDocument(originalDoc);
      final delta = quillDoc.toDelta();
      final ops = delta.toList();

      // Find the newline after title — should have center alignment
      final titleNewline = ops.firstWhere(
        (op) => op.data == '\n' && op.attributes?['align'] == 'center',
        orElse: () => throw StateError('No centered newline found'),
      );
      expect(titleNewline.attributes?['align'], equals('center'));
    });

    test('toQuillDocument preserves font size', () {
      final quillDoc = UdfDeltaConverter.toQuillDocument(originalDoc);
      final delta = quillDoc.toDelta();
      final ops = delta.toList();

      // First op should have size 16px
      final firstOp = ops.first;
      expect(firstOp.attributes?['size'], equals('16px'));
    });

    test('fromQuillDocument creates valid UdfDocument', () {
      final quillDoc = UdfDeltaConverter.toQuillDocument(originalDoc);
      final restoredDoc = UdfDeltaConverter.fromQuillDocument(
        quillDoc,
        template: originalDoc,
      );

      expect(restoredDoc.formatId, equals('1.7'));
      expect(restoredDoc.sections, isNotEmpty);
      expect(restoredDoc.text, isNotEmpty);
    });

    test('fromQuillDocument preserves format settings from template', () {
      final quillDoc = UdfDeltaConverter.toQuillDocument(originalDoc);
      final restoredDoc = UdfDeltaConverter.fromQuillDocument(
        quillDoc,
        template: originalDoc,
      );

      expect(restoredDoc.pageFormat.leftMargin, equals(1134));
      expect(restoredDoc.pageFormat.topMargin, equals(1134));
    });

    test('roundtrip preserves text content', () {
      // UDF → Delta → UDF → serialized XML
      final quillDoc = UdfDeltaConverter.toQuillDocument(originalDoc);
      final restoredDoc = UdfDeltaConverter.fromQuillDocument(
        quillDoc,
        template: originalDoc,
      );

      expect(restoredDoc.text, contains('YETKİ BELGESİ'));
      expect(restoredDoc.text, contains('Bu belge'));
    });

    test('roundtrip produces valid serializable UDF', () {
      final quillDoc = UdfDeltaConverter.toQuillDocument(originalDoc);
      final restoredDoc = UdfDeltaConverter.fromQuillDocument(
        quillDoc,
        template: originalDoc,
      );

      // Should serialize without throwing
      final xml = UdfSerializer.serialize(restoredDoc);
      expect(xml, contains('format_id="1.7"'));
      expect(xml, contains('CDATA'));
    });

    test('handles empty document', () {
      final emptyDoc = UdfDocument(
        formatId: '1.7',
        text: '',
        pageFormat: const UdfPageFormat(),
        sections: [
          UdfSection(
            type: UdfSectionType.body,
            paragraphs: [],
          ),
        ],
        styles: {},
      );

      final quillDoc = UdfDeltaConverter.toQuillDocument(emptyDoc);
      expect(quillDoc.length, greaterThan(0)); // At minimum a newline

      final restored = UdfDeltaConverter.fromQuillDocument(
        quillDoc,
        template: emptyDoc,
      );
      expect(restored.formatId, equals('1.7'));
    });

    test('handles Turkish characters in roundtrip', () {
      final quillDoc = UdfDeltaConverter.toQuillDocument(originalDoc);
      final restoredDoc = UdfDeltaConverter.fromQuillDocument(
        quillDoc,
        template: originalDoc,
      );

      // Turkish characters must survive the roundtrip
      expect(restoredDoc.text, contains('İ'));
      expect(restoredDoc.text, contains('ü'));
      expect(restoredDoc.text, contains('ş'));
    });

    test('fromQuillDocument without template uses defaults', () {
      final quillDoc = UdfDeltaConverter.toQuillDocument(originalDoc);
      final restoredDoc = UdfDeltaConverter.fromQuillDocument(quillDoc);

      expect(restoredDoc.formatId, equals('1.7'));
      expect(restoredDoc.pageFormat, isNotNull);
      expect(restoredDoc.sections, isNotEmpty);
    });
  });
}
