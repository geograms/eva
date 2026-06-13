import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'app_prefs.dart';
import 'document_service.dart';
import 'music_store.dart';

/// Running totals for a music-library scan.
class MusicScanResult {
  int added = 0;
  int skippedExisting = 0;
  int skippedNonMusic = 0;
  int failed = 0;
}

/// Heuristic: does this audio file look like an actual song (vs a voice note,
/// ringtone, notification sound, call recording, app SFX…)? Used both to skip
/// junk during the scan and to purge it from an already-built catalog.
///
/// Kept generous so real music is never dropped: anything with an artist or
/// album tag is always treated as music. Untagged files are judged by where
/// they live, their length, and messaging/recorder filename patterns.
bool isLikelyMusic({
  required String path,
  required String title,
  required String artist,
  required String album,
  required int durationMs,
}) {
  final p = path.toLowerCase();
  // Locations that never hold songs.
  const badDirs = [
    'ringtone', 'notification', '/alarm', 'voice', 'recording', 'recordings',
    '/call', 'whatsapp', 'telegram', 'signal', 'viber', 'voicemail',
    '/sounds/', '/sound/', '/ui/', 'grav', // pt: gravações
  ];
  if (badDirs.any(p.contains)) return false;

  // A real tag is the strongest signal of music — keep it.
  if (artist.trim().isNotEmpty || album.trim().isNotEmpty) return true;

  // Untagged: judge by filename + length.
  final n = title.trim().toLowerCase();
  final looksLikeClip =
      RegExp(r'\+?\d[\d\s\-]{5,}').hasMatch(n) || // phone-number-ish
          RegExp(r'^(aud[-_]|ptt[-_]|rec[-_ ]?\d|vn[-_]|voice|audio[-_ ]?\d|'
                  r'wa\d|msg|sig[-_]|gravac|gravação)')
              .hasMatch(n) ||
          RegExp(r'^\d{8}[-_ ]').hasMatch(n); // 20230102-...
  if (looksLikeClip) return false;

  // Untagged + short → almost certainly a clip; untagged + long → keep (could
  // be an untagged rip). Unknown duration (0) is given the benefit of the doubt.
  if (durationMs > 0 && durationMs < 60000) return false;
  return true;
}

/// Indexes the device's audio files into a [MusicStore]: walks music files,
/// reads embedded tags (artist/album/title/genre/year/track) via
/// audio_metadata_reader, and stores them. Lyrics (online, third-party) are a
/// separate enrichment pass — see [fetchLyricsBatch].
class MusicService {
  MusicService(this._docs);
  final DocumentService _docs;

  // Containers the (pinned) metadata reader can parse: MP3/MP4/FLAC/Vorbis/WAV.
  static const Set<String> audioExtensions = {
    'mp3', 'm4a', 'aac', 'flac', 'ogg', 'oga', 'opus', 'wav',
  };

  Future<String> _storePath() async => '${await _docs.corpusPath()}/music.sqlite';

  Future<MusicStore> openStore() async => MusicStore.open(await _storePath());

  Future<File> _skipFile() async =>
      File('${await _docs.corpusPath()}/_music_skip.json');

  Future<Set<String>> _loadSkip() async {
    final f = await _skipFile();
    if (!await f.exists()) return <String>{};
    try {
      return (jsonDecode(await f.readAsString()) as List).cast<String>().toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> _saveSkip(Set<String> s) async =>
      (await _skipFile()).writeAsString(jsonEncode(s.toList()));

  Future<int> trackCount() async {
    final store = await openStore();
    try {
      return store.count;
    } finally {
      store.close();
    }
  }

  /// One-time cleanup: removes already-indexed tracks that the music heuristic
  /// now rejects (e.g. voice notes catalogued before this filter existed).
  /// Returns the number purged.
  Future<int> purgeNonMusic() async {
    final store = await openStore();
    try {
      return store.removeNonMusic((t) => isLikelyMusic(
            path: t.path,
            title: t.title,
            artist: t.artist,
            album: t.album,
            durationMs: t.durationMs,
          ));
    } finally {
      store.close();
    }
  }

  /// Resolves a "play …" request into an ordered queue of tracks.
  Future<List<TrackInfo>> resolvePlay(String query) async {
    final store = await openStore();
    try {
      return store.resolvePlay(query);
    } finally {
      store.close();
    }
  }

  /// Records that [trackId] was played (for favourites ranking).
  Future<void> recordPlay(int trackId, int whenMs) async {
    final store = await openStore();
    try {
      store.recordPlay(trackId, whenMs);
    } finally {
      store.close();
    }
  }

  /// Walks [roots] (default: whole shared storage) and indexes new audio files.
  /// Resumable: already-indexed and known-bad paths are skipped.
  Future<MusicScanResult> scan({
    List<String> roots = const ['/storage/emulated/0'],
    void Function(int scanned, MusicScanResult partial)? onProgress,
    bool Function()? shouldContinue,
    Duration perItemDelay = Duration.zero,
  }) async {
    final res = MusicScanResult();
    final store = await openStore();
    final indexed = store.indexedPaths();
    final skip = await _loadSkip();
    final skip0 = skip.length;
    var scanned = 0;
    final stack = <Directory>[for (final r in roots) Directory(r)];
    try {
      while (stack.isNotEmpty) {
        if (shouldContinue != null && !shouldContinue()) break;
        final dir = stack.removeLast();
        List<FileSystemEntity> entries;
        try {
          entries = dir.listSync(followLinks: false);
        } catch (_) {
          continue;
        }
        for (final e in entries) {
          if (shouldContinue != null && !shouldContinue()) break;
          final name = e.path.split('/').last;
          if (e is Directory) {
            if (name == 'Android' || name.startsWith('.')) continue;
            stack.add(e);
            continue;
          }
          if (e is! File) continue;
          final dot = name.lastIndexOf('.');
          if (dot < 0) continue;
          final ext = name.substring(dot + 1).toLowerCase();
          if (!audioExtensions.contains(ext)) continue;
          scanned++;
          if (indexed.contains(e.path)) {
            res.skippedExisting++;
            onProgress?.call(scanned, res);
            continue;
          }
          if (skip.contains(e.path)) {
            onProgress?.call(scanned, res);
            continue;
          }
          try {
            final info = _indexOne(e);
            if (!isLikelyMusic(
              path: info.path,
              title: info.title,
              artist: info.artist,
              album: info.album,
              durationMs: info.durationMs,
            )) {
              // Not a song (voice note, ringtone…). Remember it so we don't
              // re-read its tags on every rescan.
              res.skippedNonMusic++;
              skip.add(e.path);
              onProgress?.call(scanned, res);
              continue;
            }
            store.upsert(info);
            indexed.add(e.path);
            res.added++;
          } catch (_) {
            res.failed++;
            skip.add(e.path);
          }
          onProgress?.call(scanned, res);
          if (perItemDelay > Duration.zero) await Future<void>.delayed(perItemDelay);
        }
        await Future<void>.delayed(Duration.zero); // keep the UI responsive
      }
    } finally {
      store.close();
      if (skip.length != skip0) await _saveSkip(skip);
    }
    return res;
  }

  TrackInfo _indexOne(File f) {
    String title = '', artist = '', album = '', genre = '', lyrics = '';
    int year = 0, trackNo = 0, durationMs = 0;
    try {
      final m = readMetadata(f, getImage: false);
      title = (m.title ?? '').trim();
      artist =
          (m.artist ?? (m.performers.isNotEmpty ? m.performers.first : '')).trim();
      album = (m.album ?? '').trim();
      genre = m.genres.isNotEmpty ? m.genres.first.trim() : '';
      year = m.year?.year ?? 0;
      trackNo = m.trackNumber ?? 0;
      durationMs = m.duration?.inMilliseconds ?? 0;
      lyrics = (m.lyrics ?? '').trim();
    } catch (_) {
      // Untagged or unsupported container — fall back to the filename below.
    }
    final bucket = _bucket(f.path);
    if (title.isEmpty) title = _titleFromName(f.path);
    return TrackInfo(
      id: 0,
      path: f.path,
      title: title,
      artist: artist,
      album: album,
      genre: genre,
      year: year,
      trackNo: trackNo,
      durationMs: durationMs,
      size: f.lengthSync(),
      bucket: bucket,
      lyrics: lyrics.isEmpty ? null : lyrics,
    );
  }

  String _bucket(String path) {
    final parts = path.split('/');
    return parts.length >= 2 ? parts[parts.length - 2] : '';
  }

  /// Best-effort title from a filename: drop the extension and any leading
  /// track-number prefix ("03 - ", "03. ").
  String _titleFromName(String path) {
    var name = path.split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    name = name.replaceFirst(RegExp(r'^\s*\d{1,3}\s*[-._)]\s*'), '');
    return name.replaceAll('_', ' ').trim();
  }

  // ── Lyrics enrichment (online, third-party) ────────────────────────────────

  /// Fetches lyrics for up to [limit] pending tracks from the free lyrics.ovh
  /// API (no key required), when the network is reachable. Each lookup also
  /// marks the track resolved so it isn't retried indefinitely. Returns the
  /// number of tracks newly given lyrics. Best-effort: any error is swallowed.
  Future<int> fetchLyricsBatch({
    int limit = 8,
    bool Function()? shouldContinue,
  }) async {
    if (!await _hasNetwork()) return 0;
    final store = await openStore();
    var found = 0;
    try {
      final pending = store.pendingLyrics(limit: limit);
      for (final t in pending) {
        if (shouldContinue != null && !shouldContinue()) break;
        final lyrics = await _lyricsOvh(t.artist, t.title);
        store.setLyrics(t.id, lyrics);
        if ((lyrics ?? '').trim().isNotEmpty) found++;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    } catch (_) {
      // transient network/server error — retry next pass
    } finally {
      store.close();
    }
    return found;
  }

  Future<int> lyricsPendingCount() async {
    final store = await openStore();
    try {
      return store.lyricsPendingCount;
    } finally {
      store.close();
    }
  }

  Future<bool> _hasNetwork() async {
    try {
      final r = await InternetAddress.lookup('api.lyrics.ovh')
          .timeout(const Duration(seconds: 4));
      return r.isNotEmpty && r.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Returns lyrics from lyrics.ovh, or null when not found / on error.
  Future<String?> _lyricsOvh(String artist, String title) async {
    String enc(String s) => Uri.encodeComponent(s.trim());
    final uri = Uri.parse(
        'https://api.lyrics.ovh/v1/${enc(artist)}/${enc(title)}');
    try {
      final resp = await http.get(uri).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body);
      if (body is Map && body['lyrics'] is String) {
        final l = (body['lyrics'] as String).trim();
        return l.isEmpty ? null : l;
      }
    } catch (_) {}
    return null;
  }
}

/// Drives the music scan as a continuous background task, mirroring the photo
/// indexer: auto-resumes until the whole library is catalogued, then runs the
/// lyrics-enrichment pass when online. Throttled and pausable. Progress is
/// observable for a banner.
class MusicIndexController extends ChangeNotifier {
  MusicIndexController(this._music);
  final MusicService _music;

  bool _running = false;
  bool _paused = false;
  int _scanned = 0;
  int _added = 0;
  int _total = 0;
  int _lyricsFound = 0;
  bool _fetchingLyrics = false;
  bool _purgedOnce = false;
  Completer<void>? _idle;

  bool get isIndexing => _running && !_paused;
  bool get isFetchingLyrics => _fetchingLyrics;
  int get added => _added;
  int get scanned => _scanned;
  int get total => _total;
  int get lyricsFound => _lyricsFound;

  /// Starts/continues the music scan if it hasn't fully completed yet, then
  /// keeps fetching lyrics in the background. Safe to call repeatedly.
  Future<void> ensureRunning() async {
    if (_running || _paused) return;
    // One-time cleanup of non-music catalogued before the filter existed
    // (voice notes, ringtones…), regardless of whether the scan is "done".
    if (!_purgedOnce) {
      _purgedOnce = true;
      try {
        if (await _music.purgeNonMusic() > 0) notifyListeners();
      } catch (_) {}
    }
    if (await loadMusicScanDone()) {
      // Catalog is complete; still try to fill in any missing lyrics.
      unawaited(_runLyrics());
      return;
    }
    unawaited(_run());
  }

  /// Forces a fresh full pass (e.g. to pick up new tracks).
  Future<void> rescan() async {
    await saveMusicScanDone(false);
    _paused = false;
    if (!_running) unawaited(_run());
  }

  void pause() => _paused = true;

  void resume() {
    if (!_paused) return;
    _paused = false;
    if (!_running) unawaited(_run());
  }

  Future<void> stop() async {
    _paused = true;
    if (!_running) return;
    _idle ??= Completer<void>();
    await _idle!.future;
  }

  Future<void> _run() async {
    if (_running || _paused) return;
    _running = true;
    try {
      _total = await _music.trackCount();
      final res = await _music.scan(
        perItemDelay: const Duration(milliseconds: 15),
        onProgress: (n, p) {
          _scanned = n;
          _added = p.added;
          if (_total < p.added) _total = p.added;
          notifyListeners();
        },
        shouldContinue: () => !_paused,
      );
      if (!_paused) {
        await saveMusicScanDone(true);
        _added = res.added;
      }
    } catch (_) {
      // transient — will retry next launch / resume
    } finally {
      _running = false;
      _idle?.complete();
      _idle = null;
      notifyListeners();
    }
    // Once the catalog is in place, enrich with lyrics (needs network).
    if (!_paused) unawaited(_runLyrics());
  }

  /// Background lyrics enrichment: loops in small batches until nothing is left
  /// to fetch or the network drops. Paused alongside the scan.
  Future<void> _runLyrics() async {
    if (_fetchingLyrics || _paused) return;
    _fetchingLyrics = true;
    notifyListeners();
    try {
      while (!_paused) {
        final n = await _music.fetchLyricsBatch(
          limit: 8,
          shouldContinue: () => !_paused,
        );
        _lyricsFound += n;
        notifyListeners();
        if (n == 0) break; // nothing fetched this round (offline or all done)
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    } catch (_) {
      // best-effort
    } finally {
      _fetchingLyrics = false;
      notifyListeners();
    }
  }
}
