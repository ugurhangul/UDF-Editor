import 'dart:io';

import 'package:flutter/material.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/theme.dart';
import '../../core/paywall/paywall_service.dart';
import '../../core/udf/udf_archive.dart';
import '../../core/udf/udf_document.dart';
import '../../core/udf/udf_parser.dart';
import '../../core/udf/udf_serializer.dart';

/// Editor screen — plain text UDF editor.
///
/// Loads a .udf file, extracts text for editing, and saves back.
/// Uses a standard TextField instead of flutter_quill to avoid
/// upstream rendering bugs (RenderViewport, InheritedElement, ScrollPosition).
class EditorScreen extends StatefulWidget {
  const EditorScreen({
    super.key,
    this.filePath,
    this.isNewDocument = false,
  });

  /// Path to existing .udf file. Null if creating a new document.
  final String? filePath;

  /// Whether this is a new blank document.
  final bool isNewDocument;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late TextEditingController _textController;
  UdfDocument? _originalDoc;
  UdfArchive? _originalArchive;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _hasChanges = false;
  String? _error;
  String? _savePath;

  // Toolbar state
  bool _isBold = false;
  bool _isItalic = false;
  bool _isUnderline = false;
  TextAlign _textAlign = TextAlign.left;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController();
    _textController.addListener(_onTextChanged);
    _initEditor();
  }

  Future<void> _initEditor() async {
    // Paywall check
    if (PaywallService.instance.isFree) {
      setState(() {
        _error = 'Bu özellik Pro abonelik gerektirir.';
        _isLoading = false;
      });
      return;
    }

    if (widget.isNewDocument) {
      setState(() => _isLoading = false);
    } else {
      await _loadExistingDocument();
    }
  }

  Future<void> _loadExistingDocument() async {
    try {
      final bytes = await File(widget.filePath!).readAsBytes();
      final archive = UdfArchive.fromBytes(bytes);
      final udfDoc = UdfParser.parse(archive.contentXml);

      _originalDoc = udfDoc;
      _originalArchive = archive;
      _savePath = widget.filePath;

      // Extract text with newlines at paragraph boundaries.
      // UDF stores text as a flat CData string — paragraphs define ranges.
      // We need to insert \n between paragraphs so _rebuildDocument can
      // split them back correctly on save.
      _textController.text = _extractTextWithNewlines(udfDoc);

      setState(() => _isLoading = false);
    } on UdfArchiveException catch (e) {
      setState(() {
        _error = e.message;
        _isLoading = false;
      });
    } on UdfParseException catch (e) {
      setState(() {
        _error = e.message;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Dosya yüklenemedi: $e';
        _isLoading = false;
      });
    }
  }

  void _onTextChanged() {
    if (!_hasChanges) {
      setState(() => _hasChanges = true);
    }
  }

  /// Extract text from a UDF document, inserting \n at paragraph boundaries.
  ///
  /// UDF stores all text in a single flat CData block with no newlines.
  /// Paragraphs reference character ranges via startOffset/length.
  /// This method reconstructs readable text with line breaks.
  String _extractTextWithNewlines(UdfDocument doc) {
    final buffer = StringBuffer();
    final paragraphs = doc.allParagraphs;

    for (var i = 0; i < paragraphs.length; i++) {
      final para = paragraphs[i];

      if (para.runs.isEmpty) {
        // Empty paragraph → blank line
      } else {
        // Concatenate all runs in this paragraph
        for (final run in para.runs) {
          final start = run.startOffset;
          final end = (start + run.length).clamp(0, doc.text.length);
          if (start >= 0 && start < doc.text.length) {
            buffer.write(doc.text.substring(start, end));
          }
        }
      }

      // Add newline between paragraphs (not after the last one)
      if (i < paragraphs.length - 1) {
        buffer.write('\n');
      }
    }

    // Fallback: if no paragraphs, return the raw text
    if (paragraphs.isEmpty) return doc.text;

    return buffer.toString();
  }

  Future<void> _save() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    try {
      final editedText = _textController.text;

      // Rebuild UDF document with edited text
      final udfDoc = _rebuildDocument(editedText);

      // Serialize to content.xml
      final contentXml = UdfSerializer.serialize(udfDoc);

      // Pack into .udf ZIP (signature is dropped on edit)
      final zipBytes = UdfArchive.toBytes(
        contentXml: contentXml,
        propertiesXml: _originalArchive?.propertiesXml,
        otherFiles: _originalArchive?.otherFiles ?? {},
      );

      // Determine save path
      _savePath ??= _generateSavePath();

      await File(_savePath!).writeAsBytes(zipBytes, flush: true);

      _originalDoc = udfDoc;
      setState(() {
        _hasChanges = false;
        _isSaving = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Belge kaydedildi.')),
        );
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Kaydetme hatası: $e')),
        );
      }
    }
  }

  /// Rebuild a UDF document from edited plain text.
  ///
  /// Strategy:
  /// 1. Split edited text into lines (one line = one paragraph).
  /// 2. For each edited line, if a corresponding original paragraph exists,
  ///    preserve its attributes (alignment, spacing, indents) and create runs
  ///    that match the original formatting as closely as possible.
  /// 3. If more lines than original paragraphs → new paragraphs with defaults.
  /// 4. If fewer lines → drop extra original paragraphs.
  /// 5. Recalculate all startOffset/length values for the flat CData.
  UdfDocument _rebuildDocument(String text) {
    final lines = text.split('\n');
    final originalParagraphs = _originalDoc?.allParagraphs ?? [];
    final paragraphs = <UdfParagraph>[];
    var offset = 0;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final hasOriginal = i < originalParagraphs.length;
      final origPara = hasOriginal ? originalParagraphs[i] : null;

      if (line.isEmpty) {
        // Empty line → preserve original paragraph attributes if available
        paragraphs.add(UdfParagraph(
          runs: const [],
          alignment: origPara?.alignment ?? UdfAlignment.left,
          lineSpacing: origPara?.lineSpacing ?? 1.0,
          spaceBefore: origPara?.spaceBefore ?? 0,
          spaceAfter: origPara?.spaceAfter ?? 0,
          leftIndent: origPara?.leftIndent ?? 0,
          rightIndent: origPara?.rightIndent ?? 0,
          firstLineIndent: origPara?.firstLineIndent ?? 0,
          hangingIndent: origPara?.hangingIndent ?? 0,
          styleName: origPara?.styleName,
        ));
        continue;
      }

      // Build runs for this line
      List<UdfTextRun> runs;

      if (origPara != null && origPara.runs.isNotEmpty) {
        // Preserve original run formatting, reflow text across runs
        runs = _reflowRuns(origPara.runs, offset, line.length);
      } else {
        // No original → single default run
        runs = [
          UdfTextRun(
            startOffset: offset,
            length: line.length,
            fontSize: 12,
            fontFamily: 'Times New Roman',
          ),
        ];
      }

      paragraphs.add(UdfParagraph(
        runs: runs,
        alignment: origPara?.alignment ?? UdfAlignment.left,
        lineSpacing: origPara?.lineSpacing ?? 1.0,
        spaceBefore: origPara?.spaceBefore ?? 0,
        spaceAfter: origPara?.spaceAfter ?? 0,
        leftIndent: origPara?.leftIndent ?? 0,
        rightIndent: origPara?.rightIndent ?? 0,
        firstLineIndent: origPara?.firstLineIndent ?? 0,
        hangingIndent: origPara?.hangingIndent ?? 0,
        styleName: origPara?.styleName,
      ));

      offset += line.length;
    }

    // The full text without newlines (UDF stores text as a flat string)
    final flatText = lines.join();

    return UdfDocument(
      formatId: _originalDoc?.formatId ?? '1.7',
      text: flatText,
      pageFormat: _originalDoc?.pageFormat ?? const UdfPageFormat(),
      sections: [
        UdfSection(type: UdfSectionType.body, paragraphs: paragraphs),
      ],
      styles: _originalDoc?.styles ?? {},
      properties: _originalDoc?.properties ?? {},
    );
  }

  /// Reflow text across original runs with new offset and total length.
  ///
  /// Distributes [newTotalLength] characters proportionally across the
  /// original runs, preserving each run's formatting (bold, italic, font, etc).
  /// If the text grew or shrank, the last run absorbs the difference.
  List<UdfTextRun> _reflowRuns(
    List<UdfTextRun> originalRuns,
    int newStartOffset,
    int newTotalLength,
  ) {
    if (originalRuns.length == 1) {
      final orig = originalRuns.first;
      return [
        UdfTextRun(
          startOffset: newStartOffset,
          length: newTotalLength,
          bold: orig.bold,
          italic: orig.italic,
          underline: orig.underline,
          strikethrough: orig.strikethrough,
          superscript: orig.superscript,
          subscript: orig.subscript,
          fontSize: orig.fontSize,
          fontFamily: orig.fontFamily,
          foregroundColor: orig.foregroundColor,
          backgroundColor: orig.backgroundColor,
          styleName: orig.styleName,
        ),
      ];
    }

    // Calculate the total original length
    final origTotal = originalRuns.fold<int>(0, (sum, r) => sum + r.length);
    if (origTotal == 0) {
      // Degenerate case — all zero-length runs
      final first = originalRuns.first;
      return [
        UdfTextRun(
          startOffset: newStartOffset,
          length: newTotalLength,
          bold: first.bold,
          italic: first.italic,
          underline: first.underline,
          strikethrough: first.strikethrough,
          fontSize: first.fontSize,
          fontFamily: first.fontFamily,
          foregroundColor: first.foregroundColor,
          backgroundColor: first.backgroundColor,
          styleName: first.styleName,
        ),
      ];
    }

    // Distribute proportionally
    final runs = <UdfTextRun>[];
    var currentOffset = newStartOffset;
    var remainingChars = newTotalLength;

    for (var i = 0; i < originalRuns.length; i++) {
      final orig = originalRuns[i];
      final int runLength;

      if (i == originalRuns.length - 1) {
        // Last run takes whatever's left
        runLength = remainingChars;
      } else {
        // Proportional distribution
        runLength = (orig.length * newTotalLength / origTotal).round();
      }

      if (runLength <= 0) continue;

      final actualLength = runLength.clamp(0, remainingChars);
      if (actualLength <= 0) continue;

      runs.add(UdfTextRun(
        startOffset: currentOffset,
        length: actualLength,
        bold: orig.bold,
        italic: orig.italic,
        underline: orig.underline,
        strikethrough: orig.strikethrough,
        superscript: orig.superscript,
        subscript: orig.subscript,
        fontSize: orig.fontSize,
        fontFamily: orig.fontFamily,
        foregroundColor: orig.foregroundColor,
        backgroundColor: orig.backgroundColor,
        styleName: orig.styleName,
      ));

      currentOffset += actualLength;
      remainingChars -= actualLength;
    }

    // Safety: if proportional distribution didn't cover all chars
    if (remainingChars > 0 && runs.isNotEmpty) {
      final last = runs.removeLast();
      runs.add(UdfTextRun(
        startOffset: last.startOffset,
        length: last.length + remainingChars,
        bold: last.bold,
        italic: last.italic,
        underline: last.underline,
        strikethrough: last.strikethrough,
        superscript: last.superscript,
        subscript: last.subscript,
        fontSize: last.fontSize,
        fontFamily: last.fontFamily,
        foregroundColor: last.foregroundColor,
        backgroundColor: last.backgroundColor,
        styleName: last.styleName,
      ));
    }

    return runs;
  }

  String _generateSavePath() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final defaultName = 'belge_$timestamp.udf';
    final dir = File(widget.filePath ?? '').parent;
    return '${dir.path}/$defaultName';
  }

  String get _title {
    if (widget.isNewDocument) return 'Yeni Belge';
    if (_savePath != null) {
      return _savePath!.split(Platform.pathSeparator).last;
    }
    return 'Düzenleme';
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_title, style: const TextStyle(fontSize: 16)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => _confirmExit(context),
        ),
        actions: [
          if (!_isLoading && _error == null) ...[
            // Save
            IconButton(
              icon: _isSaving
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colorScheme.onSurface,
                      ),
                    )
                  : Icon(
                      Icons.save_outlined,
                      color: _hasChanges
                          ? colorScheme.primary
                          : colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
              onPressed: _hasChanges && !_isSaving ? _save : null,
              tooltip: 'Kaydet',
            ),
            // Share
            if (_savePath != null)
              IconButton(
                icon: const Icon(Icons.share_outlined),
                onPressed: () async {
                  await SharePlus.instance.share(
                    ShareParams(files: [XFile(_savePath!)], title: _title),
                  );
                },
                tooltip: 'Paylaş',
              ),
          ],
        ],
      ),
      body: _buildBody(theme, colorScheme),
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
              Icon(Icons.lock_outline, size: 64, color: colorScheme.error),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 24),
              if (PaywallService.instance.isFree)
                FilledButton.icon(
                  onPressed: () async {
                    final result = await PaywallService.instance.presentPaywallIfNeeded();
                    if (result == PaywallResult.purchased && mounted) {
                      setState(() {
                        _error = null;
                        _isLoading = true;
                      });
                      _initEditor();
                    }
                  },
                  icon: const Icon(Icons.star),
                  label: const Text('Pro\'ya Yükselt'),
                ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        // Formatting toolbar
        _buildToolbar(colorScheme),

        // Editor
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _textController,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              textAlign: _textAlign,
              style: TextStyle(
                fontFamily: 'Times New Roman',
                fontSize: AppTheme.udfFontSizeToLogical(12),
                fontWeight: _isBold ? FontWeight.bold : FontWeight.normal,
                fontStyle: _isItalic ? FontStyle.italic : FontStyle.normal,
                decoration: _isUnderline ? TextDecoration.underline : null,
                height: 1.5,
              ),
              decoration: InputDecoration(
                hintText: 'Belge içeriğini buraya yazın...',
                border: InputBorder.none,
                contentPadding: const EdgeInsets.all(16),
                hintStyle: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildToolbar(ColorScheme colorScheme) {
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        border: Border(
          bottom: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          // Bold
          _toolbarButton(
            icon: Icons.format_bold,
            isActive: _isBold,
            onPressed: () => setState(() => _isBold = !_isBold),
            tooltip: 'Kalın',
          ),
          // Italic
          _toolbarButton(
            icon: Icons.format_italic,
            isActive: _isItalic,
            onPressed: () => setState(() => _isItalic = !_isItalic),
            tooltip: 'İtalik',
          ),
          // Underline
          _toolbarButton(
            icon: Icons.format_underline,
            isActive: _isUnderline,
            onPressed: () => setState(() => _isUnderline = !_isUnderline),
            tooltip: 'Altı Çizili',
          ),

          const SizedBox(width: 8),
          Container(width: 1, height: 24, color: colorScheme.outlineVariant),
          const SizedBox(width: 8),

          // Alignment
          _toolbarButton(
            icon: Icons.format_align_left,
            isActive: _textAlign == TextAlign.left,
            onPressed: () => setState(() => _textAlign = TextAlign.left),
            tooltip: 'Sola Hizala',
          ),
          _toolbarButton(
            icon: Icons.format_align_center,
            isActive: _textAlign == TextAlign.center,
            onPressed: () => setState(() => _textAlign = TextAlign.center),
            tooltip: 'Ortala',
          ),
          _toolbarButton(
            icon: Icons.format_align_right,
            isActive: _textAlign == TextAlign.right,
            onPressed: () => setState(() => _textAlign = TextAlign.right),
            tooltip: 'Sağa Hizala',
          ),
          _toolbarButton(
            icon: Icons.format_align_justify,
            isActive: _textAlign == TextAlign.justify,
            onPressed: () => setState(() => _textAlign = TextAlign.justify),
            tooltip: 'İki Yana Yasla',
          ),

          const Spacer(),

          // Undo / Redo
          IconButton(
            icon: const Icon(Icons.undo, size: 20),
            onPressed: _textController.value.composing.isValid ? null : null,
            tooltip: 'Geri Al',
            iconSize: 20,
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: const Icon(Icons.redo, size: 20),
            onPressed: null,
            tooltip: 'Yinele',
            iconSize: 20,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _toolbarButton({
    required IconData icon,
    required bool isActive,
    required VoidCallback onPressed,
    required String tooltip,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: isActive
                ? colorScheme.primaryContainer
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            icon,
            size: 20,
            color: isActive
                ? colorScheme.onPrimaryContainer
                : colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Future<void> _confirmExit(BuildContext context) async {
    if (!_hasChanges) {
      Navigator.of(context).pop();
      return;
    }

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kaydedilmemiş Değişiklikler'),
        content: const Text('Kaydetmeden çıkmak istediğinize emin misiniz?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('İptal'),
          ),
          TextButton(
            onPressed: () async {
              await _save();
              if (ctx.mounted) Navigator.of(ctx).pop(true);
            },
            child: const Text('Kaydet ve Çık'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'Çık',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );

    if (result == true && context.mounted) {
      Navigator.of(context).pop();
    }
  }
}
