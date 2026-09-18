import 'dart:io';

import 'package:flutter/widgets.dart';

/// 原生平台实现：使用 `Image.file` 加载本地文件。
Widget crossFileImage(
  String path, {
  double? width,
  double? height,
  BoxFit? fit,
  Widget Function(BuildContext, Object, StackTrace?)? errorBuilder,
}) {
  return Image.file(
    File(path),
    width: width,
    height: height,
    fit: fit,
    errorBuilder: errorBuilder,
  );
}
