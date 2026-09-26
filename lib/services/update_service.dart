import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// 更新信息模型
class AppUpdateInfo {
  final String platform;
  final String channel;
  final bool updateAvailable;
  final int? buildNumber;
  final String? versionName;
  final bool force;
  final String? changelog;
  final String? changelogHtml;
  final String? updatedAt;
  final String? url;
  final String? sha256;
  final int? size;
  final String? downloadPage;

  AppUpdateInfo({
    required this.platform,
    required this.channel,
    required this.updateAvailable,
    this.buildNumber,
    this.versionName,
    this.force = false,
    this.changelog,
    this.changelogHtml,
    this.updatedAt,
    this.url,
    this.sha256,
    this.size,
    this.downloadPage,
  });

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    return AppUpdateInfo(
      platform: json['platform'] as String? ?? '',
      channel: json['channel'] as String? ?? 'stable',
      updateAvailable: json['updateAvailable'] as bool? ?? false,
      buildNumber: json['buildNumber'] as int?,
      versionName: json['versionName'] as String?,
      force: json['force'] as bool? ?? false,
      changelog: json['changelog'] as String?,
      changelogHtml: json['changelogHtml'] as String?,
      updatedAt: json['updatedAt'] as String?,
      url: json['url'] as String?,
      sha256: json['sha256'] as String?,
      size: json['size'] as int?,
      downloadPage: json['downloadPage'] as String?,
    );
  }

  /// 格式化文件大小
  String get formattedSize {
    if (size == null) return '';
    if (size! < 1024) return '${size!} B';
    if (size! < 1024 * 1024) return '${(size! / 1024).toStringAsFixed(1)} KB';
    if (size! < 1024 * 1024 * 1024) {
      return '${(size! / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size! / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// 下载状态
enum DownloadStatus {
  idle,
  downloading,
  completed,
  failed,
  installing,
}

/// 更新服务
///
/// 负责：
/// - 检查更新
/// - Windows 平台下载安装
/// - 下载状态管理（供 UI 监听）
///
/// Android 平台的 OTA 安装在 UI 层直接调用 ota_update 插件
class UpdateService extends ChangeNotifier {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  /// 更新检测接口地址
  static const String updateUrl = 'https://tff.xhcminecraft.top/update.json';

  /// 更新渠道：stable / beta
  static const String channel = 'stable';

  final Dio _dio = Dio();

  PackageInfo? _packageInfo;
  AppUpdateInfo? _latestUpdate;
  DownloadStatus _downloadStatus = DownloadStatus.idle;
  double _downloadProgress = 0.0;
  String? _downloadError;

  /// 当前应用包信息
  PackageInfo? get packageInfo => _packageInfo;

  /// 最新版本信息
  AppUpdateInfo? get latestUpdate => _latestUpdate;

  /// 下载状态
  DownloadStatus get downloadStatus => _downloadStatus;

  /// 下载进度 0.0 ~ 1.0
  double get downloadProgress => _downloadProgress;

  /// 下载错误信息
  String? get downloadError => _downloadError;

  /// 初始化（获取当前应用版本信息）
  Future<void> initialize() async {
    try {
      _packageInfo = await PackageInfo.fromPlatform();
    } catch (e) {
      debugPrint('获取应用版本信息失败: $e');
    }
  }

  /// 获取当前平台字符串
  String get _platform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  /// 检查更新
  ///
  /// 返回 [AppUpdateInfo]，如果有更新则 [updateAvailable] 为 true
  Future<AppUpdateInfo?> checkUpdate() async {
    if (_packageInfo == null) await initialize();
    if (_packageInfo == null) return null;

    try {
      final buildNumber = int.tryParse(_packageInfo!.buildNumber) ?? 0;
      final response = await _dio.get(
        updateUrl,
        queryParameters: {
          'platform': _platform,
          'channel': channel,
          'build': buildNumber,
        },
        options: Options(
          headers: {'Cache-Control': 'no-store'},
          receiveTimeout: const Duration(seconds: 8),
          sendTimeout: const Duration(seconds: 8),
        ),
      );

      if (response.data is Map<String, dynamic>) {
        _latestUpdate = AppUpdateInfo.fromJson(response.data);
        notifyListeners();
        return _latestUpdate;
      }
    } catch (e) {
      debugPrint('检查更新失败: $e');
    }
    return null;
  }

  // ==================== 状态管理 ====================

  /// 更新下载进度
  void updateProgress(double progress) {
    _downloadProgress = progress.clamp(0.0, 1.0);
    notifyListeners();
  }

  /// 更新下载状态
  void updateStatus(DownloadStatus status, {String? error}) {
    _downloadStatus = status;
    if (error != null) _downloadError = error;
    if (status == DownloadStatus.idle) {
      _downloadProgress = 0.0;
      _downloadError = null;
    }
    notifyListeners();
  }

  /// 重置下载状态
  void resetDownload() {
    updateStatus(DownloadStatus.idle);
  }

  // ==================== Windows 更新 ====================

  /// Windows 平台下载并安装更新
  ///
  /// 下载完成后自动运行安装程序并退出当前应用
  Future<void> downloadAndInstallWindows() async {
    final update = _latestUpdate;
    if (update == null || update.url == null) return;
    if (!Platform.isWindows) return;

    updateStatus(DownloadStatus.downloading);

    try {
      final directory = await getTemporaryDirectory();
      final fileName = update.url!.split('/').last;
      final savePath = '${directory.path}\\$fileName';

      debugPrint('开始下载更新包到: $savePath');

      await _dio.download(
        update.url!,
        savePath,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            updateProgress(received / total);
          }
        },
        options: Options(
          receiveTimeout: const Duration(minutes: 30),
          sendTimeout: const Duration(minutes: 2),
        ),
      );

      updateStatus(DownloadStatus.installing);
      debugPrint('下载完成，开始安装...');

      // 运行安装程序（以分离模式启动，不阻塞当前进程）
      try {
        await Process.start(
          savePath,
          ['/verysilent', '/norestart'], // 尝试静默安装参数
          mode: ProcessStartMode.detached,
        );
      } catch (e) {
        // 如果静默安装失败，用普通方式运行
        debugPrint('静默安装失败，尝试普通安装: $e');
        await Process.start(
          savePath,
          [],
          mode: ProcessStartMode.normal,
        );
      }

      updateStatus(DownloadStatus.completed);

      // 短暂延迟后退出当前应用，让安装程序接管
      await Future.delayed(const Duration(milliseconds: 500));
      exit(0);
    } catch (e) {
      debugPrint('下载更新失败: $e');
      updateStatus(DownloadStatus.failed, error: e.toString());
    }
  }
}
