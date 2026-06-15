import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_prefs.dart';
import 'background_indexer.dart';
import 'foreground_service.dart';
import 'index_metrics.dart';
import 'music_service.dart';
import 'photo_service.dart';

/// What a category is doing right now.
enum IndexStatus { idle, scanning, indexing, paused, done }

/// A point-in-time view of one category, consumed by the Indexer panel.
class IndexSnapshot {
  const IndexSnapshot({
    required this.category,
    required this.status,
    required this.done,
    required this.total,
    required this.pending,
    required this.currentName,
    required this.itemsPerSec,
    required this.eta,
    required this.elapsedTotal,
    required this.lifetimeItems,
  });

  final IndexCategory category;
  final IndexStatus status;
  final int done;
  final int? total; // null = open-ended (filesystem scan, total unknown)
  final int pending; // finite backlog (documents, captions); else 0
  final String? currentName;
  final double itemsPerSec;
  final Duration? eta; // null = not estimable
  final Duration elapsedTotal; // lifetime time spent on this category
  final int lifetimeItems;

  bool get isBusy => status == IndexStatus.scanning || status == IndexStatus.indexing;
}

/// A thin window into the photo-captioning state that lives in `main.dart`
/// (it owns the inference engine and the charging gate). Lets the coordinator
/// observe and drive captioning without reaching into the chat screen.
class CaptionBridge {
  CaptionBridge({
    required this.isCaptioning,
    required this.isCharging,
    required this.captionCounts,
    required this.captionNow,
    required this.pauseCaptioning,
  });

  final bool Function() isCaptioning;
  final bool Function() isCharging;
  // Cheap-ish DB counts (pending = uncaptioned, done = captioned).
  final Future<({int pending, int done})> Function() captionCounts;
  // Force a captioning pass regardless of the charging gate.
  final Future<void> Function() captionNow;
  final void Function() pauseCaptioning;
}

/// Single source of truth for the Indexer panel: aggregates the three indexers
/// + captioning, records timing metrics, estimates remaining time, and holds an
/// Android foreground service while anything is working so indexing survives the
/// app being backgrounded or the phone suspended.
class IndexCoordinator extends ChangeNotifier {
  IndexCoordinator({
    required this.metrics,
    required IndexingController? Function() docIndexer,
    required MusicIndexController? Function() musicIndexer,
    required PhotoIndexController? Function() photoIndexer,
    required this.bridge,
  })  : _docIndexerOf = docIndexer,
        _musicIndexerOf = musicIndexer,
        _photoIndexerOf = photoIndexer;

  final IndexMetrics metrics;
  final CaptionBridge bridge;
  final IndexingController? Function() _docIndexerOf;
  final MusicIndexController? Function() _musicIndexerOf;
  final PhotoIndexController? Function() _photoIndexerOf;

  static const String _fgsKey = 'index';

  Timer? _ticker;
  DateTime? _lastTick;
  bool _holdingFgs = false;
  bool _disposed = false;

  // Manual pause state (the music/photo controllers don't expose isPaused).
  final Set<IndexCategory> _paused = <IndexCategory>{};

  // Sampling state for rate + metrics.
  final Map<IndexCategory, int> _prevDone = {};
  final Map<IndexCategory, double> _rate = {};

  // Cached async-derived values, refreshed by the ticker.
  bool _musicScanDone = false;
  bool _photoScanDone = false;
  int _captionPending = 0;
  int _captionDone = 0;
  int _ticksSinceSlowRefresh = 0;
  final Set<Listenable> _listening = {};

  // ── Public surface ──────────────────────────────────────────────────────────

  Duration get totalElapsed => metrics.totalElapsed();
  bool get charging => bridge.isCharging();

  /// Kick the coordinator to (re)attach listeners and start the ticker. Call
  /// whenever indexing may have started (boot, attach document, settings close,
  /// Index now). The ticker self-stops once everything is idle.
  void kick() {
    if (_disposed) return;
    _attachListeners();
    _refreshSlow();
    _startTicker();
    notifyListeners();
  }

  IndexSnapshot snapshot(IndexCategory cat) {
    final paused = _paused.contains(cat);
    final active = _isActive(cat) && !paused;
    final (done, total, pending) = _counts(cat);
    final status = _statusFor(cat, paused: paused, active: active, pending: pending);
    return IndexSnapshot(
      category: cat,
      status: status,
      done: done,
      total: total,
      pending: pending,
      currentName: cat == IndexCategory.documents ? _docIndexerOf()?.currentName : null,
      itemsPerSec: _rate[cat] ?? 0,
      eta: _eta(cat, pending),
      elapsedTotal: metrics.elapsed(cat),
      lifetimeItems: metrics.items(cat),
    );
  }

  bool get anyActive =>
      IndexCategory.values.any((c) => _isActive(c) && !_paused.contains(c));

  // ── Controls ──────────────────────────────────────────────────────────────

  void pause(IndexCategory cat) {
    _paused.add(cat);
    switch (cat) {
      case IndexCategory.documents:
        _docIndexerOf()?.pause();
      case IndexCategory.music:
        _musicIndexerOf()?.pause();
      case IndexCategory.photos:
        _photoIndexerOf()?.pause();
      case IndexCategory.captions:
        bridge.pauseCaptioning();
    }
    notifyListeners();
  }

  void resume(IndexCategory cat) {
    _paused.remove(cat);
    switch (cat) {
      case IndexCategory.documents:
        _docIndexerOf()?.resume();
      case IndexCategory.music:
        _musicIndexerOf()?.resume();
      case IndexCategory.photos:
        _photoIndexerOf()?.resume();
      case IndexCategory.captions:
        unawaited(bridge.captionNow());
    }
    kick();
  }

  void pauseAll() {
    for (final c in IndexCategory.values) {
      pause(c);
    }
  }

  void resumeAll() {
    for (final c in const [
      IndexCategory.documents,
      IndexCategory.music,
      IndexCategory.photos,
    ]) {
      resume(c);
    }
  }

  /// Start (or restart) a single category — used after granting a permission
  /// or to kick off a category's first scan.
  void rescanCategory(IndexCategory cat) {
    _paused.remove(cat);
    switch (cat) {
      case IndexCategory.documents:
        final d = _docIndexerOf();
        d?.resume();
        unawaited(d?.run() ?? Future.value());
      case IndexCategory.music:
        unawaited(_musicIndexerOf()?.rescan() ?? Future.value());
      case IndexCategory.photos:
        unawaited(_photoIndexerOf()?.rescan() ?? Future.value());
      case IndexCategory.captions:
        unawaited(bridge.captionNow());
    }
    kick();
  }

  /// Force everything to (re)scan now, bypassing the captioning charging gate.
  Future<void> indexNow() async {
    _paused.clear();
    _docIndexerOf()?.resume();
    unawaited(_musicIndexerOf()?.rescan() ?? Future.value());
    unawaited(_photoIndexerOf()?.rescan() ?? Future.value());
    unawaited(bridge.captionNow());
    kick();
  }

  // ── Internals ───────────────────────────────────────────────────────────────

  void _attachListeners() {
    for (final l in [_docIndexerOf(), _musicIndexerOf(), _photoIndexerOf()]) {
      if (l != null && _listening.add(l)) l.addListener(_onChange);
    }
  }

  void _onChange() {
    if (_disposed) return;
    if (anyActive) _startTicker();
    notifyListeners();
  }

  void _startTicker() {
    if (_ticker != null || _disposed) return;
    _lastTick = DateTime.now();
    // Seed prevDone so the first tick doesn't count a gap as one window.
    for (final c in IndexCategory.values) {
      _prevDone[c] = _doneOf(c);
    }
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  Future<void> _tick() async {
    if (_disposed) return;
    final now = DateTime.now();
    final deltaMs = _lastTick == null ? 1000 : now.difference(_lastTick!).inMilliseconds;
    _lastTick = now;

    if (++_ticksSinceSlowRefresh >= 3) {
      _ticksSinceSlowRefresh = 0;
      await _refreshSlow();
    }

    for (final c in IndexCategory.values) {
      final done = _doneOf(c);
      final prev = _prevDone[c] ?? done;
      final deltaItems = done - prev;
      _prevDone[c] = done;
      final active = _isActive(c) && !_paused.contains(c);
      // Smooth the per-second rate (EMA); decay toward 0 when idle.
      final instant = deltaMs > 0 ? (deltaItems.clamp(0, 1 << 30)) * 1000 / deltaMs : 0.0;
      _rate[c] = active ? (0.6 * (_rate[c] ?? 0) + 0.4 * instant) : (_rate[c] ?? 0) * 0.5;
      if (active && deltaMs > 0) {
        metrics.record(c, deltaMs, deltaItems > 0 ? deltaItems : 0);
      }
    }

    _updateForegroundService();

    if (!anyActive) {
      // Idle: stop ticking and release the keep-alive until the next kick().
      _ticker?.cancel();
      _ticker = null;
      metrics.flush();
      await _releaseForegroundService();
    }
    notifyListeners();
  }

  Future<void> _refreshSlow() async {
    try {
      _musicScanDone = await loadMusicScanDone();
      _photoScanDone = await loadPhotoScanDone();
    } catch (_) {}
    try {
      final c = await bridge.captionCounts();
      _captionPending = c.pending;
      _captionDone = c.done;
    } catch (_) {}
  }

  void _updateForegroundService() {
    if (!anyActive) return;
    final parts = <String>[];
    for (final c in IndexCategory.values) {
      if (_isActive(c) && !_paused.contains(c)) {
        final (done, total, _) = _counts(c);
        parts.add(total != null && total > 0
            ? '${c.label.toLowerCase()} $done/$total'
            : '${c.label.toLowerCase()} $done');
      }
    }
    final label = 'Indexing — ${parts.join(' · ')}';
    if (!_holdingFgs) {
      _holdingFgs = true;
      unawaited(ForegroundService.acquire(_fgsKey, label));
    } else {
      ForegroundService.setLabel(_fgsKey, label);
    }
  }

  Future<void> _releaseForegroundService() async {
    if (!_holdingFgs) return;
    _holdingFgs = false;
    await ForegroundService.release(_fgsKey);
  }

  bool _isActive(IndexCategory cat) => switch (cat) {
        IndexCategory.documents => _docIndexerOf()?.isIndexing ?? false,
        IndexCategory.music => _musicIndexerOf()?.isIndexing ?? false,
        IndexCategory.photos => _photoIndexerOf()?.isIndexing ?? false,
        IndexCategory.captions => bridge.isCaptioning(),
      };

  int _doneOf(IndexCategory cat) => switch (cat) {
        IndexCategory.documents => _docIndexerOf()?.processed ?? 0,
        IndexCategory.music => _musicIndexerOf()?.scanned ?? 0,
        IndexCategory.photos => _photoIndexerOf()?.scanned ?? 0,
        IndexCategory.captions => _captionDone,
      };

  /// (done, total, pending) — total is null for open-ended scans.
  (int, int?, int) _counts(IndexCategory cat) {
    switch (cat) {
      case IndexCategory.documents:
        final d = _docIndexerOf();
        return (d?.processed ?? 0, d?.total ?? 0, d?.pending ?? 0);
      case IndexCategory.captions:
        return (_captionDone, _captionDone + _captionPending, _captionPending);
      case IndexCategory.music:
        return (_musicIndexerOf()?.scanned ?? 0, null, 0);
      case IndexCategory.photos:
        return (_photoIndexerOf()?.scanned ?? 0, null, 0);
    }
  }

  IndexStatus _statusFor(IndexCategory cat,
      {required bool paused, required bool active, required int pending}) {
    if (paused) return IndexStatus.paused;
    if (active) {
      return (cat == IndexCategory.music || cat == IndexCategory.photos)
          ? IndexStatus.scanning
          : IndexStatus.indexing;
    }
    switch (cat) {
      case IndexCategory.documents:
        return pending > 0 ? IndexStatus.idle : IndexStatus.done;
      case IndexCategory.captions:
        return pending > 0 ? IndexStatus.idle : IndexStatus.done;
      case IndexCategory.music:
        return _musicScanDone ? IndexStatus.done : IndexStatus.idle;
      case IndexCategory.photos:
        return _photoScanDone ? IndexStatus.done : IndexStatus.idle;
    }
  }

  Duration? _eta(IndexCategory cat, int pending) {
    if (pending <= 0) return null;
    if (cat != IndexCategory.documents && cat != IndexCategory.captions) {
      return null; // open-ended scans: total unknown, no honest ETA
    }
    final avg = metrics.avgMsPerItem(cat);
    if (avg == null) return null;
    return Duration(milliseconds: (pending * avg).round());
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    for (final l in _listening) {
      l.removeListener(_onChange);
    }
    _listening.clear();
    metrics.flush();
    unawaited(_releaseForegroundService());
    super.dispose();
  }
}
