import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Per-document metadata for the e-reader: the LLM-assigned category hierarchy
/// (genre → subcategory + tags), whether it's favourited, and read history
/// (last opened, how many times). Kept in shared preferences as one JSON map
/// keyed by the document id, alongside the reading positions in [app_prefs].
class DocMeta {
  DocMeta({
    required this.id,
    this.category = '',
    this.subcategory = '',
    this.tags = const [],
    this.favorite = false,
    this.lastReadMs = 0,
    this.readCount = 0,
    this.categorized = false,
  });

  final String id;
  String category; // top-level "genre" (e.g. Fiction, Reference, Finance)
  String subcategory; // a more specific category within the genre
  List<String> tags;
  bool favorite;
  int lastReadMs;
  int readCount;
  bool categorized; // the LLM pass has run for this doc

  Map<String, dynamic> toJson() => {
        'category': category,
        'subcategory': subcategory,
        'tags': tags,
        'favorite': favorite,
        'lastReadMs': lastReadMs,
        'readCount': readCount,
        'categorized': categorized,
      };

  static DocMeta fromJson(String id, Map<String, dynamic> j) => DocMeta(
        id: id,
        category: (j['category'] as String?) ?? '',
        subcategory: (j['subcategory'] as String?) ?? '',
        tags: (j['tags'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        favorite: (j['favorite'] as bool?) ?? false,
        lastReadMs: (j['lastReadMs'] as num?)?.toInt() ?? 0,
        readCount: (j['readCount'] as num?)?.toInt() ?? 0,
        categorized: (j['categorized'] as bool?) ?? false,
      );
}

class DocMetaStore {
  static const String _key = 'doc_meta';

  static Future<Map<String, DocMeta>> all() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return {};
    try {
      final map = (jsonDecode(raw) as Map).cast<String, dynamic>();
      return {
        for (final e in map.entries)
          e.key: DocMeta.fromJson(e.key, (e.value as Map).cast<String, dynamic>())
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> _save(Map<String, DocMeta> map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode({for (final e in map.entries) e.key: e.value.toJson()}));
  }

  static Future<DocMeta> get(String id) async =>
      (await all())[id] ?? DocMeta(id: id);

  static Future<void> _update(String id, void Function(DocMeta m) change) async {
    final map = await all();
    final m = map[id] ?? DocMeta(id: id);
    change(m);
    map[id] = m;
    await _save(map);
  }

  /// Stores the LLM categorisation and marks the doc categorised (so the pass
  /// doesn't re-run it). Empty values still mark it done.
  static Future<void> setCategory(
          String id, String category, String subcategory, List<String> tags) =>
      _update(id, (m) {
        m.category = category;
        m.subcategory = subcategory;
        m.tags = tags;
        m.categorized = true;
      });

  static Future<void> toggleFavorite(String id) =>
      _update(id, (m) => m.favorite = !m.favorite);

  /// Records that a document was opened (recency + read count).
  static Future<void> markRead(String id, int nowMs) =>
      _update(id, (m) {
        m.lastReadMs = nowMs;
        m.readCount += 1;
      });
}
