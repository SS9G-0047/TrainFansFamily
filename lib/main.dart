import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'pages/home_page.dart';
import 'services/warning_notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 全局错误处理：过滤地图瓦片加载过程中的非致命异常
  // 包括：瓦片取消加载(CancellationException)、网络请求失败、超时等
  // 这些异常不影响应用功能，瓦片加载失败后对应区域仅显示空白
  FlutterError.onError = (FlutterErrorDetails details) {
    final exceptionStr = details.exception.toString();
    final stackStr = details.stack?.toString() ?? '';

    if (exceptionStr.contains('Attempted to send a key down event when no keys are in keysPressed') ||
        exceptionStr.contains('Unable to parse JSON message: The document is empty')) {
      return;
    }

    // 瓦片取消加载（flutter_map 缩放/平移时的正常行为）
    if (exceptionStr.contains('Cancelled') ||
        exceptionStr.contains('CancellationException')) {
      return;
    }
    // 网络请求失败（404/204/超时/连接失败等，地图瓦片加载时常见）
    if (exceptionStr.contains('SocketException') ||
        exceptionStr.contains('HandshakeException') ||
        exceptionStr.contains('TimeoutException') ||
        exceptionStr.contains('HttpException') ||
        exceptionStr.contains('Failed host lookup') ||
        exceptionStr.contains('Connection refused') ||
        exceptionStr.contains('Connection closed') ||
        exceptionStr.contains('NetworkImageLoadException') ||
        exceptionStr.contains('image load failed') ||
        exceptionStr.contains('ProviderException') ||
        exceptionStr.contains('Invalid tile coordinates')) {
      return;
    }
    // 通过堆栈判断是否为瓦片加载相关错误
    if (stackStr.contains('tile') ||
        stackStr.contains('Tile') ||
        stackStr.contains('flutter_map') ||
        stackStr.contains('vector_map_tiles') ||
        stackStr.contains('NetworkImage') ||
        stackStr.contains('ImageProvider') ||
        stackStr.contains('ImageStream')) {
      return;
    }
    FlutterError.presentError(details);
  };

  await WarningNotificationService.instance.initialize();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '车迷驿',
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color.fromARGB(255, 37, 157, 255),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color.fromARGB(255, 37, 157, 255),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: '首页'),
      debugShowCheckedModeBanner: false,
    );
  }
}
