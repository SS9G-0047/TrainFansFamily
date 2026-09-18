import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/trip_record.dart';
import 'ble_warning_service.dart';
import 'lock_screen_overlay.dart';
import 'native_location_service.dart';

/// 行程状态。
enum TripState { idle, recording, paused }

/// 行程记录服务。
///
/// 使用手机 GPS 实时定位记录轨迹点和速度，
/// 同时监听 [BleWarningService] 自动填充车次和里程。
/// 支持开始/暂停/恢复/结束行程，已结束的行程持久化到 SharedPreferences。
class TripService extends ChangeNotifier with WidgetsBindingObserver {
  TripService._() {
    _bleService.addListener(_onBleMessage);
    WidgetsBinding.instance.addObserver(this);
    _loadHistory();
    _loadInterruptedTrip();
  }

  static final TripService instance = TripService._();

  static const String _storageKey = 'trip_records';
  static const String _activeTripKey = 'trip_active';
  static const int _maxRecords = 200;

  /// 基准建立所需的连续一致帧数。
  static const int _baselineFrames = 3;

  /// GPS 信号丢失阈值（秒），超过则重新进入基准建立阶段。
  static const int _gpsGapThresholdSec = 5;

  /// 自动保存间隔（秒）。
  static const int _autoSaveIntervalSec = 10;

  final BleWarningService _bleService = BleWarningService.instance;
  final NativeLocationService _locationService = NativeLocationService.instance;

  // —— 当前行程状态 ——
  TripState _state = TripState.idle;
  TripType _tripType = TripType.train;
  String _tripName = '';
  String _identifier = '';
  DateTime? _startedAt;
  final List<TripPoint> _currentPoints = [];
  Timer? _tickTimer;
  StreamSubscription<GpsLocationUpdate>? _gpsSubscription;

  // BLE 最新里程（用于在 GPS 记录点中附带里程信息）
  String _latestMileage = '';

  // 速度基准是否已建立（连续 N 帧速度一致后才建立）
  bool _baselineReady = false;

  // 上一次有效速度，用于加速度异常帧检测
  double _lastValidSpeed = 0;

  // 基准建立期间的候选速度列表（需连续一致才采纳）
  final List<double> _pendingSpeeds = [];

  // 上一个真实 GPS 帧的轨迹点（用于距离计算，stale 帧不更新此值）
  TripPoint? _lastRealPoint;

  // 上一个真实帧的时间戳（用于 GPS 信号丢失检测）
  DateTime? _lastRealFrameTime;

  // 当前帧是否被剔除（GPS跳点/加速度超限等），由 _calculateSpeed 设置
  bool _lastFrameRejected = false;

  // 自动保存定时器
  Timer? _autoSaveTimer;

  // 中断的未完成行程（App 被杀死后恢复用）
  TripRecord? _interruptedTrip;

  // —— 已完成行程 ——
  final List<TripRecord> _history = [];

  // Getters
  TripState get state => _state;
  bool get isRecording => _state == TripState.recording;
  bool get isPaused => _state == TripState.paused;
  bool get isActive => _state != TripState.idle;
  TripType get tripType => _tripType;
  String get tripName => _tripName;
  String get identifier => _identifier;
  List<TripPoint> get currentPoints => List.unmodifiable(_currentPoints);
  List<TripRecord> get history => List.unmodifiable(_history);

  /// 是否存在未完成的中断行程。
  bool get hasInterruptedTrip => _interruptedTrip != null;

  /// 中断行程记录（可能为 null）。
  TripRecord? get interruptedTrip => _interruptedTrip;

  /// 当前行程的临时记录对象（用于 UI 读取统计信息）。
  TripRecord get currentRecord => TripRecord(
        id: _startedAt?.millisecondsSinceEpoch.toString() ?? '',
        tripType: _tripType,
        tripName: _tripName,
        identifier: _identifier,
        startedAt: _startedAt ?? DateTime.now(),
        endedAt: null,
        points: List.from(_currentPoints),
      );

  // —— 行程控制 ——

  /// 开始新行程。
  void startTrip({
    TripType tripType = TripType.train,
    String tripName = '',
    String identifier = '',
  }) {
    if (_state != TripState.idle) return;
    _tripType = tripType;
    _tripName = tripName.trim();
    _identifier = identifier.trim();
    _startedAt = DateTime.now();
    _currentPoints.clear();
    _latestMileage = '';
    _lastValidSpeed = 0;
    _baselineReady = false;
    _pendingSpeeds.clear();
    _lastRealPoint = null;
    _lastRealFrameTime = null;
    _state = TripState.recording;
    _startTick();
    _startGpsStream();
    _startAutoSave();
    _ensureBackgroundRunning();
    notifyListeners();
  }

  /// 暂停行程。
  void pauseTrip() {
    if (_state != TripState.recording) return;
    _state = TripState.paused;
    _stopTick();
    _stopGpsStream();
    _stopAutoSave();
    _saveActiveTrip();
    notifyListeners();
  }

  /// 恢复行程。
  void resumeTrip() {
    if (_state != TripState.paused) return;
    _state = TripState.recording;
    _baselineReady = false;
    _pendingSpeeds.clear();
    _lastRealPoint = null;
    _lastRealFrameTime = null;
    _startTick();
    _startGpsStream();
    _startAutoSave();
    notifyListeners();
  }

  /// 结束行程并保存到历史记录。
  Future<void> stopTrip() async {
    if (_state == TripState.idle) return;
    _stopTick();
    _stopGpsStream();
    _stopAutoSave();
    _stopBackgroundRunning();

    final endedAt = DateTime.now();
    if (_currentPoints.isNotEmpty) {
      final record = TripRecord(
        id: (_startedAt ?? endedAt).millisecondsSinceEpoch.toString(),
        tripType: _tripType,
        tripName: _tripName,
        identifier: _identifier,
        startedAt: _startedAt ?? endedAt,
        endedAt: endedAt,
        points: List.from(_currentPoints),
      );
      _history.insert(0, record);
      if (_history.length > _maxRecords) {
        _history.removeRange(_maxRecords, _history.length);
      }
      await _saveHistory();
    }

    await _clearActiveTrip();
    _state = TripState.idle;
    _tripType = TripType.train;
    _tripName = '';
    _identifier = '';
    _startedAt = null;
    _latestMileage = '';
    _currentPoints.clear();
    notifyListeners();
  }

  /// 删除指定历史行程。
  Future<void> deleteRecord(String id) async {
    _history.removeWhere((r) => r.id == id);
    await _saveHistory();
    notifyListeners();
  }

  /// 清空所有历史行程。
  Future<void> clearHistory() async {
    _history.clear();
    await _saveHistory();
    notifyListeners();
  }

  // —— 内部逻辑 ——

  /// BLE 报文监听：仅用于火车行程自动填充车次和里程。
  void _onBleMessage() {
    final message = _bleService.latestMessage;
    if (message == null) return;

    // 仅火车行程自动填充车次
    if (_tripType == TripType.train) {
      final trainNo = _cleanField(message.trainNo);
      if (_identifier.isEmpty && trainNo.isNotEmpty) {
        _identifier = trainNo;
        notifyListeners();
      }
    }

    final mileage = _cleanField(message.mileage);
    if (mileage.isNotEmpty) {
      _latestMileage = mileage;
    }
  }

  /// 启动 GPS 位置流，每个更新记录一个轨迹点。
  ///
  /// 速度计算三阶段设计（修复 Bug1/2/3）：
  /// - **stale 帧**：上次已知位置（可能过期），记录位置但速度为 0，
  ///   重置基准建立状态，不作为后续速度计算参考。
  /// - **基准建立阶段**：收集连续一致的速度样本（通过加速度校验），
  ///   达到 [_baselineFrames] 帧后建立可信基准。
  ///   此阶段始终做 maxSpeed + 加速度双重检查，
  ///   GPS 跳点会被加速度校验拦截，不会污染基准（修复 Bug2）。
  /// - **正常阶段**：maxSpeed + 加速度双重检查，异常帧回退到上次有效速度。
  /// - **GPS 丢失恢复**：真实帧间隔超过 [_gpsGapThresholdSec] 秒时，
  ///   重新进入基准建立阶段（修复 Bug3）。
  /// - **第一帧处理**：不依赖 GPS 硬件速度，仅记录位置，速度为 0，
  ///   后续帧通过距离差分计算速度（修复 Bug1）。
  void _startGpsStream() {
    _stopGpsStream();
    _gpsSubscription = _locationService.locationStream().listen(
      (update) {
        if (_state != TripState.recording) return;

        double speed = 0;
        bool rejected = false;

        if (update.stale) {
          // stale 帧：重置基准建立状态，标记为剔除
          _baselineReady = false;
          _pendingSpeeds.clear();
          _lastRealPoint = null;
          _lastRealFrameTime = null;
          rejected = true;
        } else {
          speed = _calculateSpeed(update);
          rejected = _lastFrameRejected;
          _lastRealFrameTime = update.timestamp;
        }

        final point = TripPoint(
          timestamp: update.timestamp,
          speed: speed,
          latitude: update.latitude,
          longitude: update.longitude,
          mileage: _latestMileage,
          rejected: rejected,
        );
        _currentPoints.add(point);

        // 仅非剔除的真实帧才更新 _lastRealPoint，
        // 防止 GPS 跳点位置污染下一帧的距离计算
        if (!update.stale && !rejected) {
          _lastRealPoint = point;
        }

        notifyListeners();
      },
      onError: (error) {
        debugPrint('GPS 位置流错误：$error');
      },
    );
  }

  /// 计算当前真实帧的速度。
  ///
  /// 使用距离差分作为主速度源，GPS 硬件速度仅在正常阶段距离计算失败时
  /// 作为最后手段回退。
  /// 通过 [_lastFrameRejected] 向调用方传递当前帧是否被剔除。
  double _calculateSpeed(GpsLocationUpdate update) {
    _lastFrameRejected = false;
    final now = update.timestamp;

    // Bug3: GPS 信号丢失检测——真实帧间隔过长则重新建立基准
    if (_lastRealFrameTime != null) {
      final gapSec = now.difference(_lastRealFrameTime!).inSeconds;
      if (gapSec > _gpsGapThresholdSec) {
        _baselineReady = false;
        _pendingSpeeds.clear();
        _lastRealPoint = null;
      }
    }

    // Bug1: 第一个真实帧（或重置后的第一帧）
    // 不依赖 GPS 硬件速度，仅记录位置，速度为 0
    // 此帧位置有效，不标记为剔除
    if (_lastRealPoint == null || !_lastRealPoint!.hasValidLocation) {
      return 0;
    }

    final last = _lastRealPoint!;
    final distanceKm = _haversineKm(
      last.latitude,
      last.longitude,
      update.latitude,
      update.longitude,
    );
    final dtMs = now.difference(last.timestamp).inMilliseconds;
    final hours = dtMs / 3600000.0;
    final dtSeconds = dtMs / 1000.0;

    if (hours <= 0 || dtSeconds <= 0) {
      // 时间差为 0：无法计算速度，标记为剔除
      _lastFrameRejected = true;
      return _baselineReady ? _lastValidSpeed : 0;
    }

    final rawSpeed = distanceKm / hours;

    // 绝对上限检查（始终生效）
    if (rawSpeed > _tripType.maxSpeed) {
      // 超过上限：GPS 跳点，标记为剔除
      _lastFrameRejected = true;
      if (!_baselineReady) _pendingSpeeds.clear();
      return _baselineReady ? _lastValidSpeed : 0;
    }

    if (!_baselineReady) {
      // Bug2: 基准建立阶段——用加速度校验验证帧间一致性
      // 不再跳过加速度检查，GPS 跳点会被拦截
      if (_pendingSpeeds.isEmpty) {
        // 第一个候选速度，暂不做一致性校验
        _pendingSpeeds.add(rawSpeed);
        return rawSpeed;
      }

      final maxDelta = _tripType.maxAcceleration * dtSeconds;
      final actualDelta = (rawSpeed - _pendingSpeeds.last).abs();
      if (actualDelta > maxDelta) {
        // 不一致：GPS 跳点，丢弃已有候选
        // 不将跳点速度加入候选（位置不可信），标记为剔除
        _lastFrameRejected = true;
        _pendingSpeeds.clear();
        return rawSpeed;
      }

      // 一致：添加候选
      _pendingSpeeds.add(rawSpeed);
      if (_pendingSpeeds.length >= _baselineFrames) {
        // 达到所需帧数，建立可信基准
        _baselineReady = true;
        _lastValidSpeed = rawSpeed;
      }
      return rawSpeed;
    }

    // 正常阶段：加速度检查
    final maxDelta = _tripType.maxAcceleration * dtSeconds;
    final actualDelta = (rawSpeed - _lastValidSpeed).abs();
    if (actualDelta > maxDelta) {
      // 异常帧：使用上次有效速度，不更新基准，标记为剔除
      _lastFrameRejected = true;
      return _lastValidSpeed;
    }

    // 正常帧：更新基准
    _lastValidSpeed = rawSpeed;

    // Bug1 fallback: 距离计算结果为 0 时（静止），回退到 GPS 硬件速度
    if (rawSpeed == 0 &&
        update.speed > 0 &&
        update.speed <= _tripType.maxSpeed) {
      _lastValidSpeed = update.speed;
      return update.speed;
    }

    return rawSpeed;
  }

  void _stopGpsStream() {
    _gpsSubscription?.cancel();
    _gpsSubscription = null;
  }

  /// 请求电池优化白名单并启动前台服务，确保后台不被系统杀死。
  void _ensureBackgroundRunning() {
    // 请求电池优化白名单
    LockScreenOverlay.isIgnoringBatteryOptimizations().then((ok) {
      if (!ok) {
        LockScreenOverlay.requestIgnoreBatteryOptimizations();
      }
    });
    // 启动前台服务保活
    final displayName = _tripName.isNotEmpty
        ? _tripName
        : (_identifier.isNotEmpty ? identifier : '行程记录');
    _locationService.startTripForegroundService(tripName: displayName);
  }

  /// 停止行程前台服务。
  void _stopBackgroundRunning() {
    _locationService.stopTripForegroundService();
  }

  /// 每秒 tick：刷新时长显示。
  void _startTick() {
    _stopTick();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      notifyListeners();
    });
  }

  void _stopTick() {
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  String _cleanField(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == '#' || trimmed == '--') return '';
    return trimmed;
  }

  /// Haversine 公式计算两点间距离（公里）。
  static double _haversineKm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const r = 6371.0;
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

  // —— 持久化 ——

  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_storageKey);
      if (jsonStr == null) return;
      final list = json.decode(jsonStr) as List<dynamic>;
      _history.clear();
      _history.addAll(
        list.map((e) => TripRecord.fromJson(e as Map<String, dynamic>)),
      );
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _saveHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = json.encode(_history.map((r) => r.toJson()).toList());
      await prefs.setString(_storageKey, jsonStr);
    } catch (_) {}
  }

  // —— 进行中行程自动保存 / 崩溃恢复 ——

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App 进入后台时立即保存，防止被系统杀死后丢失数据
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (_state == TripState.recording || _state == TripState.paused) {
        _saveActiveTrip();
      }
    }
  }

  void _startAutoSave() {
    _stopAutoSave();
    _autoSaveTimer = Timer.periodic(
      const Duration(seconds: _autoSaveIntervalSec),
      (_) => _saveActiveTrip(),
    );
  }

  void _stopAutoSave() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
  }

  /// 将当前进行中的行程保存到 SharedPreferences（防崩溃丢失）。
  Future<void> _saveActiveTrip() async {
    if (_state == TripState.idle) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = {
        'tripType': _tripType.name,
        'tripName': _tripName,
        'identifier': _identifier,
        'startedAt': _startedAt?.toIso8601String(),
        'mileage': _latestMileage,
        'points': _currentPoints.map((p) => p.toJson()).toList(),
      };
      await prefs.setString(_activeTripKey, json.encode(data));
    } catch (_) {}
  }

  /// 清除进行中行程的持久化数据。
  Future<void> _clearActiveTrip() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_activeTripKey);
    } catch (_) {}
  }

  /// 从 SharedPreferences 加载中断的行程。
  Future<void> _loadInterruptedTrip() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_activeTripKey);
      if (jsonStr == null) return;

      final data = json.decode(jsonStr) as Map<String, dynamic>;
      final tripTypeName = data['tripType'] as String? ?? 'train';
      final TripType tripType = TripType.values.firstWhere(
        (t) => t.name == tripTypeName,
        orElse: () => TripType.train,
      );

      final startedAtStr = data['startedAt'] as String?;
      if (startedAtStr == null) {
        await prefs.remove(_activeTripKey);
        return;
      }

      final points = (data['points'] as List<dynamic>? ?? [])
          .map((e) => TripPoint.fromJson(e as Map<String, dynamic>))
          .toList();

      if (points.isEmpty) {
        await prefs.remove(_activeTripKey);
        return;
      }

      _interruptedTrip = TripRecord(
        id: DateTime.parse(startedAtStr).millisecondsSinceEpoch.toString(),
        tripType: tripType,
        tripName: data['tripName'] as String? ?? '',
        identifier: data['identifier'] as String? ?? '',
        startedAt: DateTime.parse(startedAtStr),
        endedAt: null,
        points: points,
      );
      notifyListeners();
    } catch (_) {}
  }

  /// 恢复中断的行程，继续记录。
  Future<void> restoreInterruptedTrip() async {
    if (_interruptedTrip == null || _state != TripState.idle) return;

    final trip = _interruptedTrip!;
    _tripType = trip.tripType;
    _tripName = trip.tripName;
    _identifier = trip.identifier;
    _startedAt = trip.startedAt;
    _currentPoints.clear();
    _currentPoints.addAll(trip.points);
    _latestMileage = trip.latestValid?.mileage ?? '';
    _lastValidSpeed = 0;
    _baselineReady = false;
    _pendingSpeeds.clear();
    _lastRealPoint = null;
    _lastRealFrameTime = null;
    _interruptedTrip = null;

    _state = TripState.recording;
    _startTick();
    _startGpsStream();
    _startAutoSave();
    _ensureBackgroundRunning();
    notifyListeners();
  }

  /// 将中断的行程保存为历史记录（不继续记录）。
  Future<void> saveInterruptedTripAsHistory() async {
    if (_interruptedTrip == null) return;

    final trip = _interruptedTrip!;
    final record = TripRecord(
      id: trip.id,
      tripType: trip.tripType,
      tripName: trip.tripName,
      identifier: trip.identifier,
      startedAt: trip.startedAt,
      endedAt: DateTime.now(),
      points: trip.points,
    );
    _history.insert(0, record);
    if (_history.length > _maxRecords) {
      _history.removeRange(_maxRecords, _history.length);
    }
    await _saveHistory();

    _interruptedTrip = null;
    await _clearActiveTrip();
    notifyListeners();
  }

  /// 丢弃中断的行程。
  Future<void> discardInterruptedTrip() async {
    _interruptedTrip = null;
    await _clearActiveTrip();
    notifyListeners();
  }

  @override
  void dispose() {
    _bleService.removeListener(_onBleMessage);
    WidgetsBinding.instance.removeObserver(this);
    _stopTick();
    _stopGpsStream();
    _stopAutoSave();
    super.dispose();
  }
}
