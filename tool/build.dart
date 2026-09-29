/// 构建包装脚本：自动更新 version.json 后再执行 flutter build
///
/// 用法：
///   dart run tool/build.dart apk           # 构建 Android APK
///   dart run tool/build.dart appbundle     # 构建 Android App Bundle
///   dart run tool/build.dart windows       # 构建 Windows
///   dart run tool/build.dart web           # 构建 Web
///   dart run tool/build.dart apk --release # 带额外参数
///
/// 等价于先执行 dart run tool/generate_version.dart，再执行 flutter build <目标>
import 'dart:io';

void main(List<String> args) async {
  if (args.isEmpty) {
    print('用法: dart run tool/build.dart <build目标> [额外参数...]');
    print('');
    print('示例:');
    print('  dart run tool/build.dart apk');
    print('  dart run tool/build.dart apk --release');
    print('  dart run tool/build.dart windows');
    print('  dart run tool/build.dart web --release');
    exit(1);
  }

  // 1. 先生成 version.json
  print('▶ 更新 version.json...');
  final genResult = await Process.run(
    Platform.resolvedExecutable,
    ['run', 'tool/generate_version.dart'],
    workingDirectory: Directory.current.path,
  );
  stdout.write(genResult.stdout);
  stderr.write(genResult.stderr);
  if (genResult.exitCode != 0) {
    print('❌ version.json 生成失败，终止构建');
    exit(genResult.exitCode);
  }

  // 2. 执行 flutter build
  final target = args.first;
  final extraArgs = args.skip(1).toList();
  final buildArgs = ['build', target, ...extraArgs];

  print('');
  print('▶ flutter ${buildArgs.join(' ')}');
  print('');

  final flutterExe = _findFlutter();
  if (flutterExe == null) {
    print('❌ 找不到 flutter 命令，请确保 Flutter 已加入 PATH');
    exit(1);
  }

  final buildProcess = await Process.start(
    flutterExe,
    buildArgs,
    workingDirectory: Directory.current.path,
    mode: ProcessStartMode.inheritStdio,
  );

  final exitCode = await buildProcess.exitCode;
  if (exitCode != 0) {
    print('\n❌ 构建失败 (exit code: $exitCode)');
  } else {
    print('\n✅ 构建完成');
  }
  exit(exitCode);
}

String? _findFlutter() {
  // 优先从 PATH 找
  for (final dir in _pathDirs) {
    final flutter = File('$dir${Platform.pathSeparator}flutter');
    final flutterBat = File('$dir${Platform.pathSeparator}flutter.bat');
    if (flutter.existsSync()) return flutter.path;
    if (flutterBat.existsSync()) return flutterBat.path;
  }
  return null;
}

List<String> get _pathDirs {
  final path = Platform.environment['PATH'] ?? '';
  return path.split(Platform.isWindows ? ';' : ':')
    ..where((d) => d.isNotEmpty);
}
