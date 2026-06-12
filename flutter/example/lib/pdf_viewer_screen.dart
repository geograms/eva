import 'dart:io';

import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

/// Shows a local PDF, optionally jumping to [initialPage] (1-based) — used to
/// open a citation at the exact page it was retrieved from.
class PdfViewerScreen extends StatefulWidget {
  const PdfViewerScreen({
    super.key,
    required this.path,
    required this.title,
    this.initialPage,
  });

  final String path;
  final String title;
  final int? initialPage;

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  final PdfViewerController _controller = PdfViewerController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final exists = File(widget.path).existsSync();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
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
              onDocumentLoaded: (_) {
                final p = widget.initialPage;
                if (p != null && p > 0) _controller.jumpToPage(p);
              },
            ),
    );
  }
}
