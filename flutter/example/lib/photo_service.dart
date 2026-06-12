import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

import 'app_prefs.dart';
import 'document_service.dart';
import 'photo_store.dart';

/// Running totals for a gallery scan.
class PhotoScanResult {
  int added = 0;
  int skippedExisting = 0;
  int failed = 0;
}

/// Indexes the device's photo gallery into a [PhotoStore]: walks image files,
/// reads the capture time (EXIF, falling back to the file date), classifies the
/// photo cheaply (screenshot/photo/other), generates a small cached JPEG
/// thumbnail, and stores it — so browsing and chat results are instant. The
/// content-understanding (captioning) pass is separate and runs later.
class PhotoService {
  PhotoService(this._docs);
  final DocumentService _docs;

  static const Set<String> imageExtensions = {
    'jpg', 'jpeg', 'png', 'heic', 'heif', 'webp', 'gif', 'bmp'
  };

  Future<String> _storePath() async => '${await _docs.corpusPath()}/photos.sqlite';

  Future<PhotoStore> openStore() async => PhotoStore.open(await _storePath());

  Future<File> _skipFile() async =>
      File('${await _docs.corpusPath()}/_photo_skip.json');

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

  Future<int> photoCount() async {
    final store = await openStore();
    try {
      return store.count;
    } finally {
      store.close();
    }
  }

  /// Walks [roots] (default: whole shared storage) and indexes new images.
  /// Throttled + resumable: already-indexed and known-bad paths are skipped.
  Future<PhotoScanResult> scan({
    List<String> roots = const ['/storage/emulated/0'],
    void Function(int scanned, PhotoScanResult partial)? onProgress,
    bool Function()? shouldContinue,
    Duration perItemDelay = Duration.zero,
  }) async {
    final res = PhotoScanResult();
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
          if (!imageExtensions.contains(ext)) continue;
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
            final info = await _indexOne(e);
            store.upsert(info);
            indexed.add(e.path);
            res.added++;
          } catch (_) {
            res.failed++;
            skip.add(e.path);
          }
          onProgress?.call(scanned, res);
          // Background throttle: spare CPU/battery between photos.
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

  Future<PhotoInfo> _indexOne(File f) async {
    final bytes = await f.readAsBytes();
    // Thumbnail (native, fast, small). Throws via empty result -> caught above.
    final thumb = await FlutterImageCompress.compressWithList(
      bytes,
      minWidth: 256,
      minHeight: 256,
      quality: 70,
      format: CompressFormat.jpeg,
    );
    if (thumb.isEmpty) throw Exception('no thumbnail');

    DateTime taken;
    int w = 0, h = 0;
    try {
      final tags = await readExifFromBytes(bytes);
      taken = _exifDate(tags) ?? (await f.lastModified());
      w = _exifInt(tags, 'EXIF ExifImageWidth') ??
          _exifInt(tags, 'Image ImageWidth') ??
          0;
      h = _exifInt(tags, 'EXIF ExifImageLength') ??
          _exifInt(tags, 'Image ImageLength') ??
          0;
    } catch (_) {
      taken = await f.lastModified();
    }

    final bucket = _bucket(f.path);
    return PhotoInfo(
      id: 0,
      path: f.path,
      takenAt: taken,
      width: w,
      height: h,
      size: await f.length(),
      bucket: bucket,
      type: _classify(f.path, bucket),
      thumb: thumb,
    );
  }

  String _bucket(String path) {
    final parts = path.split('/');
    return parts.length >= 2 ? parts[parts.length - 2] : '';
  }

  PhotoType _classify(String path, String bucket) {
    final p = path.toLowerCase();
    final b = bucket.toLowerCase();
    final name = path.split('/').last.toLowerCase();
    if (b.contains('screenshot') ||
        p.contains('/screenshots/') ||
        name.startsWith('screenshot') ||
        name.startsWith('screen_')) {
      return PhotoType.screenshot;
    }
    if (p.contains('/dcim/') || b == 'camera') return PhotoType.photo;
    return PhotoType.image;
  }

  DateTime? _exifDate(Map<String, IfdTag> tags) {
    for (final key in const [
      'EXIF DateTimeOriginal',
      'EXIF DateTimeDigitized',
      'Image DateTime'
    ]) {
      final v = tags[key]?.printable;
      if (v == null || v.isEmpty) continue;
      // Format: "YYYY:MM:DD HH:MM:SS"
      final m = RegExp(r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})')
          .firstMatch(v);
      if (m != null) {
        return DateTime(
          int.parse(m.group(1)!),
          int.parse(m.group(2)!),
          int.parse(m.group(3)!),
          int.parse(m.group(4)!),
          int.parse(m.group(5)!),
          int.parse(m.group(6)!),
        );
      }
    }
    return null;
  }

  int? _exifInt(Map<String, IfdTag> tags, String key) {
    final v = tags[key]?.printable;
    return v == null ? null : int.tryParse(v.trim());
  }
}

/// Drives the gallery scan as a continuous background task: auto-resumes until
/// the whole gallery is catalogued, throttled so the app stays responsive, and
/// pausable (e.g. while the model answers). Progress is observable for a banner.
class PhotoIndexController extends ChangeNotifier {
  PhotoIndexController(this._photos);
  final PhotoService _photos;

  bool _running = false;
  bool _paused = false;
  int _scanned = 0;
  int _added = 0;
  int _total = 0; // best-effort total in the index
  Completer<void>? _idle;

  bool get isIndexing => _running && !_paused;
  int get added => _added;
  int get scanned => _scanned;
  int get total => _total;

  /// Starts/continues the gallery scan if it hasn't fully completed yet. Safe to
  /// call repeatedly — coalesces into the running pass.
  Future<void> ensureRunning() async {
    if (_running || _paused) return;
    if (await loadPhotoScanDone()) return; // whole gallery already catalogued
    unawaited(_run());
  }

  /// Forces a fresh full pass (e.g. to pick up new photos).
  Future<void> rescan() async {
    await savePhotoScanDone(false);
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
      _total = await _photos.photoCount();
      final res = await _photos.scan(
        perItemDelay: const Duration(milliseconds: 20),
        onProgress: (n, p) {
          _scanned = n;
          _added = p.added;
          _total = (_total) < p.added ? p.added : _total;
          notifyListeners();
        },
        shouldContinue: () => !_paused,
      );
      // Completed the whole walk (not paused) — mark done so we don't re-walk.
      if (!_paused) {
        await savePhotoScanDone(true);
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
  }
}
