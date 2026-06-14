import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_location_marker/flutter_map_location_marker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'app_prefs.dart';
import 'maps/map_ref.dart';
import 'maps/map_service.dart';

/// Full-screen map for a [MapRef]: streets/satellite tiles (cached on demand),
/// the destination, an optional route, and the device's live GPS dot with a
/// distance/bearing readout — so the user can walk toward the place. Opens like
/// the document/Wikipedia viewers.
class MapViewerScreen extends StatefulWidget {
  const MapViewerScreen({super.key, required this.title, required this.ref});

  final String title;
  final MapRef ref;

  @override
  State<MapViewerScreen> createState() => _MapViewerScreenState();
}

class _MapViewerScreenState extends State<MapViewerScreen> {
  final MapController _controller = MapController();
  TileProvider? _streets;
  TileProvider? _satellite;
  bool _satelliteOn = false;
  bool _saving = false; // prefetching the visible area for offline use
  LatLng? _here; // live position, for the distance readout
  StreamSubscription<Position>? _posSub;

  LatLng get _dest => LatLng(widget.ref.lat, widget.ref.lon);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _satelliteOn = await loadMapsSatellite();
    final svc = MapService.instance;
    final streets = await svc.tileProvider('streets');
    final satellite = await svc.tileProvider('satellite');
    if (!mounted) return;
    setState(() {
      _streets = streets;
      _satellite = satellite;
    });
    await _startLocation();
  }

  Future<void> _startLocation() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }
      _posSub = Geolocator.getPositionStream(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5),
      ).listen((p) {
        if (mounted) setState(() => _here = LatLng(p.latitude, p.longitude));
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  List<LatLng> get _route {
    final flat = widget.ref.routeLatLngs;
    if (flat == null || flat.length < 4) return const [];
    return [
      for (var i = 0; i + 1 < flat.length; i += 2) LatLng(flat[i], flat[i + 1]),
    ];
  }

  String? get _distanceText {
    final here = _here;
    if (here == null) return null;
    const d = Distance();
    final meters = d.as(LengthUnit.Meter, here, _dest);
    final dist = meters >= 1000
        ? '${(meters / 1000).toStringAsFixed(1)} km'
        : '${meters.round()} m';
    final brg = d.bearing(here, _dest);
    return '$dist · ${_compass(brg)}';
  }

  String _compass(double bearing) {
    const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    return dirs[(((bearing % 360) + 22.5) ~/ 45) % 8];
  }

  /// Caches the tiles covering the current viewport (a few zoom levels) so this
  /// area keeps working offline. User-initiated to respect tile-server fair-use.
  Future<void> _saveArea() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bounds = _controller.camera.visibleBounds;
      final z = _controller.camera.zoom.round();
      final count = await MapService.instance.prefetchArea(
        bounds,
        layerKey: _satelliteOn ? 'satellite' : 'streets',
        satellite: _satelliteOn,
        fromZoom: (z - 1).clamp(3, 18),
        toZoom: (z + 2).clamp(3, 18),
      );
      messenger.showSnackBar(SnackBar(
          content: Text('Saved $count tiles — this area now works offline.')));
    } catch (_) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Could not save this area.')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _streets != null && _satellite != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: _saving ? 'Saving…' : 'Save this area offline',
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.download_for_offline_outlined),
            onPressed: _saving ? null : _saveArea,
          ),
          IconButton(
            tooltip: _satelliteOn ? 'Streets' : 'Satellite',
            icon: Icon(_satelliteOn ? Icons.map_outlined : Icons.satellite_alt),
            onPressed: () async {
              setState(() => _satelliteOn = !_satelliteOn);
              await saveMapsSatellite(_satelliteOn);
            },
          ),
        ],
      ),
      body: !ready
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                FlutterMap(
                  mapController: _controller,
                  options: MapOptions(
                    initialCenter: _dest,
                    initialZoom: widget.ref.zoom,
                    maxZoom: 19,
                    // For a route, frame the whole path instead of just the end.
                    initialCameraFit: _route.length < 2
                        ? null
                        : CameraFit.bounds(
                            bounds: LatLngBounds.fromPoints(_route),
                            padding: const EdgeInsets.all(48),
                          ),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: _satelliteOn
                          ? MapService.satelliteUrl
                          : MapService.streetUrl,
                      tileProvider: _satelliteOn ? _satellite! : _streets!,
                      maxNativeZoom: 19,
                      userAgentPackageName: 'radio.geogram.eva',
                      // A blank tile (rather than an error X) when offline + uncached.
                      errorTileCallback: (tile, error, stack) {},
                    ),
                    if (_route.isNotEmpty)
                      PolylineLayer(polylines: [
                        Polyline(
                          points: _route,
                          strokeWidth: 5,
                          color: Colors.blueAccent,
                        ),
                      ]),
                    MarkerLayer(markers: [
                      Marker(
                        point: _dest,
                        width: 40,
                        height: 40,
                        alignment: Alignment.topCenter,
                        child: const Icon(Icons.location_on,
                            color: Colors.red, size: 40),
                      ),
                    ]),
                    CurrentLocationLayer(),
                  ],
                ),
                if (_distanceText != null)
                  Positioned(
                    left: 12,
                    bottom: 12,
                    child: _pill(Icons.straighten, _distanceText!),
                  ),
              ],
            ),
      floatingActionButton: !ready
          ? null
          : FloatingActionButton(
              tooltip: 'Centre on me',
              onPressed: () {
                final here = _here;
                if (here != null) _controller.move(here, _controller.camera.zoom);
              },
              child: const Icon(Icons.my_location),
            ),
    );
  }

  Widget _pill(IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
