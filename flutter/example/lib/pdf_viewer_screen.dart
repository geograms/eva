import 'dart:io';

import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import 'app_prefs.dart';

/// Shows a local PDF, optionally jumping to [initialPage] (1-based) — used to
/// open a citation at the exact page it was retrieved from. When [resumeKey] is
/// set and no [initialPage] is given, it resumes at the last-read page and
/// remembers the page as you read. The app bar shows "Page X of Y".
class PdfViewerScreen extends StatefulWidget {
  const PdfViewerScreen({
    super.key,
    required this.path,
    required this.title,
    this.initialPage,
    this.resumeKey,
  });

  final String path;
  final String title;
  final int? initialPage;
  final String? resumeKey;

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  final PdfViewerController _controller = PdfViewerController();
  int _page = 1;
  int _pages = 0;
  bool _ready = false; // don't persist the page until restore is done

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onLoaded(PdfDocumentLoadedDetails d) async {
    setState(() => _pages = d.document.pages.count);
    var target = widget.initialPage;
    if ((target == null || target <= 0) && widget.resumeKey != null) {
      target = await loadDocPage(widget.resumeKey!);
    }
    if (target != null && target > 1 && mounted) {
      // syncfusion needs the viewer settled before a jump takes effect.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      _controller.jumpToPage(target);
    }
    _ready = true;
  }

  @override
  Widget build(BuildContext context) {
    final exists = File(widget.path).existsSync();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        bottom: (exists && _pages > 0)
            ? PreferredSize(
                preferredSize: const Size.fromHeight(22),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('Page $_page of $_pages',
                      style: Theme.of(context).textTheme.labelSmall),
                ),
              )
            : null,
      ),
      body: !exists
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'The original file is no longer at its saved location, so it '
                  "can't be opened. Re-scan to refresh its location.",
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : SfPdfViewer.file(
              File(widget.path),
              controller: _controller,
              onDocumentLoaded: _onLoaded,
              onPageChanged: (details) {
                setState(() => _page = details.newPageNumber);
                final key = widget.resumeKey;
                if (key != null && _ready) saveDocPage(key, details.newPageNumber);
              },
            ),
    );
  }
}
