import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

/// Photo type classification (cheap heuristics for now; "meme" is filled later
/// by the on-device vision pass).
enum PhotoType { photo, screenshot, image, meme }

PhotoType photoTypeFromString(String s) =>
    PhotoType.values.firstWhere((t) => t.name == s, orElse: () => PhotoType.image);

/// One indexed photo. The thumbnail is a small cached JPEG so the UI never
/// re-decodes the original.
class PhotoInfo {
  PhotoInfo({
    required this.id,
    required this.path,
    required this.takenAt,
    required this.width,
    required this.height,
    required this.size,
    required this.bucket,
    required this.type,
    this.thumb,
    this.caption,
  });
  final int id;
  final String path;
  final DateTime takenAt;
  final int width;
  final int height;
  final int size;
  final String bucket; // source folder name
  final PhotoType type;
  final Uint8List? thumb; // cached JPEG thumbnail
  final String? caption; // filled by the later ML pass
}

/// SQLite-backed photo metadata + cached thumbnails. Lives in the corpus pack so
/// it travels with the chosen storage location. Thumbnails are stored as JPEG
/// blobs to avoid regenerating them on every browse/query.
class PhotoStore {
  PhotoStore._(this._db);
  final Database _db;

  static PhotoStore open(String path) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode=WAL;');
    db.execute('''
      CREATE TABLE IF NOT EXISTS photos(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT NOT NULL UNIQUE,
        taken_at INTEGER NOT NULL,   -- epoch ms
        width INTEGER NOT NULL DEFAULT 0,
        height INTEGER NOT NULL DEFAULT 0,
        size INTEGER NOT NULL DEFAULT 0,
        bucket TEXT NOT NULL DEFAULT '',
        type TEXT NOT NULL DEFAULT 'image',
        thumb BLOB,                  -- cached JPEG thumbnail
        caption TEXT,                -- filled by the vision pass (later)
        captioned INTEGER NOT NULL DEFAULT 0
      );
    ''');
    db.execute('CREATE INDEX IF NOT EXISTS idx_photos_taken ON photos(taken_at);');
    db.execute('CREATE INDEX IF NOT EXISTS idx_photos_type ON photos(type);');
    // Full-text index over captions (the vision pass writes them), so content
    // search ("beach", "dog", "receipt") matches on the photo id (= rowid).
    db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS captions_fts
        USING fts5(caption, content='photos', content_rowid='id');
    ''');
    return PhotoStore._(db);
  }

  /// Photos still needing a vision caption, newest-first, optionally scoped to a
  /// time range (for on-demand captioning of a queried period).
  List<PhotoInfo> pendingCaption({DateTime? from, DateTime? to, int limit = 8}) {
    final where = <String>['captioned = 0'];
    final args = <Object?>[];
    if (from != null) {
      where.add('taken_at >= ?');
      args.add(from.millisecondsSinceEpoch);
    }
    if (to != null) {
      where.add('taken_at <= ?');
      args.add(to.millisecondsSinceEpoch);
    }
    final rs = _db.select(
      'SELECT id, path, taken_at, width, height, size, bucket, type, '
      'thumb, caption FROM photos WHERE ${where.join(' AND ')} '
      'ORDER BY taken_at DESC LIMIT ?;',
      [...args, limit],
    );
    return [for (final r in rs) _row(r)];
  }

  int get captionPendingCount =>
      _db.select('SELECT COUNT(*) AS n FROM photos WHERE captioned=0;')
          .first['n'] as int;

  /// Whether any photo in [from]..[to] still lacks a caption.
  bool hasUncaptionedInRange(DateTime? from, DateTime? to) {
    final where = <String>['captioned = 0'];
    final args = <Object?>[];
    if (from != null) {
      where.add('taken_at >= ?');
      args.add(from.millisecondsSinceEpoch);
    }
    if (to != null) {
      where.add('taken_at <= ?');
      args.add(to.millisecondsSinceEpoch);
    }
    final n = _db.select(
        'SELECT COUNT(*) AS n FROM photos WHERE ${where.join(' AND ')} LIMIT 1;',
        args).first['n'] as int;
    return n > 0;
  }
  int get captionedCount =>
      _db.select('SELECT COUNT(*) AS n FROM photos WHERE captioned=1;')
          .first['n'] as int;

  /// Stores a caption for a photo and keeps the FTS index in sync.
  void setCaption(int id, String caption, {PhotoType? type}) {
    _db.execute(
      'UPDATE photos SET caption=?, captioned=1${type != null ? ', type=?' : ''} '
      'WHERE id=?;',
      type != null ? [caption, type.name, id] : [caption, id],
    );
    _db.execute('INSERT INTO captions_fts(rowid, caption) VALUES(?,?);',
        [id, caption]);
  }

  /// Content search over captions (keyword). Returns matching photos, best
  /// first, optionally filtered by time/type.
  List<PhotoInfo> searchCaptions(String query,
      {DateTime? from, DateTime? to, PhotoType? type, int limit = 60}) {
    final tokens = RegExp(r'[\p{L}\p{N}]+', unicode: true)
        .allMatches(query)
        .map((m) => '"${m.group(0)}"')
        .toList();
    if (tokens.isEmpty) return const [];
    final match = tokens.join(' OR ');
    final extra = <String>[];
    final args = <Object?>[match];
    if (from != null) {
      extra.add('p.taken_at >= ?');
      args.add(from.millisecondsSinceEpoch);
    }
    if (to != null) {
      extra.add('p.taken_at <= ?');
      args.add(to.millisecondsSinceEpoch);
    }
    if (type != null) {
      extra.add('p.type = ?');
      args.add(type.name);
    }
    try {
      final rs = _db.select(
        'SELECT p.id, p.path, p.taken_at, p.width, p.height, p.size, p.bucket, '
        'p.type, p.thumb, p.caption FROM captions_fts f '
        'JOIN photos p ON p.id = f.rowid '
        'WHERE captions_fts MATCH ?'
        '${extra.isEmpty ? '' : ' AND ${extra.join(' AND ')}'} '
        'ORDER BY bm25(captions_fts) LIMIT ?;',
        [...args, limit],
      );
      return [for (final r in rs) _row(r)];
    } catch (_) {
      return const [];
    }
  }

  /// Paths already indexed (to skip on re-scan).
  Set<String> indexedPaths() {
    final rs = _db.select('SELECT path FROM photos;');
    return {for (final r in rs) r['path'] as String};
  }

  int get count =>
      _db.select('SELECT COUNT(*) AS n FROM photos;').first['n'] as int;

  void upsert(PhotoInfo p) {
    _db.execute(
      'INSERT OR REPLACE INTO photos'
      '(path, taken_at, width, height, size, bucket, type, thumb) '
      'VALUES(?,?,?,?,?,?,?,?);',
      [
        p.path,
        p.takenAt.millisecondsSinceEpoch,
        p.width,
        p.height,
        p.size,
        p.bucket,
        p.type.name,
        p.thumb,
      ],
    );
  }

  /// Queries photos with optional time range / type filters, newest first.
  List<PhotoInfo> query({
    DateTime? from,
    DateTime? to,
    PhotoType? type,
    int limit = 500,
    bool withThumb = true,
  }) {
    final where = <String>[];
    final args = <Object?>[];
    if (from != null) {
      where.add('taken_at >= ?');
      args.add(from.millisecondsSinceEpoch);
    }
    if (to != null) {
      where.add('taken_at <= ?');
      args.add(to.millisecondsSinceEpoch);
    }
    if (type != null) {
      where.add('type = ?');
      args.add(type.name);
    }
    final cols = withThumb
        ? 'id, path, taken_at, width, height, size, bucket, type, thumb, caption'
        : 'id, path, taken_at, width, height, size, bucket, type, NULL AS thumb, caption';
    final sql = 'SELECT $cols FROM photos'
        '${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'}'
        ' ORDER BY taken_at DESC LIMIT ?;';
    final rs = _db.select(sql, [...args, limit]);
    return [for (final r in rs) _row(r)];
  }

  PhotoInfo _row(Row r) => PhotoInfo(
        id: r['id'] as int,
        path: r['path'] as String,
        takenAt: DateTime.fromMillisecondsSinceEpoch(r['taken_at'] as int),
        width: r['width'] as int,
        height: r['height'] as int,
        size: r['size'] as int,
        bucket: r['bucket'] as String,
        type: photoTypeFromString(r['type'] as String),
        thumb: r['thumb'] as Uint8List?,
        caption: r['caption'] as String?,
      );

  void removeMissing(bool Function(String path) exists) {
    final rs = _db.select('SELECT id, path FROM photos;');
    for (final r in rs) {
      if (!exists(r['path'] as String)) {
        _db.execute('DELETE FROM photos WHERE id=?;', [r['id']]);
      }
    }
  }

  void close() => _db.dispose();
}
