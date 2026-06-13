import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'wikipedia_service.dart';

/// In-app reader for an offline Wikipedia article. Serves the ZIM's HTML (and
/// its images / intra-wiki links) from a tiny loopback HTTP server backed by
/// libzim — a mini kiwix-serve — so everything stays offline and navigation
/// remains inside the archive. Opens at [articlePath] and, when given, scrolls
/// to the cited [highlight] text.
class WikipediaReaderScreen extends StatefulWidget {
  const WikipediaReaderScreen({
    super.key,
    required this.title,
    required this.articlePath,
    this.highlight,
  });

  final String title;
  final String articlePath;
  final String? highlight;

  @override
  State<WikipediaReaderScreen> createState() => _WikipediaReaderScreenState();
}

class _WikipediaReaderScreenState extends State<WikipediaReaderScreen> {
  final WikipediaService _wiki = WikipediaService.instance;
  HttpServer? _server;
  WebViewController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      if (!await _wiki.ensureOpen()) {
        setState(() => _error = 'No offline Wikipedia is installed.');
        return;
      }
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      unawaited(_serve(server));
      final base = 'http://127.0.0.1:${server.port}/';
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(NavigationDelegate(
          onPageFinished: (_) => _scrollToHighlight(),
        ))
        ..loadRequest(Uri.parse('$base${_encode(widget.articlePath)}'));
      setState(() => _controller = controller);
    } catch (e) {
      setState(() => _error = 'Could not open the article.');
    }
  }

  String _encode(String path) =>
      path.split('/').map(Uri.encodeComponent).join('/');

  /// Loopback handler: maps each request path to a ZIM entry and streams it back
  /// with its mimetype. Relative links/images in the article resolve here, so
  /// navigation + media stay inside the archive.
  Future<void> _serve(HttpServer server) async {
    await for (final req in server) {
      try {
        var path = Uri.decodeFull(req.uri.path);
        if (path.startsWith('/')) path = path.substring(1);
        final c = path.isEmpty ? null : await _wiki.content(path);
        if (c == null) {
          req.response.statusCode = HttpStatus.notFound;
        } else {
          req.response.headers.contentType = _contentType(c.mimetype);
          req.response.add(c.bytes);
        }
      } catch (_) {
        req.response.statusCode = HttpStatus.internalServerError;
      }
      await req.response.close();
    }
  }

  ContentType _contentType(String mime) {
    final parts = mime.split('/');
    if (parts.length == 2) {
      return ContentType(parts[0], parts[1].split(';').first,
          charset: mime.contains('html') || mime.contains('text') ? 'utf-8' : null);
    }
    return ContentType('application', 'octet-stream');
  }

  Future<void> _scrollToHighlight() async {
    final h = widget.highlight?.trim();
    final c = _controller;
    if (h == null || h.isEmpty || c == null) return;
    // window.find scrolls to + selects the first occurrence (best-effort).
    final js = "try{window.find(${_jsString(h)});}catch(e){}";
    try {
      await c.runJavaScript(js);
    } catch (_) {}
  }

  String _jsString(String s) =>
      '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', ' ')}"';

  @override
  void dispose() {
    _server?.close(force: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : _controller == null
              ? const Center(child: CircularProgressIndicator())
              : WebViewWidget(controller: _controller!),
    );
  }
}
