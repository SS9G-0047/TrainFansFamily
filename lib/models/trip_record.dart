import 'dart:math';

/// 行程类型。
enum TripType {
  walking('步行', '', null, 15.0, 10.0),
  cycling('骑行', '', null, 60.0, 15.0),
  car('汽车', '线路号', '线路号（留空自动获取）', 250.0, 30.0),
  train('火车', '车次', '车次（留空自动获取）', 400.0, 10.0),
  airplane('飞机', '航班号', '航班号（留空自动获取）', 1200.0, 30.0);

  final String label;
  final String idLabel;
  final String? idHint;
  final double maxSpeed;        // 合理速度上限 km/h
  final double maxAcceleration; // 合理加速度上限 km/h per second
  const TripType(this.label, this.idLabel, this.idHint, this.maxSpeed, this.maxAcceleration);

  /// 是否需要标识符输入。
  bool get hasIdentifier => idLabel.isNotEmpty;

  String get fromJsonKey => name;
}

/// 行程轨迹点模型。
class TripPoint {
  final DateTime timestamp;
  final double speed; // km/h
  final double latitude;
  final double longitude;
  final String mileage;
  final bool rejected; // true 表示该点为异常帧（GPS跳点/stale/加速度超限），不计入任何计算

  const TripPoint({
    required this.timestamp,
    required this.speed,
    required this.latitude,
    required this.longitude,
    required this.mileage,
    this.rejected = false,
  });

  bool get hasValidLocation =>
      latitude.abs() <= 90 &&
      longitude.abs() <= 180 &&
      !(latitude == 0 && longitude == 0);

  /// 是否为有效点（位置合法且未被剔除）。
  bool get isValid => hasValidLocation && !rejected;

  factory TripPoint.fromJson(Map<String, dynamic> json) {
    return TripPoint(
      timestamp: DateTime.parse(json['timestamp'] as String),
      speed: (json['speed'] as num?)?.toDouble() ?? 0,
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0,
      mileage: json['mileage'] as String? ?? '',
      rejected: json['rejected'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'speed': speed,
        'latitude': latitude,
        'longitude': longitude,
        'mileage': mileage,
        'rejected': rejected,
      };
}

/// 行程记录模型。
class TripRecord {
  final String id;
  final TripType tripType;
  final String tripName;
  final String identifier; // 车次/线路号/航班号
  final DateTime startedAt;
  final DateTime? endedAt;
  final List<TripPoint> points;

  TripRecord({
    required this.id,
    this.tripType = TripType.train,
    this.tripName = '',
    this.identifier = '',
    required this.startedAt,
    this.endedAt,
    required this.points,
  });

  /// 行程时长。
  Duration get duration {
    final end = endedAt ?? DateTime.now();
    return end.difference(startedAt);
  }

  /// 有效轨迹点（位置合法且未被剔除）。
  List<TripPoint> get validPoints =>
      points.where((p) => p.isValid).toList();

  /// 总距离（公里），按相邻有效点 Haversine 距离累加。
  double get totalDistance {
    final valid = validPoints;
    if (valid.length < 2) return 0;
    double total = 0;
    for (int i = 1; i < valid.length; i++) {
      total += _haversineKm(
        valid[i - 1].latitude,
        valid[i - 1].longitude,
        valid[i].latitude,
        valid[i].longitude,
      );
    }
    return total;
  }

  /// 均速 = 总距离 / 有效点时间跨度（小时），km/h。
  ///
  /// 时间跨度仅取第一个有效点到最后一个有效点之间，
  /// 被剔除的点不参与计算（包括 warmup 阶段和 GPS 丢失阶段的时间）。
  double get averageSpeed {
    final valid = validPoints;
    if (valid.length < 2) return 0;
    final timeSpan = valid.last.timestamp.difference(valid.first.timestamp);
    final hours = timeSpan.inSeconds / 3600;
    if (hours <= 0) return 0;
    return totalDistance / hours;
  }

  /// 最高速度（仅有效点）。
  double get maxSpeed {
    final valid = validPoints;
    if (valid.isEmpty) return 0;
    return valid.map((p) => p.speed).reduce(max);
  }

  /// 当前速度（最后一个有效点）。
  double get currentSpeed {
    for (int i = points.length - 1; i >= 0; i--) {
      if (points[i].isValid) return points[i].speed;
    }
    return 0;
  }

  /// 最新里程（取最后一个有效点的里程，跳过被剔除的点）。
  String get latestMileage =>
      latestValid?.mileage ?? '--';

  TripPoint? get latest => points.isEmpty ? null : points.last;

  /// 最后一个有效点（跳过被剔除的点）。
  TripPoint? get latestValid {
    for (int i = points.length - 1; i >= 0; i--) {
      if (points[i].isValid) return points[i];
    }
    return null;
  }

  /// 显示标题：行程名称优先，否则用标识符，再否则用类型标签。
  String get displayTitle {
    if (tripName.isNotEmpty) return tripName;
    if (identifier.isNotEmpty) return identifier;
    return tripType.label;
  }

  factory TripRecord.fromJson(Map<String, dynamic> json) {
    // 向后兼容：旧数据没有 tripType / tripName，identifier 从 trainNo 读取
    final tripTypeName = json['tripType'] as String?;
    final TripType tripType = tripTypeName != null
        ? TripType.values.firstWhere(
            (t) => t.name == tripTypeName,
            orElse: () => TripType.train,
          )
        : TripType.train;

    return TripRecord(
      id: json['id'] as String,
      tripType: tripType,
      tripName: json['tripName'] as String? ?? '',
      identifier: (json['identifier'] as String?) ??
          (json['trainNo'] as String? ?? ''),
      startedAt: DateTime.parse(json['startedAt'] as String),
      endedAt: json['endedAt'] != null
          ? DateTime.parse(json['endedAt'] as String)
          : null,
      points: (json['points'] as List<dynamic>? ?? [])
          .map((e) => TripPoint.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'tripType': tripType.name,
        'tripName': tripName,
        'identifier': identifier,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt?.toIso8601String(),
        'points': points.map((p) => p.toJson()).toList(),
      };

  /// Haversine 公式计算两点间距离（公里）。
  static double _haversineKm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const r = 6371.0; // 地球半径 km
    final dLat = _toRad(lat2 - lat1);
    final dLon = _toRad(lon2 - lon1);
    final a = pow(sin(dLat / 2), 2) +
        pow(cos(_toRad(lat1)), 2) *
            pow(cos(_toRad(lat2)), 2) *
            pow(sin(dLon / 2), 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return r * c;
  }

  static double _toRad(double deg) => deg * pi / 180;
}
