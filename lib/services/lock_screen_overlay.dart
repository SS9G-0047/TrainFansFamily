import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 锁屏浮窗桥接
/// iOS 无对应实现，调用会直接忽略
class LockScreenOverlay {
  static const MethodChannel _channel =
      MethodChannel('com.example.warningapplication_1/overlay');

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 检查是否已授予悬浮窗权限（Android 6+）
  static Future<bool> canDrawOverlays() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('canDrawOverlays') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 跳转到系统设置页手动开启悬浮窗权限
  static Future<void> openOverlaySettings() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('openOverlaySettings');
    } on MissingPluginException {
      return;
    }
  }

  /// 检查是否已经忽略系统电池优化
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!_isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 请求忽略系统电池优化，通常会弹出系统授权页
  static Future<void> requestIgnoreBatteryOptimizations() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } on MissingPluginException {
      return;
    }
  }

  /// 显示锁屏浮窗（首次调用会启动前台 Service）
  static Future<void> showOverlay(String title, String content, {String trainNo = ''}) async {
    if (!_isAndroid) return;
    try {
      final batteryOk = await isIgnoringBatteryOptimizations();
      if (!batteryOk) {
        await requestIgnoreBatteryOptimizations();
      }
      await _channel.invokeMethod('showOverlay', {
        'title': title,
        'content': content,
        'trainNo': trainNo,
      });
    } on MissingPluginException {
      return;
    }
  }

  /// 更新已显示的锁屏浮窗内容
  static Future<void> updateOverlay(String title, String content, {String trainNo = ''}) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('updateOverlay', {
        'title': title,
        'content': content,
        'trainNo': trainNo,
      });
    } on MissingPluginException {
      return;
    }
  }

  /// 隐藏并销毁锁屏浮窗
  static Future<void> hideOverlay() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('hideOverlay');
    } on MissingPluginException {
      return;
    }
  }
}
