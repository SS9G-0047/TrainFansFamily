import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

class NativeLocation {
  final double latitude;
  final double longitude;

  const NativeLocation({required this.latitude, required this.longitude});
}

/// 实时 GPS 位置更新（含速度）。
class GpsLocationUpdate {
  final double latitude;
  final double longitude;
  final double speed; // km/h
  final DateTime timestamp;
  final bool stale; // true 表示这是上次已知位置（可能过期），不可用于速度计算

  const GpsLocationUpdate({
    required this.latitude,
    required this.longitude,
    required this.speed,
    required this.timestamp,
    this.stale = false,
  });
}

class NativeLocationService {
  NativeLocationService._();

  static final NativeLocationService instance = NativeLocationService._();

  static const MethodChannel _channel = MethodChannel(
    'com.example.train_fans_family/overlay',
  );

  static const EventChannel _locationStreamChannel = EventChannel(
    'com.example.train_fans_family/location_stream',
  );

  Future<NativeLocation?> getCurrentLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever ||
          permission == LocationPermission.unableToDetermine) {
        return null;
      }

      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        final update = await locationStream().first.timeout(
          const Duration(seconds: 30),
        );
        return NativeLocation(
          latitude: update.latitude,
          longitude: update.longitude,
        );
      }

      final locationSettings = LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 30),
      );
      final position = await Geolocator.getCurrentPosition(
        locationSettings: locationSettings,
      );
      return NativeLocation(
        latitude: position.latitude,
        longitude: position.longitude,
      );
    } catch (error) {
      debugPrint('Unable to get current location: $error');
      return null;
    }
  }

  /// 启动实时 GPS 位置流，返回包含速度（km/h）的位置更新 Stream。
  ///
  /// 仅在 Android 原生平台可用；Web / iOS 会返回空流。
  Stream<GpsLocationUpdate> locationStream() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return _locationStreamChannel.receiveBroadcastStream().map((event) {
        final map = event as Map<dynamic, dynamic>;
        return GpsLocationUpdate(
          latitude: (map['latitude'] as num?)?.toDouble() ?? 0,
          longitude: (map['longitude'] as num?)?.toDouble() ?? 0,
          speed: (map['speed'] as num?)?.toDouble() ?? 0,
          timestamp: DateTime.fromMillisecondsSinceEpoch(
            (map['timestamp'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch,
          ),
          stale: (map['stale'] as bool?) ?? false,
        );
      });
    }
    return const Stream.empty();
  }

  /// 启动行程记录前台服务，保活进程以防后台被系统杀死。
  Future<void> startTripForegroundService({String tripName = '行程记录'}) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _channel.invokeMethod('startTripForeground', {
          'tripName': tripName,
        });
      } on MissingPluginException {
        // 忽略：旧版本原生代码不支持
      }
    }
  }

  /// 停止行程记录前台服务。
  Future<void> stopTripForegroundService() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _channel.invokeMethod('stopTripForeground');
      } on MissingPluginException {
        // 忽略
      }
    }
  }
}
