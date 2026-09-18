import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:warningapplication_1/models/camera_position.dart' as cam_model;
import 'package:warningapplication_1/widgets/railway_vector_layer.dart';
import '../models/warning_history_record.dart';
import '../services/camera_position_service.dart';
import '../services/warning_history_service.dart';
import '../utils/map_config.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final WarningHistoryService _historyService = WarningHistoryService.instance;
  final TextEditingController _trainController = TextEditingController();
  final TextEditingController _locomotiveController = TextEditingController();

  DateTime? _selectedDate;
  TimeOfDay? _startTime;
  TimeOfDay? _endTime;

  bool _manageMode = false;
  final Set<String> _selectedForDeletion = {};

  @override
  void initState() {
    super.initState();
    _historyService.addListener(_refresh);
    _historyService.load();
    _trainController.addListener(_refresh);
    _locomotiveController.addListener(_refresh);
  }

  @override
  void dispose() {
    _historyService.removeListener(_refresh);
    _trainController.dispose();
    _locomotiveController.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final records = _filteredRecords();
    return Scaffold(
      appBar: AppBar(
        title: Text(_manageMode
            ? "已选 ${_selectedForDeletion.length} 项"
            : "历史预警记录"),
        actions: [
          if (!_manageMode && records.isNotEmpty)
            IconButton(
              tooltip: "批量管理",
              onPressed: () => setState(() => _manageMode = true),
              icon: const Icon(Icons.manage_history),
            ),
          if (!_manageMode && _historyService.records.isNotEmpty)
            IconButton(
              tooltip: "清空全部",
              onPressed: _confirmClearAll,
              icon: const Icon(Icons.delete_sweep),
            ),
          if (_manageMode)
            IconButton(
              tooltip: "退出管理",
              onPressed: _exitManageMode,
              icon: const Icon(Icons.close),
            ),
        ],
      ),
      bottomNavigationBar: _manageMode
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => setState(() {
                        if (_selectedForDeletion.length == records.length) {
                          _selectedForDeletion.clear();
                        } else {
                          _selectedForDeletion
                            ..clear()
                            ..addAll(records.map((r) => r.id));
                        }
                      }),
                      child: Text(
                        _selectedForDeletion.length == records.length
                            ? "取消全选"
                            : "全选",
                      ),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: _selectedForDeletion.isEmpty
                          ? null
                          : _confirmBatchDelete,
                      icon: const Icon(Icons.delete_outline),
                      label: Text(
                        "删除${_selectedForDeletion.isEmpty ? '' : '(${_selectedForDeletion.length})'}",
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: Column(
        children: [
          _buildSearchPanel(context),
          Expanded(
            child: records.isEmpty
                ? const Center(child: Text("暂无匹配的历史记录"))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    itemCount: records.length,
                    itemBuilder: (context, index) =>
                        _buildRecordCard(records[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchPanel(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.calendar_today, size: 18),
                    label: Text(
                      _selectedDate == null
                          ? "选择日期"
                          : _formatDate(_selectedDate!),
                    ),
                    onPressed: _pickDate,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: "清除日期",
                  onPressed: _selectedDate == null
                      ? null
                      : () {
                          setState(() {
                            _selectedDate = null;
                            _startTime = null;
                            _endTime = null;
                          });
                        },
                  icon: const Icon(Icons.clear),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _selectedDate == null
                        ? null
                        : () => _pickTime(isStart: true),
                    child: Text(
                      _startTime == null
                          ? "开始时间"
                          : _formatTimeOfDay(_startTime!),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _selectedDate == null
                        ? null
                        : () => _pickTime(isStart: false),
                    child: Text(
                      _endTime == null ? "结束时间" : _formatTimeOfDay(_endTime!),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _trainController,
              decoration: const InputDecoration(
                labelText: "按车次搜索",
                prefixIcon: Icon(Icons.train),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _locomotiveController,
              decoration: const InputDecoration(
                labelText: "按机车搜索",
                prefixIcon: Icon(Icons.directions_railway),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordCard(WarningHistoryRecord record) {
    final latest = record.latest;
    if (_manageMode) {
      final checked = _selectedForDeletion.contains(record.id);
      return Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: ListTile(
          leading: IconButton(
            icon: Icon(
              checked ? Icons.check_box : Icons.check_box_outline_blank,
              color: checked ? Theme.of(context).colorScheme.primary : null,
            ),
            onPressed: () => setState(() {
              if (checked) {
                _selectedForDeletion.remove(record.id);
              } else {
                _selectedForDeletion.add(record.id);
              }
            }),
          ),
          title: Text(
            "车次：${record.trainNo}",
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          subtitle: Text(
            "${_formatDateTime(record.startedAt)} 至 ${_formatDateTime(record.updatedAt)} · ${record.points.length} 个时刻",
            style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
          ),
          tileColor: Colors.transparent,
          onTap: () => setState(() {
            if (checked) {
              _selectedForDeletion.remove(record.id);
            } else {
              _selectedForDeletion.add(record.id);
            }
          }),
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: () => _openDetail(record),
        onLongPress: () {
          setState(() {
            _manageMode = true;
            _selectedForDeletion.add(record.id);
          });
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      "车次：${record.trainNo}",
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Colors.grey),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                "${_formatDateTime(record.startedAt)} 至 ${_formatDateTime(record.updatedAt)} · ${record.points.length} 个时刻",
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
              ),
              const SizedBox(height: 8),
              _buildSummary(latest),
            ],
          ),
        ),
      ),
    );
  }

  void _openDetail(WarningHistoryRecord record) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HistoryRecordDetailPage(record: record),
      ),
    );
  }

  void _exitManageMode() {
    setState(() {
      _manageMode = false;
      _selectedForDeletion.clear();
    });
  }

  Future<void> _confirmBatchDelete() async {
    if (_selectedForDeletion.isEmpty) return;
    final count = _selectedForDeletion.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("批量删除"),
        content: Text("确定删除选中的 $count 条历史记录？此操作不可撤销。"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("删除", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _historyService.deleteRecords(Set.from(_selectedForDeletion));
    if (!mounted) return;
    _exitManageMode();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("已删除 $count 条记录")),
    );
  }

  Future<void> _confirmClearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("清空全部历史"),
        content: const Text("确定清空所有历史预警记录？此操作不可撤销。"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("清空", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _historyService.clear();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("已清空全部历史记录")),
    );
  }

  Widget _buildSummary(WarningHistoryPoint point) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _chip("机车", point.locomotive),
        _chip("上下行", point.direction),
        _chip("线路", point.line),
        _chip("最新里程", point.mileage),
        _chip("强度", point.signalStrength),
      ],
    );
  }

  Widget _chip(String label, String value) {
    return Chip(
      label: Text("$label：$value"),
      visualDensity: VisualDensity.compact,
    );
  }

  List<WarningHistoryRecord> _filteredRecords() {
    final range = _selectedDate == null ? null : _buildDateRange();
    return _historyService.search(
      startAt: range?.$1,
      endAt: range?.$2,
      trainNo: _trainController.text,
      locomotive: _locomotiveController.text,
    );
  }

  (DateTime, DateTime) _buildDateRange() {
    final date = _selectedDate!;
    final start = _startTime == null
        ? DateTime(date.year, date.month, date.day)
        : DateTime(
            date.year,
            date.month,
            date.day,
            _startTime!.hour,
            _startTime!.minute,
          );
    final end = _endTime == null
        ? DateTime(date.year, date.month, date.day, 23, 59, 59, 999)
        : DateTime(
            date.year,
            date.month,
            date.day,
            _endTime!.hour,
            _endTime!.minute,
            59,
            999,
          );
    return (start, end);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      locale: const Locale('zh', 'CN'),
      initialDate: _selectedDate ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
    );
    if (picked == null) return;
    setState(() => _selectedDate = picked);
  }

  Future<void> _pickTime({required bool isStart}) async {
    final picked = await showTimePicker(
      context: context,
      helpText: isStart ? "选择开始时间" : "选择结束时间",
      cancelText: "取消",
      confirmText: "确定",
      hourLabelText: "小时",
      minuteLabelText: "分钟",
      initialTime: isStart
          ? (_startTime ?? const TimeOfDay(hour: 0, minute: 0))
          : (_endTime ?? const TimeOfDay(hour: 23, minute: 59)),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _startTime = picked;
      } else {
        _endTime = picked;
      }
    });
  }

  String _formatDate(DateTime value) => formatDate(value);
  String _formatDateTime(DateTime value) => formatDateTime(value);
  String _formatTimeOfDay(TimeOfDay value) =>
      '${_two(value.hour)}:${_two(value.minute)}';
  String _two(int value) => twoDigit(value);
}

String twoDigit(int value) => value.toString().padLeft(2, '0');

String formatDate(DateTime value) {
  return "${value.year}-${twoDigit(value.month)}-${twoDigit(value.day)}";
}

String formatDateTime(DateTime value) {
  return "${formatDate(value)} ${twoDigit(value.hour)}:${twoDigit(value.minute)}:${twoDigit(value.second)}";
}

/// 历史记录详情页：展示单条预警记录的地图动画和各时刻详情。
class HistoryRecordDetailPage extends StatefulWidget {
  final WarningHistoryRecord record;

  const HistoryRecordDetailPage({super.key, required this.record});

  @override
  State<HistoryRecordDetailPage> createState() =>
      _HistoryRecordDetailPageState();
}

class _HistoryRecordDetailPageState extends State<HistoryRecordDetailPage> {
  final MapController _mapController = MapController();

  late final List<WarningHistoryPoint> _validPoints;
  /// GCJ-02 坐标列表（已从 WGS-84 转换，用于地图显示）。
  late final List<LatLng> _validLatLngs;
  /// GCJ-02 动画路径点（动画播放时的已走过路径）。
  final List<LatLng> _animatedPathPoints = [];
  int _currentIndex = 0;
  Timer? _animationTimer;
  bool _isPlaying = false;
  bool _showAllPath = true;

  /// 当前地图上的线条（完整路径或动画路径）。
  List<Polyline> _polylines = [];
  /// 当前地图上的圆形标记列表。
  List<CircleMarker> _circles = [];

  static const double _defaultZoom = 14.0;

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
    _validPoints = _buildValidPoints();
    final wgs84Points =
        _validPoints.map(_parsePoint).whereType<LatLng>().toList();
    _validLatLngs = wgs84ListToGcj02(wgs84Points);
    if (_validLatLngs.isNotEmpty) {
      _animatedPathPoints.add(_validLatLngs.first);
    }
    _polylines = _buildPolylines();
    _circles = _buildCircles();

    // 在 initState 中创建一次 MapOptions，后续 build 复用同一实例。
    // initialCenter 使用默认北京坐标，实际位置由 post-frame callback 设置。
    _mapOptions = MapOptions(
      initialCenter: wgs84ToGcj02(39.9042, 116.4074),
      initialZoom: _defaultZoom,
      minZoom: 4.0,
      maxZoom: 14.0,
      interactionOptions: InteractionOptions(
        flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
      ),
    );

    // 地图就绪后将中心移动到当前路径点。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _moveCameraToCurrent();
    });
  }

  List<WarningHistoryPoint> _buildValidPoints() {
    return widget.record.points.where((p) {
      final lat = double.tryParse(p.latitude);
      final lon = double.tryParse(p.longitude);
      return lat != null &&
          lon != null &&
          lat >= -90 &&
          lat <= 90 &&
          lon >= -180 &&
          lon <= 180;
    }).toList();
  }

  cam_model.CameraPosition? get _cameraPosition {
    final cameraId = widget.record.points.firstOrNull?.cameraPositionId ?? '';
    if (cameraId.isEmpty) return null;
    for (final p in CameraPositionService.instance.positions) {
      if (p.id == cameraId) return p;
    }
    return null;
  }

  @override
  void dispose() {
    _animationTimer?.cancel();
    super.dispose();
  }

  /// 解析 WarningHistoryPoint 的字符串坐标为 WGS-84 LatLng。
  LatLng? _parsePoint(WarningHistoryPoint point) {
    final lat = double.tryParse(point.latitude);
    final lon = double.tryParse(point.longitude);
    if (lat == null || lon == null) return null;
    return LatLng(lat, lon);
  }

  // ---------------------------------------------------------------------------
  // Declarative annotation builders
  // ---------------------------------------------------------------------------

  /// 根据当前状态构建线条列表。
  List<Polyline> _buildPolylines() {
    if (_showAllPath && _validLatLngs.length > 1) {
      return [
        Polyline(
          points: _validLatLngs,
          color: const Color(0xFF0000FF),
          strokeWidth: 3.0,
        ),
      ];
    } else if (!_showAllPath && _animatedPathPoints.length > 1) {
      return [
        Polyline(
          points: _animatedPathPoints,
          color: const Color(0xFF0000FF),
          strokeWidth: 3.0,
        ),
      ];
    }
    return [];
  }

  /// 根据当前状态构建圆形标记列表。
  List<CircleMarker> _buildCircles() {
    final List<CircleMarker> circles = [];

    final currentPoint =
        _validLatLngs.isEmpty ? null : _validLatLngs[_currentIndex];

    // 当前车辆位置（红色）
    if (currentPoint != null) {
      circles.add(CircleMarker(
        point: currentPoint,
        radius: 8,
        color: const Color(0xFFFF0000),
        borderColor: Colors.white,
        borderStrokeWidth: 2,
        useRadiusInMeter: false,
      ));
    }

    // 机位位置（绿色）—— CameraPosition 模型坐标为 WGS-84，需转 GCJ-02
    final camera = _cameraPosition;
    if (camera != null) {
      final camGcj = wgs84ToGcj02(camera.latitude, camera.longitude);
      circles.add(CircleMarker(
        point: camGcj,
        radius: 8,
        color: const Color(0xFF4CAF50),
        borderColor: Colors.white,
        borderStrokeWidth: 2,
        useRadiusInMeter: false,
      ));
    }

    // 起点（蓝色）
    if (_validLatLngs.isNotEmpty) {
      circles.add(CircleMarker(
        point: _validLatLngs.first,
        radius: 6,
        color: const Color(0xFF0000FF),
        borderColor: Colors.white,
        borderStrokeWidth: 2,
        useRadiusInMeter: false,
      ));
    }

    // 终点（橙色）
    if (_validLatLngs.length > 1) {
      circles.add(CircleMarker(
        point: _validLatLngs.last,
        radius: 6,
        color: const Color(0xFFFF9800),
        borderColor: Colors.white,
        borderStrokeWidth: 2,
        useRadiusInMeter: false,
      ));
    }

    return circles;
  }

  /// 更新声明式注解列表并触发重建。
  void _updateAnnotations() {
    setState(() {
      _polylines = _buildPolylines();
      _circles = _buildCircles();
    });
  }

  /// 将地图相机移动到当前动画帧对应的坐标。
  void _moveCameraToCurrent() {
    if (_validLatLngs.isEmpty) return;
    final currentPoint = _validLatLngs[_currentIndex];
    _mapController.move(currentPoint, _mapController.camera.zoom);
  }

  // ---------------------------------------------------------------------------
  // Animation controls
  // ---------------------------------------------------------------------------

  void _startAnimation() {
    if (_validLatLngs.length < 2) return;
    _animationTimer?.cancel();
    setState(() {
      _isPlaying = true;
      _showAllPath = false;
      _currentIndex = 0;
      _animatedPathPoints
        ..clear()
        ..add(_validLatLngs.first);
    });
    _updateAnnotations();
    _advanceFrame();
  }

  void _advanceFrame() {
    if (_currentIndex >= _validLatLngs.length - 1) {
      setState(() => _isPlaying = false);
      return;
    }
    final current = _validPoints[_currentIndex];
    final next = _validPoints[_currentIndex + 1];
    final timeDiff = next.receivedAt.difference(current.receivedAt);
    // 10 倍速：真实时间差 / 10，但至少 200ms，最多 3s
    final durationMs =
        max(200, min(3000, timeDiff.inMilliseconds ~/ 10)).toInt();

    _animationTimer = Timer(Duration(milliseconds: durationMs), () {
      if (!mounted) return;
      setState(() {
        _currentIndex++;
        _animatedPathPoints.add(_validLatLngs[_currentIndex]);
      });
      _updateAnnotations();
      _moveCameraToCurrent();
      _advanceFrame();
    });
  }

  void _pauseAnimation() {
    _animationTimer?.cancel();
    setState(() => _isPlaying = false);
  }

  void _resetAnimation() {
    _animationTimer?.cancel();
    setState(() {
      _isPlaying = false;
      _currentIndex = 0;
      _showAllPath = true;
      _animatedPathPoints
        ..clear()
        ..addAll(_validLatLngs.isEmpty ? const [] : [_validLatLngs.first]);
    });
    if (_validLatLngs.isNotEmpty) {
      _moveCameraToCurrent();
    }
    _updateAnnotations();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final points = _validPoints;
    final hasMultiple = points.length > 1;

    return Scaffold(
      appBar: AppBar(title: Text("车次 ${widget.record.trainNo} 详情")),
      body: Column(
        children: [
          SizedBox(
            width: double.infinity,
            height: 280,
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
          if (hasMultiple)
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
                    "${_currentIndex + 1} / ${points.length}",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  Text(
                    "速度：10x",
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              itemCount: widget.record.points.length,
              itemBuilder: (context, index) {
                final point = widget.record.points[index];
                final isCurrent = index == _currentIndex && _isPlaying;
                return ListTile(
                  dense: true,
                  leading: isCurrent
                      ? const Icon(Icons.train, color: Colors.red)
                      : const Icon(Icons.access_time, color: Colors.grey),
                  title: Text(formatDateTime(point.receivedAt)),
                  subtitle: Text(
                    "强度：${point.signalStrength}  里程：${point.mileage}  线路：${point.line}\n"
                    "速度：${point.speed}  纬度：${point.latitude}  经度：${point.longitude}",
                  ),
                  tileColor: isCurrent
                      ? Colors.red.shade50
                      : Colors.transparent,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
