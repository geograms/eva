import 'dart:io';

import 'package:flutter/material.dart';

import 'app_prefs.dart';
import 'doc_meta.dart';
import 'doc_text_viewer_screen.dart';
import 'document_service.dart' show DocumentService, DocumentInfo, htmlToPlainText;
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
  bool _wikiBusy = false; // resolving a random/main article
  List<({String title, String path})> _recent = const [];
  final TextEditingController _wikiSearchCtl = TextEditingController();
  List<ZimHit> _wikiHits = const [];
  bool _wikiSearching = false;
  bool _wikiSearched = false;

  @override
  void initState() {
    super.initState();
    _load();
    docCategorizeProgress.addListener(_onCatProgress);
  }

  // As documents get categorised in the background, refresh so they move out of
  // "To categorize" into their genre live.
  Future<void> _onCatProgress() async {
    final meta = await DocMetaStore.all();
    if (mounted) setState(() => _meta = meta);
  }

  Future<void> _load() async {
    final docs = await widget.docs.list();
    final meta = await DocMetaStore.all();
    final wiki = await _wiki.ensureOpen();
    final recent = await loadRecentWiki();
    if (!mounted) return;
    setState(() {
      _documents = docs;
      _meta = meta;
      _wikiAvailable = wiki;
      _recent = recent;
      _loading = false;
    });
  }

  @override
  void dispose() {
    docCategorizeProgress.removeListener(_onCatProgress);
    _wikiSearchCtl.dispose();
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
    final hasQuery = _wikiSearchCtl.text.trim().isNotEmpty;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: TextField(
            controller: _wikiSearchCtl,
            textInputAction: TextInputAction.search,
            onChanged: (_) => setState(() {}), // reflect clear button
            onSubmitted: (_) => _runWikiSearch(),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              hintText: 'Search Wikipedia…',
              border: const OutlineInputBorder(),
              suffixIcon: !hasQuery
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() {
                        _wikiSearchCtl.clear();
                        _wikiHits = const [];
                        _wikiSearched = false;
                      }),
                    ),
            ),
          ),
        ),
        Expanded(
          child: _wikiSearching
              ? const Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 10),
                    Text('Searching…'),
                  ]),
                )
              : hasQuery
                  ? _wikiResults()
                  : _wikiBrowse(scheme),
        ),
      ],
    );
  }

  /// Inline search results.
  Widget _wikiResults() {
    if (_wikiSearched && _wikiHits.isEmpty) {
      return const Center(child: Padding(
        padding: EdgeInsets.all(24), child: Text('No articles found.')));
    }
    if (!_wikiSearched) {
      return const Center(child: Padding(
        padding: EdgeInsets.all(24),
        child: Text('Press search to find articles.', style: TextStyle(color: Colors.grey))));
    }
    return ListView(
      children: [
        for (final h in _wikiHits)
          ListTile(
            leading: const Icon(Icons.article_outlined),
            title: Text(h.title),
            subtitle: _cleanSnippet(h.snippet) == null
                ? null
                : Text(_cleanSnippet(h.snippet)!,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: () => _openArticle(h.title, h.path),
          ),
      ],
    );
  }

  /// Browse view (no query): random + main page + recently viewed.
  Widget _wikiBrowse(ColorScheme scheme) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        OutlinedButton.icon(
          icon: _wikiBusy
              ? const SizedBox(
                  width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.casino),
          label: Text(_wikiBusy ? 'Finding an article…' : 'Surprise me (random article)'),
          onPressed: _wikiBusy ? null : _openRandom,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.home),
          label: const Text('Open main page'),
          onPressed: _wikiBusy ? null : _openMain,
        ),
        if (_recent.isNotEmpty) ...[
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Text('Recently viewed',
                    style: Theme.of(context).textTheme.titleSmall),
              ),
              TextButton(
                onPressed: () async {
                  await clearRecentWiki();
                  final r = await loadRecentWiki();
                  if (mounted) setState(() => _recent = r);
                },
                child: const Text('Clear'),
              ),
            ],
          ),
          for (final a in _recent)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.history),
              title: Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => _openArticle(a.title, a.path),
            ),
        ],
      ],
    );
  }

  String? _cleanSnippet(String raw) {
    final t = htmlToPlainText(raw).trim();
    return t.isEmpty ? null : t;
  }

  Future<void> _runWikiSearch() async {
    final q = _wikiSearchCtl.text.trim();
    if (q.isEmpty) return;
    setState(() => _wikiSearching = true);
    await Future<void>.delayed(const Duration(milliseconds: 50)); // paint spinner
    final hits = await _wiki.search(q, k: 30);
    if (!mounted) return;
    setState(() {
      _wikiHits = hits;
      _wikiSearching = false;
      _wikiSearched = true;
    });
  }

  /// Opens an article in the reader and records it in "recently viewed".
  Future<void> _openArticle(String title, String path) async {
    await addRecentWiki(title, path);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WikipediaReaderScreen(title: title, articlePath: path),
    ));
    final r = await loadRecentWiki();
    if (mounted) setState(() => _recent = r);
  }

  Future<void> _openMain() async {
    setState(() => _wikiBusy = true);
    final path = await _wiki.mainPath();
    if (!mounted) return;
    setState(() => _wikiBusy = false);
    if (path.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This edition has no main page.')));
      return;
    }
    await _openArticle('Wikipedia', path);
  }

  Future<void> _openRandom() async {
    setState(() => _wikiBusy = true);
    final hit = await _wiki.randomArticle();
    if (!mounted) return;
    setState(() => _wikiBusy = false);
    if (hit == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not pick a random article.')));
      return;
    }
    await _openArticle(hit.title, hit.path);
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
    // Group: category → subcategory → docs. Not-yet-categorised docs go under a
    // dedicated "To categorize" group.
    const toDo = 'To categorize';
    final tree = <String, Map<String, List<DocumentInfo>>>{};
    for (final d in _documents) {
      final m = _meta[d.id];
      final String cat;
      final String sub;
      if (m == null || !m.categorized) {
        cat = toDo;
        sub = '';
      } else {
        cat = m.category.isNotEmpty ? m.category : 'General';
        sub = m.subcategory;
      }
      (tree.putIfAbsent(cat, () => {}).putIfAbsent(sub, () => [])).add(d);
    }
    final cats = tree.keys.toList()
      ..sort((a, b) {
        if (a == toDo) return 1; // "To categorize" sinks to the bottom
        if (b == toDo) return -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    return ListView(
      children: [
        for (final cat in cats)
          ExpansionTile(
            leading: Icon(cat == toDo ? Icons.hourglass_empty : Icons.folder_outlined),
            initiallyExpanded: cat == toDo && cats.length == 1,
            title: Text(cat),
            subtitle: cat == toDo
                ? _toCategorizeSubtitle(tree[cat]!.values.fold<int>(0, (s, l) => s + l.length))
                : Text('${tree[cat]!.values.fold<int>(0, (s, l) => s + l.length)} documents'),
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

  /// Subtitle for the "To categorize" group: live progress while the LLM pass
  /// runs, else just the count.
  Widget _toCategorizeSubtitle(int count) => ValueListenableBuilder<({int done, int total})>(
        valueListenable: docCategorizeProgress,
        builder: (context, p, _) {
          if (p.total > 0) {
            return Text('Categorising ${p.done} of ${p.total}…',
                style: TextStyle(color: Theme.of(context).colorScheme.primary));
          }
          return Text('$count document${count == 1 ? '' : 's'} · categorising as '
              'you browse and while charging');
        },
      );

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

