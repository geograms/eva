import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;

/// A flutter_map tile provider that caches each tile to a file on first fetch
/// and serves it from disk afterwards — so areas the user has viewed work
/// offline. Tiles live under `<cacheRoot>/<layerKey>/<z>/<x>/<y>.png` in the
/// user-chosen map folder; pointing the app at a folder that already has them
/// reuses the cache with no network.
class FileCacheTileProvider extends TileProvider {
  FileCacheTileProvider({
    required this.cacheRoot,
    required this.layerKey,
    this.userAgent = 'radio.geogram.eva',
  });

  /// Root cache directory (the map data folder).
  final String cacheRoot;

  /// Subfolder per layer ('streets', 'satellite') so layers don't collide.
  final String layerKey;
  final String userAgent;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final url = getTileUrl(coordinates, options);
    final file = File('$cacheRoot/$layerKey/${coordinates.z}/'
        '${coordinates.x}/${coordinates.y}.png');
    return _CachedTileImage(file, url, userAgent);
  }
}

/// Image provider that returns a cached tile file, or fetches + caches it.
class _CachedTileImage extends ImageProvider<_CachedTileImage> {
  _CachedTileImage(this.file, this.url, this.userAgent);
  final File file;
  final String url;
  final String userAgent;

  @override
  Future<_CachedTileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_CachedTileImage>(this);

  @override
  ImageStreamCompleter loadImage(
      _CachedTileImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1.0,
      debugLabel: url,
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    Uint8List? bytes;
    if (await file.exists()) {
      try {
        bytes = await file.readAsBytes();
      } catch (_) {}
    }
    if (bytes == null || bytes.isEmpty) {
      // Not cached yet — fetch online and store for offline reuse.
      final resp = await http.get(Uri.parse(url),
          headers: {'User-Agent': userAgent});
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) {
        throw Exception('tile ${resp.statusCode}');
      }
      bytes = resp.bodyBytes;
      try {
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: false);
      } catch (_) {
        // cache write best-effort
      }
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is _CachedTileImage && other.file.path == file.path;

  @override
  int get hashCode => file.path.hashCode;
}
