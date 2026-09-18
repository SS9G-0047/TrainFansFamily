import 'dart:convert';

import 'package:coordtransform/coordtransform.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart' as vt;
import 'package:latlong2/latlong.dart';

const String mapStyleAssetPath = 'lib/assets/config/map_style.json';

const String amapTileUrlTemplate =
    'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}';

const List<String> amapSubdomains = ['1', '2', '3', '4'];

const List<double> amapGrayscaleMatrix = <double>[
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0, 0, 0, 1, 0,
];

const String railwayTileUrlTemplate =
    'https://flutter-map.xhcminecraft.top/data/railway/{z}/{x}/{y}.pbf';

LatLng wgs84ToGcj02(double lat, double lon) {
  final result = CoordTransform.transformWGS84toGCJ02(lon, lat);
  return LatLng(result.lat, result.lon);
}

LatLng gcj02ToWgs84(double lat, double lon) {
  final result = CoordTransform.transformGCJ02toWGS84(lon, lat);
  return LatLng(result.lat, result.lon);
}

List<LatLng> wgs84ListToGcj02(List<LatLng> points) {
  return points.map((p) => wgs84ToGcj02(p.latitude, p.longitude)).toList();
}

vt.Theme? _cachedRailwayTheme;

Future<vt.Theme> loadRailwayTheme() async {
  final cached = _cachedRailwayTheme;
  if (cached != null) return cached;

  final jsonString = await rootBundle.loadString(mapStyleAssetPath);
  final style = jsonDecode(jsonString) as Map<String, dynamic>;
  _cachedRailwayTheme = vt.ThemeReader().read(style);
  return _cachedRailwayTheme!;
}

class MapAttribution extends StatelessWidget {
  const MapAttribution({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 4,
      right: 4,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(2),
          ),
          child: const Text(
            '©高德地图 & OpenStreetMap Contributors',
            style: TextStyle(fontSize: 10, color: Colors.black54),
          ),
        ),
      ),
    );
  }
}
