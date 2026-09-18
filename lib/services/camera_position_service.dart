import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:math';

import '../models/ble_warning_message.dart';
import '../models/camera_position.dart';
import 'native_location_service.dart';

class CameraPositionService extends ChangeNotifier {
  CameraPositionService._() {
    load();
  }

  static final CameraPositionService instance = CameraPositionService._();
  static const String _positionsKey = 'camera_positions';
  static const String _groupsKey = 'camera_position_groups';
  static const String _currentPositionIdKey = 'current_camera_position_id';
  static const double warningDistanceKm = 5;

  final List<CameraPosition> _positions = [];
  final List<CameraPositionGroup> _groups = [];
  String? _currentPositionId;
  bool _loaded = false;

  List<CameraPosition> get positions => List.unmodifiable(_positions);
  List<CameraPositionGroup> get groups => List.unmodifiable(_groups);
  String? get currentPositionId => _currentPositionId;
  bool get loaded => _loaded;

  CameraPosition? get currentPosition {
    final id = _currentPositionId;
    if (id == null || id.isEmpty) return null;
    for (final item in _positions) {
      if (item.id == id) return item;
    }
    return null;
  }

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_positionsKey);
    final groupsRaw = sp.getString(_groupsKey);
    _positions.clear();
    _groups.clear();
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        _positions.addAll(
          list
              .whereType<Map>()
              .map(
                (item) =>
                    CameraPosition.fromJson(Map<String, dynamic>.from(item)),
              )
              .where((item) => item.name.trim().isNotEmpty),
        );
      } catch (_) {}
    }
    if (groupsRaw != null && groupsRaw.isNotEmpty) {
      try {
        final list = jsonDecode(groupsRaw) as List;
        _groups.addAll(
          list
              .whereType<Map>()
              .map(
                (item) => CameraPositionGroup.fromJson(
                  Map<String, dynamic>.from(item),
                ),
              )
              .where((item) => item.name.trim().isNotEmpty),
        );
      } catch (_) {}
    }
    _sanitizeGroupHierarchy();
    _currentPositionId = sp.getString(_currentPositionIdKey);
    if (_currentPositionId != null && currentPosition == null) {
      _currentPositionId = null;
    }
    _loaded = true;
    notifyListeners();
  }

  CameraPositionGroup? groupById(String id) {
    if (id.isEmpty) return null;
    for (final group in _groups) {
      if (group.id == id) return group;
    }
    return null;
  }

  List<CameraPositionGroup> childGroupsOf(String parentGroupId) {
    if (parentGroupId.isEmpty) {
      return _groups
          .where(
            (group) =>
                group.parentGroupId.isEmpty ||
                groupById(group.parentGroupId) == null,
          )
          .toList();
    }
    return _groups
        .where((group) => group.parentGroupId == parentGroupId)
        .toList();
  }

  List<CameraPosition> positionsInGroup(String groupId) {
    return _positions.where((position) => position.groupId == groupId).toList();
  }

  List<CameraPosition> get ungroupedPositions {
    return _positions
        .where((position) => groupById(position.groupId) == null)
        .toList();
  }

  String groupDisplayName(String groupId) {
    final group = groupById(groupId);
    if (group == null) return '未分组';
    final names = <String>[];
    var current = group;
    final visited = <String>{};
    while (visited.add(current.id)) {
      names.insert(0, current.name);
      if (current.parentGroupId.isEmpty) break;
      final parent = groupById(current.parentGroupId);
      if (parent == null) break;
      current = parent;
    }
    return names.join(' / ');
  }

  bool isDescendantGroup(String groupId, String possibleParentId) {
    var current = groupById(possibleParentId);
    final visited = <String>{};
    while (current != null && visited.add(current.id)) {
      if (current.parentGroupId == groupId) return true;
      if (current.parentGroupId.isEmpty) return false;
      current = groupById(current.parentGroupId);
    }
    return false;
  }

  void _sanitizeGroupHierarchy() {
    for (var i = 0; i < _groups.length; i++) {
      final group = _groups[i];
      if (group.parentGroupId.isEmpty) continue;
      if (group.parentGroupId == group.id ||
          groupById(group.parentGroupId) == null ||
          isDescendantGroup(group.id, group.parentGroupId)) {
        _groups[i] = group.copyWith(parentGroupId: '');
      }
    }
  }

  Future<void> saveGroup(CameraPositionGroup group) async {
    if (!_loaded) await load();
    final safeParentGroupId =
        group.parentGroupId == group.id ||
            isDescendantGroup(group.id, group.parentGroupId)
        ? ''
        : group.parentGroupId;
    final safeGroup = group.copyWith(parentGroupId: safeParentGroupId);
    final index = _groups.indexWhere((item) => item.id == group.id);
    if (index >= 0) {
      _groups[index] = safeGroup;
    } else {
      _groups.add(safeGroup);
    }
    await _persist();
    notifyListeners();
  }

  Future<bool> moveGroup(String groupId, String parentGroupId) async {
    if (!_loaded) await load();
    final group = groupById(groupId);
    if (group == null) return false;
    if (groupId == parentGroupId || isDescendantGroup(groupId, parentGroupId)) {
      return false;
    }
    await saveGroup(group.copyWith(parentGroupId: parentGroupId));
    return true;
  }

  Future<bool> movePosition(String positionId, String groupId) async {
    if (!_loaded) await load();
    final index = _positions.indexWhere((item) => item.id == positionId);
    if (index < 0) return false;
    final safeGroupId = groupById(groupId) == null ? '' : groupId;
    _positions[index] = _positions[index].copyWith(groupId: safeGroupId);
    await _persist();
    notifyListeners();
    return true;
  }

  Future<void> deleteGroup(String id) async {
    _groups.removeWhere((item) => item.id == id);
    for (var i = 0; i < _groups.length; i++) {
      if (_groups[i].parentGroupId == id) {
        _groups[i] = _groups[i].copyWith(parentGroupId: '');
      }
    }
    for (var i = 0; i < _positions.length; i++) {
      if (_positions[i].groupId == id) {
        _positions[i] = _positions[i].copyWith(groupId: '');
      }
    }
    await _persist();
    notifyListeners();
  }

  Future<void> savePosition(CameraPosition position) async {
    if (!_loaded) await load();
    final safeGroupId = groupById(position.groupId) == null
        ? ''
        : position.groupId;
    final safePosition = position.copyWith(groupId: safeGroupId);
    final index = _positions.indexWhere((item) => item.id == position.id);
    if (index >= 0) {
      _positions[index] = safePosition;
    } else {
      _positions.add(safePosition);
    }
    _currentPositionId ??= safePosition.id;
    await _persist();
    notifyListeners();
  }

  Future<void> deletePosition(String id) async {
    _positions.removeWhere((item) => item.id == id);
    if (_currentPositionId == id) {
      _currentPositionId = _positions.isEmpty ? null : _positions.first.id;
    }
    await _persist();
    notifyListeners();
  }

  Future<String?> setCurrentPosition(String? id) async {
    if (id == null || id.isEmpty) {
      _currentPositionId = null;
      await _persist();
      notifyListeners();
      return null;
    }
    final position = currentPosition;
    if (position != null && position.id == id) return null;
    // 查找机位
    CameraPosition? targetPosition;
    for (final p in _positions) {
      if (p.id == id) {
        targetPosition = p;
        break;
      }
    }
    if (targetPosition == null) {
      _currentPositionId = null;
      await _persist();
      notifyListeners();
      return null;
    }
    final gpsDistance = await _verifyGpsDistance(targetPosition);
    if (gpsDistance != null) {
      return '当前 GPS 定位距离该机位约 $gpsDistance km，超出 1km 范围，无法设为当前机位';
    }
    _currentPositionId = id;
    await _persist();
    notifyListeners();
    return null;
  }

  /// 判断是否应播放提示音。
  /// 条件：BLE 线路为空/#/-- 时视为匹配；BLE 里程为空/#/-- 时视为匹配；
  /// 机位未设置线路/里程时视为匹配；否则检查线路匹配且里程在 ±5km 内。
  bool shouldPlayWarningSound(BleWarningMessage message) {
    final position = currentPosition;
    if (position == null) return true;

    final validLineMileages = position.lineMileages.where((item) {
      return item.line.trim().isNotEmpty && item.mileage.trim().isNotEmpty;
    }).toList();
    if (validLineMileages.isEmpty) return true;

    final messageLine = message.line.trim();
    final messageMileage = _parseMileage(message.mileage);

    // BLE 发送的线路为空 / # / -- 时视为当前线路，条件成立
    if (messageLine.isEmpty || messageLine == '#' || messageLine == '--') {
      return true;
    }
    // BLE 发送的里程为空 / # / -- 时条件成立
    if (messageMileage == null) return true;

    for (final item in validLineMileages) {
      if (item.line.trim() != messageLine) continue;
      final cameraMileage = _parseMileage(item.mileage);
      // 机位里程未设置时条件成立
      if (cameraMileage == null) return true;
      final distance = (messageMileage - cameraMileage).abs();
      if (distance < warningDistanceKm) return true;
    }
    return false;
  }

  /// GPS 距离验证：若手机当前定位在机位 1km 内则返回 null，否则返回距离字符串。
  Future<String?> _verifyGpsDistance(CameraPosition position) async {
    final location = await NativeLocationService.instance.getCurrentLocation();
    if (location == null) return null;
    final distanceKm = _haversineDistance(
      location.latitude,
      location.longitude,
      position.latitude,
      position.longitude,
    );
    if (distanceKm <= 1.0) return null;
    return distanceKm.toStringAsFixed(2);
  }

  static double _haversineDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const r = 6371.0; // 地球半径 km
    final dLat = _toRad(lat2 - lat1);
    final dLon = _toRad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRad(lat1)) *
            cos(_toRad(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return r * c;
  }

  static double _toRad(double deg) => deg * pi / 180.0;

  double? _parseMileage(String source) {
    final normalized = source
        .trim()
        .replaceAll('公里', '')
        .replaceAll('千米', '')
        .replaceAll('km', '')
        .replaceAll('KM', '')
        .replaceAll('K', '')
        .replaceAll('k', '');
    if (normalized.isEmpty || normalized == '#' || normalized == '--') {
      return null;
    }
    final match = RegExp(r'-?\d+(\.\d+)?').firstMatch(normalized);
    if (match == null) return null;
    return double.tryParse(match.group(0)!);
  }

  Future<void> _persist() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      _positionsKey,
      jsonEncode(_positions.map((item) => item.toJson()).toList()),
    );
    await sp.setString(
      _groupsKey,
      jsonEncode(_groups.map((item) => item.toJson()).toList()),
    );
    final id = _currentPositionId;
    if (id == null || id.isEmpty) {
      await sp.remove(_currentPositionIdKey);
    } else {
      await sp.setString(_currentPositionIdKey, id);
    }
  }
}
