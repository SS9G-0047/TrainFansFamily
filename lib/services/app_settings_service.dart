import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettingsService extends ChangeNotifier {
  AppSettingsService._() {
    load();
  }

  static final AppSettingsService instance = AppSettingsService._();

  static const String _floatingOverlayKey = 'floating_overlay_enabled';
  static const String _homeWarningKey = 'home_warning_enabled';
  static const String _voiceBroadcastKey = 'voice_broadcast_enabled';

  bool _floatingOverlayEnabled = false;
  bool _homeWarningEnabled = false;
  bool _voiceBroadcastEnabled = false;
  bool _loaded = false;

  bool get floatingOverlayEnabled => _floatingOverlayEnabled;
  bool get homeWarningEnabled => _homeWarningEnabled;
  bool get voiceBroadcastEnabled => _voiceBroadcastEnabled;
  bool get loaded => _loaded;

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    _floatingOverlayEnabled = sp.getBool(_floatingOverlayKey) ?? false;
    _homeWarningEnabled = sp.getBool(_homeWarningKey) ?? false;
    _voiceBroadcastEnabled = sp.getBool(_voiceBroadcastKey) ?? false;
    _loaded = true;
    notifyListeners();
  }

  Future<void> setFloatingOverlayEnabled(bool value) async {
    if (_floatingOverlayEnabled == value) return;
    _floatingOverlayEnabled = value;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_floatingOverlayKey, value);
  }

  Future<void> setHomeWarningEnabled(bool value) async {
    if (_homeWarningEnabled == value) return;
    _homeWarningEnabled = value;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_homeWarningKey, value);
  }

  Future<void> setVoiceBroadcastEnabled(bool value) async {
    if (_voiceBroadcastEnabled == value) return;
    _voiceBroadcastEnabled = value;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_voiceBroadcastKey, value);
  }
}
