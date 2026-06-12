import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'model_catalog.dart';

/// Files `cactus_init` requires in a model directory. The transpiled graph lives
/// under components/manifest.json; raw weights + tokenizer sit at root.
const List<String> _requiredFiles = [
  'config.txt',
  'token_embeddings.weights',
  'vocab.txt',
  'tokenizer_config.txt',
  'components/manifest.json',
];

/// Embedding bundles (text_embedding component, no decoder) carry fewer root
/// files, so they validate against just the essentials.
const List<String> _requiredEmbedderFiles = [
  'config.txt',
  'components/manifest.json',
];

/// Reports install progress. [progress] is 0..1 during download, null during
/// the indeterminate unpack/copy phases.
typedef ProgressCallback = void Function(String phase, double? progress);

class ModelManager {
  Future<Directory> _modelDir(String id) async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/models/$id');
  }

  Future<bool> _isValid(Directory dir, {bool embedder = false}) async {
    if (!await dir.exists()) return false;
    for (final name in embedder ? _requiredEmbedderFiles : _requiredFiles) {
      if (!await File('${dir.path}/$name').exists()) return false;
    }
    return true;
  }

  /// Whether a usable copy of [spec] is already available.
  Future<bool> isInstalled(ModelSpec spec) async {
    if (spec.isSideloaded) {
      return _isValid(Directory(spec.localPath!), embedder: spec.isEmbedder);
    }
    return _isValid(await _modelDir(spec.id), embedder: spec.isEmbedder);
  }

  /// Ensures [spec] is available, returning its directory. Sideloaded models are
  /// used in place; bundled/downloaded models are unpacked into app storage.
  Future<String> ensureInstalled(ModelSpec spec, ProgressCallback onProgress) async {
    if (spec.isSideloaded) {
      final dir = Directory(spec.localPath!);
      if (!await _isValid(dir, embedder: spec.isEmbedder)) {
        throw Exception('Model folder not found or invalid: ${spec.localPath}');
      }
      return dir.path;
    }

    final modelDir = await _modelDir(spec.id);
    if (await _isValid(modelDir, embedder: spec.isEmbedder)) return modelDir.path;

    final tmp = await getTemporaryDirectory();
    final zipPath = '${tmp.path}/${spec.id}.zip';

    if (spec.isBundled) {
      onProgress('Preparing model…', null);
      final data = await rootBundle.load(spec.asset!);
      await File(zipPath).writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    } else {
      await _download(spec.url!, zipPath, onProgress);
    }

    onProgress('Unpacking…', null);
    await Isolate.run(() => _extractZip(zipPath, modelDir.path));
    _promoteSingleRoot(modelDir);

    if (!await _isValid(modelDir)) {
      try {
        await modelDir.delete(recursive: true);
      } catch (_) {}
      throw Exception('Model bundle is missing required files after unpacking.');
    }
    try {
      await File(zipPath).delete();
    } catch (_) {}
    return modelDir.path;
  }

  /// Scans [folder] (and its immediate subfolders) for valid Cactus model
  /// directories the user can use directly.
  Future<List<ModelSpec>> scanFolder(String folder) async {
    final root = Directory(folder);
    final found = <ModelSpec>[];

    Future<void> consider(Directory d) async {
      if (await _isValid(d)) {
        final name = d.path.split(Platform.pathSeparator).last;
        found.add(ModelSpec(
          id: 'sideload:${d.path}',
          name: name,
          sizeLabel: 'on device',
          localPath: d.path,
        ));
      }
    }

    if (!await root.exists()) return found;
    await consider(root);
    if (found.isEmpty) {
      for (final entry in root.listSync()) {
        if (entry is Directory) await consider(entry);
      }
    }
    return found;
  }

  /// Streams the bundle to a `.part` file with HTTP Range resume. If a previous
  /// attempt left a partial file, the download continues from where it stopped;
  /// on completion the `.part` is promoted to the final zip.
  Future<void> _download(String url, String finalZipPath, ProgressCallback onProgress) async {
    final partFile = File('$finalZipPath.part');
    var existing = await partFile.exists() ? await partFile.length() : 0;

    onProgress(existing > 0 ? 'Resuming download…' : 'Downloading…', null);
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url));
      if (existing > 0) req.headers['range'] = 'bytes=$existing-';
      final resp = await client.send(req);

      int total;
      IOSink sink;
      if (resp.statusCode == 206) {
        total = _contentRangeTotal(resp.headers['content-range']) ??
            (existing + (resp.contentLength ?? 0));
        sink = partFile.openWrite(mode: FileMode.append);
      } else if (resp.statusCode == 200) {
        existing = 0; // server ignored the range — restart cleanly
        total = resp.contentLength ?? 0;
        sink = partFile.openWrite();
      } else {
        throw Exception('Download failed: HTTP ${resp.statusCode}');
      }

      var received = existing;
      try {
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress('Downloading…', received / total);
        }
      } finally {
        await sink.close(); // flush whatever we got (partial survives for resume)
      }
    } finally {
      client.close();
    }

    if (await File(finalZipPath).exists()) await File(finalZipPath).delete();
    await partFile.rename(finalZipPath);
  }
}

int? _contentRangeTotal(String? header) {
  // e.g. "bytes 200-1004/1005" -> 1005
  if (header == null) return null;
  final slash = header.lastIndexOf('/');
  if (slash < 0) return null;
  return int.tryParse(header.substring(slash + 1).trim());
}

/// Runs inside an `Isolate.run` — extracts the zip to [outDirPath].
void _extractZip(String zipPath, String outDirPath) {
  final bytes = File(zipPath).readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);
  final outDir = Directory(outDirPath)..createSync(recursive: true);
  for (final entry in archive) {
    final outPath = '${outDir.path}/${entry.name}';
    if (entry.isFile) {
      File(outPath)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(entry.content as List<int>);
    } else {
      Directory(outPath).createSync(recursive: true);
    }
  }
}

/// If the archive wrapped everything in one top-level directory, hoist its
/// contents up so `config.txt` sits at the model-dir root.
void _promoteSingleRoot(Directory outDir) {
  if (File('${outDir.path}/config.txt').existsSync()) return;
  final children = outDir
      .listSync()
      .where((e) => e.path.split(Platform.pathSeparator).last != '__MACOSX')
      .toList();
  if (children.length != 1 || children.first is! Directory) return;
  final nested = children.first as Directory;
  if (!File('${nested.path}/config.txt').existsSync()) return;
  for (final child in nested.listSync()) {
    final name = child.path.split(Platform.pathSeparator).last;
    child.renameSync('${outDir.path}/$name');
  }
  nested.deleteSync();
}
