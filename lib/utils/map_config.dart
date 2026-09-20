import 'package:coordtransform/coordtransform.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

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
