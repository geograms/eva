/// A map reference attached to a chat answer: where to centre, and an optional
/// destination/route. Pure data (no Flutter deps) so it persists in chat_store.
class MapRef {
  MapRef({
    required this.lat,
    required this.lon,
    this.zoom = 14,
    this.label,
    this.routeLatLngs,
  });

  final double lat;
  final double lon;
  final double zoom;
  final String? label; // place / destination name
  // Optional route polyline as flat [lat,lon,lat,lon,...] (v2 routing).
  final List<double>? routeLatLngs;

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lon': lon,
        'zoom': zoom,
        'label': label,
        if (routeLatLngs != null) 'route': routeLatLngs,
      };

  static MapRef fromJson(Map<String, dynamic> j) => MapRef(
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        zoom: (j['zoom'] as num?)?.toDouble() ?? 14,
        label: j['label'] as String?,
        routeLatLngs: (j['route'] as List?)?.map((e) => (e as num).toDouble()).toList(),
      );
}
