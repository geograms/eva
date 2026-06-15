import 'dart:io';

import 'package:flutter/material.dart';

import 'map_viewer_screen.dart';
import 'maps/map_ref.dart';
import 'photo_service.dart';
import 'photo_store.dart';
import 'photos_screen.dart' show PhotoViewScreen;

/// Gallery browser: search photos by the LLM caption or user tags, filter by
/// category (type / tag), grouped by day. Tap a photo to view it full-screen
/// and add tags. Reuses the existing photo index ([PhotoStore]).
class ImagesTab extends StatefulWidget {
  const ImagesTab({super.key, required this.photos});

  final PhotoService photos;

  @override
  State<ImagesTab> createState() => _ImagesTabState();
}

class _ImagesTabState extends State<ImagesTab> {
  PhotoStore? _store;
  final TextEditingController _search = TextEditingController();
  List<PhotoInfo> _results = const [];
  List<({String tag, int count})> _tags = const [];
  // Active filter: a PhotoType, a tag string, "located", or null for "all".
  PhotoType? _typeFilter;
  String? _tagFilter;
  bool _locatedOnly = false;
  int _locatedCount = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    _store = await widget.photos.openStore();
    _reload();
  }

  void _reload() {
    final store = _store;
    if (store == null) return;
    final q = _search.text.trim();
    List<PhotoInfo> rows;
    if (q.isNotEmpty) {
      rows = store.searchAll(q, limit: 400);
    } else if (_locatedOnly) {
      rows = store.located(limit: 500);
    } else if (_tagFilter != null) {
      rows = store.byTag(_tagFilter!, limit: 500);
    } else {
      rows = store.query(type: _typeFilter, limit: 500);
    }
    setState(() {
      _results = rows;
      _tags = store.tagCounts();
      _locatedCount = store.locatedCount;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _store?.close();
    super.dispose();
  }

  /// Buckets the results by day for date headers.
  Map<String, List<PhotoInfo>> get _byDay {
    final map = <String, List<PhotoInfo>>{};
    for (final p in _results) {
      final d = p.takenAt;
      final key = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      (map[key] ??= []).add(p);
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final scheme = Theme.of(context).colorScheme;
    final days = _byDay;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            onChanged: (_) => _reload(),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              hintText: 'Search captions & tags…',
              border: const OutlineInputBorder(),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _search.clear();
                        _reload();
                      },
                    ),
            ),
          ),
        ),
        // Category / tag filter chips.
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _chip('All', _typeFilter == null && _tagFilter == null && !_locatedOnly, () {
                setState(() {
                  _typeFilter = null;
                  _tagFilter = null;
                  _locatedOnly = false;
                });
                _reload();
              }),
              if (_locatedCount > 0)
                _chip('📍 Located ($_locatedCount)', _locatedOnly, () {
                  setState(() {
                    _locatedOnly = true;
                    _typeFilter = null;
                    _tagFilter = null;
                    _search.clear();
                  });
                  _reload();
                }),
              for (final t in const [
                ('Photos', PhotoType.photo),
                ('Screenshots', PhotoType.screenshot),
                ('Memes', PhotoType.meme),
              ])
                _chip(t.$1, _typeFilter == t.$2 && _search.text.isEmpty && !_locatedOnly, () {
                  setState(() {
                    _typeFilter = t.$2;
                    _tagFilter = null;
                    _locatedOnly = false;
                    _search.clear();
                  });
                  _reload();
                }),
              for (final tag in _tags)
                _chip('#${tag.tag} (${tag.count})', _tagFilter == tag.tag, () {
                  setState(() {
                    _tagFilter = tag.tag;
                    _typeFilter = null;
                    _locatedOnly = false;
                    _search.clear();
                  });
                  _reload();
                }),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _results.isEmpty
              ? Center(
                  child: Text(
                    _search.text.isNotEmpty
                        ? 'No photos match "${_search.text}".'
                        : 'No photos yet. Index your gallery in Settings → Photos.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    for (final entry in days.entries) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                        child: Text(_prettyDay(entry.value.first.takenAt),
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 3,
                          crossAxisSpacing: 3,
                        ),
                        itemCount: entry.value.length,
                        itemBuilder: (context, i) => _thumb(entry.value[i]),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => onTap(),
        ),
      );

  Widget _thumb(PhotoInfo p) => GestureDetector(
        onTap: () => _openPhoto(p),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: p.thumb == null
              ? Container(color: Colors.black12)
              : Image.memory(p.thumb!, fit: BoxFit.cover, gaplessPlayback: true),
        ),
      );

  Future<void> _openPhoto(PhotoInfo p) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _PhotoDetail(
        photo: p,
        onSaveTags: (tags) {
          _store?.setTags(p.id, tags);
        },
      ),
    ));
    _reload(); // tags may have changed
  }

  String _prettyDay(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }
}

/// Full photo with its caption and an editable set of tags.
class _PhotoDetail extends StatefulWidget {
  const _PhotoDetail({required this.photo, required this.onSaveTags});
  final PhotoInfo photo;
  final void Function(List<String> tags) onSaveTags;

  @override
  State<_PhotoDetail> createState() => _PhotoDetailState();
}

class _PhotoDetailState extends State<_PhotoDetail> {
  late final List<String> _tags = List.of(widget.photo.tags);
  final TextEditingController _newTag = TextEditingController();

  @override
  void dispose() {
    _newTag.dispose();
    super.dispose();
  }

  void _addTag() {
    final t = _newTag.text.trim();
    if (t.isEmpty || _tags.contains(t)) return;
    setState(() {
      _tags.add(t);
      _newTag.clear();
    });
    widget.onSaveTags(_tags);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.photo;
    return Scaffold(
      appBar: AppBar(title: Text(p.path.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: ListView(
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PhotoViewScreen(path: p.path),
            )),
            child: File(p.path).existsSync()
                ? Image.file(File(p.path), fit: BoxFit.contain)
                : Container(
                    height: 240,
                    color: Colors.black12,
                    child: const Center(child: Icon(Icons.broken_image)),
                  ),
          ),
          if ((p.caption ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text('“${p.caption}”',
                  style: const TextStyle(fontStyle: FontStyle.italic)),
            ),
          if (p.hasLocation)
            ListTile(
              leading: const Icon(Icons.place_outlined),
              title: Text(
                  '${p.lat!.toStringAsFixed(5)}, ${p.lon!.toStringAsFixed(5)}'),
              subtitle: const Text('Taken here'),
              trailing: const Icon(Icons.map_outlined),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => MapViewerScreen(
                  title: 'Photo location',
                  ref: MapRef(lat: p.lat!, lon: p.lon!, zoom: 15, label: 'Photo'),
                ),
              )),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
            child: Text('Tags', style: Theme.of(context).textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final t in _tags)
                  Chip(
                    label: Text(t),
                    onDeleted: () {
                      setState(() => _tags.remove(t));
                      widget.onSaveTags(_tags);
                    },
                  ),
                if (_tags.isEmpty)
                  const Text('No tags yet — add one below.',
                      style: TextStyle(color: Colors.grey)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newTag,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _addTag(),
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'Add a tag (e.g. family, receipts)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _addTag, child: const Text('Add')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
