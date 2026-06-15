import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-folder music categorisation: an LLM-assigned genre → subgenre for each
/// source folder (usually an album or an artist), so the Music › Folders tab
/// can group folders by genre even when the audio tags lack one. Kept in shared
/// preferences as one JSON map keyed by the folder (bucket) name.
class MusicFolderMeta {
  MusicFolderMeta({
    required this.folder,
    this.genre = '',
    this.subgenre = '',
    this.categorized = false,
  });

  final String folder;
  String genre; // broad genre, e.g. Rock, Metal, Electronic, Classical
  String subgenre; // specific style, e.g. Alternative Rock, Synthpop
  bool categorized;

  Map<String, dynamic> toJson() =>
      {'genre': genre, 'subgenre': subgenre, 'categorized': categorized};

  static MusicFolderMeta fromJson(String folder, Map<String, dynamic> j) =>
      MusicFolderMeta(
        folder: folder,
        genre: (j['genre'] as String?) ?? '',
        subgenre: (j['subgenre'] as String?) ?? '',
        categorized: (j['categorized'] as bool?) ?? false,
      );
}

/// Live progress of the music-folder categorisation pass, for the Folders tab.
final ValueNotifier<({int done, int total})> musicCategorizeProgress =
    ValueNotifier<({int done, int total})>((done: 0, total: 0));

class MusicMetaStore {
  static const String _key = 'music_folder_meta';

  static Future<Map<String, MusicFolderMeta>> all() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return {};
    try {
      final map = (jsonDecode(raw) as Map).cast<String, dynamic>();
      return {
        for (final e in map.entries)
          e.key:
              MusicFolderMeta.fromJson(e.key, (e.value as Map).cast<String, dynamic>())
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> _save(Map<String, MusicFolderMeta> map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode({for (final e in map.entries) e.key: e.value.toJson()}));
  }

  /// Stores the genre/subgenre for a folder and marks it categorised (so the
  /// pass doesn't re-run it). Empty values still mark it done.
  static Future<void> setGenre(String folder, String genre, String subgenre) async {
    final map = await all();
    map[folder] = MusicFolderMeta(
        folder: folder, genre: genre, subgenre: subgenre, categorized: true);
    await _save(map);
  }
}
