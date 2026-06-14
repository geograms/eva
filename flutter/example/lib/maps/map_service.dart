import 'dart:convert';
import 'dart:io';

import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import '../app_prefs.dart';
import 'file_cache_tile_provider.dart';
import 'geo_cache.dart';

/// Coordinates maps for Eva: tile sources (cached on demand to the chosen
/// folder), online geocoding with a local cache, and reachability checks. Tiles
/// and geocodes the user has seen keep working offline.
class MapService {
  MapService._();
  static final MapService instance = MapService._();

  static const String userAgent = 'radio.geogram.eva';
  // Streets/roads/paths/POIs/labels (OpenStreetMap raster).
  static const String streetUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  // Satellite imagery (ESRI World Imagery — note z/y/x order).
  static const String satelliteUrl =
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/'
      'MapServer/tile/{z}/{y}/{x}';

  GeoCache? _cache;
  String? _root;

  /// The map cache directory (chosen folder, else app external storage).
  Future<String> cacheRoot() async {
    final folder = await loadMapsFolder();
    Directory dir;
    if (folder.isNotEmpty) {
      dir = Directory('$folder/maps');
    } else {
      final ext = await getExternalStorageDirectory();
      dir = Directory(
          '${ext?.path ?? (await getApplicationSupportDirectory()).path}/maps');
    }
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  Future<GeoCache> _geoCache() async {
    final root = await cacheRoot();
    if (_cache != null && _root == root) return _cache!;
    _cache?.close();
    _root = root;
    _cache = GeoCache.open('$root/geo.sqlite');
    return _cache!;
  }

  /// Tile provider for a layer ('streets' / 'satellite'), caching to the folder.
  Future<TileProvider> tileProvider(String layerKey) async =>
      FileCacheTileProvider(
          cacheRoot: await cacheRoot(), layerKey: layerKey, userAgent: userAgent);

  Future<bool> hasNetwork() async {
    try {
      final r = await InternetAddress.lookup('nominatim.openstreetmap.org')
          .timeout(const Duration(seconds: 4));
      return r.isNotEmpty && r.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Resolves [text] to a place. Returns a cached result first (works offline);
  /// otherwise geocodes online via Nominatim and caches it. Null if it can't be
  /// resolved (e.g. offline + not cached).
  Future<GeoResult?> geocode(String text, {int nowMs = 0}) async {
    final query = text.trim();
    if (query.isEmpty) return null;
    final cache = await _geoCache();
    final key = query.toLowerCase();
    final cached = cache.get(key);
    if (cached != null) return cached;
    if (!await hasNetwork()) return null;
    try {
      final uri = Uri.parse('https://nominatim.openstreetmap.org/search'
          '?format=jsonv2&limit=1&q=${Uri.encodeQueryComponent(query)}');
      final resp = await http
          .get(uri, headers: {'User-Agent': userAgent})
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;
      final list = jsonDecode(resp.body);
      if (list is! List || list.isEmpty) return null;
      final m = list.first as Map<String, dynamic>;
      final lat = double.tryParse('${m['lat']}');
      final lon = double.tryParse('${m['lon']}');
      if (lat == null || lon == null) return null;
      final name = (m['display_name'] as String?) ?? query;
      final result = GeoResult(lat, lon, name);
      cache.put(key, result, nowMs);
      return result;
    } catch (_) {
      return null;
    }
  }

  /// A walking route from ([fromLat],[fromLon]) to ([toLat],[toLon]) as a flat
  /// [lat,lon,lat,lon,...] polyline. Cache-first (so a route computed once
  /// replays offline); otherwise queries OSRM and caches it. Null when it can't
  /// be computed (offline + uncached, or no road/path found).
  Future<List<double>?> route(
      double fromLat, double fromLon, double toLat, double toLon,
      {int nowMs = 0}) async {
    // Round the origin to ~100 m and the destination to ~10 m so repeated walks
    // of the same trip reuse one cached route instead of missing every time.
    String r(double v, int dp) => v.toStringAsFixed(dp);
    final key = 'foot:${r(fromLat, 3)},${r(fromLon, 3)}->'
        '${r(toLat, 4)},${r(toLon, 4)}';
    final cache = await _geoCache();
    final cached = cache.getRoute(key);
    if (cached != null) {
      final list = jsonDecode(cached);
      if (list is List) return [for (final e in list) (e as num).toDouble()];
    }
    if (!await hasNetwork()) return null;
    try {
      // OSRM public demo server, walking profile; coords are lon,lat order.
      final uri = Uri.parse('https://router.project-osrm.org/route/v1/foot/'
          '$fromLon,$fromLat;$toLon,$toLat?overview=full&geometries=geojson');
      final resp = await http
          .get(uri, headers: {'User-Agent': userAgent})
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body);
      if (body is! Map ||
          body['routes'] is! List ||
          (body['routes'] as List).isEmpty) {
        return null;
      }
      final coords = (body['routes'] as List).first['geometry']['coordinates'];
      if (coords is! List || coords.isEmpty) return null;
      // GeoJSON is [lon,lat]; store as flat [lat,lon,...].
      final flat = <double>[];
      for (final c in coords) {
        flat.add((c[1] as num).toDouble());
        flat.add((c[0] as num).toDouble());
      }
      cache.putRoute(key, jsonEncode(flat), nowMs);
      return flat;
    } catch (_) {
      return null;
    }
  }

  LatLng latLng(GeoResult r) => LatLng(r.lat, r.lon);
}
