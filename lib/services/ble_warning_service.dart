import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/ble_warning_message.dart';
import 'app_settings_service.dart';
import 'camera_position_service.dart';
import 'lock_screen_overlay.dart';
import 'warning_history_service.dart';
import 'warning_notification_service.dart';

// BLE 全局测试开关：改成 true 后进入测试模式，不依赖真实蓝牙设备。
// ignore: constant_identifier_names
const bool TEST = false;
const Duration _businessIdleStatusDelay = Duration(seconds: 5);

class BleWarningService extends ChangeNotifier {
  BleWarningService._() {
    if (TEST) {
      _startTestMode();
    }
  }

  static final BleWarningService instance = BleWarningService._();

  BluetoothDevice? _connectedDevice;
  final List<BluetoothCharacteristic> _notifyCharacteristics = [];
  final List<StreamSubscription<List<int>>> _notifySubscriptions = [];
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  Timer? _heartbeatWatchdog;
  Timer? _testTimer;

  BleWarningMessage? _latestMessage;
  DateTime? _lastHeartbeatAt;
  DateTime? _lastBusinessMessageAt;
  DateTime? _listeningStartedAt;
  String _statusText = '未连接蓝牙预警器';
  String _rxBuffer = '';
  bool _isConnecting = false;
  bool _nextTestPushIsSample = true;
  int _testTrainIndex = 0; // 0=Z155下行, 1=Z156上行
  final AppSettingsService _settings = AppSettingsService.instance;
  final CameraPositionService _cameraPositionService =
      CameraPositionService.instance;
  final WarningHistoryService _historyService = WarningHistoryService.instance;

  BluetoothDevice? get connectedDevice => _connectedDevice;
  BleWarningMessage? get latestMessage => _latestMessage;
  DateTime? get lastHeartbeatAt => _lastHeartbeatAt;
  String get statusText => _statusText;
  bool get isConnecting => _isConnecting;
  bool get isConnected => _connectedDevice != null;
  bool get isReceiving => _notifyCharacteristics.isNotEmpty;
  bool get isTestMode => TEST;

  List<String> get warningTextList {
    final message = _latestMessage;
    if (message == null) {
      return const [
        '信号强度：--',
        '车次：--',
        '上下行：--',
        '线路：--',
        '机车：--',
        '里程：--',
        '速度：--',
        '纬度：--',
        '经度：--',
      ];
    }
    return message.toWarningTextList();
  }

  Future<bool> ensureBluetoothReady() async {
    if (TEST) {
      _startTestMode();
      _setStatus('BLE 测试模式运行中');
      return true;
    }

    final hasPermission = await _requestBluetoothPermissions();
    if (!hasPermission) {
      _setStatus('蓝牙权限未开启，请授权后重试');
      return false;
    }

    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState == BluetoothAdapterState.on) return true;

    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {
        _setStatus('蓝牙未开启，请手动开启蓝牙');
        return false;
      }
      final currentState = await FlutterBluePlus.adapterState
          .where(
            (state) =>
                state == BluetoothAdapterState.on ||
                state == BluetoothAdapterState.off,
          )
          .first
          .timeout(
            const Duration(seconds: 8),
            onTimeout: () => BluetoothAdapterState.unknown,
          );
      final ok = currentState == BluetoothAdapterState.on;
      if (!ok) _setStatus('蓝牙未开启，请手动开启蓝牙');
      return ok;
    }

    _setStatus('蓝牙未开启，请在系统设置中开启蓝牙');
    return false;
  }

  Future<void> connectAndSubscribe(BluetoothDevice device) async {
    if (TEST) {
      _startTestMode();
      _setStatus('BLE 测试模式运行中，不连接真实设备');
      return;
    }

    if (_isConnecting) return;
    _isConnecting = true;
    _setStatus('正在连接蓝牙预警器...');

    try {
      await disconnect(showStatus: false);
      await device.connect(
        timeout: const Duration(seconds: 8),
        autoConnect: false,
      );
      _connectedDevice = device;
      _listenConnectionState(device);

      final characteristics = await _findNotifyCharacteristics(device);
      if (characteristics.isEmpty) {
        _setStatus('已连接，但未找到可接收数据的 Notify 特征');
        return;
      }

      await _clearNotifySubscriptions();
      for (final characteristic in characteristics) {
        _notifyCharacteristics.add(characteristic);
        _notifySubscriptions.add(
          characteristic.onValueReceived.listen(_handleIncomingBytes),
        );
        await characteristic.setNotifyValue(true);
      }
      _listeningStartedAt = DateTime.now();
      _lastBusinessMessageAt = null;
      _startHeartbeatWatchdog();

      _setStatus('已连接，已订阅 ${characteristics.length} 个 Notify/Indicate 特征');
      unawaited(WarningNotificationService.instance.showStatus('已连接，正在接收预警数据'));
      if (_settings.floatingOverlayEnabled) {
        unawaited(LockScreenOverlay.showOverlay('火车预警接收中', '已连接，等待预警数据...'));
      }
    } catch (e) {
      await disconnect(showStatus: false);
      _setStatus('连接或订阅失败：$e');
      rethrow;
    } finally {
      _isConnecting = false;
      notifyListeners();
    }
  }

  Future<void> disconnect({bool showStatus = true}) async {
    await _clearNotifySubscriptions();

    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _heartbeatWatchdog?.cancel();
    _heartbeatWatchdog = null;
    _lastHeartbeatAt = null;
    _lastBusinessMessageAt = null;
    _listeningStartedAt = null;
    if (!TEST) {
      _testTimer?.cancel();
      _testTimer = null;
    }

    final device = _connectedDevice;
    _connectedDevice = null;
    if (device != null) {
      try {
        await device.disconnect();
      } catch (_) {}
    }

    if (showStatus) _setStatus('已断开蓝牙连接');
    unawaited(LockScreenOverlay.hideOverlay());
    notifyListeners();
  }

  void _startTestMode() {
    if (_testTimer != null) return;

    _setStatus('BLE 测试模式运行中');
    _pushTestMessage();
  }

  /// 来车持续 15 秒，无车持续 10 秒，交替循环。
  void _scheduleNextTestPush(bool wasSample) {
    _testTimer?.cancel();
    final delay = wasSample
        ? const Duration(seconds: 15)
        : const Duration(seconds: 10);
    _testTimer = Timer(delay, () {
      _pushTestMessage();
    });
  }

  void _pushTestMessage() {
    final isSample = _nextTestPushIsSample;
    final message = isSample
        ? _buildSampleTestMessage(_testTrainIndex)
        : _buildNoInfoTestMessage();
    _nextTestPushIsSample = !isSample;
    // 来车后切换到下一车次，两车次循环
    if (isSample) {
      _testTrainIndex = (_testTrainIndex + 1) % 2;
    }
    _lastHeartbeatAt = DateTime.now();
    _lastBusinessMessageAt = DateTime.now();
    _showAcceptedWarning(
      message,
      playSound: _cameraPositionService.shouldPlayWarningSound(message),
      statusText: isSample ? '测试模式：示例预警信息' : '测试模式：无预警信息',
    );
    notifyListeners();
    _scheduleNextTestPush(isSample);
  }

  /// 构建示例测试报文，index=0 为 Z155 下行，index=1 为 Z156 上行。
  BleWarningMessage _buildSampleTestMessage(int index) {
    if (index == 1) {
      return BleWarningMessage(
        signalStrength: '-58',
        trainNo: 'Z156',
        direction: '上',
        line: '京哈线',
        locomotive: 'HXD3D-0501',
        mileage: '12.5K',
        speed: '140km/h',
        latitude: '39.9120',
        longitude: '116.4180',
        receivedAt: DateTime.now(),
      );
    }
    return BleWarningMessage(
      signalStrength: '-62',
      trainNo: 'Z155',
      direction: '下',
      line: '京哈线',
      locomotive: 'SS9G-0047',
      mileage: '10.2K',
      speed: '160km/h',
      latitude: '39.9042',
      longitude: '116.4074',
      receivedAt: DateTime.now(),
    );
  }

  BleWarningMessage _buildNoInfoTestMessage() {
    return BleWarningMessage(
      signalStrength: '#',
      trainNo: '#',
      direction: '#',
      line: '#',
      locomotive: '#',
      mileage: '#',
      speed: '#',
      latitude: '#',
      longitude: '#',
      receivedAt: DateTime.now(),
    );
  }

  Future<bool> _requestBluetoothPermissions() async {
    if (kIsWeb) return false;

    if (defaultTargetPlatform == TargetPlatform.android) {
      final permissions = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      final bluetoothOk =
          _permissionOk(permissions[Permission.bluetoothScan]) &&
          _permissionOk(permissions[Permission.bluetoothConnect]);
      final legacyScanOk = _permissionOk(
        permissions[Permission.locationWhenInUse],
      );
      return bluetoothOk || legacyScanOk;
    }

    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      final status = await Permission.bluetooth.request();
      return status.isGranted || status.isLimited;
    }

    return true;
  }

  bool _permissionOk(PermissionStatus? status) {
    return status == PermissionStatus.granted ||
        status == PermissionStatus.limited;
  }

  void _listenConnectionState(BluetoothDevice device) {
    _connectionSubscription?.cancel();
    _connectionSubscription = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected &&
          _connectedDevice?.remoteId == device.remoteId) {
        _connectedDevice = null;
        unawaited(_clearNotifySubscriptions());
        _heartbeatWatchdog?.cancel();
        _heartbeatWatchdog = null;
        _setStatus('蓝牙连接已断开');
      }
    });
  }

  Future<List<BluetoothCharacteristic>> _findNotifyCharacteristics(
    BluetoothDevice device,
  ) async {
    final result = <BluetoothCharacteristic>[];
    final services = await device.discoverServices();
    for (final service in services) {
      for (final characteristic in service.characteristics) {
        if (characteristic.properties.notify ||
            characteristic.properties.indicate) {
          result.add(characteristic);
        }
      }
    }
    return result;
  }

  Future<void> _clearNotifySubscriptions() async {
    for (final subscription in _notifySubscriptions) {
      await subscription.cancel();
    }
    _notifySubscriptions.clear();

    for (final characteristic in _notifyCharacteristics) {
      try {
        await characteristic.setNotifyValue(false);
      } catch (_) {}
    }
    _notifyCharacteristics.clear();
  }

  void _startHeartbeatWatchdog() {
    _heartbeatWatchdog?.cancel();
    _heartbeatWatchdog = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_connectedDevice == null) return;
      final heartbeatAt = _lastHeartbeatAt;
      if (heartbeatAt == null) {
        _setStatus('已连接，等待心跳报文');
        return;
      }

      final diff = DateTime.now().difference(heartbeatAt);
      if (diff > const Duration(seconds: 4)) {
        _setStatus('心跳超时，请检查发射端');
        return;
      }

      if (_shouldShowListeningStatus()) {
        _setStatus('正在监听……');
      }
    });
  }

  void _handleIncomingBytes(List<int> value) {
    final text = utf8.decode(value, allowMalformed: true);
    var parsedCompleteFrame = false;

    for (final rune in text.runes) {
      final char = String.fromCharCode(rune);
      if (char == '#') {
        _lastHeartbeatAt = DateTime.now();
        if (!_shouldShowListeningStatus()) {
          _setStatus('心跳正常，等待业务报文');
        }
        continue;
      }
      if (char == '\n' || char == '\r') {
        parsedCompleteFrame = _parseBufferedFrame() || parsedCompleteFrame;
        continue;
      }
      _rxBuffer += char;
    }

    if (!parsedCompleteFrame && _looksLikeCompleteBusinessFrame(_rxBuffer)) {
      _parseBufferedFrame();
    }
  }

  bool _looksLikeCompleteBusinessFrame(String frame) {
    final text = frame.trim();
    if (text.startsWith('!')) {
      final count = text.substring(1).split(',').length;
      return count == 7 || count == 9;
    }
    if (text.startsWith('W|')) {
      final count = text.split('|').length;
      return count == 8 || count == 10;
    }
    return false;
  }

  bool _parseBufferedFrame() {
    final frame = _rxBuffer.trim();
    _rxBuffer = '';
    if (frame.isEmpty) return false;

    final message = BleWarningMessage.tryParse(frame);
    if (message == null) {
      _setStatus('收到无法识别的业务报文：$frame');
      return false;
    }

    final playSound = _cameraPositionService.shouldPlayWarningSound(message);
    _showAcceptedWarning(
      message,
      playSound: playSound,
      statusText: playSound ? '预警内容已更新' : '车辆不在当前机位预警范围内',
    );
    notifyListeners();
    return true;
  }

  void _showAcceptedWarning(
    BleWarningMessage message, {
    required bool playSound,
    required String statusText,
  }) {
    _latestMessage = message;
    _lastBusinessMessageAt = DateTime.now();
    _setStatus(statusText);
    final cameraId = _cameraPositionService.currentPositionId ?? '';
    unawaited(_historyService.saveMessage(message, cameraPositionId: cameraId));
    unawaited(
      WarningNotificationService.instance.showWarning(
        message,
        playSound: playSound,
      ),
    );
    if (_settings.floatingOverlayEnabled) {
      unawaited(
        LockScreenOverlay.updateOverlay(
          '火车预警：${message.trainNo} ${message.direction}',
          _formatOverlayContent(message),
          trainNo: message.trainNo,
        ),
      );
    }
  }

  String _formatOverlayContent(BleWarningMessage message) {
    return [
      '信号强度：${message.signalStrength}',
      '车次：${message.trainNo}',
      '上下行：${message.direction}',
      '线路：${message.line}',
      '机车：${message.locomotive}',
      '里程：${message.mileage}',
      '速度：${message.speed}',
      '纬度：${message.latitude}',
      '经度：${message.longitude}',
    ].join('\n');
  }

  bool _shouldShowListeningStatus() {
    final referenceTime = _lastBusinessMessageAt ?? _listeningStartedAt;
    if (referenceTime == null) return false;
    return DateTime.now().difference(referenceTime) >= _businessIdleStatusDelay;
  }

  void _setStatus(String value) {
    if (_statusText == value) return;
    _statusText = value;
    notifyListeners();
  }
}
