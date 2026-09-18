import 'package:flutter/material.dart';

class AppFunctionItem {
  final IconData icon;
  final String name;
  final Color themeColor;
  final Widget targetPage;

  const AppFunctionItem({
    required this.icon,
    required this.name,
    required this.themeColor,
    required this.targetPage,
  });
}