import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

  /// 复制并修改 updateAvailable
  AppUpdateInfo copyWith({bool? updateAvailable}) {
    return AppUpdateInfo(
      platform: platform,
      channel: channel,
      updateAvailable: updateAvailable ?? this.updateAvailable,
      buildNumber: buildNumber,
      versionName: versionName,
      force: force,
      changelog: changelog,
      changelogHtml: changelogHtml,
      updatedAt: updatedAt,
      url: url,
      sha256: sha256,
      size: size,
      downloadPage: downloadPage,
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

/// 本地版本信息
class LocalVersionInfo {
  final String versionName;
  final int buildNumber;

  const LocalVersionInfo({
    required this.versionName,
    required this.buildNumber,
  });

  factory LocalVersionInfo.fromJson(Map<String, dynamic> json) {
    return LocalVersionInfo(
      versionName: json['versionName'] as String? ?? '0.0.0',
      buildNumber: json['buildNumber'] as int? ?? 0,
    );
  }
}

/// 更新服务
///
/// 负责：
/// - 检查更新
/// - Windows 平台下载安装
/// - 下载状态管理（供 UI 监听）
///
/// 版本读取优先级（从高到低）：
/// 1. assets/version.json（打包时生成，最可靠）
/// 2. package_info_plus（原生读取）
/// 3. 硬编码兜底
class UpdateService extends ChangeNotifier {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  /// 更新检测接口地址
  static const String updateUrl = 'https://tff.xhcminecraft.top/update.json';

  /// 更新渠道：stable / beta
  static const String channel = 'stable';

  /// 硬编码兜底版本（最后一道防线）
  static const String _fallbackVersionName = '0.0.2-beta';
  static const int _fallbackBuildNumber = 3;

  final Dio _dio = Dio();

  PackageInfo? _packageInfo;
  LocalVersionInfo? _assetVersion;
  bool _assetVersionLoaded = false;
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
    // 并行加载两个版本来源
    await Future.wait([
      _loadAssetVersion(),
      _loadPackageInfo(),
    ]);
  }

  /// 从 assets/version.json 读取版本（最可靠）
  Future<void> _loadAssetVersion() async {
    if (_assetVersionLoaded) return;
    _assetVersionLoaded = true;

    try {
      final jsonStr = await rootBundle.loadString('lib/assets/version.json');
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      _assetVersion = LocalVersionInfo.fromJson(json);
      debugPrint(
        '[Update] asset version.json 读取成功: '
        '${_assetVersion!.versionName}+${_assetVersion!.buildNumber}',
      );
    } catch (e) {
      debugPrint('[Update] 读取 version.json 失败: $e');
    }
  }

  /// 从 package_info_plus 读取版本
  Future<void> _loadPackageInfo() async {
    try {
      _packageInfo = await PackageInfo.fromPlatform();
      debugPrint(
        '[Update] package_info_plus 读取结果: '
        'version=${_packageInfo?.version}, build=${_packageInfo?.buildNumber}',
      );
    } catch (e) {
      debugPrint('[Update] package_info_plus 读取失败: $e');
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

  /// 获取本地版本信息
  ///
  /// 优先级：asset JSON > package_info_plus > 硬编码兜底
  LocalVersionInfo get _currentVersion {
    // 1. 优先用 asset 里的 version.json（打包时生成，最可靠）
    if (_assetVersion != null && _assetVersion!.buildNumber > 0) {
      return _assetVersion!;
    }

    // 2. 其次用 package_info_plus
    final buildFromPackage =
        int.tryParse(_packageInfo?.buildNumber ?? '');
    if (buildFromPackage != null && buildFromPackage > 0) {
      return LocalVersionInfo(
        versionName: _packageInfo?.version ?? _fallbackVersionName,
        buildNumber: buildFromPackage,
      );
    }

    // 3. 最后用硬编码兜底
    debugPrint(
      '[Update] 使用硬编码兜底版本: $_fallbackVersionName+$_fallbackBuildNumber',
    );
    return const LocalVersionInfo(
      versionName: _fallbackVersionName,
      buildNumber: _fallbackBuildNumber,
    );
  }

  /// 检查更新
  ///
  /// 返回 [AppUpdateInfo]，如果有更新则 [updateAvailable] 为 true。
  /// 客户端自己比较 build number，不依赖服务端的 updateAvailable 字段。
  Future<AppUpdateInfo?> checkUpdate() async {
    if (!_assetVersionLoaded || _packageInfo == null) {
      await initialize();
    }

    try {
      final local = _currentVersion;
      debugPrint(
        '[Update] 本地版本: ${local.versionName}+${local.buildNumber} '
        '(platform=$_platform, channel=$channel)',
      );

      final response = await _dio.get(
        updateUrl,
        queryParameters: {
          'platform': _platform,
          'channel': channel,
          'build': local.buildNumber,
        },
        options: Options(
          headers: {'Cache-Control': 'no-store'},
          receiveTimeout: const Duration(seconds: 8),
          sendTimeout: const Duration(seconds: 8),
        ),
      );

      debugPrint('[Update] 服务端返回: ${response.data}');

      if (response.data is Map<String, dynamic>) {
        var info = AppUpdateInfo.fromJson(response.data);

        // 客户端自己比对版本
        final serverBuild = info.buildNumber ?? 0;
        final hasUpdate = serverBuild > local.buildNumber;

        debugPrint(
          '[Update] 版本比对: 本地 build=${local.buildNumber}, '
          '服务端 build=$serverBuild, 是否有更新=$hasUpdate',
        );

        // 用客户端比对结果覆盖服务端的 updateAvailable
        info = info.copyWith(updateAvailable: hasUpdate);

        _latestUpdate = info;
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
