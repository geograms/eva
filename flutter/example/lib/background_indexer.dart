import 'dart:async';

import 'package:flutter/foundation.dart';

import 'document_service.dart';
import 'rag_index.dart';

/// Drives document indexing off the UI's critical path.
///
/// Instead of blocking the user behind a modal while a (potentially huge)
/// backlog is embedded, this processes not-yet-indexed documents one at a time
/// in the background: the app stays usable and queries run against whatever is
/// already indexed. It is:
///  - throttled — yields briefly between documents to spare CPU/battery;
///  - pausable — [pause] lets a chat turn use the embedder without contention,
///    stopping at the next batch boundary; [resume] picks up where it left off;
///  - resumable — progress is persisted per document (idempotent re-runs), so a
///    crash or app kill mid-backlog simply continues next launch.
///
/// Progress is observable via [ChangeNotifier] for a lightweight status banner.
class IndexingController extends ChangeNotifier {
  IndexingController(this._docs, this._embed);

  final DocumentService _docs;
  final EmbedBatch _embed;

  RagIndex? _rag;
  bool _running = false;
  bool _paused = false;
  int _processed = 0;
  int _total = 0;
  String? _current;
  Object? _lastError;
  Completer<void>? _idle;
  // Documents that errored this session. They are skipped (deferred to the
  // bottom) so one bad document never blocks the rest; cleared on rebind, so a
  // fresh launch retries them once.
  final Set<String> _failed = {};

  /// Whether the backlog is actively being worked through.
  bool get isIndexing => _running;
  bool get isPaused => _paused;
  int get processed => _processed;
  int get total => _total;

  /// Documents still waiting to be indexed.
  int get pending => (_total - _processed).clamp(0, _total);
  String? get currentName => _current;
  Object? get lastError => _lastError;

  /// How many documents were skipped this session because indexing them failed.
  int get failedCount => _failed.length;

  /// Binds the controller to the currently-open pack. Call on (re)open. Clears
  /// the per-session failed set so previously-failed documents are retried once.
  void bind(RagIndex rag) {
    _rag = rag;
    _failed.clear();
  }

  /// Requests a pause at the next batch boundary (does not interrupt mid-batch).
  void pause() {
    _paused = true;
  }

  /// Clears a pause and restarts the worker if there is anything pending.
  void resume() {
    if (!_paused) return;
    _paused = false;
    unawaited(run());
  }

  /// Pauses and waits until any in-flight document finishes, so the caller can
  /// safely close/replace the bound pack without the worker touching it.
  Future<void> stop() async {
    _paused = true;
    if (!_running) return;
    _idle ??= Completer<void>();
    await _idle!.future;
  }

  /// Processes the backlog until it is empty or paused. Safe to call repeatedly
  /// — overlapping calls coalesce into the one already running.
  Future<void> run() async {
    if (_running || _paused || _rag == null) return;
    _running = true;
    _lastError = null;
    try {
      while (!_paused) {
        final rag = _rag;
        if (rag == null) break;
        final indexed = rag.indexedDocIds;
        final docs = await _docs.list();
        // Skip already-indexed AND already-failed docs — failures are deferred
        // so they never block the documents behind them.
        final pendingDocs = docs
            .where((d) => !indexed.contains(d.id) && !_failed.contains(d.id))
            .toList();
        _total = docs.length;
        _processed = docs.length - pendingDocs.length;
        if (pendingDocs.isEmpty) break;

        final d = pendingDocs.first;
        _current = d.name;
        notifyListeners();

        // A single bad document (bad text, embedder hiccup, FFI error) must not
        // stop the run — record it and move on.
        try {
          final text = await _docs.readText(d.id);
          await rag.addDocument(
            docId: d.id,
            name: d.name,
            fullText: text,
            embed: _embed,
            shouldContinue: () async => !_paused,
          );
        } catch (e) {
          _failed.add(d.id);
          _lastError = e;
        }

        _current = null;
        notifyListeners();
        // Throttle: hand the event loop back between documents.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    } catch (e) {
      _lastError = e; // unexpected loop-level failure (not a per-doc error)
    } finally {
      _running = false;
      _idle?.complete();
      _idle = null;
      notifyListeners();
    }
  }
}
