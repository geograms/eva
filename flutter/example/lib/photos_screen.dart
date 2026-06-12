import 'dart:io';

import 'package:flutter/material.dart';

import 'photo_service.dart';
import 'photo_store.dart';

/// Browses indexed photos as a thumbnail grid grouped by day, with type filters
/// (all / photos / screenshots). Thumbnails come from the cached JPEG blobs, so
/// rendering is instant. Tapping opens the full image.
class PhotosScreen extends StatefulWidget {
  const PhotosScreen({super.key, required this.photos, this.initialType});

  final PhotoService photos;
  final PhotoType? initialType;

  @override
  State<PhotosScreen> createState() => _PhotosScreenState();
}

class _PhotosScreenState extends State<PhotosScreen> {
  PhotoStore? _store;
  List<PhotoInfo> _items = const [];
  PhotoType? _filter;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _filter = widget.initialType;
    _load();
  }

  @override
  void dispose() {
    _store?.close();
    super.dispose();
  }

  Future<void> _load() async {
    _store ??= await widget.photos.openStore();
    final items = _store!.query(type: _filter, limit: 2000);
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  String _dayLabel(DateTime d) {
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
    final y = d.year == now.year ? '' : ' ${d.year}';
    return '${d.day} ${months[d.month - 1]}$y';
  }

  @override
  Widget build(BuildContext context) {
    // Group items (already newest-first) into day buckets, preserving order.
    final groups = <String, List<PhotoInfo>>{};
    for (final p in _items) {
      (groups[_dayLabel(p.takenAt)] ??= []).add(p);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Photos')),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                for (final f in [
                  (null, 'All'),
                  (PhotoType.photo, 'Photos'),
                  (PhotoType.screenshot, 'Screenshots'),
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(f.$2),
                      selected: _filter == f.$1,
                      onSelected: (_) {
                        setState(() {
                          _filter = f.$1;
                          _loading = true;
                        });
                        _load();
                      },
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                    ? const Center(child: Text('No photos indexed yet.'))
                    : CustomScrollView(
                        slivers: [
                          for (final entry in groups.entries) ...[
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                                child: Text(entry.key,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold)),
                              ),
                            ),
                            SliverGrid(
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 4,
                                mainAxisSpacing: 2,
                                crossAxisSpacing: 2,
                              ),
                              delegate: SliverChildBuilderDelegate(
                                (context, i) => _thumb(entry.value[i]),
                                childCount: entry.value.length,
                              ),
                            ),
                          ],
                          const SliverToBoxAdapter(child: SizedBox(height: 16)),
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  Widget _thumb(PhotoInfo p) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PhotoViewScreen(path: p.path),
      )),
      child: p.thumb == null
          ? Container(color: Colors.black12)
          : Image.memory(p.thumb!, fit: BoxFit.cover, gaplessPlayback: true),
    );
  }
}

/// Full-screen, zoomable view of one original image.
class PhotoViewScreen extends StatelessWidget {
  const PhotoViewScreen({super.key, required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    final exists = File(path).existsSync();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(path.split('/').last,
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Center(
        child: !exists
            ? const Text('Image not found.',
                style: TextStyle(color: Colors.white70))
            : InteractiveViewer(
                maxScale: 5,
                child: Image.file(File(path), fit: BoxFit.contain),
              ),
      ),
    );
  }
}
