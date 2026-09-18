import 'package:flutter/material.dart';
import '../models/ble_warning_message.dart';
import '../services/app_settings_service.dart';
import '../services/lock_screen_overlay.dart';
import '../services/tts_service.dart';

class SettingPage extends StatefulWidget {
  const SettingPage({super.key});

  @override
  State<SettingPage> createState() => _SettingPageState();
}

class _SettingPageState extends State<SettingPage> {
  final AppSettingsService _settings = AppSettingsService.instance;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_refresh);
    _settings.load();
  }

  @override
  void dispose() {
    _settings.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("系统设置")),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          SwitchListTile(
            value: _settings.floatingOverlayEnabled,
            title: const Text("浮窗开关"),
            subtitle: const Text("关闭后不显示桌面悬浮球、信息浮窗和锁屏预警页"),
            secondary: const Icon(Icons.picture_in_picture_alt),
            onChanged: (value) async {
              await _settings.setFloatingOverlayEnabled(value);
              if (!value) {
                await LockScreenOverlay.hideOverlay();
              }
            },
          ),
          const Divider(height: 1),
          SwitchListTile(
            value: _settings.homeWarningEnabled,
            title: const Text("主页显示开关"),
            subtitle: const Text("控制首页顶部实时行车预警信息卡片是否显示"),
            secondary: const Icon(Icons.home),
            onChanged: (value) async {
              await _settings.setHomeWarningEnabled(value);
            },
          ),
          const Divider(height: 1),
          SwitchListTile(
            value: _settings.voiceBroadcastEnabled,
            title: const Text("语音播报开关"),
            subtitle: const Text("来车时嘟嘟嘟 + 方向/列车/接近语音播报\n上行男声，下行女声"),
            secondary: const Icon(Icons.notifications_active),
            onChanged: (value) async {
              await _settings.setVoiceBroadcastEnabled(value);
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.volume_up),
            title: const Text("语音播报复试"),
            subtitle: const Text("点击试听来车语音播报效果"),
            trailing: TextButton(
              onPressed: () {
                TtsService.instance.speakWarning(
                  BleWarningMessage(
                    signalStrength: '-62',
                    trainNo: 'Z155',
                    direction: '下',
                    line: '京哈线',
                    locomotive: 'SS9G-0501',
                    mileage: '10.2K',
                    speed: '160km/h',
                    receivedAt: DateTime.now(),
                  ),
                );
              },
              child: const Text("试听"),
            ),
          ),
        ],
      ),
    );
  }
}
