import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
import 'package:yaml/yaml.dart';

/// Builder：从 pubspec.yaml 读取版本号，生成 version.json
///
/// 每次 build_runner build 时自动执行，无需手动调用。
class VersionBuilder implements Builder {
  @override
  final buildExtensions = const {
    r'$package$': ['lib/assets/version.json'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    // 读取 pubspec.yaml
    final pubspecId = AssetId(buildStep.inputId.package, 'pubspec.yaml');
    final pubspecContent = await buildStep.readAsString(pubspecId);
    final pubspec = loadYaml(pubspecContent) as YamlMap;

    final version = pubspec['version']?.toString() ?? '0.0.0+1';

    String versionName;
    int buildNumber = 1;
    if (version.contains('+')) {
      final parts = version.split('+');
      versionName = parts[0];
      buildNumber = int.tryParse(parts[1]) ?? 1;
    } else {
      versionName = version;
    }

    final output = {
      'versionName': versionName,
      'buildNumber': buildNumber,
      'generatedAt': DateTime.now().toIso8601String(),
    };

    final outputId = AssetId(
      buildStep.inputId.package,
      'lib/assets/version.json',
    );

    await buildStep.writeAsString(
      outputId,
      const JsonEncoder.withIndent('  ').convert(output),
    );

    // 同步写入源文件（build_runner 输出到 build 缓存，不直接写源文件）
    // 为了让 flutter build 也能拿到最新版本，这里同时写源文件
    final outputFile = File('lib/assets/version.json');
    if (!outputFile.parent.existsSync()) {
      outputFile.parent.createSync(recursive: true);
    }
    await outputFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(output),
    );
  }
}

Builder versionBuilder(BuilderOptions options) => VersionBuilder();
