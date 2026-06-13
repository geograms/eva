import 'package:sqlite3/sqlite3.dart';

/// One indexed audio track. Tag fields come from the file's embedded metadata
/// (ID3 / MP4 / Vorbis); [lyrics] and [genre] may be filled/enriched later by
/// the online lyrics pass.
class TrackInfo {
  TrackInfo({
    required this.id,
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    required this.genre,
    required this.year,
    required this.trackNo,
    required this.durationMs,
    required this.size,
    required this.bucket,
    this.lyrics,
    this.lyricsFetched = false,
    this.playCount = 0,
  });

  final int id;
  final String path;
  final String title; // falls back to the filename when untagged
  final String artist;
  final String album;
  final String genre;
  final int year; // 0 = unknown
  final int trackNo; // 0 = unknown
  final int durationMs; // 0 = unknown
  final int size;
  final String bucket; // source folder name
  final String? lyrics;
  final bool lyricsFetched;
  final int playCount; // times this track has been played in-app

  /// A human label for chat results, e.g. "Artist — Title".
  String get label {
    final a = artist.isNotEmpty ? artist : 'Unknown artist';
    final t = title.isNotEmpty ? title : path.split('/').last;
    return '$a — $t';
  }
}

/// SQLite-backed music catalog + full-text search. Lives in the corpus pack so
/// it travels with the chosen storage location. Tags are extracted once on
/// scan; the FTS index over title/artist/album/genre/lyrics powers chat queries
/// like "songs by X", "techno tracks", or a lyric line.
class MusicStore {
  MusicStore._(this._db);
  final Database _db;

  static MusicStore open(String path) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode=WAL;');
    db.execute('''
      CREATE TABLE IF NOT EXISTS tracks(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT NOT NULL UNIQUE,
        title TEXT NOT NULL DEFAULT '',
        artist TEXT NOT NULL DEFAULT '',
        album TEXT NOT NULL DEFAULT '',
        genre TEXT NOT NULL DEFAULT '',
        year INTEGER NOT NULL DEFAULT 0,
        track_no INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        size INTEGER NOT NULL DEFAULT 0,
        bucket TEXT NOT NULL DEFAULT '',
        lyrics TEXT,
        lyrics_fetched INTEGER NOT NULL DEFAULT 0,
        play_count INTEGER NOT NULL DEFAULT 0,
        last_played INTEGER NOT NULL DEFAULT 0
      );
    ''');
    // Migrate older catalogs (created before play tracking) in place.
    for (final col in const [
      'play_count INTEGER NOT NULL DEFAULT 0',
      'last_played INTEGER NOT NULL DEFAULT 0',
    ]) {
      try {
        db.execute('ALTER TABLE tracks ADD COLUMN $col;');
      } catch (_) {
        // column already exists
      }
    }
    db.execute('CREATE INDEX IF NOT EXISTS idx_tracks_artist ON tracks(artist);');
    db.execute('CREATE INDEX IF NOT EXISTS idx_tracks_genre ON tracks(genre);');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_tracks_plays ON tracks(play_count);');
    // One FTS row per track over everything an LLM might match on. Self-stored
    // (not external-content) so we can safely DELETE/re-insert a row when its
    // lyrics arrive later. rowid is kept equal to tracks.id for the JOIN.
    db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS tracks_fts
        USING fts5(title, artist, album, genre, lyrics);
    ''');
    return MusicStore._(db);
  }

  /// Paths already indexed (to skip on re-scan).
  Set<String> indexedPaths() {
    final rs = _db.select('SELECT path FROM tracks;');
    return {for (final r in rs) r['path'] as String};
  }

  int get count =>
      _db.select('SELECT COUNT(*) AS n FROM tracks;').first['n'] as int;

  int get artistCount => _db
      .select("SELECT COUNT(DISTINCT artist) AS n FROM tracks WHERE artist<>'';")
      .first['n'] as int;

  void upsert(TrackInfo t) {
    _db.execute(
      'INSERT OR REPLACE INTO tracks'
      '(path, title, artist, album, genre, year, track_no, duration_ms, '
      'size, bucket) VALUES(?,?,?,?,?,?,?,?,?,?);',
      [
        t.path,
        t.title,
        t.artist,
        t.album,
        t.genre,
        t.year,
        t.trackNo,
        t.durationMs,
        t.size,
        t.bucket,
      ],
    );
    final id = _db.select('SELECT id FROM tracks WHERE path=?;', [t.path])
        .first['id'] as int;
    _reindex(id, t.title, t.artist, t.album, t.genre, t.lyrics);
    // If the file itself carried embedded lyrics, mark them fetched.
    if ((t.lyrics ?? '').trim().isNotEmpty) {
      _db.execute('UPDATE tracks SET lyrics=?, lyrics_fetched=1 WHERE id=?;',
          [t.lyrics, id]);
    }
  }

  void _reindex(int id, String title, String artist, String album,
      String genre, String? lyrics) {
    _db.execute('DELETE FROM tracks_fts WHERE rowid=?;', [id]);
    _db.execute(
      'INSERT INTO tracks_fts(rowid, title, artist, album, genre, lyrics) '
      'VALUES(?,?,?,?,?,?);',
      [id, title, artist, album, genre, lyrics ?? ''],
    );
  }

  /// Tracks still needing an online lyrics lookup (have an artist+title, no
  /// lyrics yet). Oldest rowid first so we make steady progress.
  List<TrackInfo> pendingLyrics({int limit = 8}) {
    final rs = _db.select(
      'SELECT * FROM tracks '
      "WHERE lyrics_fetched=0 AND artist<>'' AND title<>'' "
      'ORDER BY id LIMIT ?;',
      [limit],
    );
    return [for (final r in rs) _row(r)];
  }

  int get lyricsPendingCount => _db
      .select("SELECT COUNT(*) AS n FROM tracks "
          "WHERE lyrics_fetched=0 AND artist<>'' AND title<>'';")
      .first['n'] as int;

  /// Records the result of a lyrics lookup. [lyrics] may be null/empty when the
  /// service had nothing — we still set lyrics_fetched so we don't retry it
  /// forever. An optional [genre] refines an untagged track.
  void setLyrics(int id, String? lyrics, {String? genre}) {
    final hasGenre = genre != null && genre.trim().isNotEmpty;
    _db.execute(
      'UPDATE tracks SET lyrics=?, lyrics_fetched=1'
      '${hasGenre ? ', genre=?' : ''} WHERE id=?;',
      hasGenre ? [lyrics, genre, id] : [lyrics, id],
    );
    final r = _db.select(
        'SELECT title, artist, album, genre FROM tracks WHERE id=?;', [id]);
    if (r.isNotEmpty) {
      final row = r.first;
      _reindex(id, row['title'] as String, row['artist'] as String,
          row['album'] as String, row['genre'] as String, lyrics);
    }
  }

  /// Full-text search across tags + lyrics, best match first.
  List<TrackInfo> search(String query, {int limit = 40}) {
    final tokens = RegExp(r'[\p{L}\p{N}]+', unicode: true)
        .allMatches(query)
        .map((m) => '"${m.group(0)}"')
        .toList();
    if (tokens.isEmpty) return const [];
    final match = tokens.join(' OR ');
    try {
      final rs = _db.select(
        'SELECT t.* FROM tracks_fts f JOIN tracks t ON t.id = f.rowid '
        'WHERE tracks_fts MATCH ? ORDER BY bm25(tracks_fts) LIMIT ?;',
        [match, limit],
      );
      return [for (final r in rs) _row(r)];
    } catch (_) {
      return const [];
    }
  }

  /// All tracks by an artist (case-insensitive substring), album/track order.
  List<TrackInfo> byArtist(String artist, {int limit = 100}) {
    final rs = _db.select(
      'SELECT * FROM tracks WHERE LOWER(artist) LIKE ? '
      'ORDER BY album, track_no, title LIMIT ?;',
      ['%${artist.toLowerCase()}%', limit],
    );
    return [for (final r in rs) _row(r)];
  }

  /// Records that a track was played: bumps its play count and recency. Used to
  /// surface the user's favourites first when they just ask to "play music".
  void recordPlay(int id, int whenMs) {
    _db.execute(
      'UPDATE tracks SET play_count = play_count + 1, last_played = ? '
      'WHERE id = ?;',
      [whenMs, id],
    );
  }

  /// Most-played tracks first (favourites), then most-recently played. Tracks
  /// never played fall to the end. Used for a bare "play music" request.
  /// Before any play history exists, properly-tagged tracks (with an artist)
  /// lead so we don't open with stray voice notes / untagged clips.
  List<TrackInfo> topPlayed({int limit = 100}) {
    final rs = _db.select(
      'SELECT * FROM tracks '
      'ORDER BY play_count DESC, last_played DESC, '
      "(CASE WHEN artist='' THEN 1 ELSE 0 END), artist, album, track_no "
      'LIMIT ?;',
      [limit],
    );
    return [for (final r in rs) _row(r)];
  }

  /// Resolves a "play …" request into an ordered queue of tracks.
  /// - empty/generic query → favourites first (then the rest), shuffled feel is
  ///   left to the caller;
  /// - otherwise: exact-ish artist match wins (whole albums in order), else a
  ///   full-text match across title/album/genre/lyrics.
  /// Favourites are used as a tiebreaker so often-played tracks lead.
  List<TrackInfo> resolvePlay(String query, {int limit = 200}) {
    final q = query.trim();
    if (q.isEmpty) return topPlayed(limit: limit);
    // Artist match (most common: "play Radiohead"), ordered by favourites then
    // album/track so a coherent set plays.
    final artist = _db.select(
      'SELECT * FROM tracks WHERE LOWER(artist) LIKE ? '
      'ORDER BY play_count DESC, album, track_no, title LIMIT ?;',
      ['%${q.toLowerCase()}%', limit],
    );
    if (artist.isNotEmpty) return [for (final r in artist) _row(r)];
    // Fall back to full-text (song title, genre, a lyric line…).
    final hits = search(q, limit: limit);
    if (hits.isNotEmpty) return hits;
    return const [];
  }

  /// Recent/representative tracks for browsing.
  List<TrackInfo> query({int limit = 500}) {
    final rs = _db.select(
        'SELECT * FROM tracks ORDER BY artist, album, track_no, title LIMIT ?;',
        [limit]);
    return [for (final r in rs) _row(r)];
  }

  TrackInfo _row(Row r) => TrackInfo(
        id: r['id'] as int,
        path: r['path'] as String,
        title: r['title'] as String,
        artist: r['artist'] as String,
        album: r['album'] as String,
        genre: r['genre'] as String,
        year: r['year'] as int,
        trackNo: r['track_no'] as int,
        durationMs: r['duration_ms'] as int,
        size: r['size'] as int,
        bucket: r['bucket'] as String,
        lyrics: r['lyrics'] as String?,
        lyricsFetched: (r['lyrics_fetched'] as int) == 1,
        playCount: (r['play_count'] as int?) ?? 0,
      );

  /// Deletes catalogued tracks for which [keep] returns false (used to purge
  /// non-music that was indexed before the filter existed). Returns the count
  /// removed.
  int removeNonMusic(bool Function(TrackInfo t) keep) {
    final rs = _db.select('SELECT * FROM tracks;');
    var removed = 0;
    for (final r in rs) {
      final t = _row(r);
      if (keep(t)) continue;
      _db.execute('DELETE FROM tracks WHERE id=?;', [t.id]);
      _db.execute('DELETE FROM tracks_fts WHERE rowid=?;', [t.id]);
      removed++;
    }
    return removed;
  }

  void removeMissing(bool Function(String path) exists) {
    final rs = _db.select('SELECT id, path FROM tracks;');
    for (final r in rs) {
      if (!exists(r['path'] as String)) {
        final id = r['id'] as int;
        _db.execute('DELETE FROM tracks WHERE id=?;', [id]);
        _db.execute('DELETE FROM tracks_fts WHERE rowid=?;', [id]);
      }
    }
  }

  void close() => _db.dispose();
}
