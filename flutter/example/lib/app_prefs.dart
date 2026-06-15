import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Default persona: a friendly woman named Eva who elaborates on request.
const String kDefaultSystemPrompt =
    "You are Eva, a warm and friendly woman. You chat in a relaxed, kind, and "
    "approachable way. You're always happy to go into detail and give thorough, "
    "helpful explanations whenever the user asks for more.";

const String _kSystemPromptKey = 'system_prompt';

Future<String> loadSystemPrompt() async {
  final prefs = await SharedPreferences.getInstance();
  final v = prefs.getString(_kSystemPromptKey);
  return (v == null || v.trim().isEmpty) ? kDefaultSystemPrompt : v;
}

Future<void> saveSystemPrompt(String value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kSystemPromptKey, value);
}

// ── Theme ────────────────────────────────────────────────────────────────────

/// Current theme mode; the root app rebuilds when this changes.
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(ThemeMode.system);

const String _kThemeModeKey = 'theme_mode';

Future<void> initThemeMode() async {
  final prefs = await SharedPreferences.getInstance();
  themeModeNotifier.value = switch (prefs.getString(_kThemeModeKey)) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
}

Future<void> setThemeMode(ThemeMode mode) async {
  themeModeNotifier.value = mode;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    _kThemeModeKey,
    switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    },
  );
}

// ── Voice input ──────────────────────────────────────────────────────────────

/// Which speech-to-text engine the mic button uses.
/// - [fast]: the bundled offline streaming model (English only).
/// - [system]: the phone's built-in recognizer (many languages, incl. the
///   system language; uses Android's speech service).
enum VoiceEngine { fast, system }

const String _kVoiceEngineKey = 'voice_engine';
const String _kVoiceLocaleKey = 'voice_locale';

Future<VoiceEngine> loadVoiceEngine() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_kVoiceEngineKey) == 'system'
      ? VoiceEngine.system
      : VoiceEngine.fast;
}

Future<void> saveVoiceEngine(VoiceEngine engine) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
      _kVoiceEngineKey, engine == VoiceEngine.system ? 'system' : 'fast');
}

/// Locale id for the system recognizer (e.g. `pt_BR`). Empty means "auto" —
/// fall back to the device's system locale / let the recognizer decide.
Future<String> loadVoiceLocale() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_kVoiceLocaleKey) ?? '';
}

Future<void> saveVoiceLocale(String localeId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kVoiceLocaleKey, localeId);
}

// ── Reply length ─────────────────────────────────────────────────────────────

/// Cap on generated tokens per reply. 1024 ≈ a few paragraphs; raise it for
/// long-form answers at the cost of slower turns.
const int kDefaultMaxTokens = 1024;
const List<int> kMaxTokensChoices = [256, 1024, 2048];

const String _kMaxTokensKey = 'max_tokens';

Future<int> loadMaxTokens() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getInt(_kMaxTokensKey) ?? kDefaultMaxTokens;
}

Future<void> saveMaxTokens(int value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(_kMaxTokensKey, value);
}

// ── Intro / onboarding ───────────────────────────────────────────────────────

const String _kIntroSeenKey = 'intro_seen';

/// Whether the first-run intro (permissions + downloads explainer) was shown.
Future<bool> loadIntroSeen() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_kIntroSeenKey) ?? false;
}

Future<void> saveIntroSeen() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_kIntroSeenKey, true);
}

// The first-run setup wizard (choose & download models / Wikipedia). Persisted
// so an interrupted setup can resume on the next launch.
const String _kSetupDoneKey = 'setup_done';
const String _kSetupPlanKey = 'setup_plan';

/// Whether the first-run download setup has been completed (or skipped).
Future<bool> loadSetupDone() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_kSetupDoneKey) ?? false;
}

Future<void> saveSetupDone(bool done) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_kSetupDoneKey, done);
}

/// The chosen download plan: which model ids, the embedder, and which Wikipedia
/// edition labels to fetch. Kept so a killed/interrupted setup resumes the same
/// selection on relaunch.
Future<Map<String, dynamic>> loadSetupPlan() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_kSetupPlanKey);
  if (raw == null) return {};
  try {
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  } catch (_) {
    return {};
  }
}

Future<void> saveSetupPlan(Map<String, dynamic> plan) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kSetupPlanKey, jsonEncode(plan));
}

// ── Unified storage location ─────────────────────────────────────────────────
//
// One folder holds all of Eva's data: models, the offline Wikipedia, the
// document corpus and the map cache, each in its own subfolder. The per-area
// getters below derive from this root when it's set (and fall back to the older
// per-area prefs / app-private defaults otherwise), so consumers don't change.

const String _kStorageRootKey = 'storage_root';
const String _kModelsLocationKey = 'models_location';

/// The chosen unified storage folder, or empty for app-private storage.
Future<String> loadStorageRoot() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_kStorageRootKey) ?? '';
}

Future<void> saveStorageRoot(String path) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kStorageRootKey, path);
}

/// Folder model bundles live under (`<this>/models`). Prefers the unified root.
Future<String> loadModelsLocation() async {
  final prefs = await SharedPreferences.getInstance();
  final root = prefs.getString(_kStorageRootKey) ?? '';
  if (root.isNotEmpty) return root;
  return prefs.getString(_kModelsLocationKey) ?? '';
}

Future<void> saveModelsLocation(String path) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kModelsLocationKey, path);
}

// ── Photo gallery indexing ───────────────────────────────────────────────────

const String _kPhotoScanDoneKey = 'photo_scan_done';

/// Whether the gallery has been fully walked at least once. While false, the
/// background photo indexer auto-resumes on launch until the whole gallery is
/// catalogued. Reset to force a fresh pass (e.g. to pick up new photos).
Future<bool> loadPhotoScanDone() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_kPhotoScanDoneKey) ?? false;
}

Future<void> savePhotoScanDone(bool done) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_kPhotoScanDoneKey, done);
}

// ── Music library indexing ───────────────────────────────────────────────────

const String _kMusicScanDoneKey = 'music_scan_done';

/// Whether the music library has been fully walked at least once. While false,
/// the background music indexer auto-resumes on launch until every audio file
/// is catalogued. Reset to force a fresh pass (e.g. to pick up new tracks).
Future<bool> loadMusicScanDone() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_kMusicScanDoneKey) ?? false;
}

Future<void> saveMusicScanDone(bool done) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_kMusicScanDoneKey, done);
}

// ── Maps (cache-on-demand) ───────────────────────────────────────────────────

const String _kMapsEnabledKey = 'maps_enabled';
const String _kMapsFolderKey = 'maps_folder';
const String _kMapsSatelliteKey = 'maps_satellite';

/// Whether Eva may answer location/route questions with a map (default on).
Future<bool> loadMapsEnabled() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_kMapsEnabledKey) ?? true;
}

Future<void> saveMapsEnabled(bool enabled) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_kMapsEnabledKey, enabled);
}

/// Folder where map tiles + geocode/route results are cached. Empty = app
/// storage. Visited areas served from here when offline; point it at a folder
/// that already has the cache to reuse it.
Future<String> loadMapsFolder() async {
  final prefs = await SharedPreferences.getInstance();
  final root = prefs.getString(_kStorageRootKey) ?? '';
  if (root.isNotEmpty) return root;
  return prefs.getString(_kMapsFolderKey) ?? '';
}

Future<void> saveMapsFolder(String path) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kMapsFolderKey, path);
}

/// Whether the map opens on the satellite layer (vs streets). Default streets.
Future<bool> loadMapsSatellite() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_kMapsSatelliteKey) ?? false;
}

Future<void> saveMapsSatellite(bool on) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_kMapsSatelliteKey, on);
}

// ── Offline Wikipedia (libzim) ───────────────────────────────────────────────

const String _kWikipediaZimPathKey = 'wikipedia_zim_path';
const String _kWikipediaEnabledKey = 'wikipedia_enabled';

/// Absolute path of the installed Wikipedia `.zim`, or empty if none.
Future<String> loadWikipediaZimPath() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_kWikipediaZimPathKey) ?? '';
}

Future<void> saveWikipediaZimPath(String path) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kWikipediaZimPathKey, path);
}

/// Whether Eva may consult the offline Wikipedia to help answer (default on).
Future<bool> loadWikipediaEnabled() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_kWikipediaEnabledKey) ?? true;
}

Future<void> saveWikipediaEnabled(bool enabled) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_kWikipediaEnabledKey, enabled);
}

// ── Document corpus location ─────────────────────────────────────────────────

const String _kCorpusLocationKey = 'corpus_location';

/// Absolute path of the folder holding the document corpus + index. Empty means
/// the app's default documents directory. A user can point this at an SD card
/// so the indexed archive survives a reinstall.
Future<String> loadCorpusLocation() async {
  final prefs = await SharedPreferences.getInstance();
  final root = prefs.getString(_kStorageRootKey) ?? '';
  if (root.isNotEmpty) return '$root/corpus';
  return prefs.getString(_kCorpusLocationKey) ?? '';
}

Future<void> saveCorpusLocation(String path) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kCorpusLocationKey, path);
}

// ── Web radio stations ───────────────────────────────────────────────────────

/// An online radio station the user can play (a name + a stream URL).
class RadioStation {
  const RadioStation(
      {required this.name, required this.url, this.genre = '', this.playCount = 0});
  final String name;
  final String url; // direct audio stream (http/https), e.g. an Icecast/MP3 URL
  final String genre;
  final int playCount; // times tuned in, so favourites can float to the top

  RadioStation copyWith({String? name, String? url, String? genre, int? playCount}) =>
      RadioStation(
        name: name ?? this.name,
        url: url ?? this.url,
        genre: genre ?? this.genre,
        playCount: playCount ?? this.playCount,
      );

  Map<String, dynamic> toJson() =>
      {'name': name, 'url': url, 'genre': genre, 'playCount': playCount};
  static RadioStation fromJson(Map<String, dynamic> j) => RadioStation(
        name: (j['name'] as String?) ?? '',
        url: (j['url'] as String?) ?? '',
        genre: (j['genre'] as String?) ?? '',
        playCount: (j['playCount'] as num?)?.toInt() ?? 0,
      );
}

/// Example stations seeded on first run so radio works out of the box. All use
/// HTTPS streams so no cleartext exception is needed.
const List<RadioStation> kDefaultRadioStations = [
  RadioStation(
      name: 'SomaFM Groove Salad',
      url: 'https://ice1.somafm.com/groovesalad-128-mp3',
      genre: 'Ambient / downtempo'),
  RadioStation(
      name: 'SomaFM Drone Zone',
      url: 'https://ice1.somafm.com/dronezone-128-mp3',
      genre: 'Ambient'),
  RadioStation(
      name: 'SomaFM Lush',
      url: 'https://ice1.somafm.com/lush-128-mp3',
      genre: 'Vocal / chill'),
  RadioStation(
      name: 'Radio Paradise (Main Mix)',
      url: 'https://stream.radioparadise.com/mp3-128',
      genre: 'Eclectic'),
  RadioStation(
      name: 'Radio Paradise (Mellow Mix)',
      url: 'https://stream.radioparadise.com/mellow-128',
      genre: 'Mellow'),
  RadioStation(
      name: 'FIP',
      url: 'https://icecast.radiofrance.fr/fip-midfi.mp3',
      genre: 'Eclectic (France)'),
];

const String _kRadioStationsKey = 'radio_stations';

/// The saved stations. On first ever load (key absent) returns the examples and
/// persists them, so the list is pre-filled.
Future<List<RadioStation>> loadRadioStations() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_kRadioStationsKey);
  if (raw == null) {
    await saveRadioStations(kDefaultRadioStations);
    return List.of(kDefaultRadioStations);
  }
  try {
    final list = jsonDecode(raw) as List;
    return [
      for (final e in list) RadioStation.fromJson(e as Map<String, dynamic>)
    ];
  } catch (_) {
    return List.of(kDefaultRadioStations);
  }
}

Future<void> saveRadioStations(List<RadioStation> stations) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
      _kRadioStationsKey, jsonEncode([for (final s in stations) s.toJson()]));
}

/// Increments the play count for the station with [url] and persists it, so
/// most-played stations can be surfaced first. Returns the updated list.
Future<List<RadioStation>> incrementRadioPlay(String url) async {
  final stations = await loadRadioStations();
  final updated = [
    for (final s in stations)
      s.url == url ? s.copyWith(playCount: s.playCount + 1) : s
  ];
  await saveRadioStations(updated);
  return updated;
}

// ── Timed reminders ──────────────────────────────────────────────────────────

/// A scheduled reminder, persisted so Settings can list/cancel pending ones and
/// so the notification id is stable.
class ReminderItem {
  const ReminderItem({required this.id, required this.text, required this.whenMs});
  final int id;
  final String text;
  final int whenMs; // epoch millis it fires at

  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'whenMs': whenMs};
  static ReminderItem fromJson(Map<String, dynamic> j) => ReminderItem(
        id: (j['id'] as num).toInt(),
        text: (j['text'] as String?) ?? '',
        whenMs: (j['whenMs'] as num).toInt(),
      );
}

const String _kRemindersKey = 'reminders';

Future<List<ReminderItem>> loadReminders() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_kRemindersKey);
  if (raw == null) return [];
  try {
    final list = jsonDecode(raw) as List;
    return [
      for (final e in list) ReminderItem.fromJson(e as Map<String, dynamic>)
    ];
  } catch (_) {
    return [];
  }
}

Future<void> saveReminders(List<ReminderItem> reminders) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
      _kRemindersKey, jsonEncode([for (final r in reminders) r.toJson()]));
}

// ── Recently viewed Wikipedia articles ───────────────────────────────────────

const String _kRecentWikiKey = 'recent_wiki';

/// Recently opened Wikipedia articles, most recent first (title + ZIM path).
Future<List<({String title, String path})>> loadRecentWiki() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_kRecentWikiKey);
  if (raw == null) return [];
  try {
    return [
      for (final e in (jsonDecode(raw) as List))
        (title: (e['title'] as String?) ?? '', path: (e['path'] as String?) ?? '')
    ].where((e) => e.path.isNotEmpty).toList();
  } catch (_) {
    return [];
  }
}

/// Records an opened article at the top of the recents (deduped by path, capped).
Future<void> addRecentWiki(String title, String path) async {
  if (path.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  final list = await loadRecentWiki();
  list.removeWhere((e) => e.path == path);
  list.insert(0, (title: title.isEmpty ? path : title, path: path));
  final capped = list.take(25).toList();
  await prefs.setString(_kRecentWikiKey,
      jsonEncode([for (final e in capped) {'title': e.title, 'path': e.path}]));
}

Future<void> clearRecentWiki() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_kRecentWikiKey);
}

// ── Reading positions (resume where you left off) ────────────────────────────

const String _kDocPagesKey = 'doc_pages'; // {docKey: pageNumber}
const String _kDocScrollKey = 'doc_scroll'; // {docKey: 0..1 scroll fraction}

Future<Map<String, dynamic>> _loadMap(String key) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(key);
  if (raw == null) return {};
  try {
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  } catch (_) {
    return {};
  }
}

Future<void> _putMapValue(String key, String field, Object value) async {
  final prefs = await SharedPreferences.getInstance();
  final map = await _loadMap(key);
  map[field] = value;
  await prefs.setString(key, jsonEncode(map));
}

/// Last-read page for a PDF (1-based), or null if none saved.
Future<int?> loadDocPage(String docKey) async =>
    (await _loadMap(_kDocPagesKey))[docKey] as int?;

Future<void> saveDocPage(String docKey, int page) =>
    _putMapValue(_kDocPagesKey, docKey, page);

/// Last scroll fraction (0..1) for a text document, or null if none saved.
Future<double?> loadDocScroll(String docKey) async {
  final v = (await _loadMap(_kDocScrollKey))[docKey];
  return (v as num?)?.toDouble();
}

Future<void> saveDocScroll(String docKey, double fraction) =>
    _putMapValue(_kDocScrollKey, docKey, fraction);

// ── Storage migration ────────────────────────────────────────────────────────

/// The absolute directories where Eva's data currently lives (models, offline
/// Wikipedia, document corpus, map cache), derived the same way the consumers
/// derive them. Keyed by area.
Future<Map<String, String>> currentDataDirs() async {
  final prefs = await SharedPreferences.getInstance();
  final root = prefs.getString(_kStorageRootKey) ?? '';
  final appDocs = (await getApplicationDocumentsDirectory()).path;
  final ext = await getExternalStorageDirectory();
  final extPath = ext?.path ?? (await getApplicationSupportDirectory()).path;
  if (root.isNotEmpty) {
    return {
      'models': '$root/models',
      'wikipedia': '$root/wikipedia',
      'corpus': '$root/corpus',
      'maps': '$root/maps',
    };
  }
  final modelsLoc = prefs.getString(_kModelsLocationKey) ?? '';
  final corpusLoc = prefs.getString(_kCorpusLocationKey) ?? '';
  final mapsLoc = prefs.getString(_kMapsFolderKey) ?? '';
  return {
    'models': modelsLoc.isEmpty ? '$appDocs/models' : '$modelsLoc/models',
    'wikipedia': modelsLoc.isEmpty ? '$extPath/wikipedia' : '$modelsLoc/wikipedia',
    'corpus': corpusLoc.isEmpty ? '$appDocs/corpus' : corpusLoc,
    'maps': mapsLoc.isEmpty ? '$extPath/maps' : '$mapsLoc/maps',
  };
}

/// Moves all of Eva's data into [newRoot] (one subfolder per area), repoints the
/// stored Wikipedia path, makes [newRoot] the unified storage root, and clears
/// the old per-area location prefs. Progress is reported via [onStep]. Existing
/// files already at the destination are left in place. Best-effort and safe to
/// re-run.
Future<void> migrateStorageTo(String newRoot,
    {void Function(String message)? onStep}) async {
  final src = await currentDataDirs();
  final targets = <String, String>{
    'models': '$newRoot/models',
    'wikipedia': '$newRoot/wikipedia',
    'corpus': '$newRoot/corpus',
    'maps': '$newRoot/maps',
  };
  for (final area in src.keys) {
    final from = Directory(src[area]!);
    final to = targets[area]!;
    if (from.path == to) continue;
    if (!await from.exists()) continue;
    onStep?.call('Moving ${_areaLabel(area)}…');
    await _moveDir(from, Directory(to));
  }
  // Repoint the stored Wikipedia .zim path if it sat under the moved folder.
  final zim = await loadWikipediaZimPath();
  if (zim.isNotEmpty && _isUnder(zim, src['wikipedia']!)) {
    await saveWikipediaZimPath(
        zim.replaceFirst(src['wikipedia']!, targets['wikipedia']!));
  }
  onStep?.call('Finishing…');
  await saveStorageRoot(newRoot);
  // Clear the legacy per-area prefs so everything derives from the new root.
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_kModelsLocationKey);
  await prefs.remove(_kCorpusLocationKey);
  await prefs.remove(_kMapsFolderKey);
}

String _areaLabel(String area) {
  switch (area) {
    case 'models':
      return 'models';
    case 'wikipedia':
      return 'offline Wikipedia';
    case 'corpus':
      return 'documents';
    case 'maps':
      return 'map cache';
  }
  return area;
}

bool _isUnder(String path, String dir) => path == dir || path.startsWith('$dir/');

/// Moves [src] to [dst]: a fast rename when on the same filesystem, else a
/// recursive copy + delete (e.g. internal storage → SD card).
Future<void> _moveDir(Directory src, Directory dst) async {
  try {
    await dst.parent.create(recursive: true);
    await src.rename(dst.path);
    return;
  } catch (_) {
    // Cross-device move or destination exists — fall back to copy + delete.
  }
  await _copyDir(src, dst);
  try {
    await src.delete(recursive: true);
  } catch (_) {}
}

Future<void> _copyDir(Directory src, Directory dst) async {
  await dst.create(recursive: true);
  await for (final entity in src.list(followLinks: false)) {
    final name = entity.path.split('/').last;
    if (entity is Directory) {
      await _copyDir(entity, Directory('${dst.path}/$name'));
    } else if (entity is File) {
      await entity.copy('${dst.path}/$name');
    }
  }
}
