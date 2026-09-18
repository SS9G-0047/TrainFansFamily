import 'package:flutter/services.dart';

import '../models/ble_warning_message.dart';

/// 语音朗读预警信息服务。
///
/// 使用 res/raw 目录中的预录音频文件拼接播放，不依赖 TTS 引擎。
/// 朗读流程：先播放嘟嘟嘟蜂鸣音（beep_warning.wav），
/// 然后按顺序拼接播放：方向 → 列车 → 接近。
///
/// 朗读规则：
/// - 上行 → 男声（male_* 系列）
/// - 下行 → 女声（female_* 系列）
/// - 无上下行信息 → 默认男声，不播放方向音频
///
/// 音频文件命名（res/raw/，全英文小写）：
/// - beep_warning.wav    蜂鸣音
/// - male_up.wav         上行（男声）
/// - female_down.wav     下行（女声）
/// - male_train.wav      列车（男声）
/// - female_train.wav    列车（女声）
/// - male_approach.wav   接近（男声）
/// - female_approach.wav 接近（女声）
/// - sound_test.mp3      声音自检
class TtsService {
  TtsService._();

  static final TtsService instance = TtsService._();
  static const MethodChannel _channel = MethodChannel(
    'com.example.warningapplication_1/tts',
  );

  /// 播放预警语音。
  /// 车次为空时不播放。
  Future<void> speakWarning(BleWarningMessage message) async {
    final trainNo = _cleanField(message.trainNo);
    if (trainNo.isEmpty) return;
    await _channel.invokeMethod<void>('speakWarning', {
      'direction': message.direction,
      'trainNo': trainNo,
    });
  }

  /// 停止播放。
  Future<void> stopSpeak() async {
    await _channel.invokeMethod<void>('stopSpeak');
  }

  /// 清理字段：去除空值占位符。
  String _cleanField(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == '#' || trimmed == '--') return '';
    return trimmed;
  }
}
