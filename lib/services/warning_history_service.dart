import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ble_warning_message.dart';
import '../models/warning_history_record.dart';

class WarningHistoryService extends ChangeNotifier {
  WarningHistoryService._() {
    load();
  }

  static final WarningHistoryService instance = WarningHistoryService._();
  static const String _storageKey = 'warning_history_records';
  static const Duration _mergeWindow = Duration(minutes: 20);

  final List<WarningHistoryRecord> _records = [];
  bool _loaded = false;

  List<WarningHistoryRecord> get records => List.unmodifiable(_records);
  bool get loaded => _loaded;

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_storageKey);
    _records.clear();

    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        _records.addAll(
          list
              .whereType<Map>()
              .map(
                (item) => WarningHistoryRecord.fromJson(
                  Map<String, dynamic>.from(item),
                ),
              )
              .where((record) => record.points.isNotEmpty),
        );
      } catch (_) {}
    }

    _sortRecords();
    _loaded = true;
    notifyListeners();
  }

  Future<void> saveMessage(
    BleWarningMessage message, {
    String cameraPositionId = '',
  }) async {
    final trainNo = message.trainNo.trim();
    if (trainNo.isEmpty || trainNo == '#' || trainNo == '--') return;

    if (!_loaded) {
      await load();
    }

    final point = WarningHistoryPoint.fromMessage(
      message,
      cameraPositionId: cameraPositionId,
    );
    final index = _records.indexWhere((record) {
      if (record.trainNo != trainNo) return false;
      final diff = point.receivedAt.difference(record.updatedAt).abs();
      return diff <= _mergeWindow;
    });

    if (index >= 0) {
      _records[index] = _records[index].addPoint(point);
    } else {
      _records.add(WarningHistoryRecord.fromPoint(point));
    }

    _sortRecords();
    await _persist();
    notifyListeners();
  }

  List<WarningHistoryRecord> search({
    DateTime? startAt,
    DateTime? endAt,
    String trainNo = '',
    String locomotive = '',
  }) {
    final trainKeyword = trainNo.trim().toLowerCase();
    final locomotiveKeyword = locomotive.trim().toLowerCase();

    return _records.where((record) {
      if (trainKeyword.isNotEmpty &&
          !record.trainNo.toLowerCase().contains(trainKeyword)) {
        return false;
      }

      final hasMatchedPoint = record.points.any((point) {
        if (startAt != null && point.receivedAt.isBefore(startAt)) return false;
        if (endAt != null && point.receivedAt.isAfter(endAt)) return false;
        if (locomotiveKeyword.isNotEmpty &&
            !point.locomotive.toLowerCase().contains(locomotiveKeyword)) {
          return false;
        }
        return true;
      });

      return hasMatchedPoint;
    }).toList();
  }

  Future<void> clear() async {
    _records.clear();
    await _persist();
    notifyListeners();
  }

  /// 删除单条记录。
  Future<void> deleteRecord(String id) async {
    _records.removeWhere((record) => record.id == id);
    await _persist();
    notifyListeners();
  }

  /// 批量删除多条记录。
  Future<void> deleteRecords(Set<String> ids) async {
    if (ids.isEmpty) return;
    _records.removeWhere((record) => ids.contains(record.id));
    await _persist();
    notifyListeners();
  }

  void _sortRecords() {
    _records.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<void> _persist() async {
    final sp = await SharedPreferences.getInstance();
    final raw = jsonEncode(_records.map((item) => item.toJson()).toList());
    await sp.setString(_storageKey, raw);
  }
}
