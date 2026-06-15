import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app_prefs.dart';
import 'disk_space.dart';

/// A downloadable Wikipedia edition.
class WikiEdition {
  const WikiEdition(this.label, this.filePattern, this.approxBytes);
  final String label;
  final String filePattern; // regex over the Kiwix listing
  final int approxBytes; // fallback size estimate when HEAD is unavailable
}

/// Result of checking whether an edition can be downloaded.
class WikiSpaceCheck {
  WikiSpaceCheck({
    required this.url,
    required this.needBytes,
    required this.freeBytes,
    required this.destPath,
  });
  final String url;
  final int needBytes; // download size + headroom
  final int? freeBytes; // null = couldn't determine
  final String destPath;
  bool get ok => freeBytes == null || freeBytes! >= needBytes;
}

/// Downloads an offline-Wikipedia ZIM from the Kiwix mirror, with a free-space
/// pre-check so a download is never started when it can't fit. Progress is
/// observable for the Settings UI.
class WikipediaDownload extends ChangeNotifier {
  WikipediaDownload._();
  // Singleton so an in-flight download keeps running if the user leaves the
  // Settings screen.
  static final WikipediaDownload instance = WikipediaDownload._();

  static const _listingUrl = 'https://download.kiwix.org/zim/wikipedia/';

  static const int _gb = 1024 * 1024 * 1024;
  static const int _mb = 1024 * 1024;

  // Simple English, no images — the recommended phone-sized edition.
  static const simpleNopic = WikiEdition(
    'Simple English (no images)',
    r'wikipedia_en_simple_all_nopic_\d{4}-\d{2}\.zim',
    980 * _mb, // ~937 MB; updated from HEAD when available
  );

  /// Curated downloadable editions, smallest first. Sizes are estimates
  /// refined from a HEAD request before each download; the free-space check
  /// gates anything that won't fit. Anything else can still be sideloaded via
  /// "install a .zim you already have".
  static const editions = <WikiEdition>[
    simpleNopic,
    WikiEdition('Simple English (with images)',
        r'wikipedia_en_simple_all_maxi_\d{4}-\d{2}\.zim', 3 * _gb),
    WikiEdition('English — essentials (top ~50k, with images)',
        r'wikipedia_en_100_maxi_\d{4}-\d{2}\.zim', 350 * _mb),
    WikiEdition('English — medicine (with images)',
        r'wikipedia_en_medicine_maxi_\d{4}-\d{2}\.zim', 2 * _gb),
    WikiEdition('English — full (no images)',
        r'wikipedia_en_all_nopic_\d{4}-\d{2}\.zim', 55 * _gb),
    WikiEdition('Portuguese — full (no images)',
        r'wikipedia_pt_all_nopic_\d{4}-\d{2}\.zim', 14 * _gb),
    WikiEdition('Spanish — full (no images)',
        r'wikipedia_es_all_nopic_\d{4}-\d{2}\.zim', 19 * _gb),
    WikiEdition('French — full (no images)',
        r'wikipedia_fr_all_nopic_\d{4}-\d{2}\.zim', 25 * _gb),
    WikiEdition('German — full (no images)',
        r'wikipedia_de_all_nopic_\d{4}-\d{2}\.zim', 27 * _gb),
  ];

  bool _busy = false;
  bool _cancel = false;
  int received = 0;
  int total = 0;
  String? error;

  bool get downloading => _busy;
  double get progress => total > 0 ? received / total : 0;

  /// Resolves the latest dated file for [edition] and where it would be saved,
  /// then checks free space at that location. Returns null only if the URL
  /// can't be resolved (e.g. offline).
  Future<WikiSpaceCheck?> check(WikiEdition edition) async {
    final url = await _resolveUrl(edition);
    if (url == null) return null;
    var size = edition.approxBytes;
    try {
      final head = await http.head(Uri.parse(url)).timeout(const Duration(seconds: 20));
      final len = int.tryParse(head.headers['content-length'] ?? '');
      if (len != null && len > 0) size = len;
    } catch (_) {}
    final dir = await _destDir();
    final destPath = '${dir.path}/${url.split('/').last}';
    // Headroom: the part-file + the filesystem shouldn't be filled to the brim.
    final need = size + 256 * 1024 * 1024;
    return WikiSpaceCheck(
      url: url,
      needBytes: need,
      freeBytes: freeBytesForPath(dir.path),
      destPath: destPath,
    );
  }

  /// Streams the ZIM at [check.url] to disk and, on success, sets it as the
  /// active Wikipedia. Returns true when installed. Refuses if space is short.
  Future<bool> start(WikiSpaceCheck check) async {
    if (_busy) return false;
    if (!check.ok) {
      error = 'Not enough storage.';
      notifyListeners();
      return false;
    }
    _busy = true;
    _cancel = false;
    error = null;
    received = 0;
    total = 0;
    notifyListeners();

    final client = http.Client();
    final tmp = File('${check.destPath}.part');
    try {
      // Resume from a previous partial download via an HTTP Range request.
      var existing = await tmp.exists() ? await tmp.length() : 0;
      final req = http.Request('GET', Uri.parse(check.url));
      if (existing > 0) req.headers['range'] = 'bytes=$existing-';
      final resp = await client.send(req);

      IOSink sink;
      if (resp.statusCode == 206) {
        total = _contentRangeTotal(resp.headers['content-range']) ??
            (existing + (resp.contentLength ?? check.needBytes));
        sink = tmp.openWrite(mode: FileMode.append);
      } else if (resp.statusCode == 200) {
        existing = 0; // server ignored the range — restart cleanly
        total = resp.contentLength ?? check.needBytes;
        sink = tmp.openWrite();
      } else {
        error = 'Download failed (${resp.statusCode}).';
        return false;
      }
      received = existing;
      var sinceNotify = 0;
      try {
        await for (final chunk in resp.stream) {
          if (_cancel) {
            // Keep the partial file so the download can resume later.
            error = null;
            return false;
          }
          sink.add(chunk);
          received += chunk.length;
          sinceNotify += chunk.length;
          if (sinceNotify >= 2 * 1024 * 1024) {
            sinceNotify = 0;
            notifyListeners();
          }
        }
      } finally {
        await sink.close(); // flush; the partial survives for resume
      }
      await tmp.rename(check.destPath);
      await saveWikipediaZimPath(check.destPath);
      return true;
    } catch (e) {
      // Keep the .part for resume; report the error.
      error = 'Download error: $e';
      return false;
    } finally {
      client.close();
      _busy = false;
      notifyListeners();
    }
  }

  static int? _contentRangeTotal(String? header) {
    if (header == null) return null;
    final slash = header.lastIndexOf('/');
    if (slash < 0) return null;
    return int.tryParse(header.substring(slash + 1).trim());
  }

  void cancel() => _cancel = true;

  /// Whether a file for [edition] already exists in the destination folder (so
  /// the setup can show it as installed and skip it). Reuses anything already on
  /// the chosen storage folder / card.
  Future<bool> isInstalled(WikiEdition edition) async {
    try {
      final dir = await _destDir();
      final re = RegExp(edition.filePattern);
      for (final e in dir.listSync()) {
        if (e is File && re.hasMatch(e.path.split('/').last)) return true;
      }
    } catch (_) {}
    return false;
  }

  /// Resolves [edition] to a space-check and downloads it (resumable). Sets it as
  /// the active Wikipedia on success. Returns true when installed.
  Future<bool> download(WikiEdition edition) async {
    final c = await check(edition);
    if (c == null) {
      error = 'Could not reach the download server.';
      notifyListeners();
      return false;
    }
    return start(c);
  }

  Future<Directory> _destDir() async {
    // Prefer the user's chosen models location (may be an SD card); else app
    // external storage (no permission needed, survives most app updates).
    final loc = await loadModelsLocation();
    Directory dir;
    if (loc.isNotEmpty) {
      dir = Directory('$loc/wikipedia');
    } else {
      final ext = await getExternalStorageDirectory();
      dir = Directory('${ext?.path ?? (await getApplicationSupportDirectory()).path}/wikipedia');
    }
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String?> _resolveUrl(WikiEdition edition) async {
    try {
      final resp =
          await http.get(Uri.parse(_listingUrl)).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return null;
      final files = RegExp(edition.filePattern)
          .allMatches(resp.body)
          .map((m) => m.group(0)!)
          .toSet()
          .toList()
        ..sort(); // dated names sort chronologically — last is newest
      if (files.isEmpty) return null;
      return '$_listingUrl${files.last}';
    } catch (_) {
      return null;
    }
  }
}
