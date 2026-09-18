import 'package:flutter/widgets.dart';

import 'cross_file_image_io.dart' if (dart.library.html) 'cross_file_image_web.dart'
    as impl;

/// 跨平台的本地文件图片显示组件。
///
/// 在原生平台（Android/iOS/macOS）使用 `Image.file` 加载本地文件；
/// 在 Web 平台显示占位图（Web 无法访问本地文件系统）。
Widget crossFileImage(
  String path, {
  double? width,
  double? height,
  BoxFit? fit,
  Widget Function(BuildContext, Object, StackTrace?)? errorBuilder,
}) {
  return impl.crossFileImage(
    path,
    width: width,
    height: height,
    fit: fit,
    errorBuilder: errorBuilder,
  );
}
