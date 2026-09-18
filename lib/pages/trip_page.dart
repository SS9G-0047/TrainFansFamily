import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:warningapplication_1/widgets/railway_vector_layer.dart';

import '../models/trip_record.dart';
import '../services/trip_service.dart';
import '../utils/map_config.dart';
import 'trip_history_page.dart';

class TripPage extends StatefulWidget {
  const TripPage({super.key});

  @override
  State<TripPage> createState() => _TripPageState();
}

class _TripPageState extends State<TripPage> {
  final TripService _tripService = TripService.instance;
  final MapController _mapController = MapController();

  /// 自动跟随当前位置。
  bool _autoFollow = true;

  /// 上次居中定位的轨迹点时间戳，避免 tick 刷新时重复 move。
  DateTime? _lastCenteredTime;

  /// 当前路径线列表。
  final List<Polyline> _polylines = [];

  /// 当前标记圆点列表。
  final List<CircleMarker> _circles = [];

  /// 防止注记更新重入。
  bool _isUpdating = false;

  /// 缓存的 MapOptions — 避免每次 build 创建新实例。
  ///
  /// FlutterMap.didUpdateWidget 检测到 MapOptions 变化（按引用比较）后
  /// 会调用 MapControllerImpl.options setter，创建新的 _MapControllerState
  /// 并触发 notifyListeners()。GPS 每秒更新一次时，这会导致 FlutterMap
  /// 及所有子 Widget（含 VectorTileLayer / TileLayer）频繁全量 rebuild，
  /// 干扰 tile loading 流程，新区域瓦片无法正确加载。
  /// initialCenter 只在首次渲染时使用，后续 camera 位置由 MapController
  /// 管理，不会受 initialCenter 影响。
  late final MapOptions _mapOptions;

  @override
  void initState() {
    super.initState();
    _tripService.addListener(_refresh);

    // 在 initState 中创建一次 MapOptions，后续 build 复用同一实例。
    // initialCenter 使用默认北京坐标，实际位置由 _centerOnLatest() 设置。
    _mapOptions = MapOptions(
      initialCenter: wgs84ToGcj02(39.9042, 116.4074),
      initialZoom: 15.0,
      minZoom: 4.0,
      maxZoom: 14.0,
      interactionOptions: InteractionOptions(
        flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
      ),
      onPositionChanged: (position, hasGesture) {
        if (hasGesture && _autoFollow) {
          // 只在 _autoFollow 从 true→false 时 setState，避免每次拖动都触发
          // 全量 rebuild 干扰 tile loading。
          setState(() => _autoFollow = false);
        }
      },
    );
  }

  @override
  void dispose() {
    _tripService.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    if (!_tripService.isActive) {
      _polylines.clear();
      _circles.clear();
      _autoFollow = true;
      _lastCenteredTime = null;
    }
    setState(() {});
    if (_tripService.isActive) {
      _updateAnnotations();
      if (_autoFollow && _tripService.isRecording) {
        _centerOnLatest();
      }
    }
  }

  /// 将地图居中到最新有效 GPS 轨迹点（跳过被剔除的点）。
  void _centerOnLatest() {
    final last = _tripService.currentRecord.latestValid;
    if (last == null || !last.hasValidLocation) return;
    if (_lastCenteredTime == last.timestamp) return;
    _lastCenteredTime = last.timestamp;

    final target = wgs84ToGcj02(last.latitude, last.longitude);
    final zoom = _mapController.camera.zoom;
    _mapController.move(target, zoom < 15 ? 15 : zoom);
  }

  /// 更新地图上的路径线和标记圆点。
  ///
  /// 所有坐标从 WGS-84 转换为 GCJ-02。
  void _updateAnnotations() {
    if (_isUpdating) return;
    _isUpdating = true;
    try {
      final record = _tripService.currentRecord;
      final validPoints = record.validPoints;

      _polylines.clear();
      _circles.clear();

      // 添加路径线（WGS-84 -> GCJ-02）
      if (validPoints.length > 1) {
        final wgsPoints = validPoints
            .map((p) => LatLng(p.latitude, p.longitude))
            .toList();
        final gcjPoints = wgs84ListToGcj02(wgsPoints);
        _polylines.add(Polyline(
          points: gcjPoints,
          color: const Color(0xFF0000FF),
          strokeWidth: 4,
        ));
      }

      // 添加当前点标记（红色）
      if (validPoints.isNotEmpty) {
        final current = wgs84ToGcj02(
          validPoints.last.latitude,
          validPoints.last.longitude,
        );
        _circles.add(CircleMarker(
          point: current,
          radius: 8,
          color: const Color(0xFFFF0000),
          borderColor: Colors.white,
          borderStrokeWidth: 2,
          useRadiusInMeter: false,
        ));
      }

      // 添加起点标记（蓝色）
      if (validPoints.isNotEmpty) {
        final start = wgs84ToGcj02(
          validPoints.first.latitude,
          validPoints.first.longitude,
        );
        _circles.add(CircleMarker(
          point: start,
          radius: 6,
          color: const Color(0xFF0000FF),
          borderColor: Colors.white,
          borderStrokeWidth: 2,
          useRadiusInMeter: false,
        ));
      }

      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('更新地图注记失败: $e');
    } finally {
      _isUpdating = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final record = _tripService.currentRecord;
    final isActive = _tripService.isActive;

    return Scaffold(
      appBar: AppBar(
        title: const Text("行程"),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: "历史行程",
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const TripHistoryPage(),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildRecordPanel(context, record, isActive, scheme),
          if (isActive)
            Expanded(child: _buildRealtimeMap(record))
          else
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _tripTypeIcon(_tripService.tripType),
                      size: 72,
                      color: Colors.grey.shade400,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      "点击下方按钮开始新行程",
                      style: TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: !isActive
          ? FloatingActionButton.extended(
              onPressed: _showTripSettingsDialog,
              icon: const Icon(Icons.play_arrow),
              label: const Text("开始行程"),
            )
          : null,
    );
  }

  // —— 行程设置对话框 ——

  void _showTripSettingsDialog() {
    TripType selectedType = TripType.train;
    final nameController = TextEditingController();
    final idController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text("设置行程"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 行程类型选择
                DropdownButtonFormField<TripType>(
                  initialValue: selectedType,
                  decoration: const InputDecoration(
                    labelText: "行程类型",
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: TripType.values.map((t) {
                    return DropdownMenuItem(
                      value: t,
                      child: Row(
                        children: [
                          Icon(_tripTypeIcon(t), size: 20),
                          const SizedBox(width: 8),
                          Text(t.label),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (v) {
                    if (v != null) {
                      setDialogState(() {
                        selectedType = v;
                        idController.clear();
                      });
                    }
                  },
                ),
                const SizedBox(height: 12),
                // 行程名称
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: "行程名称（可选）",
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                if (selectedType.hasIdentifier) ...[
                  const SizedBox(height: 12),
                  // 标识符（车次/线路号/航班号）
                  TextField(
                    controller: idController,
                    decoration: InputDecoration(
                      labelText: selectedType.idLabel,
                      border: const OutlineInputBorder(),
                      isDense: true,
                      hintText: selectedType.idHint,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("取消"),
            ),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _autoFollow = true;
                _lastCenteredTime = null;
                _tripService.startTrip(
                  tripType: selectedType,
                  tripName: nameController.text,
                  identifier: idController.text,
                );
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text("开始"),
            ),
          ],
        ),
      ),
    );
  }

  IconData _tripTypeIcon(TripType type) {
    return switch (type) {
      TripType.walking => Icons.directions_walk,
      TripType.cycling => Icons.directions_bike,
      TripType.car => Icons.directions_car,
      TripType.train => Icons.train,
      TripType.airplane => Icons.flight,
    };
  }

  // —— 记录面板 ——

  Widget _buildRecordPanel(
    BuildContext context,
    TripRecord record,
    bool isActive,
    ColorScheme scheme,
  ) {
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 行程信息行
            if (isActive) _buildTripInfoRow(record),
            if (isActive) const SizedBox(height: 12),
            // 当前速度大显示
            _buildSpeedDisplay(record, scheme),
            const SizedBox(height: 12),
            // 统计网格
            _buildStatsGrid(record),
            if (isActive) ...[
              const SizedBox(height: 16),
              // 控制按钮
              _buildControls(isActive),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTripInfoRow(TripRecord record) {
    return Row(
      children: [
        Icon(_tripTypeIcon(record.tripType), size: 20, color: Colors.blue),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            record.displayTitle,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (record.identifier.isNotEmpty)
          Text(
            "${record.tripType.idLabel}：${record.identifier}",
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade600,
            ),
          ),
      ],
    );
  }

  Widget _buildSpeedDisplay(TripRecord record, ColorScheme scheme) {
    final speed = record.currentSpeed;
    final color = _tripService.isRecording
        ? Colors.blue
        : _tripService.isPaused
            ? Colors.orange
            : scheme.outline;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          speed.toStringAsFixed(0),
          style: TextStyle(
            fontSize: 56,
            fontWeight: FontWeight.bold,
            color: color,
            height: 1,
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(bottom: 8, left: 4),
          child: Text("km/h", style: TextStyle(fontSize: 14, color: Colors.grey)),
        ),
      ],
    );
  }

  Widget _buildStatsGrid(TripRecord record) {
    final duration = record.duration;
    final durationStr =
        "${duration.inHours.toString().padLeft(2, '0')}:"
        "${(duration.inMinutes % 60).toString().padLeft(2, '0')}:"
        "${(duration.inSeconds % 60).toString().padLeft(2, '0')}";

    return Row(
      children: [
        Expanded(
          child: _statCard("均速", record.averageSpeed.toStringAsFixed(1), "km/h"),
        ),
        Expanded(
          child: _statCard("最高", record.maxSpeed.toStringAsFixed(0), "km/h"),
        ),
        Expanded(
          child: _statCard("里程", record.totalDistance.toStringAsFixed(2), "km"),
        ),
        Expanded(
          child: _statCard("时长", durationStr, ""),
        ),
      ],
    );
  }

  Widget _statCard(String label, String value, String unit) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (unit.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Text(
                  unit,
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildControls(bool isActive) {
    return Row(
      children: [
        if (_tripService.isRecording)
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _tripService.pauseTrip,
              icon: const Icon(Icons.pause),
              label: const Text("暂停"),
            ),
          )
        else
          Expanded(
            child: FilledButton.icon(
              onPressed: _tripService.resumeTrip,
              icon: const Icon(Icons.play_arrow),
              label: const Text("继续"),
            ),
          ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.icon(
            onPressed: () async {
              await _tripService.stopTrip();
            },
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            icon: const Icon(Icons.stop),
            label: const Text("结束"),
          ),
        ),
      ],
    );
  }

  // —— 实时地图 ——

  Widget _buildRealtimeMap(TripRecord record) {
    final validPoints = record.validPoints;
    final hasPoints = validPoints.isNotEmpty;

    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: FlutterMap(
                mapController: _mapController,
                options: _mapOptions,
                children: [
                  TileLayer(
                    urlTemplate: amapTileUrlTemplate,
                    subdomains: amapSubdomains,
                    maxZoom: 18,
                    maxNativeZoom: 18,
                    tileBuilder: (context, tile, tileImage) => ColorFiltered(
                      colorFilter: const ColorFilter.matrix(amapGrayscaleMatrix),
                      child: tile,
                    ),
                  ),
                  RailwayVectorLayer(),
                  PolylineLayer(polylines: _polylines),
                  CircleLayer(circles: _circles),
                ],
              ),
            ),
          ),
        ),
        const MapAttribution(),
        // 定位/跟随按钮
        Positioned(
          right: 24,
          bottom: 24,
          child: FloatingActionButton.small(
            heroTag: 'trip_recenter',
            onPressed: () {
              setState(() => _autoFollow = true);
              _centerOnLatest();
            },
            child: Icon(
              _autoFollow ? Icons.my_location : Icons.location_searching,
            ),
          ),
        ),
        // 等待 GPS 定位提示
        if (!hasPoints)
          Positioned.fill(
            child: Center(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _tripService.isRecording
                            ? "等待GPS定位..."
                            : "已暂停",
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
