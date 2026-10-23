import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config/app_endpoints.dart';
import '../utils/map_config.dart';

/// OpenRailwayMap 车站信息
class RailwayStation {
  final String name;
  final double latitude; // WGS84
  final double longitude; // WGS84
  final String? uicRef;
  final String? type;

  const RailwayStation({
    required this.name,
    required this.latitude,
    required this.longitude,
    this.uicRef,
    this.type,
  });

  /// 获取 GCJ-02 坐标
  LatLng get gcj02 => wgs84ToGcj02(latitude, longitude);
}

/// OpenRailwayMap API 车站查询服务
class RailwayStationService {
  static const String _baseUrl = AppEndpoints.openRailwayMapBase;

  /// 按名称查询车站
  ///
  /// [name] 车站名称
  /// [limit] 返回结果数量限制
  static Future<List<RailwayStation>> searchByName(
    String name, {
    int limit = 5,
  }) async {
    try {
      final uri = Uri.parse(
        '$_baseUrl/facility?name=${Uri.encodeQueryComponent(name)}&limit=$limit',
      );

      final response = await http.get(
        uri,
        headers: {
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        return [];
      }

      final data = jsonDecode(response.body) as List<dynamic>;
      final stations = <RailwayStation>[];

      for (final item in data) {
        final map = item as Map<String, dynamic>;

        // 提取名称
        final name = map['name'] as String?;
        if (name == null || name.isEmpty) continue;

        // 提取坐标
        final lat = (map['latitude'] as num?)?.toDouble();
        final lon = (map['longitude'] as num?)?.toDouble();
        if (lat == null || lon == null) continue;

        // 只保留车站类型
        final type = map['type'] as String?;
        if (type != null && !type.contains('station') && type != 'halt') {
          continue;
        }

        stations.add(RailwayStation(
          name: name,
          latitude: lat,
          longitude: lon,
          uicRef: map['uic_ref'] as String?,
          type: type,
        ));
      }

      return stations;
    } catch (_) {
      return [];
    }
  }
}
