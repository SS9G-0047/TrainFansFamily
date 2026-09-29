# 自动更新 version.json

`lib/assets/version.json` 用于在 App 内显示当前版本号，版本来源于 `pubspec.yaml` 的 `version` 字段。

## 两种自动更新方式

### 方式一：包装脚本（推荐，最简单）

直接用 `tool/build.dart` 代替 `flutter build` 命令，构建前自动更新 version.json。

```bash
# 构建 Android APK
dart run tool/build.dart apk

# 构建 Android App Bundle
dart run tool/build.dart appbundle

# 构建 Windows
dart run tool/build.dart windows

# 构建 Web
dart run tool/build.dart web

# 带额外参数
dart run tool/build.dart apk --release --obfuscate --split-debug-info=./debug-info
```

等价于先执行 `dart run tool/generate_version.dart`，再执行 `flutter build <目标>`。

### 方式二：build_runner（自动化程度最高）

通过 `build_runner` 的 Builder 机制，每次构建自动生成 version.json。

**初始设置（只需一次）：**

```bash
flutter pub get
```

**使用：**

```bash
# 生成 version.json
dart run build_runner build

# 持续监听 pubspec.yaml 变化，自动更新
dart run build_runner watch
```

> **注意：** `flutter build` 本身不会自动触发 `build_runner`。如果想要完全自动化，请结合方式一使用，或在 CI/CD 中先执行 `dart run build_runner build` 再 `flutter build`。

### 方式三：手动更新（备胎）

任何时候手动执行：

```bash
dart run tool/generate_version.dart
```

## 文件说明

| 文件 | 作用 |
|------|------|
| `tool/generate_version.dart` | 核心生成脚本，从 pubspec.yaml 读取版本并写入 version.json |
| `tool/build.dart` | 包装脚本，先更新版本再执行 flutter build |
| `lib/builder/version_builder.dart` | build_runner Builder，供 build.yaml 调用 |
| `build.yaml` | build_runner 配置，注册 version_builder |
