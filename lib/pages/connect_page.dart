import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/ble_warning_service.dart';

class ConnectWarningPage extends StatefulWidget {
  const ConnectWarningPage({super.key});

  @override
  State<ConnectWarningPage> createState() => _ConnectWarningPageState();
}

class _ConnectWarningPageState extends State<ConnectWarningPage> {
  final List<BluetoothDevice> _deviceList = [];
  final BleWarningService _bleService = BleWarningService.instance;
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<bool>? _isScanningSubscription;
  bool _isScanning = false;
  String? _savedDeviceId;
  String? _savedDeviceName;

  @override
  void initState() {
    super.initState();
    _bleService.addListener(_refresh);
    _loadSavedDevice();
    _listenScanningState();
  }

  @override
  void dispose() {
    _bleService.removeListener(_refresh);
    _scanResultsSubscription?.cancel();
    _isScanningSubscription?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  // 读取本地保存设备
  Future<void> _loadSavedDevice() async {
    final sp = await SharedPreferences.getInstance();
    setState(() {
      _savedDeviceId = sp.getString("ble_device_id");
      _savedDeviceName = sp.getString("ble_device_name");
    });
    if (_savedDeviceId != null) {
      final device = BluetoothDevice(remoteId: DeviceIdentifier(_savedDeviceId!));
      unawaited(_autoConnectDevice(device));
    }
  }

  // 保存设备
  Future<void> _saveDevice(BluetoothDevice device) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString("ble_device_id", device.remoteId.str);
    await sp.setString("ble_device_name", device.platformName.isNotEmpty ? device.platformName : "未知设备");
    setState(() {
      _savedDeviceId = device.remoteId.str;
      _savedDeviceName = device.platformName;
    });
  }

  // 清除保存设备
  Future<void> _clearSavedDevice() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove("ble_device_id");
    await sp.remove("ble_device_name");
    setState(() {
      _savedDeviceId = null;
      _savedDeviceName = null;
    });
  }

  // 监听扫描状态，避免按钮状态和实际扫描状态不同步
  void _listenScanningState() {
    _isScanningSubscription?.cancel();
    _isScanningSubscription = FlutterBluePlus.isScanning.listen((bool scanning) {
      if (mounted) setState(() => _isScanning = scanning);
    });
  }

  // 开始/停止扫描
  Future<void> _scanToggle() async {
    if (_isScanning) {
      await FlutterBluePlus.stopScan();
    } else {
      final ready = await _bleService.ensureBluetoothReady();
      if (!ready) {
        _showSnack(_bleService.statusText, isError: true);
        return;
      }

      if (_bleService.isTestMode) {
        _showSnack("BLE 测试模式运行中，示例数据每 5 秒推送一次");
        return;
      }

      _deviceList.clear();
      await _scanResultsSubscription?.cancel();
      _scanResultsSubscription = FlutterBluePlus.scanResults.listen((List<ScanResult> results) {
        for (var result in results) {
          final exists = _deviceList.any((device) => device.remoteId == result.device.remoteId);
          if (!exists) {
            setState(() => _deviceList.add(result.device));
          }
        }
      });
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    }
  }

  // 连接设备
  Future<void> _connectDevice(BluetoothDevice device) async {
    try {
      final ready = await _bleService.ensureBluetoothReady();
      if (!ready) {
        _showSnack(_bleService.statusText, isError: true);
        return;
      }

      await FlutterBluePlus.stopScan();
      await _bleService.connectAndSubscribe(device);
      await _saveDevice(device);
      _showSnack("已连接设备：${_deviceName(device)}");
    } catch (e) {
      _showSnack("连接失败：$e", isError: true);
    }
  }

  // 自动重连
  Future<void> _autoConnectDevice(BluetoothDevice device) async {
    if (_bleService.isConnected) return;
    try {
      final ready = await _bleService.ensureBluetoothReady();
      if (!ready) return;
      await _bleService.connectAndSubscribe(device);
    } catch (_) {}
  }

  // 断开连接
  Future<void> _disconnectDevice() async {
    await _bleService.disconnect();
    _showSnack("已断开蓝牙连接");
  }

  String _deviceName(BluetoothDevice device) {
    return device.platformName.isNotEmpty ? device.platformName : device.remoteId.str;
  }

  void _showSnack(String text, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: isError ? Colors.red : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connectedDevice = _bleService.connectedDevice;
    return Scaffold(
      appBar: AppBar(title: const Text("预警器蓝牙连接")),
      body: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 连接状态卡片
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: connectedDevice != null
                    ? Colors.green.withValues(alpha: 0.1)
                    : Colors.grey.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: connectedDevice != null ? Colors.green : Colors.grey),
              ),
              child: Column(
                children: [
                  Text(
                    connectedDevice != null
                        ? "✅ 当前已连接：${_deviceName(connectedDevice)}"
                        : "❌ 当前无蓝牙设备连接",
                    style: TextStyle(
                      fontSize: 15,
                      color: connectedDevice != null ? Colors.green : Colors.grey,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _bleService.statusText,
                    style: TextStyle(
                      fontSize: 12,
                      color: connectedDevice != null ? Colors.green.shade700 : Colors.grey.shade700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton(
                        onPressed: connectedDevice != null ? _disconnectDevice : null,
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                        child: const Text("断开连接"),
                      ),
                      const SizedBox(width: 10),
                      ElevatedButton(
                        onPressed: _clearSavedDevice,
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                        child: const Text("清除记住设备"),
                      ),
                    ],
                  )
                ],
              ),
            ),

            const SizedBox(height: 16),

            // 扫描按钮
            SizedBox(
              height: 46,
              child: ElevatedButton(
                onPressed: _scanToggle,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isScanning ? Colors.blueGrey : Colors.blue,
                ),
                child: Text(_isScanning ? "正在扫描蓝牙..." : "扫描附近BLE设备"),
              ),
            ),

            const SizedBox(height: 12),

            // 已记住设备提示
            if (_savedDeviceName != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  "已记住设备：$_savedDeviceName，打开页面自动尝试重连",
                  style: TextStyle(color: Colors.blueAccent.withValues(alpha: 1), fontSize: 13),
                ),
              ),

            // 设备列表
            Expanded(
              child: _deviceList.isEmpty
                  ? const Center(child: Text("暂无扫描到蓝牙设备，请点击扫描"))
                  : ListView.builder(
                      itemCount: _deviceList.length,
                      itemBuilder: (ctx, index) {
                        BluetoothDevice dev = _deviceList[index];
                        bool isCurrConnect = connectedDevice?.remoteId == dev.remoteId;
                        return ListTile(
                          title: Text(dev.platformName.isNotEmpty ? dev.platformName : "无名设备"),
                          subtitle: Text(dev.remoteId.str),
                          trailing: isCurrConnect ? const Icon(Icons.check, color: Colors.green) : null,
                          onTap: () => _connectDevice(dev),
                          tileColor: isCurrConnect ? Colors.green.withValues(alpha: 0.08) : Colors.transparent,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        );
                      },
                    ),
            )
          ],
        ),
      ),
    );
  }
}
