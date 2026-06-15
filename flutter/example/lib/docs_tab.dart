import 'dart:io';

import 'package:flutter/material.dart';

import 'doc_meta.dart';
import 'doc_text_viewer_screen.dart';
import 'document_service.dart';
import 'pdf_viewer_screen.dart';
import 'wikipedia_reader_screen.dart';
import 'wikipedia_service.dart';
import 'zim_ffi.dart' show ZimHit;

/// The reading hub, in three sub-tabs:
///  • Wikipedia — read the offline encyclopedia (search / random / main page);
///  • Folders — your documents grouped by the LLM-assigned genre → subcategory;
///  • Favourites — recently read, favourited, and often-read documents.
class DocsTab extends StatefulWidget {
  const DocsTab({super.key, required this.docs});

  final DocumentService docs;

  @override
  State<DocsTab> createState() => _DocsTabState();
}

class _DocsTabState extends State<DocsTab> with TickerProviderStateMixin {
  late final TabController _subTab = TabController(length: 3, vsync: this);
  List<DocumentInfo> _documents = const [];
  Map<String, DocMeta> _meta = {};
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
    final meta = await DocMetaStore.all();
    final wiki = await _wiki.ensureOpen();
    if (!mounted) return;
    setState(() {
      _documents = docs;
      _meta = meta;
      _wikiAvailable = wiki;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _subTab.dispose();
    super.dispose();
  }

  String _ext(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  IconData _iconOf(DocumentInfo d) {
    switch (_ext(d.name)) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart;
      case 'epub':
        return Icons.menu_book;
      default:
        return Icons.article;
    }
  }

  Future<void> _open(DocumentInfo d) async {
    await DocMetaStore.markRead(d.id, DateTime.now().millisecondsSinceEpoch);
    if (!mounted) return;
    final path = d.sourcePath;
    if (_ext(d.name) == 'pdf' && path != null && File(path).existsSync()) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PdfViewerScreen(path: path, title: d.name, resumeKey: d.id),
      ));
    } else {
      final text = await widget.docs.readText(d.id);
      if (!mounted) return;
      if (text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No readable text for this document.')));
        return;
      }
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DocTextViewerScreen(
            title: d.name, fullText: text, snippet: '', resumeKey: d.id),
      ));
    }
    // Reading position / read-count may have changed.
    final meta = await DocMetaStore.all();
    if (mounted) setState(() => _meta = meta);
  }

  Future<void> _toggleFavorite(DocumentInfo d) async {
    await DocMetaStore.toggleFavorite(d.id);
    final meta = await DocMetaStore.all();
    if (mounted) setState(() => _meta = meta);
  }

  Widget _docTile(DocumentInfo d, {String? subtitle}) {
    final m = _meta[d.id];
    final fav = m?.favorite ?? false;
    return ListTile(
      leading: Icon(_iconOf(d)),
      title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        tooltip: fav ? 'Unfavourite' : 'Favourite',
        icon: Icon(fav ? Icons.star : Icons.star_border,
            color: fav ? Colors.amber : null),
        onPressed: () => _toggleFavorite(d),
      ),
      onTap: () => _open(d),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Column(
      children: [
        TabBar(
          controller: _subTab,
          tabs: const [
            Tab(text: 'Wikipedia'),
            Tab(text: 'Folders'),
            Tab(text: 'Favourites'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _subTab,
            children: [
              _wikipediaPage(),
              _foldersPage(),
              _favouritesPage(),
            ],
          ),
        ),
      ],
    );
  }

  // ── Wikipedia ───────────────────────────────────────────────────────────────

  Widget _wikipediaPage() {
    final scheme = Theme.of(context).colorScheme;
    if (!_wikiAvailable) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No Wikipedia installed. Add an edition in Settings → Wikipedia, '
            'then read articles here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Read Wikipedia', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text('Fully offline. Search a topic, open a random article, or start '
            'from the main page.',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 16),
        FilledButton.icon(
          icon: const Icon(Icons.search),
          label: const Text('Search articles'),
          onPressed: _searchWiki,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.casino),
          label: const Text('Surprise me (random article)'),
          onPressed: _openRandom,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.home),
          label: const Text('Open main page'),
          onPressed: _openMain,
        ),
      ],
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

  // ── Folders (LLM genre → subcategory) ───────────────────────────────────────

  Widget _foldersPage() {
    if (_documents.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('No documents yet. Add files in Settings → Documents.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      );
    }
    // Group: category → subcategory → docs.
    final tree = <String, Map<String, List<DocumentInfo>>>{};
    var pending = 0;
    for (final d in _documents) {
      final m = _meta[d.id];
      if (m == null || !m.categorized) pending++;
      final cat = (m?.category.isNotEmpty ?? false) ? m!.category : 'Uncategorised';
      final sub = m?.subcategory ?? '';
      (tree.putIfAbsent(cat, () => {}).putIfAbsent(sub, () => [])).add(d);
    }
    final cats = tree.keys.toList()
      ..sort((a, b) {
        if (a == 'Uncategorised') return 1;
        if (b == 'Uncategorised') return -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    return ListView(
      children: [
        if (pending > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Text(
              'Categorising $pending document${pending == 1 ? '' : 's'} in the '
              'background while charging…',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        for (final cat in cats)
          ExpansionTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(cat),
            subtitle: Text('${tree[cat]!.values.fold<int>(0, (s, l) => s + l.length)} documents'),
            childrenPadding: const EdgeInsets.only(left: 8),
            children: [
              for (final sub in (tree[cat]!.keys.toList()..sort()))
                if (sub.isEmpty)
                  for (final d in tree[cat]![sub]!)
                    _docTile(d, subtitle: _tagsOf(d))
                else
                  ExpansionTile(
                    leading: const Icon(Icons.subdirectory_arrow_right),
                    title: Text(sub),
                    subtitle: Text('${tree[cat]![sub]!.length} documents'),
                    childrenPadding: const EdgeInsets.only(left: 8),
                    children: [
                      for (final d in tree[cat]![sub]!)
                        _docTile(d, subtitle: _tagsOf(d)),
                    ],
                  ),
            ],
          ),
      ],
    );
  }

  String? _tagsOf(DocumentInfo d) {
    final tags = _meta[d.id]?.tags ?? const [];
    return tags.isEmpty ? null : tags.map((t) => '#$t').join(' ');
  }

  // ── Favourites (recent / favourited / often-read) ───────────────────────────

  Widget _favouritesPage() {
    final byId = {for (final d in _documents) d.id: d};
    DocumentInfo? doc(String id) => byId[id];

    final recents = (_meta.values.where((m) => m.lastReadMs > 0).toList()
          ..sort((a, b) => b.lastReadMs.compareTo(a.lastReadMs)))
        .map((m) => doc(m.id))
        .whereType<DocumentInfo>()
        .take(15)
        .toList();
    final favourites = _meta.values
        .where((m) => m.favorite)
        .map((m) => doc(m.id))
        .whereType<DocumentInfo>()
        .toList();
    final often = (_meta.values.where((m) => m.readCount > 1).toList()
          ..sort((a, b) => b.readCount.compareTo(a.readCount)))
        .map((m) => doc(m.id))
        .whereType<DocumentInfo>()
        .take(15)
        .toList();

    if (recents.isEmpty && favourites.isEmpty && often.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Nothing here yet. Open a document to see it under "Recently read", '
            'and tap the star to favourite it.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return ListView(
      children: [
        if (favourites.isNotEmpty) ...[
          _header('Favourites'),
          for (final d in favourites) _docTile(d),
        ],
        if (recents.isNotEmpty) ...[
          _header('Recently read'),
          for (final d in recents)
            _docTile(d, subtitle: _ago(_meta[d.id]!.lastReadMs)),
        ],
        if (often.isNotEmpty) ...[
          _header('Often read'),
          for (final d in often)
            _docTile(d, subtitle: '${_meta[d.id]!.readCount} times'),
        ],
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Text(text,
            style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary)),
      );

  String _ago(int ms) {
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    return '${diff.inDays} d ago';
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
            const Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator())
          else
            ConstrainedBox(
              constraints:
                  BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final h in _hits)
                    ListTile(
                      leading: const Icon(Icons.article_outlined),
                      title: Text(h.title),
                      subtitle: h.snippet.isEmpty
                          ? null
                          : Text(h.snippet, maxLines: 2, overflow: TextOverflow.ellipsis),
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
