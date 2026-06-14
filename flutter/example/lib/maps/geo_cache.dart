import 'package:sqlite3/sqlite3.dart';

/// A resolved place: coordinates + a display name.
class GeoResult {
  GeoResult(this.lat, this.lon, this.name);
  final double lat;
  final double lon;
  final String name;
}

/// SQLite cache of geocoding (and later routing) results, in the map data
/// folder — so a place looked up once resolves offline afterwards.
class GeoCache {
  GeoCache._(this._db);
  final Database _db;

  static GeoCache open(String path) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode=WAL;');
    db.execute('''
      CREATE TABLE IF NOT EXISTS geocodes(
        query TEXT PRIMARY KEY,
        lat REAL NOT NULL,
        lon REAL NOT NULL,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
    ''');
    return GeoCache._(db);
  }

  GeoResult? get(String query) {
    final rs = _db.select(
        'SELECT lat, lon, name FROM geocodes WHERE query=?;', [query]);
    if (rs.isEmpty) return null;
    final r = rs.first;
    return GeoResult(r['lat'] as double, r['lon'] as double, r['name'] as String);
  }

  void put(String query, GeoResult r, int whenMs) {
    _db.execute(
      'INSERT OR REPLACE INTO geocodes(query, lat, lon, name, created_at) '
      'VALUES(?,?,?,?,?);',
      [query, r.lat, r.lon, r.name, whenMs],
    );
  }

  void close() => _db.dispose();
}
