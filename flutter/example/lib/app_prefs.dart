import 'package:flutter/material.dart';
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

// ── Models storage location ──────────────────────────────────────────────────

const String _kModelsLocationKey = 'models_location';

/// Absolute path of the folder where model bundles are stored. Empty means the
/// app's private storage. Pointing this at an SD card / shared folder lets the
/// (large) model downloads survive a reinstall and be reused — no re-download.
Future<String> loadModelsLocation() async {
  final prefs = await SharedPreferences.getInstance();
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

// ── Document corpus location ─────────────────────────────────────────────────

const String _kCorpusLocationKey = 'corpus_location';

/// Absolute path of the folder holding the document corpus + index. Empty means
/// the app's default documents directory. A user can point this at an SD card
/// so the indexed archive survives a reinstall.
Future<String> loadCorpusLocation() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_kCorpusLocationKey) ?? '';
}

Future<void> saveCorpusLocation(String path) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kCorpusLocationKey, path);
}
