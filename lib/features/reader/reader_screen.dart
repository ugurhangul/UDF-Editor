import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/paywall/paywall_service.dart';

import '../../app/theme.dart';
import '../../core/crypto/models.dart';
import '../../core/crypto/signature_verifier.dart';
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

  /// Cached verification result — verify once per loaded document.
  SignatureInfo? _signatureInfo;

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

      if (!mounted) return;
      setState(() {
        _archive = archive;
        _document = document;
        _signatureInfo = null; // re-verify after any reload (edit/sign)
      });
    } on UdfArchiveException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } on UdfParseException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      debugPrint('Dosya okuma hatası: $e');
      if (!mounted) return;
      setState(() => _error = 'Dosya okunamadı. Dosya bozuk veya erişilemiyor olabilir.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String get _fileName =>
      widget.filePath.split(Platform.pathSeparator).last;

  /// Version snapshots are opened read-only: editing or signing one would
  /// corrupt the history entry instead of the live document.
  bool get _isVersionSnapshot => widget.filePath.contains('udf_versions');

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
          if (_archive != null && !(_archive!.isSigned) && !_isVersionSnapshot)
            IconButton(
              icon: const Icon(Icons.draw_outlined),
              onPressed: () async {
                final allowed = await PaywallService.instance.requirePro();
                if (!allowed || !context.mounted) return;
                await context.pushNamed(
                  'signing',
                  queryParameters: {'path': widget.filePath},
                );
                // Signing rewrites the file (sign.sgn added) — reload so the
                // badge and content reflect the on-disk state.
                if (mounted) _loadDocument();
              },
              tooltip: 'İmzala',
            ),
          // Edit document
          if (!_isLoading && _error == null && !_isVersionSnapshot)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                await context.pushNamed(
                  'editor',
                  queryParameters: {'path': widget.filePath},
                );
                // The editor may have saved changes — reload from disk,
                // otherwise the reader shows the stale pre-edit document.
                if (mounted) _loadDocument();
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
          // UX-08: only show ad once the document has actually loaded.
          if (!_isLoading && _error == null) const AdBannerWidget(),
        ],
      ),
    );
  }

  Widget _buildSignatureBadge(ColorScheme colorScheme) {
    final isSigned = _archive?.isSigned ?? false;

    // UX-04: Use theme-aware colors for dark mode compatibility.
    final badgeColor = isSigned
        ? colorScheme.tertiary
        : colorScheme.outline;
    final badgeBg = isSigned
        ? colorScheme.tertiaryContainer
        : colorScheme.surfaceContainerHighest;

    return Tooltip(
      message: isSigned ? 'İmzalı belge — detay için dokunun' : 'İmzasız belge',
      child: GestureDetector(
        onTap: isSigned ? _showSignatureDetails : null,
        child: Chip(
          avatar: Icon(
            isSigned ? Icons.verified : Icons.lock_open,
            size: 16,
            color: badgeColor,
          ),
          label: Text(
            isSigned ? 'İmzalı' : 'İmzasız',
            style: TextStyle(
              fontSize: 11,
              color: badgeColor,
            ),
          ),
          backgroundColor: badgeBg,
          side: BorderSide.none,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }

  // ── Signature details ─────────────────────────────────────────────────

  void _showSignatureDetails() {
    final archive = _archive;
    if (archive == null || !archive.isSigned) return;

    // Same encoding path the signing flow hashes — see signing_screen.
    _signatureInfo ??= SignatureVerifier.verify(
      signSgnBytes: archive.signatureBytes!,
      contentXmlBytes: Uint8List.fromList(utf8.encode(archive.contentXml)),
    );
    final info = _signatureInfo!;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final colorScheme = Theme.of(ctx).colorScheme;
        final (icon, color, bg, title, subtitle) = switch (info.status) {
          SignatureStatus.valid => (
              Icons.verified,
              colorScheme.tertiary,
              colorScheme.tertiaryContainer,
              'İmza Geçerli',
              'İmza kriptografik olarak doğrulandı. Belge imzalandıktan sonra değiştirilmemiş.',
            ),
          SignatureStatus.invalid => (
              Icons.gpp_bad,
              colorScheme.error,
              colorScheme.errorContainer,
              'İmza Geçersiz',
              'İmza doğrulanamadı — belge imzalandıktan sonra değiştirilmiş veya imza bozuk.',
            ),
          SignatureStatus.expired => (
              Icons.timer_off_outlined,
              colorScheme.error,
              colorScheme.surfaceContainerHighest,
              'Sertifika Süresi Dolmuş',
              'İmza doğru ancak imza sertifikasının geçerlilik süresi dolmuş.',
            ),
          _ => (
              Icons.help_outline,
              colorScheme.outline,
              colorScheme.surfaceContainerHighest,
              'Doğrulanamadı',
              'İmza çözümlenemedi veya desteklenmeyen bir algoritma kullanılmış.',
            ),
        };

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(icon, size: 32, color: color),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                                    color: color,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              subtitle,
                              style: Theme.of(ctx).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _sigDetailRow(ctx, 'İmzalayan', info.signerName),
                _sigDetailRow(ctx, 'Sertifika Sağlayıcı', info.issuerName),
                _sigDetailRow(
                  ctx,
                  info.hasTimestamp ? 'İmza / Zaman Damgası' : 'İmza Tarihi',
                  _formatSigTime(info.signingTime),
                ),
                _sigDetailRow(
                  ctx,
                  'Sertifika Geçerliliği',
                  info.validFrom != null && info.validTo != null
                      ? '${_formatSigTime(info.validFrom)} — ${_formatSigTime(info.validTo)}'
                      : null,
                ),
                _sigDetailRow(ctx, 'Seri No', info.serialNumber),
                _sigDetailRow(
                  ctx,
                  'Algoritma',
                  info.signatureAlgorithm != null
                      ? '${info.signatureAlgorithm} / ${info.digestAlgorithm ?? '-'}'
                      : info.digestAlgorithm,
                ),
                _sigDetailRow(ctx, 'CAdES Profili', info.cadesProfile),
                _sigDetailRow(ctx, 'Zaman Damgası', info.hasTimestamp ? 'Var' : 'Yok'),
                const SizedBox(height: 12),
                Text(
                  'Not: Sertifika zinciri kök sertifika otoritesine kadar doğrulanmamıştır.',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _sigDetailRow(BuildContext ctx, String label, String? value) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: Theme.of(ctx).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  String? _formatSigTime(DateTime? dt) {
    if (dt == null) return null;
    final local = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}.${local.year} ${two(local.hour)}:${two(local.minute)}';
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

    // UDF CDATA is a flat string with NO newlines — paragraphs are offset
    // ranges. Derive one "line" per paragraph from its run offsets; splitting
    // on '\n' would collapse the whole document into a single styled line.
    // Newline split remains only as a fallback when parsing found no
    // paragraphs at all.
    final allParagraphs = doc.allParagraphs;
    final lines = allParagraphs.isNotEmpty
        ? [for (final p in allParagraphs) p.plainText(doc.text)]
        : doc.text.split('\n');

    // Scale UDF point margins to logical pixels (UDF uses ~2.83 pts per mm)
    final scale = 0.45;
    final pagePadding = EdgeInsets.only(
      left: doc.pageFormat.leftMargin * scale,
      right: doc.pageFormat.rightMargin * scale,
      top: doc.pageFormat.topMargin * scale,
      bottom: doc.pageFormat.bottomMargin * scale,
    );

    // UX-03: Use theme-aware background for dark mode compatibility.
    // The paper itself stays white (it's a document), but the canvas adapts.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final canvasColor = isDark
        ? colorScheme.surfaceContainerLowest
        : const Color(0xFFE8E8E8);

    // C-02: large docs would render every line eagerly in a Column inside a
    // SingleChildScrollView (OOM/jank risk). Switch to a lazy ListView.builder
    // once the doc is big enough that eager layout becomes a problem.
    if (lines.length > 200) {
      return Container(
        color: canvasColor,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: Alignment.topCenter,
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxWidth: 680),
              color: Colors.white, // Paper is always white
              child: SelectionArea(
                child: ListView.builder(
                  padding: pagePadding,
                  itemCount: lines.length,
                  itemBuilder: (context, index) =>
                      _buildLineWidget(doc, lines, allParagraphs, index),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      color: canvasColor,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 680),
            decoration: BoxDecoration(
              color: Colors.white, // Paper is always white
              borderRadius: BorderRadius.circular(2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.15),
                  blurRadius: 12,
                  offset: const Offset(0, 2),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.06),
                  blurRadius: 3,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: Padding(
              padding: pagePadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _buildDocumentWidgets(doc, lines, allParagraphs),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Render the document using the CData text directly.
  ///
  /// Strategy (matching reference implementation):
  /// 1. Split CData text by newlines → one widget per line.
  /// 2. For each line, apply formatting from the corresponding paragraph's
  ///    runs (bold, font size, font family, alignment, spacing).
  /// 3. This avoids all startOffset/length byte-vs-char issues entirely.
  List<Widget> _buildDocumentWidgets(
    UdfDocument doc,
    List<String> lines,
    List<UdfParagraph> allParagraphs,
  ) {
    final widgets = <Widget>[
      for (var i = 0; i < lines.length; i++)
        _buildLineWidget(doc, lines, allParagraphs, i),
    ];

    // Fallback: if no lines, show raw text
    if (widgets.isEmpty && doc.text.isNotEmpty) {
      widgets.add(SelectableText(doc.text));
    }

    return widgets;
  }

  /// Builds the widget for a single line, shared by both the eager
  /// (Column) and lazy (ListView.builder) rendering paths — see C-02.
  Widget _buildLineWidget(
    UdfDocument doc,
    List<String> lines,
    List<UdfParagraph> allParagraphs,
    int index,
  ) {
    final line = lines[index];
    final para = index < allParagraphs.length ? allParagraphs[index] : null;

    if (line.trim().isEmpty) {
      // Empty line — use paragraph spacing if available
      final lineHeight = para != null && para.runs.isNotEmpty
          ? AppTheme.udfFontSizeToLogical(para.runs.first.fontSize)
          : AppTheme.udfFontSizeToLogical(12);
      return SizedBox(height: lineHeight * _flutterLineHeight(para?.lineSpacing));
    }

    // Determine formatting from the paragraph's runs
    final textAlign = para != null ? _toTextAlign(para.alignment) : TextAlign.left;
    final leftIndent = para?.leftIndent.toDouble() ?? 0;
    final rightIndent = para?.rightIndent.toDouble() ?? 0;
    final spaceBefore = para?.spaceBefore.toDouble() ?? 0;
    final spaceAfter = para?.spaceAfter.toDouble() ?? 0;
    final lineSpacing = para?.lineSpacing ?? 0.0;

    // Build styled text — use runs for formatting if available
    Widget textWidget;
    if (para != null && para.runs.isNotEmpty) {
      if (para.runs.length == 1) {
        // Single run — apply its style to the entire line
        final run = para.runs.first;
        textWidget = SelectableText(
          line,
          textAlign: textAlign,
          style: TextStyle(
            fontSize: AppTheme.udfFontSizeToLogical(run.fontSize),
            fontFamily: run.fontFamily,
            fontWeight: run.bold ? FontWeight.bold : FontWeight.normal,
            fontStyle: run.italic ? FontStyle.italic : FontStyle.normal,
            decoration: _textDecoration(run),
            color: run.foregroundColor ?? Colors.black,
            backgroundColor: run.backgroundColor,
            height: _flutterLineHeight(lineSpacing),
          ),
        );
      } else {
        // Multiple runs — try to distribute formatting across the line
        // Use each run's style for its proportional portion of text
        final spans = <InlineSpan>[];
        var charPos = 0;
        final totalOrigLen = para.runs.fold<int>(0, (sum, r) => sum + r.length);

        for (var j = 0; j < para.runs.length; j++) {
          final run = para.runs[j];
          final int segmentLen;

          if (j == para.runs.length - 1) {
            segmentLen = line.length - charPos;
          } else if (totalOrigLen > 0) {
            segmentLen = (run.length * line.length / totalOrigLen).round();
          } else {
            segmentLen = line.length ~/ para.runs.length;
          }

          if (segmentLen <= 0 || charPos >= line.length) continue;

          final end = (charPos + segmentLen).clamp(0, line.length);
          final segment = line.substring(charPos, end);
          if (segment.isEmpty) continue;

          spans.add(TextSpan(
            text: segment,
            style: TextStyle(
              fontSize: AppTheme.udfFontSizeToLogical(run.fontSize),
              fontFamily: run.fontFamily,
              fontWeight: run.bold ? FontWeight.bold : FontWeight.normal,
              fontStyle: run.italic ? FontStyle.italic : FontStyle.normal,
              decoration: _textDecoration(run),
              color: run.foregroundColor ?? Colors.black,
              backgroundColor: run.backgroundColor,
            ),
          ));

          charPos = end;
        }

        // If we didn't cover all chars (rounding), add remainder with last run's style
        if (charPos < line.length && para.runs.isNotEmpty) {
          final lastRun = para.runs.last;
          spans.add(TextSpan(
            text: line.substring(charPos),
            style: TextStyle(
              fontSize: AppTheme.udfFontSizeToLogical(lastRun.fontSize),
              fontFamily: lastRun.fontFamily,
              fontWeight: lastRun.bold ? FontWeight.bold : FontWeight.normal,
              fontStyle: lastRun.italic ? FontStyle.italic : FontStyle.normal,
              color: lastRun.foregroundColor ?? Colors.black,
            ),
          ));
        }

        textWidget = SelectableText.rich(
          TextSpan(children: spans),
          textAlign: textAlign,
          style: TextStyle(
            height: _flutterLineHeight(lineSpacing),
          ),
        );
      }
    } else {
      // No paragraph data — default rendering
      textWidget = SelectableText(
        line,
        textAlign: textAlign,
        style: TextStyle(
          fontSize: AppTheme.udfFontSizeToLogical(12),
          fontFamily: 'Times New Roman',
          color: Colors.black,
          height: _flutterLineHeight(lineSpacing),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(
        left: leftIndent / 3,
        right: rightIndent / 3,
        top: spaceBefore / 2,
        bottom: spaceAfter / 2,
      ),
      child: textWidget,
    );
  }

  /// UDF LineSpacing is Java Swing's additive factor (0.5 = half a line of
  /// EXTRA space), not a total line-height multiplier — mapping it raw onto
  /// TextStyle.height makes wrapped lines overlap (sample.udf uses 0.5).
  double _flutterLineHeight(double? udfLineSpacing) {
    if (udfLineSpacing == null || udfLineSpacing <= 0) return 1.0;
    return 1.0 + udfLineSpacing;
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

  Future<void> _shareFile() async {
    await SharePlus.instance.share(ShareParams(files: [XFile(widget.filePath)], title: _fileName));
  }
}
