import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'app_prefs.dart';
import 'model_catalog.dart';

/// A document the user added for question-answering.
class DocumentInfo {
  DocumentInfo({required this.id, required this.name, required this.chars});
  final String id; // corpus filename stem
  final String name; // original filename shown to the user
  final int chars; // extracted character count

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'chars': chars};
  static DocumentInfo fromJson(Map<String, dynamic> j) => DocumentInfo(
        id: j['id'] as String,
        name: j['name'] as String,
        chars: (j['chars'] as num).toInt(),
      );
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
  Future<DocumentInfo> addFile(String filePath) async {
    final name = filePath.split(Platform.pathSeparator).last;
    final lower = name.toLowerCase();
    final String text;
    if (lower.endsWith('.pdf')) {
      final bytes = await File(filePath).readAsBytes();
      text = await Isolate.run(() => _extractPdfText(bytes));
    } else {
      text = await File(filePath).readAsString();
    }
    if (text.trim().length < 8) {
      throw Exception(
          'No selectable text found (a scanned/image PDF needs OCR, not yet supported).');
    }

    final id = _uniqueId(name, await list());
    await File('${await corpusPath()}/$id.txt').writeAsString(text);
    final info = DocumentInfo(id: id, name: name, chars: text.length);
    final docs = await list()..add(info);
    await _saveList(docs);
    return info;
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
