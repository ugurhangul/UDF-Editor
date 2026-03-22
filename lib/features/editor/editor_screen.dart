import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/theme.dart';
import '../../core/paywall/paywall_service.dart';
import '../../core/udf/udf_archive.dart';
import '../../core/udf/udf_delta_converter.dart';
import '../../core/udf/udf_document.dart';
import '../../core/udf/udf_parser.dart';
import '../../core/udf/udf_serializer.dart';

/// Editor screen — WYSIWYG UDF editor using flutter_quill.
///
/// Loads a .udf file, converts to Quill Delta for editing, and saves back.
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
  late QuillController _quillController;
  UdfDocument? _originalDoc;
  UdfArchive? _originalArchive;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _hasChanges = false;
  String? _error;
  String? _savePath;

  @override
  void initState() {
    super.initState();
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
      _initNewDocument();
    } else {
      await _loadExistingDocument();
    }
  }

  void _initNewDocument() {
    _quillController = QuillController.basic();
    _quillController.addListener(_onDocumentChanged);
    _savePath = null;
    setState(() => _isLoading = false);
  }

  Future<void> _loadExistingDocument() async {
    try {
      final bytes = await File(widget.filePath!).readAsBytes();
      final archive = UdfArchive.fromBytes(bytes);
      final udfDoc = UdfParser.parse(archive.contentXml);

      Document quillDoc;
      try {
        quillDoc = UdfDeltaConverter.toQuillDocument(udfDoc);
      } catch (e) {
        // Delta conversion failed — fall back to plain text editing
        debugPrint('Delta conversion failed, falling back to plain text: $e');
        quillDoc = Document()..insert(0, udfDoc.text);
      }

      _originalDoc = udfDoc;
      _originalArchive = archive;
      _savePath = widget.filePath;

      _quillController = QuillController(
        document: quillDoc,
        selection: const TextSelection.collapsed(offset: 0),
      );
      _quillController.addListener(_onDocumentChanged);

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

  void _onDocumentChanged() {
    if (!_hasChanges) {
      setState(() => _hasChanges = true);
    }
  }

  Future<void> _save() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    try {
      // Convert Quill document back to UDF
      final udfDoc = UdfDeltaConverter.fromQuillDocument(
        _quillController.document,
        template: _originalDoc,
      );

      // Serialize to content.xml
      final contentXml = UdfSerializer.serialize(udfDoc);

      // Pack into .udf ZIP (signature is dropped on edit)
      final zipBytes = UdfArchive.toBytes(
        contentXml: contentXml,
        propertiesXml: _originalArchive?.propertiesXml,
        otherFiles: _originalArchive?.otherFiles ?? {},
      );

      // Determine save path
      if (_savePath == null) {
        // New document — pick save location
        _savePath = await _pickSavePath();
        if (_savePath == null) {
          setState(() => _isSaving = false);
          return;
        }
      }

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

  Future<String?> _pickSavePath() async {
    // For new documents, generate a default filename with timestamp
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final defaultName = 'belge_$timestamp.udf';

    // Use the app documents directory
    final dir = File(widget.filePath ?? '').parent;
    final path = '${dir.path}/$defaultName';
    return path;
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
    _quillController.dispose();
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
                  onPressed: () {
                    // TODO: Show paywall
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
        // Toolbar
        Container(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            border: Border(
              bottom: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
            ),
          ),
          child: QuillSimpleToolbar(
            controller: _quillController,
            config: QuillSimpleToolbarConfig(
              showAlignmentButtons: true,
              showBoldButton: true,
              showItalicButton: true,
              showUnderLineButton: true,
              showStrikeThrough: true,
              showFontSize: true,
              showFontFamily: false, // UDF uses Times New Roman
              showUndo: true,
              showRedo: true,
              showListBullets: false,
              showListNumbers: false,
              showListCheck: false,
              showQuote: false,
              showLink: false,
              showCodeBlock: false,
              showInlineCode: false,
              showHeaderStyle: false,
              showIndent: true,
              showClearFormat: true,
              showSearchButton: true,
              multiRowsDisplay: false,
              toolbarSize: AppTheme.udfFontSizeToLogical(12) * 3,
            ),
          ),
        ),

        // Editor
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: QuillEditor.basic(
              controller: _quillController,
              config: QuillEditorConfig(
                placeholder: 'Belge içeriğini buraya yazın...',
                padding: const EdgeInsets.all(16),
                scrollable: true,
                autoFocus: true,
                expands: true,
              ),
            ),
          ),
        ),
      ],
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
