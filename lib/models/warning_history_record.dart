import 'ble_warning_message.dart';

class WarningHistoryPoint {
  final DateTime receivedAt;
  final String signalStrength;
  final String trainNo;
  final String direction;
  final String line;
  final String locomotive;
  final String mileage;
  final String speed;
  final String latitude;
  final String longitude;
  final String cameraPositionId;

  const WarningHistoryPoint({
    required this.receivedAt,
    required this.signalStrength,
    required this.trainNo,
    required this.direction,
    required this.line,
    required this.locomotive,
    required this.mileage,
    required this.speed,
    required this.latitude,
    required this.longitude,
    this.cameraPositionId = '',
  });

  factory WarningHistoryPoint.fromMessage(
    BleWarningMessage message, {
    String cameraPositionId = '',
  }) {
    return WarningHistoryPoint(
      receivedAt: message.receivedAt,
      signalStrength: message.signalStrength,
      trainNo: message.trainNo,
      direction: message.direction,
      line: message.line,
      locomotive: message.locomotive,
      mileage: message.mileage,
      speed: message.speed,
      latitude: message.latitude,
      longitude: message.longitude,
      cameraPositionId: cameraPositionId,
    );
  }

  factory WarningHistoryPoint.fromJson(Map<String, dynamic> json) {
    return WarningHistoryPoint(
      receivedAt:
          DateTime.tryParse(json['receivedAt']?.toString() ?? '') ??
          DateTime.now(),
      signalStrength: json['signalStrength']?.toString() ?? '--',
      trainNo: json['trainNo']?.toString() ?? '--',
      direction: json['direction']?.toString() ?? '--',
      line: json['line']?.toString() ?? '--',
      locomotive: json['locomotive']?.toString() ?? '--',
      mileage: json['mileage']?.toString() ?? '--',
      speed: json['speed']?.toString() ?? '--',
      latitude: json['latitude']?.toString() ?? '--',
      longitude: json['longitude']?.toString() ?? '--',
      cameraPositionId: json['cameraPositionId']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'receivedAt': receivedAt.toIso8601String(),
      'signalStrength': signalStrength,
      'trainNo': trainNo,
      'direction': direction,
      'line': line,
      'locomotive': locomotive,
      'mileage': mileage,
      'speed': speed,
      'latitude': latitude,
      'longitude': longitude,
      'cameraPositionId': cameraPositionId,
    };
  }
}

class WarningHistoryRecord {
  final String id;
  final String trainNo;
  final DateTime startedAt;
  final DateTime updatedAt;
  final List<WarningHistoryPoint> points;

  const WarningHistoryRecord({
    required this.id,
    required this.trainNo,
    required this.startedAt,
    required this.updatedAt,
    required this.points,
  });

  WarningHistoryPoint get latest => points.last;

  WarningHistoryRecord addPoint(WarningHistoryPoint point) {
    return WarningHistoryRecord(
      id: id,
      trainNo: trainNo,
      startedAt: startedAt,
      updatedAt: point.receivedAt,
      points: [...points, point],
    );
  }

  factory WarningHistoryRecord.fromPoint(WarningHistoryPoint point) {
    return WarningHistoryRecord(
      id: '${point.trainNo}_${point.receivedAt.millisecondsSinceEpoch}',
      trainNo: point.trainNo,
      startedAt: point.receivedAt,
      updatedAt: point.receivedAt,
      points: [point],
    );
  }

  factory WarningHistoryRecord.fromJson(Map<String, dynamic> json) {
    final points = (json['points'] as List? ?? [])
        .whereType<Map>()
        .map(
          (item) =>
              WarningHistoryPoint.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList();
    return WarningHistoryRecord(
      id:
          json['id']?.toString() ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      trainNo: json['trainNo']?.toString() ?? '--',
      startedAt:
          DateTime.tryParse(json['startedAt']?.toString() ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.now(),
      points: points,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'trainNo': trainNo,
      'startedAt': startedAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'points': points.map((item) => item.toJson()).toList(),
    };
  }
}
