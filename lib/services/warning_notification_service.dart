import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/ble_warning_message.dart';
import 'app_settings_service.dart';
import 'tts_service.dart';

class WarningNotificationService {
  WarningNotificationService._();

  static final WarningNotificationService instance =
      WarningNotificationService._();

  static const int _warningNotificationId = 1001;
  static const String _channelId = 'train_warning_lock_screen_silent';
  static const String _channelName = '火车预警锁屏通知';
  static const String _channelDescription = '用于在锁屏和通知中心常驻显示实时行车预警信息（静音，语音由TTS播放）';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final TtsService _tts = TtsService.instance;
  final AppSettingsService _settings = AppSettingsService.instance;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: false,
      requestSoundPermission: true,
    );

    const settings = InitializationSettings(
      android: android,
      iOS: darwin,
      macOS: darwin,
    );

    await _plugin.initialize(settings);
    await _requestNotificationPermission();
    _initialized = true;
  }

  Future<void> showWarning(
    BleWarningMessage message, {
    bool playSound = true,
  }) async {
    await initialize();

    // 语音朗读预警信息：嘟嘟嘟 + 线路/方向/车次 + 接近
    if (playSound && _settings.voiceBroadcastEnabled) {
      unawaited(_tts.speakWarning(message));
    }

    final title = '火车预警：${message.trainNo} ${message.direction}';
    final body =
        '线路：${message.line}  机车：${message.locomotive}  里程：${message.mileage}  速度：${message.speed}';
    final detail = [
      '信号强度：${message.signalStrength}',
      '车次：${message.trainNo}',
      '方向：${message.direction}',
      '线路：${message.line}',
      '机车：${message.locomotive}',
      '里程：${message.mileage}',
      '速度：${message.speed}',
    ].join('\n');

    await _plugin.show(
      _warningNotificationId,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.high,
          priority: Priority.high,
          playSound: false,
          sound: null,
          category: AndroidNotificationCategory.alarm,
          visibility: NotificationVisibility.public,
          fullScreenIntent: false,
          ongoing: true,
          autoCancel: false,
          onlyAlertOnce: true,
          ticker: '收到新的火车预警信息',
          styleInformation: BigTextStyleInformation(
            detail,
            contentTitle: title,
            summaryText: '实时行车预警信息',
          ),
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentSound: false,
          presentBadge: false,
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
        macOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentSound: false,
          presentBadge: false,
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
      ),
    );
  }

  Future<void> showStatus(String statusText) async {
    await initialize();
    // 状态变化（连接、断开、心跳超时等）时停止语音朗读。
    unawaited(_tts.stopSpeak());
    await _plugin.show(
      _warningNotificationId,
      '火车预警接收端',
      statusText,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.high,
          priority: Priority.high,
          playSound: false,
          sound: null,
          category: AndroidNotificationCategory.status,
          visibility: NotificationVisibility.public,
          ongoing: true,
          autoCancel: false,
          onlyAlertOnce: true,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentSound: false,
          presentBadge: false,
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
        macOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentSound: false,
          presentBadge: false,
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
      ),
    );
  }

  Future<void> _requestNotificationPermission() async {
    if (kIsWeb) return;

    if (defaultTargetPlatform == TargetPlatform.android) {
      await Permission.notification.request();
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: false, sound: true);
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.macOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: false, sound: true);
    }
  }
}
