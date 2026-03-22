import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/paywall/paywall_service.dart';

import '../../app/theme.dart';
import '../../core/udf/udf_archive.dart';
import '../../core/udf/udf_document.dart';
import '../../core/udf/udf_parser.dart';
import '../../shared/widgets/ad_banner_widget.dart';

/// Reader screen — renders a parsed UDF document with formatting.
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.filePath});

  final String filePath;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  UdfDocument? _document;
  UdfArchive? _archive;
  String? _error;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadDocument();
  }

  Future<void> _loadDocument() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final bytes = await File(widget.filePath).readAsBytes();
      final archive = UdfArchive.fromBytes(bytes);
      final document = UdfParser.parse(archive.contentXml);

      setState(() {
        _archive = archive;
        _document = document;
      });
    } on UdfArchiveException catch (e) {
      setState(() => _error = e.message);
    } on UdfParseException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Dosya okunamadı: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  String get _fileName =>
      widget.filePath.split(Platform.pathSeparator).last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _fileName,
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          // Signature status badge
          if (_archive != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: _buildSignatureBadge(colorScheme),
            ),
          // Sign document (Pro feature)
          if (_archive != null && !(_archive!.isSigned))
            IconButton(
              icon: const Icon(Icons.draw_outlined),
              onPressed: () async {
                final allowed = await PaywallService.instance.requirePro();
                if (!allowed || !context.mounted) return;
                context.pushNamed(
                  'signing',
                  queryParameters: {'path': widget.filePath},
                );
              },
              tooltip: 'İmzala',
            ),
          // Edit document
          if (!_isLoading && _error == null)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              onPressed: () {
                context.pushNamed(
                  'editor',
                  queryParameters: {'path': widget.filePath},
                );
              },
              tooltip: 'Düzenle',
            ),
          // Share
          IconButton(
            icon: const Icon(Icons.share_outlined),
            onPressed: () => _shareFile(),
            tooltip: 'Paylaş',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildBody(theme, colorScheme)),
          const AdBannerWidget(),
        ],
      ),
    );
  }

  Widget _buildSignatureBadge(ColorScheme colorScheme) {
    final isSigned = _archive?.isSigned ?? false;

    return Tooltip(
      message: isSigned ? 'İmzalı belge' : 'İmzasız belge',
      child: Chip(
        avatar: Icon(
          isSigned ? Icons.verified : Icons.lock_open,
          size: 16,
          color: isSigned ? Colors.green.shade700 : colorScheme.outline,
        ),
        label: Text(
          isSigned ? 'İmzalı' : 'İmzasız',
          style: TextStyle(
            fontSize: 11,
            color: isSigned ? Colors.green.shade700 : colorScheme.outline,
          ),
        ),
        backgroundColor: isSigned
            ? Colors.green.shade50
            : colorScheme.surfaceContainerHighest,
        side: BorderSide.none,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Widget _buildBody(ThemeData theme, ColorScheme colorScheme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 64, color: colorScheme.error),
              const SizedBox(height: 16),
              Text(
                'Dosya açılamadı',
                style: theme.textTheme.titleLarge?.copyWith(
                  color: colorScheme.error,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _loadDocument,
                icon: const Icon(Icons.refresh),
                label: const Text('Tekrar Dene'),
              ),
            ],
          ),
        ),
      );
    }

    final doc = _document!;
    if (doc.allParagraphs.isEmpty && doc.text.isEmpty) {
      return const Center(child: Text('Boş belge.'));
    }

    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(
        horizontal: doc.pageFormat.leftMargin.toDouble() / 3,
        vertical: doc.pageFormat.topMargin.toDouble() / 2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _buildDocumentWidgets(doc),
      ),
    );
  }

  /// Render all paragraphs as RichText widgets.
  List<Widget> _buildDocumentWidgets(UdfDocument doc) {
    final widgets = <Widget>[];

    for (final section in doc.sections) {
      for (final para in section.paragraphs) {
        widgets.add(_buildParagraphWidget(doc, para, section.type));
      }
    }

    // Fallback: if no paragraphs were parsed, render raw text
    if (widgets.isEmpty && doc.text.isNotEmpty) {
      widgets.add(SelectableText(doc.text));
    }

    return widgets;
  }

  Widget _buildParagraphWidget(
    UdfDocument doc,
    UdfParagraph para,
    UdfSectionType sectionType,
  ) {
    final textAlign = _toTextAlign(para.alignment);
    final spans = <InlineSpan>[];

    for (final run in para.runs) {
      final text = _safeSubstring(doc.text, run.startOffset, run.endOffset);
      if (text.isEmpty) continue;

      spans.add(TextSpan(
        text: text,
        style: TextStyle(
          fontSize: AppTheme.udfFontSizeToLogical(run.fontSize),
          fontFamily: run.fontFamily,
          fontWeight: run.bold ? FontWeight.bold : FontWeight.normal,
          fontStyle: run.italic ? FontStyle.italic : FontStyle.normal,
          decoration: _textDecoration(run),
          color: run.foregroundColor,
          backgroundColor: run.backgroundColor,
        ),
      ));
    }

    // If no runs, show an empty line
    if (spans.isEmpty) {
      return SizedBox(
        height: AppTheme.udfFontSizeToLogical(12) * (para.lineSpacing > 0 ? para.lineSpacing : 1.0),
      );
    }

    return Padding(
      padding: EdgeInsets.only(
        left: para.leftIndent.toDouble(),
        right: para.rightIndent.toDouble(),
        top: para.spaceBefore.toDouble() / 2,
        bottom: para.spaceAfter.toDouble() / 2,
      ),
      child: SelectableText.rich(
        TextSpan(children: spans),
        textAlign: textAlign,
        style: TextStyle(
          height: para.lineSpacing > 0 ? para.lineSpacing : null,
        ),
      ),
    );
  }

  TextAlign _toTextAlign(UdfAlignment alignment) {
    return switch (alignment) {
      UdfAlignment.left => TextAlign.left,
      UdfAlignment.center => TextAlign.center,
      UdfAlignment.right => TextAlign.right,
      UdfAlignment.justify => TextAlign.justify,
    };
  }

  TextDecoration? _textDecoration(UdfTextRun run) {
    final decorations = <TextDecoration>[];
    if (run.underline) decorations.add(TextDecoration.underline);
    if (run.strikethrough) decorations.add(TextDecoration.lineThrough);
    if (decorations.isEmpty) return null;
    return TextDecoration.combine(decorations);
  }

  /// Safe substring extraction — prevents RangeError on malformed offsets.
  String _safeSubstring(String text, int start, int end) {
    if (start < 0 || start >= text.length) return '';
    final safeEnd = end.clamp(start, text.length);
    return text.substring(start, safeEnd);
  }

  Future<void> _shareFile() async {
    await SharePlus.instance.share(ShareParams(files: [XFile(widget.filePath)], title: _fileName));
  }
}
