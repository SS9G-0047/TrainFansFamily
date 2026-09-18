import 'package:flutter/material.dart';

import '../models/trip_record.dart';
import '../services/trip_service.dart';
import 'trip_detail_page.dart';

class TripHistoryPage extends StatefulWidget {
  const TripHistoryPage({super.key});

  @override
  State<TripHistoryPage> createState() => _TripHistoryPageState();
}

class _TripHistoryPageState extends State<TripHistoryPage> {
  final TripService _tripService = TripService.instance;

  @override
  void initState() {
    super.initState();
    _tripService.addListener(_refresh);
  }

  @override
  void dispose() {
    _tripService.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final history = _tripService.history;

    return Scaffold(
      appBar: AppBar(
        title: const Text("历史行程"),
        actions: [
          if (history.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: "清空全部",
              onPressed: () => _confirmClearAll(context),
            ),
        ],
      ),
      body: history.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text("暂无历史行程", style: TextStyle(color: Colors.grey)),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: history.length,
              itemBuilder: (context, index) {
                final record = history[index];
                return _buildHistoryCard(record);
              },
            ),
    );
  }

  Widget _buildHistoryCard(TripRecord record) {
    final duration = record.duration;
    final durationStr =
        "${duration.inHours.toString().padLeft(2, '0')}:"
        "${(duration.inMinutes % 60).toString().padLeft(2, '0')}:"
        "${(duration.inSeconds % 60).toString().padLeft(2, '0')}";

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TripDetailPage(record: record),
            ),
          );
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _tripTypeIcon(record.tripType),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          record.displayTitle,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
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
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => _confirmDelete(context, record),
                  ),
                  const Icon(Icons.chevron_right, color: Colors.grey),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _formatDateTime(record.startedAt),
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _miniStat("均速", record.averageSpeed.toStringAsFixed(1)),
                  _miniStat("最高", record.maxSpeed.toStringAsFixed(0)),
                  _miniStat("里程", record.totalDistance.toStringAsFixed(2)),
                  _miniStat("时长", durationStr),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tripTypeIcon(TripType type) {
    final icon = switch (type) {
      TripType.walking => Icons.directions_walk,
      TripType.cycling => Icons.directions_bike,
      TripType.car => Icons.directions_car,
      TripType.train => Icons.train,
      TripType.airplane => Icons.flight,
    };
    return Icon(icon, color: Colors.blue, size: 28);
  }

  Widget _miniStat(String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          Text(
            value,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, TripRecord record) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("删除行程"),
        content: Text("确定删除「${record.displayTitle}」？"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("取消")),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("删除", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _tripService.deleteRecord(record.id);
    }
  }

  Future<void> _confirmClearAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("清空全部历史"),
        content: const Text("确定清空所有历史行程记录？此操作不可撤销。"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("取消")),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("清空", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _tripService.clearHistory();
    }
  }

  String _formatDateTime(DateTime value) {
    return "${value.year}-${_two(value.month)}-${_two(value.day)} "
        "${_two(value.hour)}:${_two(value.minute)}:${_two(value.second)}";
  }

  String _two(int value) => value.toString().padLeft(2, '0');
}
