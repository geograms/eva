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
    // Cached route polylines (flat [lat,lon,...] as JSON), keyed by
    // profile+rounded origin→destination — so a route computed once replays
    // offline over the cached tiles.
    db.execute('''
      CREATE TABLE IF NOT EXISTS routes(
        key TEXT PRIMARY KEY,
        poly TEXT NOT NULL,
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

  /// Cached route polyline JSON for [key], or null.
  String? getRoute(String key) {
    final rs = _db.select('SELECT poly FROM routes WHERE key=?;', [key]);
    return rs.isEmpty ? null : rs.first['poly'] as String;
  }

  void putRoute(String key, String polyJson, int whenMs) {
    _db.execute(
      'INSERT OR REPLACE INTO routes(key, poly, created_at) VALUES(?,?,?);',
      [key, polyJson, whenMs],
    );
  }

  void close() => _db.dispose();
}
