import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Saved, named playlists — each a list of track file paths (resolved back to
/// tracks via [MusicStore.tracksByPaths] when loaded). Stored in shared
/// preferences as one JSON map {name: [paths]}.
class PlaylistStore {
  static const String _key = 'playlists';

  static Future<Map<String, List<String>>> all() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return {};
    try {
      final map = (jsonDecode(raw) as Map).cast<String, dynamic>();
      return {
        for (final e in map.entries)
          e.key: (e.value as List).map((p) => p.toString()).toList()
      };
    } catch (_) {
      return {};
    }
  }

  static Future<List<String>> names() async => (await all()).keys.toList()..sort();

  static Future<void> save(String name, List<String> paths) async {
    final n = name.trim();
    if (n.isEmpty || paths.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final map = await all();
    map[n] = paths;
    await prefs.setString(_key, jsonEncode(map));
  }

  static Future<void> delete(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final map = await all();
    map.remove(name);
    await prefs.setString(_key, jsonEncode(map));
  }
}
