import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:warningapplication_1/widgets/railway_vector_layer.dart';

import '../models/trip_record.dart';
import '../utils/map_config.dart';

class TripDetailPage extends StatefulWidget {
  final TripRecord record;

  const TripDetailPage({super.key, required this.record});

  @override
  State<TripDetailPage> createState() => _TripDetailPageState();
}

class _TripDetailPageState extends State<TripDetailPage> {
  final MapController _mapController = MapController();

  late final List<TripPoint> _validPoints;
  late final List<LatLng> _path;
  late final LatLng _defaultCenter;
  final List<LatLng> _animatedPath = [];
  int _currentIndex = 0;
  Timer? _timer;
  bool _isPlaying = false;
  bool _showAllPath = true;

  /// 当前路径线注记列表。
  final List<Polyline> _polylines = [];

  /// 当前标记圆点列表。
  final List<CircleMarker> _circles = [];

  /// 缓存的 MapOptions — 避免每次 build 创建新实例。
  ///
  /// FlutterMap.didUpdateWidget 检测到 MapOptions 变化（按引用比较）后
  /// 会调用 MapControllerImpl.options setter，创建新的 _MapControllerState
  /// 并触发 notifyListeners()，导致 FlutterMap 及所有子 Widget（含
  /// VectorTileLayer / TileLayer）全量 rebuild，干扰 tile loading 流程。
  /// initialCenter 只在首次渲染时使用，后续 camera 位置由 MapController
  /// 管理，不会受 initialCenter 影响。
  late final MapOptions _mapOptions;

  @override
  void initState() {
    super.initState();
    _validPoints = widget.record.validPoints;
    // 将 WGS-84 坐标转换为 GCJ-02（高德瓦片坐标系）
    _path = wgs84ListToGcj02(
      _validPoints.map((p) => LatLng(p.latitude, p.longitude)).toList(),
    );
    _defaultCenter = wgs84ToGcj02(39.9042, 116.4074);
    if (_path.isNotEmpty) _animatedPath.add(_path.first);
    _rebuildAnnotations();

    // 在 initState 中创建一次 MapOptions，后续 build 复用同一实例。
    // initialCenter 使用默认北京坐标，实际位置由 post-frame callback 设置。
    _mapOptions = MapOptions(
      initialCenter: _defaultCenter,
      initialZoom: 14.0,
      minZoom: 4.0,
      maxZoom: 14.0,
      interactionOptions: InteractionOptions(
        flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
      ),
    );

    // 地图就绪后将中心移动到当前路径点。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _path.isEmpty) return;
      final point = _showAllPath ? _path.last : _path[_currentIndex];
      _mapController.move(point, 14.0);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startAnimation() {
    if (_path.length < 2) return;
    _timer?.cancel();
    setState(() {
      _isPlaying = true;
      _showAllPath = false;
      _currentIndex = 0;
      _animatedPath
        ..clear()
        ..add(_path.first);
    });
    _updateAnnotations();
    _advance();
  }

  void _advance() {
    if (_currentIndex >= _path.length - 1) {
      setState(() => _isPlaying = false);
      return;
    }
    final current = _validPoints[_currentIndex];
    final next = _validPoints[_currentIndex + 1];
    final diff = next.timestamp.difference(current.timestamp);
    final ms = max(200, min(3000, diff.inMilliseconds ~/ 10));

    _timer = Timer(Duration(milliseconds: ms), () {
      if (!mounted) return;
      setState(() {
        _currentIndex++;
        _animatedPath.add(_path[_currentIndex]);
      });
      _updateAnnotations();
      _moveToPath(_currentIndex);
      _advance();
    });
  }

  void _pauseAnimation() {
    _timer?.cancel();
    setState(() => _isPlaying = false);
  }

  void _resetAnimation() {
    _timer?.cancel();
    setState(() {
      _isPlaying = false;
      _currentIndex = 0;
      _showAllPath = true;
      _animatedPath
        ..clear()
        ..addAll(_path.isEmpty ? const [] : [_path.first]);
    });
    _updateAnnotations();
    if (_path.isNotEmpty) {
      _moveToPath(0);
    }
  }

  /// 将相机移动到路径中指定索引的点。
  void _moveToPath(int index) {
    if (index < 0 || index >= _path.length) return;
    _mapController.move(_path[index], _mapController.camera.zoom);
  }

  /// 根据 _showAllPath 和 _currentIndex 重建注记列表（不触发重建）。
  void _rebuildAnnotations() {
    _polylines.clear();
    _circles.clear();

    // 添加路径线
    final List<LatLng> linePoints;
    if (_showAllPath) {
      linePoints = _path;
    } else {
      linePoints = _animatedPath;
    }
    if (linePoints.length > 1) {
      _polylines.add(
        Polyline(
          points: linePoints,
          color: const Color(0xFF0000FF),
          strokeWidth: 3,
        ),
      );
    }

    // 确定当前点
    final LatLng? currentPoint;
    if (_path.isEmpty) {
      currentPoint = null;
    } else if (_showAllPath) {
      currentPoint = _path.last;
    } else {
      currentPoint = _path[_currentIndex];
    }

    // 添加当前点标记（红色）
    if (currentPoint != null) {
      _circles.add(
        CircleMarker(
          point: currentPoint,
          radius: 8,
          color: const Color(0xFFFF0000),
          borderColor: Colors.white,
          borderStrokeWidth: 2,
          useRadiusInMeter: false,
        ),
      );
    }

    // 添加起点标记（蓝色）
    if (_path.isNotEmpty) {
      _circles.add(
        CircleMarker(
          point: _path.first,
          radius: 6,
          color: const Color(0xFF0000FF),
          borderColor: Colors.white,
          borderStrokeWidth: 2,
          useRadiusInMeter: false,
        ),
      );
    }

    // 添加终点标记（橙色）
    if (_path.length > 1) {
      _circles.add(
        CircleMarker(
          point: _path.last,
          radius: 6,
          color: const Color(0xFFFF9800),
          borderColor: Colors.white,
          borderStrokeWidth: 2,
          useRadiusInMeter: false,
        ),
      );
    }
  }

  /// 更新地图上的路径线和标记圆点。
  ///
  /// 根据 _showAllPath 决定显示完整路径或动画路径，
  /// 根据 _currentIndex 决定当前点标记位置。
  void _updateAnnotations() {
    _rebuildAnnotations();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final duration = record.duration;
    final durationStr =
        "${duration.inHours.toString().padLeft(2, '0')}:"
        "${(duration.inMinutes % 60).toString().padLeft(2, '0')}:"
        "${(duration.inSeconds % 60).toString().padLeft(2, '0')}";

    return Scaffold(
      appBar: AppBar(
        title: Text(record.displayTitle),
      ),
      body: Column(
        children: [
          // 行程信息卡片
          Card(
            margin: const EdgeInsets.all(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(_tripTypeIcon(record.tripType),
                          color: Colors.blue, size: 28),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              record.displayTitle,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              "${record.tripType.label}"
                              "${record.identifier.isNotEmpty ? ' · ${record.tripType.idLabel}：${record.identifier}' : ''}",
                              style: TextStyle(
                                color: Colors.grey.shade600,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 16),
                  Row(
                    children: [
                      _statItem("均速", record.averageSpeed.toStringAsFixed(1), "km/h"),
                      _statItem("最高", record.maxSpeed.toStringAsFixed(0), "km/h"),
                      _statItem("里程", record.totalDistance.toStringAsFixed(2), "km"),
                      _statItem("时长", durationStr, ""),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // 地图
          SizedBox(
            width: double.infinity,
            height: 300,
            child: Stack(
              children: [
                FlutterMap(
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
                    CircleLayer(circles: _circles),
                    PolylineLayer(polylines: _polylines),
                  ],
                ),
                const MapAttribution(),
              ],
            ),
          ),
          if (_path.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _isPlaying ? _pauseAnimation : _startAnimation,
                    icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                  ),
                  IconButton(
                    onPressed: _resetAnimation,
                    icon: const Icon(Icons.replay),
                  ),
                  Text(
                    "${_currentIndex + 1} / ${_path.length}",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  Text(
                    "速度：10x",
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                ],
              ),
            ),
          // 轨迹点列表
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              itemCount: widget.record.points.length,
              itemBuilder: (context, index) {
                final p = widget.record.points[index];
                final isCurrent = index == _currentIndex && !_showAllPath;
                return ListTile(
                  dense: true,
                  leading: isCurrent
                      ? Icon(_tripTypeIcon(widget.record.tripType), color: Colors.red)
                      : p.rejected
                          ? const Icon(Icons.warning_amber, color: Colors.orange, size: 20)
                          : const Icon(Icons.access_time, color: Colors.grey),
                  title: Text(
                    _formatDateTime(p.timestamp),
                    style: p.rejected
                        ? TextStyle(color: Colors.grey.shade400, decoration: TextDecoration.lineThrough)
                        : null,
                  ),
                  subtitle: Text(
                    "速度：${p.speed.toStringAsFixed(0)}km/h  里程：${p.mileage.isEmpty ? '--' : p.mileage}\n"
                    "纬度：${p.latitude}  经度：${p.longitude}${p.rejected ? '  [已剔除]' : ''}",
                    style: p.rejected ? TextStyle(color: Colors.grey.shade400) : null,
                  ),
                  tileColor: isCurrent ? Colors.red.shade50 : Colors.transparent,
                );
              },
            ),
          ),
        ],
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

  Widget _statItem(String label, String value, String unit) {
    return Expanded(
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 16,
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
      ),
    );
  }

  String _formatDateTime(DateTime value) {
    return "${value.year}-${_two(value.month)}-${_two(value.day)} "
        "${_two(value.hour)}:${_two(value.minute)}:${_two(value.second)}";
  }

  String _two(int value) => value.toString().padLeft(2, '0');
}
