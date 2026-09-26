// import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// import 'package:ota_update/ota_update.dart';
// import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/update_service.dart';

/// 更新对话框
class UpdateDialog extends StatefulWidget {
  final AppUpdateInfo updateInfo;

  const UpdateDialog({super.key, required this.updateInfo});

  /// 显示更新对话框
  static Future<void> show(BuildContext context, AppUpdateInfo updateInfo) {
    return showDialog(
      context: context,
      barrierDismissible: !updateInfo.force, // 强制更新不可关闭
      builder: (context) => UpdateDialog(updateInfo: updateInfo),
    );
  }

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  final UpdateService _updateService = UpdateService.instance;
  // StreamSubscription<OtaEvent>? _otaSubscription;

  @override
  void initState() {
    super.initState();
    _updateService.addListener(_onUpdateChanged);
    _updateService.resetDownload();
  }

  @override
  void dispose() {
    // _otaSubscription?.cancel();
    // _otaSubscription = null;
    _updateService.removeListener(_onUpdateChanged);
    super.dispose();
  }

  void _onUpdateChanged() {
    if (mounted) {
      // 使用 addPostFrameCallback 避免在 build 过程中触发 rebuild
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  // /// 安全地更新状态（避免 build 过程中调用 setState）
  // void _safeUpdateStatus(DownloadStatus status, {String? error}) {
  //   WidgetsBinding.instance.addPostFrameCallback((_) {
  //     if (mounted) {
  //       _updateService.updateStatus(status, error: error);
  //     }
  //   });
  // }

  // /// 安全地更新进度
  // void _safeUpdateProgress(double progress) {
  //   WidgetsBinding.instance.addPostFrameCallback((_) {
  //     if (mounted) {
  //       _updateService.updateProgress(progress);
  //     }
  //   });
  // }

  // /// 开始下载更新（已禁用，全部走浏览器下载）
  // Future<void> _startDownload() async {
  //   if (Platform.isAndroid) {
  //     await _startAndroidUpdate();
  //   } else if (Platform.isWindows) {
  //     await _updateService.downloadAndInstallWindows();
  //   } else {
  //     // 其他平台打开下载页面
  //     if (widget.updateInfo.downloadPage != null) {
  //       await launchUrl(Uri.parse(widget.updateInfo.downloadPage!));
  //     }
  //   }
  // }

  // /// Android 平台更新（使用 ota_update 插件）
  // Future<void> _startAndroidUpdate() async {
  //   final url = widget.updateInfo.url;
  //   if (url == null) return;
  //
  //   // 取消之前的订阅
  //   await _otaSubscription?.cancel();
  //   _otaSubscription = null;
  //
  //   // 请求安装包权限
  //   final status = await Permission.requestInstallPackages.request();
  //   if (!status.isGranted) {
  //     _safeUpdateStatus(
  //       DownloadStatus.failed,
  //       error: '未授予安装应用权限，请在设置中开启',
  //     );
  //     return;
  //   }
  //
  //   _safeUpdateStatus(DownloadStatus.downloading);
  //
  //   try {
  //     // 构造 OTA 更新参数
  //     final ota = OtaUpdate();
  //     Stream<OtaEvent> stream;
  //
  //     if (widget.updateInfo.sha256 != null &&
  //         widget.updateInfo.sha256!.isNotEmpty) {
  //       stream = ota.execute(
  //         url,
  //         destinationFilename: 'update.apk',
  //         sha256checksum: widget.updateInfo.sha256,
  //       );
  //     } else {
  //       // 没有 sha256 时不传，避免 native 层空指针
  //       stream = ota.execute(
  //         url,
  //         destinationFilename: 'update.apk',
  //       );
  //     }
  //
  //     _otaSubscription = stream.listen(
  //       _handleOtaEvent,
  //       onError: _handleOtaError,
  //       cancelOnError: false,
  //     );
  //   } catch (e) {
  //     debugPrint('启动 OTA 更新失败: $e');
  //     _safeUpdateStatus(
  //       DownloadStatus.failed,
  //       error: '启动更新失败：${e.toString()}',
  //     );
  //   }
  // }

  // /// 处理 OTA 事件
  // void _handleOtaEvent(OtaEvent event) {
  //   debugPrint('OTA 状态: ${event.status} - ${event.value}');
  //
  //   switch (event.status) {
  //     case OtaStatus.DOWNLOADING:
  //       final progress = double.tryParse(event.value ?? '0') ?? 0;
  //       _safeUpdateProgress(progress / 100);
  //       break;
  //
  //     case OtaStatus.INSTALLING:
  //       // 进入安装阶段，更新一次状态后不再继续监听 UI 变化
  //       // 因为系统安装界面弹出后，当前 Activity 可能被 pause 或重建
  //       _safeUpdateStatus(DownloadStatus.installing);
  //       // 取消订阅，避免后续状态回调导致崩溃
  //       _otaSubscription?.cancel();
  //       _otaSubscription = null;
  //       break;
  //
  //     case OtaStatus.INSTALLATION_DONE:
  //       _safeUpdateStatus(DownloadStatus.completed);
  //       _otaSubscription?.cancel();
  //       _otaSubscription = null;
  //       break;
  //
  //     case OtaStatus.ALREADY_RUNNING_ERROR:
  //       _safeUpdateStatus(
  //         DownloadStatus.failed,
  //         error: '更新已在运行中',
  //       );
  //       break;
  //
  //     case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
  //       _safeUpdateStatus(
  //         DownloadStatus.failed,
  //         error: '未授予安装权限',
  //       );
  //       break;
  //
  //     case OtaStatus.DOWNLOAD_ERROR:
  //       _safeUpdateStatus(
  //         DownloadStatus.failed,
  //         error: '下载失败，请检查网络',
  //       );
  //       break;
  //
  //     case OtaStatus.INTERNAL_ERROR:
  //       _safeUpdateStatus(
  //         DownloadStatus.failed,
  //         error: '内部错误',
  //       );
  //       break;
  //
  //     case OtaStatus.INSTALLATION_ERROR:
  //       _safeUpdateStatus(
  //         DownloadStatus.failed,
  //         error: '安装失败',
  //       );
  //       break;
  //
  //     default:
  //       break;
  //   }
  // }

  // /// 处理 OTA 错误
  // void _handleOtaError(Object error) {
  //   debugPrint('OTA 更新错误: $error');
  //   String errorMsg;
  //   if (error is PlatformException) {
  //     errorMsg = error.message ?? '未知错误';
  //   } else {
  //     errorMsg = error.toString();
  //   }
  //   _safeUpdateStatus(
  //     DownloadStatus.failed,
  //     error: '更新出错：$errorMsg',
  //   );
  // }

  /// 打开浏览器下载页面
  Future<void> _openDownloadPage() async {
    final url = widget.updateInfo.downloadPage ?? widget.updateInfo.url;
    if (url != null && await canLaunchUrl(Uri.parse(url))) {
      await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isForce = widget.updateInfo.force;
    // final status = _updateService.downloadStatus;
    // final progress = _updateService.downloadProgress;
    // final error = _updateService.downloadError;

    return PopScope(
      canPop: !isForce,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (isForce) {
          // 强制更新时，按返回键退出应用
          SystemNavigator.pop();
        }
      },
      child: AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.system_update, color: Colors.blue),
            const SizedBox(width: 8),
            Text(isForce ? '发现重要更新' : '发现新版本'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 版本信息
              Row(
                children: [
                  Text(
                    'v${widget.updateInfo.versionName ?? ''}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (widget.updateInfo.formattedSize.isNotEmpty)
                    Text(
                      '(${widget.updateInfo.formattedSize})',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),

              // 更新日志
              const Text(
                '更新内容：',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.maxFinite,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.updateInfo.changelog ?? '暂无更新说明',
                  style: const TextStyle(fontSize: 14, height: 1.5),
                ),
              ),

              const SizedBox(height: 12),

              // 下载提示
              const Text(
                '点击下方按钮跳转到浏览器下载更新',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),

              // 强制更新提示
              if (isForce) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        color: Colors.orange[700], size: 18),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '此版本为强制更新，更新后才能继续使用',
                        style: TextStyle(
                          color: Colors.orange[700],
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        actions: _buildActions(isForce),
      ),
    );
  }

  List<Widget> _buildActions(bool isForce) {
    return [
      if (!isForce)
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('稍后再说'),
        ),
      FilledButton.icon(
        onPressed: _openDownloadPage,
        icon: const Icon(Icons.open_in_browser, size: 18),
        label: const Text('浏览器下载'),
      ),
    ];
  }
}
