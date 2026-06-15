import 'dart:io';

import 'package:flutter/material.dart';

import 'doc_text_viewer_screen.dart';
import 'document_service.dart';
import 'pdf_viewer_screen.dart';
import 'wikipedia_reader_screen.dart';
import 'wikipedia_service.dart';
import 'zim_ffi.dart' show ZimHit;

/// E-reader tab: browse the indexed documents (grouped by type) and open them
/// in-app, plus browse the offline Wikipedia (search, random, open) for reading
/// for pleasure.
class DocsTab extends StatefulWidget {
  const DocsTab({super.key, required this.docs});

  final DocumentService docs;

  @override
  State<DocsTab> createState() => _DocsTabState();
}

class _DocsTabState extends State<DocsTab> {
  List<DocumentInfo> _documents = const [];
  final TextEditingController _search = TextEditingController();
  bool _loading = true;
  final WikipediaService _wiki = WikipediaService.instance;
  bool _wikiAvailable = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final docs = await widget.docs.list();
    final wiki = await _wiki.ensureOpen();
    if (!mounted) return;
    setState(() {
      _documents = docs;
      _wikiAvailable = wiki;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _ext(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  String _typeOf(DocumentInfo d) {
    switch (_ext(d.name)) {
      case 'pdf':
        return 'PDF';
      case 'doc':
      case 'docx':
        return 'Word';
      case 'ppt':
      case 'pptx':
        return 'PowerPoint';
      case 'xls':
      case 'xlsx':
        return 'Spreadsheet';
      case 'epub':
        return 'EPUB';
      case 'md':
      case 'markdown':
        return 'Markdown';
      default:
        return 'Text';
    }
  }

  IconData _iconOf(String type) {
    switch (type) {
      case 'PDF':
        return Icons.picture_as_pdf;
      case 'Word':
        return Icons.description;
      case 'PowerPoint':
        return Icons.slideshow;
      case 'Spreadsheet':
        return Icons.table_chart;
      case 'EPUB':
        return Icons.menu_book;
      default:
        return Icons.article;
    }
  }

  List<DocumentInfo> get _filtered {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _documents;
    return _documents.where((d) => d.name.toLowerCase().contains(q)).toList();
  }

  Future<void> _open(DocumentInfo d) async {
    final path = d.sourcePath;
    if (_ext(d.name) == 'pdf' && path != null && File(path).existsSync()) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PdfViewerScreen(path: path, title: d.name),
      ));
      return;
    }
    final text = await widget.docs.readText(d.id);
    if (!mounted) return;
    if (text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No readable text for this document.')));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DocTextViewerScreen(title: d.name, fullText: text, snippet: ''),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final scheme = Theme.of(context).colorScheme;
    final docs = _filtered;
    // Group documents by type.
    final byType = <String, List<DocumentInfo>>{};
    for (final d in docs) {
      (byType[_typeOf(d)] ??= []).add(d);
    }
    final types = byType.keys.toList()..sort();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              hintText: 'Search documents…',
              border: const OutlineInputBorder(),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() => _search.clear()),
                    ),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              _wikiCard(),
              if (docs.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _search.text.isEmpty
                        ? 'No documents indexed yet. Add files in Settings → Documents.'
                        : 'No documents match "${_search.text}".',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              for (final type in types) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Text('$type (${byType[type]!.length})',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: scheme.primary)),
                ),
                for (final d in byType[type]!)
                  ListTile(
                    leading: Icon(_iconOf(type)),
                    title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '${_kChars(d.chars)} · ${d.folder.split('/').last}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => _open(d),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  String _kChars(int chars) {
    if (chars >= 1000000) return '${(chars / 1000000).toStringAsFixed(1)}M chars';
    if (chars >= 1000) return '${(chars / 1000).toStringAsFixed(0)}k chars';
    return '$chars chars';
  }

  Widget _wikiCard() {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.public, color: scheme.primary),
              const SizedBox(width: 8),
              const Text('Offline Wikipedia',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 6),
            Text(
              _wikiAvailable
                  ? 'Read articles for pleasure — search, open a random one, or browse from the main page.'
                  : 'No Wikipedia installed. Add one in Settings → Wikipedia.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            if (_wikiAvailable) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.search, size: 18),
                    label: const Text('Search articles'),
                    onPressed: _searchWiki,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.casino, size: 18),
                    label: const Text('Random'),
                    onPressed: _openRandom,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.home, size: 18),
                    label: const Text('Main page'),
                    onPressed: _openMain,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openMain() async {
    final path = await _wiki.mainPath();
    if (!mounted || path.isEmpty) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WikipediaReaderScreen(title: 'Wikipedia', articlePath: path),
    ));
  }

  Future<void> _openRandom() async {
    final hit = await _wiki.randomArticle();
    if (!mounted) return;
    if (hit == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not pick a random article.')));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WikipediaReaderScreen(title: hit.title, articlePath: hit.path),
    ));
  }

  Future<void> _searchWiki() async {
    final hit = await showModalBottomSheet<ZimHit>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _WikiSearchSheet(wiki: _wiki),
    );
    if (hit == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WikipediaReaderScreen(title: hit.title, articlePath: hit.path),
    ));
  }
}

/// A bottom sheet to search Wikipedia titles and pick an article to read.
class _WikiSearchSheet extends StatefulWidget {
  const _WikiSearchSheet({required this.wiki});
  final WikipediaService wiki;

  @override
  State<_WikiSearchSheet> createState() => _WikiSearchSheetState();
}

class _WikiSearchSheetState extends State<_WikiSearchSheet> {
  final TextEditingController _c = TextEditingController();
  List<ZimHit> _hits = const [];
  bool _searching = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final q = _c.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    final hits = await widget.wiki.search(q, k: 30);
    if (!mounted) return;
    setState(() {
      _hits = hits;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(left: 12, right: 12, bottom: bottom + 12, top: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _c,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _run(),
            decoration: InputDecoration(
              hintText: 'Search Wikipedia…',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: _run),
            ),
          ),
          const SizedBox(height: 8),
          if (_searching)
            const Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.5),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final h in _hits)
                    ListTile(
                      leading: const Icon(Icons.article_outlined),
                      title: Text(h.title),
                      subtitle: h.snippet.isEmpty
                          ? null
                          : Text(h.snippet,
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.of(context).pop(h),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
