import 'package:sqlite3/sqlite3.dart';

/// A retrieved chunk with its source for citation.
class ChunkHit {
  ChunkHit({
    required this.id,
    required this.docId,
    required this.docName,
    required this.page,
    required this.text,
  });
  final int id;
  final String docId;
  final String docName;
  final int? page;
  final String text;
}

/// SQLite-backed catalog for document retrieval: documents + chunks tables and
/// an FTS5 keyword index over chunk text. Lives inside the corpus pack
/// (`catalog.sqlite`) so it travels with the chosen storage location. The chunk
/// `id` is also the key used in the usearch vector index.
class CorpusDb {
  CorpusDb._(this._db);
  final Database _db;

  static CorpusDb open(String path) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode=WAL;');
    db.execute('''
      CREATE TABLE IF NOT EXISTS documents(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        chars INTEGER NOT NULL,
        added_at TEXT NOT NULL,
        indexed INTEGER NOT NULL DEFAULT 0
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS chunks(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        doc_id TEXT NOT NULL,
        page INTEGER,
        text TEXT NOT NULL
      );
    ''');
    // Migrate older packs that predate the `indexed` column.
    final cols = db
        .select('PRAGMA table_info(documents);')
        .map((r) => r['name'] as String)
        .toSet();
    if (!cols.contains('indexed')) {
      db.execute(
          'ALTER TABLE documents ADD COLUMN indexed INTEGER NOT NULL DEFAULT 0;');
    }
    db.execute('CREATE INDEX IF NOT EXISTS idx_chunks_doc ON chunks(doc_id);');
    db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts
        USING fts5(text, content='chunks', content_rowid='id');
    ''');
    // Keep the FTS index in sync with the chunks table.
    db.execute('''
      CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
        INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
      END;
    ''');
    db.execute('''
      CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
        INSERT INTO chunks_fts(chunks_fts, rowid, text)
          VALUES('delete', old.id, old.text);
      END;
    ''');
    return CorpusDb._(db);
  }

  void upsertDocument(String id, String name, int chars, String addedAt) {
    _db.execute(
      'INSERT OR REPLACE INTO documents(id, name, chars, added_at, indexed) '
      'VALUES(?,?,?,?,0);',
      [id, name, chars, addedAt],
    );
  }

  void markIndexed(String id) =>
      _db.execute('UPDATE documents SET indexed=1 WHERE id=?;', [id]);

  /// Marks every document as not-indexed (e.g. after the vector format changed)
  /// so the self-heal pass rebuilds them.
  void resetIndexed() => _db.execute('UPDATE documents SET indexed=0;');

  /// Ids of documents that finished indexing (used to skip/resume on open).
  Set<String> indexedDocIds() {
    final rs = _db.select('SELECT id FROM documents WHERE indexed=1;');
    return {for (final r in rs) r['id'] as String};
  }

  /// Inserts a chunk and returns its row id (used as the vector key).
  int insertChunk(String docId, int? page, String text) {
    _db.execute(
      'INSERT INTO chunks(doc_id, page, text) VALUES(?,?,?);',
      [docId, page, text],
    );
    return _db.lastInsertRowId;
  }

  void beginTransaction() => _db.execute('BEGIN;');
  void commit() => _db.execute('COMMIT;');

  /// FTS5 keyword search returning `(chunkId, bm25Score)` (lower bm25 = better),
  /// best first.
  List<MapEntry<int, double>> ftsSearch(String query, int limit) {
    final match = _toMatchQuery(query);
    if (match.isEmpty) return const [];
    try {
      final rs = _db.select(
        'SELECT rowid, bm25(chunks_fts) AS score FROM chunks_fts '
        "WHERE chunks_fts MATCH ? ORDER BY score LIMIT ?;",
        [match, limit],
      );
      return [
        for (final r in rs)
          MapEntry((r['rowid'] as int), (r['score'] as num).toDouble())
      ];
    } catch (_) {
      return const []; // malformed query → no keyword hits
    }
  }

  /// Builds a safe FTS5 MATCH query: each alphanumeric token OR-ed together.
  String _toMatchQuery(String query) {
    final tokens = RegExp(r'[\p{L}\p{N}]+', unicode: true)
        .allMatches(query)
        .map((m) => '"${m.group(0)}"')
        .toList();
    return tokens.join(' OR ');
  }

  List<ChunkHit> fetchChunks(List<int> ids) {
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(',');
    final rs = _db.select(
      'SELECT c.id, c.doc_id, c.page, c.text, d.name AS doc_name '
      'FROM chunks c LEFT JOIN documents d ON d.id = c.doc_id '
      'WHERE c.id IN ($placeholders);',
      ids,
    );
    final byId = {
      for (final r in rs)
        (r['id'] as int): ChunkHit(
          id: r['id'] as int,
          docId: r['doc_id'] as String,
          docName: (r['doc_name'] as String?) ?? r['doc_id'] as String,
          page: r['page'] as int?,
          text: r['text'] as String,
        )
    };
    // Preserve the caller's ranking order.
    return [for (final id in ids) if (byId[id] != null) byId[id]!];
  }

  void removeDocument(String docId) {
    _db.execute('DELETE FROM chunks WHERE doc_id = ?;', [docId]);
    _db.execute('DELETE FROM documents WHERE id = ?;', [docId]);
  }

  int get documentCount =>
      (_db.select('SELECT COUNT(*) AS n FROM documents;').first['n'] as int);
  int get chunkCount =>
      (_db.select('SELECT COUNT(*) AS n FROM chunks;').first['n'] as int);

  void close() => _db.dispose();
}
