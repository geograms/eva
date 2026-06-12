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
    return PhotoStore._(db);
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
