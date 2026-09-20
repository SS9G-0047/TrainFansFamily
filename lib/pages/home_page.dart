import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:warningapplication_1/pages/train_search_page.dart';
import '../models/function_item.dart';
import '../services/app_settings_service.dart';
import '../services/ble_warning_service.dart';
import '../services/trip_service.dart';
import '../widgets/warning_widget.dart';
import 'camera_position_page.dart';
import 'connect_page.dart';
import 'history_page.dart';
import 'railway_map_page.dart';
import 'setting_page.dart';
import 'trip_page.dart';

class MyHomePage extends StatefulWidget {
  final String title;
  const MyHomePage({super.key, required this.title});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final BleWarningService _bleService = BleWarningService.instance;
  final AppSettingsService _settings = AppSettingsService.instance;
  final TripService _tripService = TripService.instance;
  late final List<AppFunctionItem> functionList;
  bool _interruptedTripChecked = false;

  @override
  void initState() {
    super.initState();
    _bleService.addListener(_refreshWarning);
    _settings.addListener(_refreshWarning);
    _tripService.addListener(_onTripServiceChanged);
    _settings.load();
    functionList = [
      AppFunctionItem(
        icon: Icons.bluetooth_connected,
        name: "预警器连接",
        themeColor: Colors.blue,
        targetPage: const ConnectWarningPage(),
      ),
      AppFunctionItem(
        icon: Icons.add_location_alt,
        name: "机位管理",
        themeColor: Colors.orange,
        targetPage: const CameraPositionPage(),
      ),
      AppFunctionItem(
        icon: Icons.map,
        name: "铁路地图浏览",
        themeColor: Colors.teal,
        targetPage: const RailwayMapPage(),
      ),
      AppFunctionItem(
        icon: Icons.history,
        name: "历史查阅",
        themeColor: Colors.green,
        targetPage: const HistoryPage(),
      ),
      AppFunctionItem(
        icon: Icons.route,
        name: "行程",
        themeColor: Colors.purple,
        targetPage: const TripPage(),
      ),
      AppFunctionItem(
        icon: Icons.train,
        name: "列车数据查询",
        themeColor: const Color.fromARGB(255, 109, 22, 6),
        targetPage: const TrainSearchPage(),
      ),
      AppFunctionItem(
        icon: Icons.settings,
        name: "系统设置",
        themeColor: Colors.grey.shade700,
        targetPage: const SettingPage(),
      ),
    ].where((item) {
      // Windows 剔除预警器连接
      if(defaultTargetPlatform == TargetPlatform.windows){
        return item.name != "预警器连接" && item.name != "行程" && item.name != "系统设置" && item.name != "历史查阅";
      }
      return true;
    }).toList();

    // 确保监听器已注册后再检查（处理异步加载已完成的情况）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkInterruptedTrip();
    });
  }

  @override
  void dispose() {
    _bleService.removeListener(_refreshWarning);
    _settings.removeListener(_refreshWarning);
    _tripService.removeListener(_onTripServiceChanged);
    super.dispose();
  }

  void _refreshWarning() {
    if (mounted) setState(() {});
  }

  void _onTripServiceChanged() {
    if (!mounted) return;
    setState(() {});
    _checkInterruptedTrip();
  }

  void _checkInterruptedTrip() {
    if (_interruptedTripChecked) return;
    if (!_tripService.hasInterruptedTrip) return;
    _interruptedTripChecked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showInterruptedTripDialog();
    });
  }

  void _showInterruptedTripDialog() {
    final trip = _tripService.interruptedTrip;
    if (trip == null) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('发现未完成的行程'),
        content: Text(
          '上次行程「${trip.displayTitle}」未正常结束，'
          '已记录 ${trip.validPoints.length} 个有效轨迹点。\n\n'
          '是否继续记录、保存为历史或丢弃？',
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await _tripService.discardInterruptedTrip();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('丢弃'),
          ),
          TextButton(
            onPressed: () async {
              await _tripService.saveInterruptedTripAsHistory();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('保存为历史'),
          ),
          FilledButton(
            onPressed: () async {
              await _tripService.restoreInterruptedTrip();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('继续记录'),
          ),
        ],
      ),
    );
  }

  @override
Widget build(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return Scaffold(
    // appBar: AppBar(
    //   backgroundColor: scheme.inversePrimary,
    //   title: Text(widget.title),
    //   centerTitle: true,
    // ),
    body: SafeArea( // 新增：自动避开手机状态栏
      child: Padding(
        // 水平12，顶部12，底部12；想加大顶部就改成 top:24
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_settings.homeWarningEnabled && defaultTargetPlatform != TargetPlatform.windows) ...[
              buildWarningPanel(context, _bleService.warningTextList),
              const SizedBox(height: 20),
            ],
            Expanded(
              child: ListView.builder(
                itemCount: functionList.length,
                itemBuilder: (context, index) {
                  final item = functionList[index];
                  return ListTile(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (ctx) => item.targetPage),
                      );
                    },
                    leading: Icon(item.icon, color: item.themeColor, size: 26),
                    title: Text(
                      item.name,
                      style: TextStyle(
                        fontSize: 15,
                        color: item.themeColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    trailing: const Icon(
                      Icons.arrow_forward_ios,
                      size: 16,
                      color: Colors.black45,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    tileColor: item.themeColor.withValues(alpha: 0.06),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
}