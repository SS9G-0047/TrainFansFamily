/// 从 pubspec.yaml 读取版本号，生成 lib/assets/version.json
///
/// 用法：
///   dart run tool/generate_version.dart
///
/// 建议在打包前执行一次，确保 version.json 和 pubspec 里的版本一致。
import 'dart:convert';
import 'dart:io';

void main() async {
  const pubspecPath = 'pubspec.yaml';
  const outputPath = 'lib/assets/version.json';

  // 读取 pubspec.yaml
  final file = File(pubspecPath);
  if (!file.existsSync()) {
    stderr.writeln('❌ 找不到 pubspec.yaml');
    exit(1);
  }

  final lines = await file.readAsLines();
  String? versionLine;

  for (final line in lines) {
    // 匹配以 version: 开头的行（前面可以有空格）
    final trimmed = line.trim();
    if (trimmed.startsWith('version:')) {
      versionLine = trimmed;
      break;
    }
  }

  if (versionLine == null) {
    stderr.writeln('❌ pubspec.yaml 中找不到 version 字段');
    exit(1);
  }

  // 解析 version: 1.0.0+1
  final versionValue = versionLine.replaceFirst('version:', '').trim();
  // 去掉引号（如果有的话）
  final cleanVersion = versionValue.replaceAll("'", '').replaceAll('"', '');

  // 拆分成 versionName 和 buildNumber
  String versionName;
  int buildNumber = 1;

  if (cleanVersion.contains('+')) {
    final parts = cleanVersion.split('+');
    versionName = parts[0];
    buildNumber = int.tryParse(parts[1]) ?? 1;
  } else {
    versionName = cleanVersion;
  }

  final json = {
    'versionName': versionName,
    'buildNumber': buildNumber,
    'generatedAt': DateTime.now().toIso8601String(),
  };

  // 确保目录存在
  final outputDir = File(outputPath).parent;
  if (!outputDir.existsSync()) {
    outputDir.createSync(recursive: true);
  }

  // 写入 JSON
  final outputFile = File(outputPath);
  await outputFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(json),
  );

  print('✅ 已生成 $outputPath');
  print('   版本: $versionName+$buildNumber');
}
