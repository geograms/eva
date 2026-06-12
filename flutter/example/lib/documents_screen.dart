
import 'package:flutter/material.dart';

import 'document_service.dart';
import 'pdf_viewer_screen.dart';
import 'rag_index.dart';

/// Browses the indexed documents grouped by their source folder, showing each
/// file's indexing status, opening the original PDF, and removing documents.
class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key, required this.docs});

  final DocumentService docs;

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  List<DocumentInfo> _all = const [];
  Set<String> _indexed = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await widget.docs.list();
    final packDir = await widget.docs.corpusPath();
    final indexed = RagIndex.peekIndexedDocIds(packDir);
    if (!mounted) return;
    setState(() {
      _all = all;
      _indexed = indexed;
      _loading = false;
    });
  }

  Map<String, List<DocumentInfo>> get _byFolder {
    final map = <String, List<DocumentInfo>>{};
    for (final d in _all) {
      (map[d.folder] ??= []).add(d);
    }
    return map;
  }

  Future<void> _open(DocumentInfo d) async {
    final path = d.sourcePath;
    if (path == null || !path.toLowerCase().endsWith('.pdf')) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(path == null
              ? 'No saved location for this file (re-scan to enable opening).'
              : 'Only PDF files can be opened in the viewer.')));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PdfViewerScreen(path: path, title: d.name),
    ));
  }

  Future<void> _remove(DocumentInfo d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove "${d.name}"?'),
        content: const Text(
            'Removes it from the search index. The original file is not deleted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.docs.remove(d.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final folders = _byFolder;
    final names = folders.keys.toList()..sort();
    final indexedCount = _all.where((d) => _indexed.contains(d.id)).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Indexed documents'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _all.isEmpty
              ? const Center(child: Text('No documents added yet.'))
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '${_all.length} documents · $indexedCount indexed · '
                          '${folders.length} folder${folders.length == 1 ? '' : 's'}',
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.builder(
                        itemCount: names.length,
                        itemBuilder: (context, i) {
                          final folder = names[i];
                          final files = folders[folder]!;
                          final shortFolder =
                              folder.split('/').where((s) => s.isNotEmpty).isEmpty
                                  ? folder
                                  : folder.split('/').last;
                          return ExpansionTile(
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(shortFolder),
                            subtitle: Text('${files.length} file'
                                '${files.length == 1 ? '' : 's'}'),
                            children: [
                              for (final d in files) _fileTile(d),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _fileTile(DocumentInfo d) {
    final isIndexed = _indexed.contains(d.id);
    final isPdf =
        d.sourcePath != null && d.sourcePath!.toLowerCase().endsWith('.pdf');
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 24, right: 8),
      leading: Icon(
        isIndexed ? Icons.check_circle : Icons.hourglass_empty,
        size: 18,
        color: isIndexed ? Colors.green : Colors.grey,
      ),
      title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${(d.chars / 1000).toStringAsFixed(1)}k chars'
        '${isIndexed ? '' : ' · indexing…'}',
      ),
      onTap: isPdf ? () => _open(d) : null,
      trailing: PopupMenuButton<String>(
        onSelected: (v) => v == 'open' ? _open(d) : _remove(d),
        itemBuilder: (_) => [
          if (isPdf)
            const PopupMenuItem(value: 'open', child: Text('Open')),
          const PopupMenuItem(value: 'remove', child: Text('Remove')),
        ],
      ),
    );
  }
}
