import 'package:flutter/material.dart';

/// Web 平台桩实现：显示占位图（Web 无法访问本地文件系统）。
Widget crossFileImage(
  String path, {
  double? width,
  double? height,
  BoxFit? fit,
  Widget Function(BuildContext, Object, StackTrace?)? errorBuilder,
}) {
  return Container(
    width: width,
    height: height,
    color: const Color(0xFFE0E0E0),
    child: const Center(
      child: Icon(Icons.image_not_supported, color: Color(0xFF9E9E9E)),
    ),
  );
}
