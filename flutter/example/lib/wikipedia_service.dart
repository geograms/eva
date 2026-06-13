import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'app_prefs.dart';
import 'document_service.dart' show htmlToPlainText;
import 'text_util.dart';
import 'zim_ffi.dart';

/// Reads the on-device offline Wikipedia (a Kiwix `.zim`) via libzim, for
/// grounding answers and for the in-app reader. Holds one open archive handle
/// for the active `.zim`; cheap to query (Xapian full-text + memory-mapped
/// content). All public methods are safe to call when no ZIM is installed —
/// they degrade to empty results.
class WikipediaService {
  WikipediaService._();
  static final WikipediaService instance = WikipediaService._();

  final ZimFfi? _ffi = ZimFfi.instance();
  Pointer<Void>? _handle;
  String? _openPath;
  bool _icuReady = false;

  bool get nativeAvailable => _ffi != null;

  /// Opens (or re-opens) the configured `.zim` if needed. Returns true when an
  /// archive is ready to query.
  Future<bool> ensureOpen() async {
    final ffi = _ffi;
    if (ffi == null) return false;
    final path = await loadWikipediaZimPath();
    if (path.isEmpty || !File(path).existsSync()) {
      _closeHandle();
      return false;
    }
    if (_handle != null && _openPath == path) return true;
    _closeHandle();
    await _ensureIcu();
    final h = ffi.open(path);
    if (h == null) return false;
    _handle = h;
    _openPath = path;
    return true;
  }

  /// If no `.zim` is configured yet, scans shared storage and adopts the largest
  /// one found (so a user can just drop a Kiwix file on the phone). Returns the
  /// adopted path, or null. Cheap: only runs while unconfigured.
  Future<String?> discoverAndAdopt() async {
    if (_ffi == null) return null;
    final existing = await loadWikipediaZimPath();
    if (existing.isNotEmpty && File(existing).existsSync()) return existing;
    final best = await scanForZim();
    if (best != null) await saveWikipediaZimPath(best);
    return best;
  }

  /// Returns the largest `.zim` found in the common storage locations (depth-
  /// limited so it's fast and doesn't thrash the whole tree). Prioritises the
  /// folders a user would drop a Kiwix file into.
  Future<String?> scanForZim() async {
    const roots = [
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Wikipedia',
      '/storage/emulated/0/kiwix',
      '/storage/emulated/0/zim',
      '/storage/emulated/0/Documents',
      '/storage/emulated/0',
    ];
    String? best;
    int bestSize = 0;
    // (directory, remaining depth)
    final stack = <(Directory, int)>[for (final r in roots) (Directory(r), 2)];
    final seen = <String>{};
    while (stack.isNotEmpty) {
      final (dir, depth) = stack.removeLast();
      if (!seen.add(dir.path)) continue;
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } catch (_) {
        continue;
      }
      for (final e in entries) {
        final name = e.path.split('/').last;
        if (e is Directory) {
          if (depth > 0 && name != 'Android' && !name.startsWith('.')) {
            stack.add((e, depth - 1));
          }
        } else if (e is File && name.toLowerCase().endsWith('.zim')) {
          final sz = e.statSync().size;
          if (sz > bestSize) {
            bestSize = sz;
            best = e.path;
          }
        }
      }
    }
    return best;
  }

  void _closeHandle() {
    final h = _handle;
    if (h != null) _ffi?.close(h);
    _handle = null;
    _openPath = null;
  }

  /// Copies the bundled ICU data out of assets once and points libzim at it
  /// (its full-text search needs ICU at runtime on Android).
  Future<void> _ensureIcu() async {
    if (_icuReady) return;
    final ffi = _ffi;
    if (ffi == null) return;
    try {
      final dir = Directory('${(await getApplicationSupportDirectory()).path}/icu');
      if (!await dir.exists()) await dir.create(recursive: true);
      final dat = File('${dir.path}/icudt73l.dat');
      if (!await dat.exists()) {
        final bytes = await rootBundle.load('assets/icu/icudt73l.dat');
        await dat.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      }
      ffi.setIcuDataDir(dir.path);
      _icuReady = true;
    } catch (_) {
      // Search may still work if libzim has embedded data; don't hard-fail.
      _icuReady = true;
    }
  }

  /// Whether a usable ZIM is currently open.
  bool get isOpen => _handle != null;

  String get openPath => _openPath ?? '';

  /// Full-text search (falls back to title suggestion when the archive lacks a
  /// full-text index, e.g. some "mini" ZIMs).
  Future<List<ZimHit>> search(String query, {int k = 5}) async {
    if (!await ensureOpen()) return const [];
    final ffi = _ffi!, h = _handle!;
    final hits = ffi.hasFulltext(h)
        ? ffi.search(h, query, k: k)
        : ffi.suggest(h, query, k: k);
    return hits;
  }

  /// Raw entry bytes + mimetype, for the WebView reader / loopback server.
  Future<ZimContent?> content(String path) async {
    if (!await ensureOpen()) return null;
    return _ffi!.get(_handle!, path);
  }

  /// The archive's landing-page path (used as the reader's home).
  Future<String> mainPath() async {
    if (!await ensureOpen()) return '';
    return _ffi!.mainPath(_handle!);
  }

  /// Plain-text lead of an article, trimmed to [maxChars] at a line boundary —
  /// what we inject into the LLM as grounding context.
  Future<String> leadText(String path, {int maxChars = 5000}) async {
    final c = await content(path);
    if (c == null) return '';
    final mime = c.mimetype.toLowerCase();
    if (!mime.contains('html') && !mime.contains('text')) return '';
    var text = htmlToPlainText(String.fromCharCodes(c.bytes));
    text = text.trim();
    if (text.length <= maxChars) return text;
    final cut = text.lastIndexOf('\n', maxChars);
    return text.substring(0, cut > maxChars ~/ 2 ? cut : maxChars).trim();
  }

  /// Conservative confidence gate for auto-grounding: the top hit's title
  /// should share a meaningful word with the query (avoids injecting unrelated
  /// articles into ordinary chat).
  bool isConfident(String query, ZimHit hit) {
    final qWords = significantWords(query).toSet();
    if (qWords.isEmpty) return false;
    final tWords = significantWords(hit.title).toSet();
    final overlap = tWords.where(qWords.contains).length;
    // Strong: the title shares meaningful words with the query.
    if (overlap >= tWords.length || overlap >= 2 ||
        (tWords.length == 1 && overlap == 1)) {
      return true;
    }
    // Acronyms/synonyms: the title may not match (e.g. "UFOs" vs "Unidentified
    // flying object"), but the full-text snippet — the matched excerpt — will
    // contain the query term. Accept when a meaningful query word appears there.
    final snip = hit.snippet.toLowerCase();
    return qWords.any((w) => snip.contains(w));
  }

}
