import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'app_prefs.dart';
import 'model_catalog.dart';

/// A document the user added for question-answering.
class DocumentInfo {
  DocumentInfo({
    required this.id,
    required this.name,
    required this.chars,
    this.sourcePath,
  });
  final String id; // corpus filename stem
  final String name; // original filename shown to the user
  final int chars; // extracted character count
  // Absolute path of the original file on the device, so citations can open it
  // (null for documents added before this was tracked).
  final String? sourcePath;

  /// The folder the original file lives in (for grouping in the browser).
  String get folder {
    final p = sourcePath;
    if (p == null) return 'Unknown location';
    final i = p.lastIndexOf('/');
    return i <= 0 ? '/' : p.substring(0, i);
  }

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'chars': chars, 'sourcePath': sourcePath};
  static DocumentInfo fromJson(Map<String, dynamic> j) => DocumentInfo(
        id: j['id'] as String,
        name: j['name'] as String,
        chars: (j['chars'] as num).toInt(),
        sourcePath: j['sourcePath'] as String?,
      );
}

/// Outcome counts of a bulk folder import.
class BulkImportResult {
  int added = 0;
  int skippedExisting = 0;
  int skippedOther = 0; // too large / empty
  int skippedKnownBad = 0; // previously failed — skipped without re-reading
  int failed = 0; // unreadable or no extractable text (e.g. scanned PDFs)
}

/// Manages the on-device document corpus that the RAG embedder indexes.
///
/// Extracted plain text for each document is written as `<id>.txt` into a
/// single corpus directory; the Cactus engine builds its hybrid (embedding +
/// BM25) index over that directory. A small `_docs.json` tracks the original
/// filenames so the UI can list and remove documents.
class DocumentService {
  static const List<String> supportedExtensions = ['pdf', 'txt', 'md', 'text'];

  /// Pack schema version (bump when the on-disk layout changes).
  static const int schemaVersion = 1;

  /// The app's default corpus directory (used when no custom location is set).
  Future<Directory> _defaultDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/corpus');
  }

  /// Resolves the active corpus directory: a user-chosen location (e.g. an SD
  /// card) if set and usable, otherwise the app's default directory. Falls back
  /// to the default if the custom path can't be created (e.g. card removed).
  Future<Directory> corpusDir() async {
    final custom = await loadCorpusLocation();
    Directory dir = custom.isNotEmpty ? Directory(custom) : await _defaultDir();
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
    } catch (_) {
      dir = await _defaultDir();
      if (!await dir.exists()) await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> corpusPath() async => (await corpusDir()).path;

  /// A human-readable label for the current corpus location.
  Future<String> locationLabel() async {
    final custom = await loadCorpusLocation();
    return custom.isEmpty ? 'App storage (default)' : custom;
  }

  Future<bool> get usingCustomLocation async =>
      (await loadCorpusLocation()).isNotEmpty;

  // ── Portable pack manifest ────────────────────────────────────────────────

  Future<File> _manifestFile() async => File('${await corpusPath()}/manifest.json');

  Future<Map<String, dynamic>?> readManifest() async =>
      readManifestAt(await corpusPath());

  /// Reads the pack manifest at an arbitrary [path] without changing the active
  /// location (used to inspect a folder the user is considering).
  Future<Map<String, dynamic>?> readManifestAt(String path) async {
    final f = File('$path/manifest.json');
    if (!await f.exists()) return null;
    try {
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Like [incompatibilityReason] but for a pack at an arbitrary [path].
  Future<String?> incompatibilityReasonAt(String path) async {
    final m = await readManifestAt(path);
    if (m == null) return null;
    final schema = m['schemaVersion'];
    if (schema is int && schema > schemaVersion) {
      return 'This archive was made by a newer app version.';
    }
    final embedder = m['embedderId'];
    if (embedder is String && embedder != kEmbedderModel.id) {
      return 'This archive was indexed with a different embedding model '
          '($embedder); search results would be unreliable.';
    }
    return null;
  }

  /// Records which embedder/schema built this pack, so a different install can
  /// validate before reusing it.
  Future<void> _writeManifest(int documentCount) async {
    final now = DateTime.now().toIso8601String();
    final existing = await readManifest() ?? {};
    final manifest = {
      'schemaVersion': schemaVersion,
      'embedderId': kEmbedderModel.id,
      'app': 'Eva',
      'createdAt': existing['createdAt'] ?? now,
      'updatedAt': now,
      'documentCount': documentCount,
    };
    await (await _manifestFile()).writeAsString(jsonEncode(manifest));
  }

  /// Returns a reason the pack at the current location can't be reused, or null
  /// if it's compatible (or empty/new). Guards against opening a pack built with
  /// a different embedder after a reinstall.
  Future<String?> incompatibilityReason() async {
    final m = await readManifest();
    if (m == null) return null; // no pack yet — fine to start fresh
    final schema = m['schemaVersion'];
    if (schema is int && schema > schemaVersion) {
      return 'This archive was made by a newer app version.';
    }
    final embedder = m['embedderId'];
    if (embedder is String && embedder != kEmbedderModel.id) {
      return 'This archive was indexed with a different embedding model '
          '($embedder); search results would be unreliable.';
    }
    return null;
  }

  // ── Location management ───────────────────────────────────────────────────

  /// Switches to [path] as the corpus location, reusing any existing pack there.
  Future<void> useLocation(String path) async => saveCorpusLocation(path);

  /// Reverts to the app's default corpus directory.
  Future<void> useDefaultLocation() async => saveCorpusLocation('');

  /// Copies the current corpus (documents + index) into [path], then switches
  /// to it — for moving the archive onto an SD card. Returns the number of
  /// files copied.
  Future<int> moveCorpusTo(String path) async {
    final src = await corpusDir();
    final dst = Directory(path);
    if (!await dst.exists()) await dst.create(recursive: true);
    var copied = 0;
    await for (final e in src.list()) {
      if (e is File) {
        final name = e.path.split(Platform.pathSeparator).last;
        await e.copy('${dst.path}/$name');
        copied++;
      }
    }
    await useLocation(path);
    await _writeManifest((await list()).length); // refresh at the new location
    return copied;
  }

  Future<File> _metaFile() async => File('${await corpusPath()}/_docs.json');

  Future<List<DocumentInfo>> list() async {
    final f = await _metaFile();
    if (!await f.exists()) return [];
    try {
      final raw = jsonDecode(await f.readAsString()) as List;
      return raw
          .map((e) => DocumentInfo.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<bool> get hasDocuments async => (await list()).isNotEmpty;

  /// Reads back the extracted plain text for a document (for indexing).
  Future<String> readText(String id) async {
    final f = File('${await corpusPath()}/$id.txt');
    return await f.exists() ? f.readAsString() : '';
  }

  Future<void> _saveList(List<DocumentInfo> docs) async {
    final f = await _metaFile();
    await f.writeAsString(jsonEncode(docs.map((d) => d.toJson()).toList()));
    await _writeManifest(docs.length);
  }

  /// Extracts text from [filePath] (PDF/txt/md), stores it in the corpus, and
  /// records it. Returns the new document's info. Throws if no text could be
  /// extracted (e.g. a scanned/image-only PDF).
  Future<DocumentInfo> addFile(String filePath,
      {Duration extractTimeout = const Duration(seconds: 45)}) async {
    final name = filePath.split(Platform.pathSeparator).last;
    final lower = name.toLowerCase();
    final String text;
    if (lower.endsWith('.pdf')) {
      final bytes = await File(filePath).readAsBytes();
      // Time-bounded + killable: a single pathological/huge PDF must not stall
      // a bulk import. On timeout the worker isolate is terminated.
      text = await _extractPdfBounded(bytes, extractTimeout);
    } else {
      text = await File(filePath).readAsString();
    }
    if (text.trim().length < 8) {
      throw Exception(
          'No selectable text found (a scanned/image PDF needs OCR, not yet supported).');
    }

    final id = _uniqueId(name, await list());
    await File('${await corpusPath()}/$id.txt').writeAsString(text);
    final info = DocumentInfo(
        id: id, name: name, chars: text.length, sourcePath: filePath);
    final docs = await list()..add(info);
    await _saveList(docs);
    return info;
  }

  /// Records the original [path] for an already-present document (matched by
  /// filename) that was added before paths were tracked — cheap backfill so a
  /// re-scan makes old documents openable without re-extracting them.
  Future<void> _backfillPath(String name, String path) async {
    final docs = await list();
    var changed = false;
    final updated = [
      for (final d in docs)
        if (d.name == name && (d.sourcePath == null || d.sourcePath!.isEmpty))
          () {
            changed = true;
            return DocumentInfo(
                id: d.id, name: d.name, chars: d.chars, sourcePath: path);
          }()
        else
          d
    ];
    if (changed) await _saveList(updated);
  }

  /// Walks [root] recursively and adds every supported document found (used by
  /// "scan phone storage" / "import folder"). Skips `Android/` app data and
  /// hidden directories, files over [maxBytes], and documents whose filename is
  /// already in the corpus. Errors are counted per file, never fatal.
  /// [onProgress] reports running counts; return false from [shouldContinue]
  /// to stop early (already-added documents stay).
  Future<BulkImportResult> importFolder(
    String root, {
    int maxBytes = 64 * 1024 * 1024,
    void Function(int scanned, BulkImportResult partial)? onProgress,
    bool Function()? shouldContinue,
  }) async {
    final res = BulkImportResult();
    final existing = (await list()).map((d) => d.name).toSet();
    final skipped = await loadSkipped();
    final initialSkipped = skipped.length;
    var scanned = 0;
    final stack = <Directory>[Directory(root)];

    while (stack.isNotEmpty) {
      if (shouldContinue != null && !shouldContinue()) break;
      final dir = stack.removeLast();
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } catch (_) {
        continue; // unreadable directory — skip
      }
      for (final e in entries) {
        if (shouldContinue != null && !shouldContinue()) break;
        final name = e.path.split(Platform.pathSeparator).last;
        if (e is Directory) {
          // App-private data (inaccessible/huge) and hidden dirs are skipped.
          if (name == 'Android' || name.startsWith('.')) continue;
          stack.add(e);
          continue;
        }
        if (e is! File) continue;
        scanned++;
        final lower = name.toLowerCase();
        if (!supportedExtensions.any((x) => lower.endsWith('.$x'))) {
          if (scanned % 200 == 0) onProgress?.call(scanned, res);
          continue;
        }
        if (existing.contains(name)) {
          res.skippedExisting++;
          // Backfill the original path for docs added before paths were tracked,
          // so citations can open them — no re-extraction needed.
          await _backfillPath(name, e.path);
          onProgress?.call(scanned, res);
          continue;
        }
        // Known to have failed before — skip instantly, no re-read.
        if (skipped.contains(e.path)) {
          res.skippedKnownBad++;
          onProgress?.call(scanned, res);
          continue;
        }
        int size;
        try {
          size = await e.length();
        } catch (_) {
          res.failed++;
          skipped.add(e.path);
          continue;
        }
        if (size > maxBytes || size < 16) {
          res.skippedOther++;
          skipped.add(e.path); // won't become valid by re-scanning
          onProgress?.call(scanned, res);
          continue;
        }
        try {
          final info = await addFile(e.path);
          existing.add(info.name);
          res.added++;
        } catch (_) {
          res.failed++; // e.g. image-only PDF with no extractable text
          skipped.add(e.path); // remember so future scans don't re-parse it
        }
        onProgress?.call(scanned, res);
      }
      // Hand the event loop back so the UI stays responsive between folders.
      await Future<void>.delayed(Duration.zero);
    }
    // Persist newly-discovered bad files once (cheap; avoids per-file writes).
    if (skipped.length != initialSkipped) await _saveSkipped(skipped);
    return res;
  }

  // ── Skip-list (files known to have no extractable text) ───────────────────
  // Persisted by absolute path in the corpus pack so a re-scan doesn't re-parse
  // the same image-only/failed PDFs every time. Device-specific (paths), which
  // is fine — the failures are device-specific too.

  Future<File> _skipFile() async => File('${await corpusPath()}/_skipped.json');

  Future<Set<String>> loadSkipped() async {
    final f = await _skipFile();
    if (!await f.exists()) return <String>{};
    try {
      return (jsonDecode(await f.readAsString()) as List).cast<String>().toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> _saveSkipped(Set<String> paths) async =>
      (await _skipFile()).writeAsString(jsonEncode(paths.toList()));

  Future<int> skippedCount() async => (await loadSkipped()).length;

  /// Forgets the skip-list so a future scan retries those files (e.g. after the
  /// files changed, or once OCR is available).
  Future<void> clearSkipped() async {
    final f = await _skipFile();
    if (await f.exists()) await f.delete();
  }

  Future<void> remove(String id) async {
    final f = File('${await corpusPath()}/$id.txt');
    if (await f.exists()) await f.delete();
    final docs = (await list()).where((d) => d.id != id).toList();
    await _saveList(docs);
  }

  Future<void> clearAll() async {
    final dir = await corpusDir();
    if (await dir.exists()) {
      await for (final e in dir.list()) {
        if (e is File) await e.delete();
      }
    }
  }

  String _uniqueId(String name, List<DocumentInfo> existing) {
    final base = name
        .replaceAll(RegExp(r'\.[^.]+$'), '')
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    final taken = existing.map((d) => d.id).toSet();
    var id = base.isEmpty ? 'doc' : base;
    var n = 1;
    while (taken.contains(id)) {
      id = '${base}_$n';
      n++;
    }
    return id;
  }
}

/// Runs [_extractPdfText] in a dedicated isolate with a hard [limit]; if it
/// exceeds the limit (a pathological/huge PDF) the isolate is killed and an
/// empty string is returned, so a bulk import never hangs on one file.
Future<String> _extractPdfBounded(List<int> bytes, Duration limit) async {
  final port = ReceivePort();
  final iso = await Isolate.spawn(_pdfIsolateEntry, [port.sendPort, bytes]);
  try {
    final result = await port.first.timeout(limit);
    return result is String ? result : '';
  } on TimeoutException {
    iso.kill(priority: Isolate.immediate);
    return '';
  } catch (_) {
    iso.kill(priority: Isolate.immediate);
    return '';
  } finally {
    port.close();
  }
}

void _pdfIsolateEntry(List<dynamic> args) {
  final SendPort send = args[0] as SendPort;
  final List<int> bytes = (args[1] as List).cast<int>();
  try {
    send.send(_extractPdfText(bytes));
  } catch (_) {
    send.send('');
  }
}

/// Extracts text from PDF [bytes], inserting `[Page N]` markers so retrieved
/// chunks carry page context for citations. Runs in a background isolate.
String _extractPdfText(List<int> bytes) {
  final doc = PdfDocument(inputBytes: bytes);
  final extractor = PdfTextExtractor(doc);
  final buf = StringBuffer();
  try {
    final count = doc.pages.count;
    for (var i = 0; i < count; i++) {
      final pageText =
          extractor.extractText(startPageIndex: i, endPageIndex: i).trim();
      if (pageText.isNotEmpty) {
        buf.writeln('\n[Page ${i + 1}]');
        buf.writeln(pageText);
      }
    }
  } finally {
    doc.dispose();
  }
  return buf.toString();
}
