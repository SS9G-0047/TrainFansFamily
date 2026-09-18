class LineMileage {
  final String line;
  final String mileage;

  const LineMileage({this.line = '', this.mileage = ''});

  factory LineMileage.fromJson(Map<String, dynamic> json) {
    return LineMileage(
      line: json['line']?.toString() ?? '',
      mileage: json['mileage']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {'line': line, 'mileage': mileage};
  }
}

class CameraPositionGroup {
  final String id;
  final String name;
  final String parentGroupId;

  const CameraPositionGroup({
    required this.id,
    required this.name,
    this.parentGroupId = '',
  });

  CameraPositionGroup copyWith({
    String? id,
    String? name,
    String? parentGroupId,
  }) {
    return CameraPositionGroup(
      id: id ?? this.id,
      name: name ?? this.name,
      parentGroupId: parentGroupId ?? this.parentGroupId,
    );
  }

  factory CameraPositionGroup.fromJson(Map<String, dynamic> json) {
    return CameraPositionGroup(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      parentGroupId: json['parentGroupId']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {'id': id, 'name': name, 'parentGroupId': parentGroupId};
  }
}

class CameraPosition {
  final String id;
  final String name;
  final String groupId;
  final double latitude;
  final double longitude;
  final List<LineMileage> lineMileages;
  final List<String> imagePaths;

  const CameraPosition({
    required this.id,
    required this.name,
    this.groupId = '',
    required this.latitude,
    required this.longitude,
    this.lineMileages = const [],
    this.imagePaths = const [],
  });

  CameraPosition copyWith({
    String? id,
    String? name,
    String? groupId,
    double? latitude,
    double? longitude,
    List<LineMileage>? lineMileages,
    List<String>? imagePaths,
  }) {
    return CameraPosition(
      id: id ?? this.id,
      name: name ?? this.name,
      groupId: groupId ?? this.groupId,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      lineMileages: lineMileages ?? this.lineMileages,
      imagePaths: imagePaths ?? this.imagePaths,
    );
  }

  factory CameraPosition.fromJson(Map<String, dynamic> json) {
    return CameraPosition(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      groupId: json['groupId']?.toString() ?? '',
      latitude: double.tryParse(json['latitude']?.toString() ?? '') ?? 0,
      longitude: double.tryParse(json['longitude']?.toString() ?? '') ?? 0,
      lineMileages: (json['lineMileages'] as List? ?? [])
          .whereType<Map>()
          .map((item) => LineMileage.fromJson(Map<String, dynamic>.from(item)))
          .toList(),
      imagePaths: (json['imagePaths'] as List? ?? [])
          .map((item) => item.toString())
          .where((item) => item.trim().isNotEmpty)
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'groupId': groupId,
      'latitude': latitude,
      'longitude': longitude,
      'lineMileages': lineMileages.map((item) => item.toJson()).toList(),
      'imagePaths': imagePaths,
    };
  }
}
