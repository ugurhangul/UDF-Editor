import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/theme.dart';
import '../../core/paywall/paywall_service.dart';
import '../../shared/draft_store.dart';
import '../../shared/version_store.dart';
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

class _EditorScreenState extends State<EditorScreen> with WidgetsBindingObserver {
  late TextEditingController _textController;
  UdfDocument? _originalDoc;
  UdfArchive? _originalArchive;

  /// One template per original paragraph, with newline characters stripped
  /// out of the runs ("visible runs"). Editor lines map 1:1 onto these —
  /// using the raw runs instead would misalign indices (runs may contain
  /// '\n') and shift formatting across paragraphs on every save.
  List<UdfParagraph> _paraTemplates = [];
  bool _isLoading = true;
  bool _isSaving = false;
  bool _hasChanges = false;
  String? _error;
  String? _savePath;

  // Note: Rich text formatting (bold/italic/underline/alignment) is not
  // supported in the plain text editor. The toolbar has been removed to
  // avoid misleading users. A future rich text editor will restore this.
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _textController = TextEditingController();
    _textController.addListener(_onTextChanged);
    _initEditor();
  }

  // H-02: opportunistically persist a plain-text draft when the app is
  // backgrounded so unsaved work survives an OS kill.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.inactive || state == AppLifecycleState.paused) &&
        _hasChanges) {
      _saveDraft();
    }
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

    if (_error == null) {
      await _checkForDraft();
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
      _paraTemplates = _buildParaTemplates(udfDoc);

      // Extract text with newlines at paragraph boundaries.
      // UDF stores text as a flat CData string — paragraphs define ranges.
      // We need to insert \n between paragraphs so _rebuildDocument can
      // split them back correctly on save.
      _setTextSilently(_extractTextWithNewlines(udfDoc));

      if (!mounted) return;
      setState(() => _isLoading = false);
    } on UdfArchiveException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _isLoading = false;
      });
    } on UdfParseException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Dosya yükleme hatası: $e');
      if (!mounted) return;
      setState(() {
        _error = 'Dosya yüklenemedi. Dosya bozuk veya erişilemiyor olabilir.';
        _isLoading = false;
      });
    }
  }

  void _onTextChanged() {
    if (!_hasChanges) {
      setState(() => _hasChanges = true);
    }
  }

  /// Programmatic text assignment must not mark the document dirty —
  /// otherwise every opened document immediately blocks back navigation
  /// and writes phantom drafts.
  void _setTextSilently(String text) {
    _textController.removeListener(_onTextChanged);
    _textController.text = text;
    _textController.addListener(_onTextChanged);
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
        // Concatenate all runs in this paragraph. Runs may contain literal
        // '\n' characters — strip them, the paragraph boundary itself is the
        // newline. Leaving them in desynchronizes line↔paragraph indices.
        for (final run in para.runs) {
          final start = run.startOffset;
          final end = (start + run.length).clamp(0, doc.text.length);
          if (start >= 0 && start < doc.text.length) {
            buffer.write(doc.text.substring(start, end).replaceAll('\n', ''));
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

  /// Build per-paragraph templates whose runs carry visible (newline-free)
  /// lengths, so an unchanged editor line reflows onto identical run
  /// boundaries instead of drifting by the stripped '\n' count.
  List<UdfParagraph> _buildParaTemplates(UdfDocument doc) {
    final templates = <UdfParagraph>[];
    for (final para in doc.allParagraphs) {
      final visibleRuns = <UdfTextRun>[];
      for (final run in para.runs) {
        final start = run.startOffset.clamp(0, doc.text.length);
        final end = (run.startOffset + run.length).clamp(start, doc.text.length);
        final visibleLength =
            doc.text.substring(start, end).replaceAll('\n', '').length;
        if (visibleLength <= 0) continue;
        visibleRuns.add(UdfTextRun(
          startOffset: 0, // recomputed on save
          length: visibleLength,
          bold: run.bold,
          italic: run.italic,
          underline: run.underline,
          strikethrough: run.strikethrough,
          superscript: run.superscript,
          subscript: run.subscript,
          fontSize: run.fontSize,
          fontFamily: run.fontFamily,
          foregroundColor: run.foregroundColor,
          backgroundColor: run.backgroundColor,
          styleName: run.styleName,
        ));
      }
      templates.add(UdfParagraph(
        runs: visibleRuns,
        alignment: para.alignment,
        lineSpacing: para.lineSpacing,
        hangingIndent: para.hangingIndent,
        firstLineIndent: para.firstLineIndent,
        leftIndent: para.leftIndent,
        rightIndent: para.rightIndent,
        spaceBefore: para.spaceBefore,
        spaceAfter: para.spaceAfter,
        styleName: para.styleName,
      ));
    }
    return templates;
  }

  /// Returns true only when the document was actually written to disk, so
  /// exit paths can refuse to close on failure.
  Future<bool> _save() async {
    if (_isSaving) return false;
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
      _savePath ??= await _generateSavePath();

      // Version history: preserve the pre-save content before overwriting.
      await VersionStore.snapshot(_savePath!);
      await File(_savePath!).writeAsBytes(zipBytes, flush: true);

      _originalDoc = udfDoc;
      _paraTemplates = _buildParaTemplates(udfDoc);
      await _deleteDraft();
      if (!mounted) return true;
      setState(() {
        _hasChanges = false;
        _isSaving = false;
      });

      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Belge kaydedildi.')),
      );
      return true;
    } catch (e) {
      debugPrint('Kaydetme hatası: $e');
      if (!mounted) return false;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Belge kaydedilemedi. Lütfen tekrar deneyin.')),
      );
      return false;
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
    final originalParagraphs = _paraTemplates;
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
          lineSpacing: origPara?.lineSpacing ?? 0.0,
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
        lineSpacing: origPara?.lineSpacing ?? 0.0,
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

  Future<String> _generateSavePath() async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final defaultName = 'belge_$timestamp.udf';
    // CODE-02: Always save to the app's udf_files directory.
    final appDir = await getApplicationDocumentsDirectory();
    final udfDir = Directory('${appDir.path}/udf_files');
    if (!await udfDir.exists()) {
      await udfDir.create(recursive: true);
    }
    return '${udfDir.path}/$defaultName';
  }

  // H-02: draft auto-save, keyed by SHA-256 of the source path (DraftStore)
  // so distinct documents can never collide onto the same draft.
  Future<void> _saveDraft() async {
    try {
      final file = await DraftStore.fileFor(widget.filePath);
      await file.writeAsString(_textController.text, flush: true);
    } catch (_) {
      // Best-effort — a failed draft write should never crash the app.
    }
  }

  Future<void> _deleteDraft() => DraftStore.deleteFor(widget.filePath);

  Future<void> _checkForDraft() async {
    try {
      final file = await DraftStore.fileFor(widget.filePath);
      if (!await file.exists()) return;

      final draftText = await file.readAsString();
      if (!mounted || draftText.isEmpty) return;

      final restore = await showDialog<bool>(
        context: context,
        // Dismissal must not destroy the draft — deletion only on explicit 'Sil'.
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Kaydedilmemiş taslak bulundu'),
          content: const Text(
            'Bu belge için kaydedilmemiş bir taslak bulundu. Ne yapmak istersiniz?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Sil'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Geri Yükle'),
            ),
          ],
        ),
      );

      if (restore == true) {
        _setTextSilently(draftText);
        // Restored draft content genuinely is unsaved work.
        if (!_hasChanges && mounted) setState(() => _hasChanges = true);
      } else if (restore == false) {
        // Only the explicit 'Sil' button deletes; a dismissed dialog
        // (system back) keeps the draft for the next open.
        await _deleteDraft();
      }
    } catch (_) {
      // Best-effort.
    }
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
    WidgetsBinding.instance.removeObserver(this);
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return PopScope(
      // C-01: block the hardware back / swipe-back gesture when there are
      // unsaved changes so it can't bypass the confirm-exit dialog.
      canPop: !_hasChanges,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmExit(context);
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
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
        body: SafeArea(
          child: _buildBody(theme, colorScheme),
        ),
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

    return GestureDetector(
      // H-01: tapping outside the TextField dismisses the keyboard.
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusScope.of(context).unfocus(),
      child: Column(
        children: [
          // Plain text editor notice
          _buildEditorInfoBar(colorScheme),

          // Editor
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: TextField(
                controller: _textController,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: TextStyle(
                  fontFamily: 'Times New Roman',
                  fontSize: AppTheme.udfFontSizeToLogical(12),
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
      ),
    );
  }

  /// UX-01: Honest info bar replacing the fake formatting toolbar.
  /// Tells the user this is plain text mode.
  Widget _buildEditorInfoBar(ColorScheme colorScheme) {
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        border: Border(
          bottom: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(
            Icons.text_fields,
            size: 16,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Text(
            'Düz Metin Düzenleyici',
            style: TextStyle(
              fontSize: 13,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          // L-04: live character/word count.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _textController,
            builder: (context, value, _) {
              final charCount = value.text.length;
              final wordCount = value.text
                  .split(RegExp(r'\s+'))
                  .where((w) => w.isNotEmpty)
                  .length;
              return Text(
                '$wordCount kelime, $charCount karakter',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              );
            },
          ),
        ],
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
              // Exit only when the write actually succeeded — a swallowed
              // save error must not silently discard the edits.
              final saved = await _save();
              if (saved && ctx.mounted) Navigator.of(ctx).pop(true);
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
      // Discarding changes also discards their draft ('Kaydet ve Çık'
      // already deleted it inside _save). Fire-and-forget.
      _deleteDraft();
      Navigator.of(context).pop();
    }
  }
}
