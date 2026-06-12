import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'corpus_db.dart';
import 'usearch.dart';

/// Matryoshka target dimension: nomic-embed supports truncating its 768-dim
/// output to a shorter prefix with little quality loss. Combined with usearch
/// int8 quantization this is ~6x smaller than f16/768 — the lever that makes a
/// very large archive fit on an SD card.
const int kTargetDim = 256;

/// On-disk vector format marker (bump when dim/quantization scheme changes so
/// old packs are rebuilt rather than mis-read). v3 = sharded layout.
const int kPackFormat = 3;

/// Max vectors per usearch shard. The active (newest) shard is held in RAM for
/// appends; once it fills it is sealed to disk and queried memory-mapped, so
/// peak RAM stays bounded no matter how large the archive grows.
const int kShardCapacity = 200000;

/// Embeds a batch of texts into unit-norm vectors (wired to the worker isolate).
typedef EmbedBatch = Future<List<Float32List>> Function(List<String> texts);

/// On-device hybrid retrieval index for documents: a usearch HNSW vector index
/// (semantic) fused with SQLite FTS5 (keyword/BM25) via Reciprocal Rank Fusion.
/// Both live inside the corpus pack so they travel with the storage location.
class RagIndex {
  RagIndex._(this._packDir, this._db, this._dim, this._shardCapacity);

  final String _packDir;
  final CorpusDb _db;
  int _dim;

  /// Max vectors per shard (defaults to [kShardCapacity]; lowered in tests to
  /// exercise shard rollover with little data).
  final int _shardCapacity;

  /// Sealed shards opened memory-mapped (read-only, search only).
  final List<UsearchIndex> _sealed = [];

  /// The newest shard, held in RAM so vectors can be appended to it.
  UsearchIndex? _active;

  /// Shard number of [_active] (its file is `vectors.<n>.usearch`).
  int _activeShard = 0;

  /// Reserved capacity of [_active], grown in blocks to avoid per-add reserves.
  int _activeReserved = 0;

  String _shardPath(int n) => '$_packDir/vectors.$n.usearch';
  String get _metaPath => '$_packDir/vectors.meta';

  int get documentCount => _db.documentCount;
  int get chunkCount => _db.chunkCount;
  int get vectorCount {
    var n = _active?.length ?? 0;
    for (final s in _sealed) {
      n += s.length;
    }
    return n;
  }

  /// Number of vector shards (sealed + active).
  int get shardCount => _active != null ? _activeShard + 1 : _sealed.length;
  bool get isEmpty => _db.chunkCount == 0;

  /// Vectors whose chunk was deleted (document removal leaves them in the
  /// shards as harmless orphans; they waste space and candidate slots).
  int get orphanVectorCount {
    final n = vectorCount - _db.chunkCount;
    return n > 0 ? n : 0;
  }

  /// Drops all vector shards and marks every document not-indexed, so the
  /// self-heal indexer rebuilds a compact index from the stored documents.
  /// Used when [orphanVectorCount] grows large after many deletions.
  Future<void> resetVectors() async {
    _disposeShards();
    _dim = 0;
    final dir = Directory(_packDir);
    if (await dir.exists()) {
      await for (final e in dir.list()) {
        final name = e.uri.pathSegments.last;
        if (e is File &&
            (RegExp(r'^vectors\.\d+\.usearch$').hasMatch(name) ||
                name == 'vectors.meta')) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    }
    _db.resetIndexed();
  }

  /// Opens (or creates) the pack at [packDir], loading the vector shards if any
  /// have already been built (sealed shards memory-mapped, the newest one in RAM
  /// so indexing can resume appending to it).
  static Future<RagIndex> open(String packDir,
      {int shardCapacity = kShardCapacity}) async {
    await Directory(packDir).create(recursive: true);
    final db = CorpusDb.open('$packDir/catalog.sqlite');
    final metaFile = File('$packDir/vectors.meta');
    var dim = 0;
    var shards = 0;
    if (await metaFile.exists()) {
      try {
        final meta = jsonDecode(await metaFile.readAsString())
            as Map<String, dynamic>;
        // Only reuse vectors written by the current format; otherwise force a
        // rebuild (self-heal re-indexes every document into the new layout).
        if ((meta['format'] as num?)?.toInt() == kPackFormat) {
          dim = (meta['dim'] as num).toInt();
          shards = (meta['shards'] as num?)?.toInt() ?? 0;
        } else {
          db.resetIndexed();
        }
      } catch (_) {
        dim = 0;
        shards = 0;
      }
    }
    final idx = RagIndex._(packDir, db, dim, shardCapacity);
    if (dim > 0 && shards > 0) {
      try {
        // Older, full shards: memory-mapped, read-only.
        for (var n = 0; n < shards - 1; n++) {
          final f = File(idx._shardPath(n));
          if (await f.exists()) {
            idx._sealed.add(UsearchIndex.viewFile(f.path, dim));
          }
        }
        // Newest shard: loaded into RAM so it can keep accepting appends.
        final lastPath = idx._shardPath(shards - 1);
        if (await File(lastPath).exists()) {
          idx._active = UsearchIndex.loadFile(lastPath, dim);
          idx._activeShard = shards - 1;
          idx._activeReserved = idx._active!.length;
        }
      } catch (_) {
        // A corrupt/partial pack: drop what we loaded and rebuild from scratch.
        idx._disposeShards();
        idx._dim = 0;
        db.resetIndexed();
      }
    }
    return idx;
  }

  void _disposeShards() {
    _active?.close();
    _active = null;
    for (final s in _sealed) {
      s.close();
    }
    _sealed.clear();
    _activeShard = 0;
    _activeReserved = 0;
  }

  /// Chunks [fullText], embeds each chunk and adds it to both indexes, then
  /// persists them. [onProgress] reports 0..1 over the embedding work.
  ///
  /// [shouldContinue] is polled between embedding batches; returning false stops
  /// early (e.g. to yield the embedder to a chat turn). The document is left
  /// not-yet-indexed so a later pass resumes it — addDocument is idempotent.
  Future<void> addDocument({
    required String docId,
    required String name,
    required String fullText,
    required EmbedBatch embed,
    void Function(double progress)? onProgress,
    Future<bool> Function()? shouldContinue,
  }) async {
    final chunks = _chunk(fullText);

    // Idempotent: clear any partial chunks from an interrupted earlier run,
    // then (re)insert the document marked not-yet-indexed.
    _db.removeDocument(docId);
    _db.upsertDocument(docId, name, fullText.length,
        DateTime.now().toIso8601String());
    if (chunks.isEmpty) {
      _db.markIndexed(docId); // nothing to embed (e.g. image-only PDF) — done
      return;
    }

    const batchSize = 16;
    var done = 0;
    for (var i = 0; i < chunks.length; i += batchSize) {
      final batch = chunks.sublist(i, (i + batchSize).clamp(0, chunks.length));
      final vectors = await embed([for (final c in batch) c.text]);

      // Lazily size the vector index from the first embedding (Matryoshka).
      if (_active == null) {
        _dim = math.min(kTargetDim, vectors.first.length);
        _activeShard = _sealed.length;
        _active = UsearchIndex.create(_dim);
        _activeReserved = 0;
      }

      _db.beginTransaction();
      for (var j = 0; j < batch.length; j++) {
        await _rollShardIfFull();
        _reserveActive(1);
        final id = _db.insertChunk(docId, batch[j].page, batch[j].text);
        _active!.add(id, _toDim(vectors[j], _dim));
      }
      _db.commit();

      done += batch.length;
      onProgress?.call(done / chunks.length);

      if (shouldContinue != null && !await shouldContinue()) {
        await _persist(); // keep what we built; resume rebuilds this doc later
        return;
      }
    }
    await _persist();
    _db.markIndexed(docId); // only after vectors are safely saved
  }

  /// Seals the active shard to disk (then memory-maps it) and starts a fresh one
  /// once it reaches [kShardCapacity], bounding peak RAM.
  Future<void> _rollShardIfFull() async {
    if (_active == null || _active!.length < _shardCapacity) return;
    final path = _shardPath(_activeShard);
    _active!.save(path);
    _active!.close();
    _sealed.add(UsearchIndex.viewFile(path, _dim));
    _activeShard += 1;
    _active = UsearchIndex.create(_dim);
    _activeReserved = 0;
    await _persistMeta();
  }

  /// Grows the active shard's reserved capacity in blocks (usearch needs
  /// capacity reserved before `add`).
  void _reserveActive(int additional) {
    final need = _active!.length + additional;
    if (need <= _activeReserved) return;
    final target = math.min(_shardCapacity,
        math.max(need, _activeReserved + 8192));
    _active!.reserve(target);
    _activeReserved = target;
  }

  /// Ids of documents that have finished indexing in this pack.
  Set<String> get indexedDocIds => _db.indexedDocIds();

  Future<void> _persist() async {
    if (_active == null) return;
    _active!.save(_shardPath(_activeShard));
    await _persistMeta();
  }

  Future<void> _persistMeta() async {
    await File(_metaPath).writeAsString(jsonEncode(
        {'dim': _dim, 'format': kPackFormat, 'shards': shardCount}));
  }

  /// Truncates [v] to [dim] (Matryoshka) and renormalizes to unit length so
  /// cosine distance stays meaningful.
  Float32List _toDim(Float32List v, int dim) {
    final d = v.length <= dim ? v.length : dim;
    final out = Float32List(d);
    var norm = 0.0;
    for (var i = 0; i < d; i++) {
      out[i] = v[i];
      norm += v[i] * v[i];
    }
    if (norm > 0) {
      final inv = 1.0 / math.sqrt(norm);
      for (var i = 0; i < d; i++) {
        out[i] *= inv;
      }
    }
    return out;
  }

  /// Hybrid retrieval: semantic (usearch) ⊕ keyword (FTS5), fused with RRF.
  /// Returns the top-[topK] chunks, best first.
  Future<List<ChunkHit>> query({
    required Float32List queryVec,
    required String queryText,
    int topK = 4,
    int candidates = 20,
  }) async {
    final ranks = <int, double>{};
    const rrfK = 60.0;
    const embWeight = 1.0;
    const ftsWeight = 0.5;

    // Semantic candidates across every shard, merged by distance. Truncate the
    // query to the pack's dimension to match the indexed vectors.
    if (_dim > 0 && vectorCount > 0) {
      final q = _toDim(queryVec, _dim);
      final merged = <UsearchHit>[];
      if (_active != null && _active!.length > 0) {
        merged.addAll(_active!.search(q, candidates));
      }
      for (final s in _sealed) {
        if (s.length > 0) merged.addAll(s.search(q, candidates));
      }
      merged.sort((a, b) => a.distance.compareTo(b.distance));
      final top = merged.take(candidates).toList();
      for (var r = 0; r < top.length; r++) {
        ranks.update(top[r].key, (v) => v + embWeight / (rrfK + r),
            ifAbsent: () => embWeight / (rrfK + r));
      }
    }
    // Keyword candidates (bm25-sorted, best first).
    final fts = _db.ftsSearch(queryText, candidates);
    for (var r = 0; r < fts.length; r++) {
      ranks.update(fts[r].key, (v) => v + ftsWeight / (rrfK + r),
          ifAbsent: () => ftsWeight / (rrfK + r));
    }
    if (ranks.isEmpty) return const [];

    final ordered = ranks.keys.toList()
      ..sort((a, b) => ranks[b]!.compareTo(ranks[a]!));
    final top = ordered.take(topK).toList();
    return _db.fetchChunks(top); // deleted chunks resolve to nothing → skipped
  }

  /// Removes a document's chunks from the catalog. Its vectors stay in the
  /// usearch index as orphans (filtered out at fetch); a future compaction can
  /// rebuild to reclaim space.
  void removeDocument(String docId) => _db.removeDocument(docId);

  void close() {
    _disposeShards();
    _db.close();
  }

  // ── Chunking ───────────────────────────────────────────────────────────────

  /// Splits text into overlapping chunks, tracking the current `[Page N]` marker
  /// (inserted during PDF extraction) for citations.
  List<({int? page, String text})> _chunk(String text,
      {int maxChars = 900, int overlapChars = 150}) {
    final out = <({int? page, String text})>[];
    final pageRe = RegExp(r'^\s*\[Page (\d+)\]\s*$');
    int? page;
    final buf = StringBuffer();

    void flush() {
      final s = buf.toString().trim();
      if (s.length >= 8) out.add((page: page, text: s));
      buf.clear();
    }

    for (final line in const LineSplitter().convert(text)) {
      final m = pageRe.firstMatch(line);
      if (m != null) {
        page = int.tryParse(m.group(1)!);
        continue;
      }
      if (buf.length + line.length + 1 > maxChars && buf.isNotEmpty) {
        final full = buf.toString();
        flush();
        // Carry an overlap tail into the next chunk for context continuity.
        if (overlapChars > 0 && full.length > overlapChars) {
          buf.write(full.substring(full.length - overlapChars));
          buf.write('\n');
        }
      }
      buf.write(line);
      buf.write('\n');
    }
    flush();
    return out;
  }
}
