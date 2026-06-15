import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The indexable categories tracked by the Indexer panel. The string values are
/// the persisted metric keys — don't rename without a migration.
enum IndexCategory { documents, music, photos, captions }

extension IndexCategoryLabel on IndexCategory {
  String get key => name;
  String get label => switch (this) {
        IndexCategory.documents => 'Documents',
        IndexCategory.music => 'Music',
        IndexCategory.photos => 'Photos',
        IndexCategory.captions => 'Photo captions',
      };
}

/// Cumulative time-spent + item-count per category, persisted across launches so
/// the Indexer panel can show "total time indexed" and estimate remaining time
/// from a lifetime average of milliseconds-per-item.
///
/// Time is sampled by [IndexCoordinator]: while a category is actively working
/// it periodically calls [record] with the elapsed wall-clock delta and the
/// number of items finished in that window.
class IndexMetrics {
  IndexMetrics._(this._prefs, this._elapsedMs, this._items);

  static const String _kKey = 'index_metrics_v1';

  final SharedPreferences _prefs;
  final Map<String, int> _elapsedMs; // category key -> cumulative ms
  final Map<String, int> _items; // category key -> cumulative items
  // Accumulate sub-second / sub-item deltas so frequent small samples aren't
  // lost to integer truncation before a persist.
  int _pendingPersist = 0;

  static Future<IndexMetrics> load() async {
    final prefs = await SharedPreferences.getInstance();
    final elapsed = <String, int>{};
    final items = <String, int>{};
    try {
      final raw = prefs.getString(_kKey);
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        for (final c in IndexCategory.values) {
          final r = j[c.key] as Map<String, dynamic>?;
          if (r != null) {
            elapsed[c.key] = (r['ms'] as num?)?.toInt() ?? 0;
            items[c.key] = (r['items'] as num?)?.toInt() ?? 0;
          }
        }
      }
    } catch (_) {/* corrupt prefs — start fresh */}
    return IndexMetrics._(prefs, elapsed, items);
  }

  /// Adds a working window for [cat]: [deltaMs] of wall-clock time during which
  /// [deltaItems] items finished. Persists every few seconds to limit writes.
  void record(IndexCategory cat, int deltaMs, int deltaItems) {
    if (deltaMs <= 0 && deltaItems <= 0) return;
    _elapsedMs[cat.key] = (_elapsedMs[cat.key] ?? 0) + (deltaMs < 0 ? 0 : deltaMs);
    _items[cat.key] = (_items[cat.key] ?? 0) + (deltaItems < 0 ? 0 : deltaItems);
    _pendingPersist += deltaMs.abs() + 1;
    if (_pendingPersist >= 5000) flush();
  }

  /// Lifetime average milliseconds per item for [cat], or null if we have no
  /// completed items yet (so an ETA can't be estimated).
  double? avgMsPerItem(IndexCategory cat) {
    final n = _items[cat.key] ?? 0;
    final ms = _elapsedMs[cat.key] ?? 0;
    if (n <= 0 || ms <= 0) return null;
    return ms / n;
  }

  Duration elapsed(IndexCategory cat) =>
      Duration(milliseconds: _elapsedMs[cat.key] ?? 0);

  int items(IndexCategory cat) => _items[cat.key] ?? 0;

  /// Total time spent indexing across every category.
  Duration totalElapsed() => Duration(
      milliseconds:
          _elapsedMs.values.fold<int>(0, (sum, ms) => sum + ms));

  void flush() {
    _pendingPersist = 0;
    final j = <String, dynamic>{};
    for (final c in IndexCategory.values) {
      j[c.key] = {
        'ms': _elapsedMs[c.key] ?? 0,
        'items': _items[c.key] ?? 0,
      };
    }
    // Fire-and-forget; the in-memory map is the source of truth this session.
    _prefs.setString(_kKey, jsonEncode(j));
  }
}
