import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:warningapplication_1/utils/map_config.dart';
import 'package:warningapplication_1/widgets/maplibre_map.dart';

import '../models/camera_position.dart' as cam_model;
import '../services/camera_position_service.dart';
import '../services/native_image_service.dart';
import '../services/native_location_service.dart';
import 'native_image_picker_page.dart';
import '../utils/cross_file_image.dart';
import 'package:coordtransform/coordtransform.dart';

class CameraPositionPage extends StatefulWidget {
  const CameraPositionPage({super.key});

  @override
  State<CameraPositionPage> createState() => _CameraPositionPageState();
}

class _CameraPositionPageState extends State<CameraPositionPage> {
  final CameraPositionService _service = CameraPositionService.instance;
  final Set<String> _expandedTreeGroupIds = {};
  final Set<String> _selectedForDeletion = {};
  bool _treeExpansionInitialized = false;
  bool _manageMode = false;

  @override
  void initState() {
    super.initState();
    _service.addListener(_refresh);
    _service.load();
  }

  @override
  void dispose() {
    _service.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _toggleManageMode() {
    setState(() {
      _manageMode = !_manageMode;
      if (!_manageMode) _selectedForDeletion.clear();
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedForDeletion.isEmpty) return;
    final count = _selectedForDeletion.length;
    for (final id in _selectedForDeletion.toList()) {
      await _service.deletePosition(id);
    }
    if (!mounted) return;
    _selectedForDeletion.clear();
    setState(() => _manageMode = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text("已删除 $count 个机位")));
  }

  @override
  Widget build(BuildContext context) {
    final rootGroups = _service.childGroupsOf('');
    final ungroupedPositions = _service.ungroupedPositions;
    if (!_treeExpansionInitialized) {
      for (final group in rootGroups) {
        _expandedTreeGroupIds.add(group.id);
      }
      _treeExpansionInitialized = true;
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_manageMode
            ? "已选 ${_selectedForDeletion.length} 项"
            : "机位管理"),
        actions: [
          IconButton(
            tooltip: _manageMode ? "退出管理" : "管理",
            onPressed: _toggleManageMode,
            icon: Icon(_manageMode ? Icons.close : Icons.manage_history),
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
                      onPressed: () => setState(_selectedForDeletion.clear),
                      child: Text(
                        _selectedForDeletion.length ==
                                _service.positions.length
                            ? "取消全选"
                            : "全选",
                      ),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: _selectedForDeletion.isEmpty
                          ? null
                          : _deleteSelected,
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
      body: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _buildNoPositionRow(),
                _buildRootDropTarget(setState),
                if (_service.positions.isEmpty && _service.groups.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.touch_app, size: 48, color: Colors.grey),
                          const SizedBox(height: 12),
                          const Text("暂无机位"),
                          const SizedBox(height: 8),
                          const Text(
                            '长按上方「根目录」可添加机位或地区组',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ),
                ...rootGroups.map(
                  (group) => _buildPositionTreeNode(
                    group,
                    0,
                    _expandedTreeGroupIds,
                    setState,
                  ),
                ),
                if (ungroupedPositions.isNotEmpty)
                  _buildUngroupedPositionTree(setState),
              ],
            ),
    );
  }

  Widget _buildPositionTile(cam_model.CameraPosition item) {
    if (_manageMode) {
      final checked = _selectedForDeletion.contains(item.id);
      return ListTile(
        leading: IconButton(
          icon: Icon(
            checked ? Icons.check_box : Icons.check_box_outline_blank,
            color: checked ? Theme.of(context).colorScheme.primary : null,
          ),
          onPressed: () => setState(() {
            if (checked) {
              _selectedForDeletion.remove(item.id);
            } else {
              _selectedForDeletion.add(item.id);
            }
          }),
        ),
        title: Text(item.name),
        subtitle: Text(_formatLineSubtitle(item)),
        tileColor: Colors.transparent,
        onTap: () => setState(() {
          if (checked) {
            _selectedForDeletion.remove(item.id);
          } else {
            _selectedForDeletion.add(item.id);
          }
        }),
      );
    }
    return ListTile(
      title: Text(item.name),
      subtitle: Text(_formatLineSubtitle(item)),
      tileColor: Colors.transparent,
      onTap: () => _openDetail(item),
    );
  }

  Widget _buildNoPositionRow() {
    final noPosition = _service.currentPositionId == null;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        dense: true,
        leading: Icon(
          noPosition ? Icons.check_circle : Icons.circle_outlined,
          color: noPosition ? Colors.green : Colors.grey,
        ),
        title: const Text("不选择机位"),
        subtitle: const Text("预警不受机位限制"),
        onTap: () => _service.setCurrentPosition(null),
      ),
    );
  }

  Widget _buildRootDropTarget(void Function(void Function()) setSheetState) {
    return DragTarget<_GroupManagerDragData>(
      onWillAcceptWithDetails: (details) => _canDropToGroup(details.data, ''),
      onAcceptWithDetails: (details) async {
        await _moveDraggedItem(details.data, '');
        setSheetState(() {});
      },
      builder: (context, candidateData, rejectedData) {
        final active = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: active
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: ListTile(
              dense: true,
              onLongPress: () => _showGroupContextMenu(context, null),
              leading: const Icon(Icons.account_tree_outlined),
              title: const Text("根目录"),
              subtitle: const Text("长按可添加机位或地区组 · 拖到这里可移到最外层"),
              tileColor: Colors.transparent,
            ),
          ),
        );
      },
    );
  }

  Widget _buildUngroupedPositionTree(
    void Function(void Function()) setSheetState,
  ) {
    final positions = _service.ungroupedPositions;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        initiallyExpanded: true,
        leading: const Icon(Icons.folder_open),
        title: const Text("未分组"),
        children: positions
            .map((item) => _buildDraggablePositionTile(item, 1))
            .toList(),
      ),
    );
  }

  Widget _buildPositionTreeNode(
    cam_model.CameraPositionGroup group,
    int depth,
    Set<String> expandedGroupIds,
    void Function(void Function()) setSheetState,
  ) {
    final childGroups = _service.childGroupsOf(group.id);
    final positions = _service.positionsInGroup(group.id);
    final expanded = expandedGroupIds.contains(group.id);
    final tile = DragTarget<_GroupManagerDragData>(
      onWillAcceptWithDetails: (details) =>
          _canDropToGroup(details.data, group.id),
      onAcceptWithDetails: (details) async {
        await _moveDraggedItem(details.data, group.id);
        expandedGroupIds.add(group.id);
        setSheetState(() {});
      },
      builder: (context, candidateData, rejectedData) {
        final active = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: EdgeInsets.only(left: depth * 10.0, bottom: 6),
          decoration: BoxDecoration(
            color: active
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
            ),
          ),
          child: Column(
            children: [
              Draggable<_GroupManagerDragData>(
                data: _GroupManagerDragData.group(group.id),
                affinity: Axis.horizontal,
                feedback: _buildDragFeedback(Icons.folder, group.name),
                childWhenDragging: Opacity(
                  opacity: 0.35,
                  child: _buildPositionTreeGroupRow(
                    group,
                    expanded,
                    expandedGroupIds,
                    setSheetState,
                  ),
                ),
                child: _buildPositionTreeGroupRow(
                  group,
                  expanded,
                  expandedGroupIds,
                  setSheetState,
                ),
              ),
              if (expanded) ...[
                ...childGroups.map(
                  (child) => _buildPositionTreeNode(
                    child,
                    depth + 1,
                    expandedGroupIds,
                    setSheetState,
                  ),
                ),
                ...positions.map(
                  (item) => _buildDraggablePositionTile(item, depth + 1),
                ),
              ],
            ],
          ),
        );
      },
    );
    return depth == 0
        ? Card(margin: const EdgeInsets.only(bottom: 8), child: tile)
        : tile;
  }

  Widget _buildPositionTreeGroupRow(
    cam_model.CameraPositionGroup group,
    bool expanded,
    Set<String> expandedGroupIds,
    void Function(void Function()) setSheetState,
  ) {
    return Material(
      color: Colors.transparent,
      child: Builder(
        builder: (tileContext) => ListTile(
          dense: true,
          leading: Icon(expanded ? Icons.keyboard_arrow_down : Icons.chevron_right),
          title: Row(
            children: [
              const Icon(Icons.folder, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(group.name)),
            ],
          ),
          trailing: Text(
            expanded ? '折叠' : '展开',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          tileColor: Colors.transparent,
          onTap: () {
            setSheetState(() {
              if (expanded) {
                expandedGroupIds.remove(group.id);
              } else {
                expandedGroupIds.add(group.id);
              }
            });
          },
          onLongPress: () => _showGroupContextMenu(tileContext, group),
        ),
      ),
    );
  }

  Widget _buildDraggablePositionTile(cam_model.CameraPosition item, int depth) {
    return Padding(
      padding: EdgeInsets.only(left: depth * 10.0),
      child: Draggable<_GroupManagerDragData>(
        data: _GroupManagerDragData.position(item.id),
        affinity: Axis.horizontal,
        feedback: _buildDragFeedback(Icons.videocam, item.name),
        childWhenDragging: Opacity(
          opacity: 0.35,
          child: _buildPositionTile(item),
        ),
        child: _buildPositionTile(item),
      ),
    );
  }

  Widget _buildDragFeedback(IconData icon, String text) {
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 8),
            Flexible(child: Text(text, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
    );
  }

  bool _canDropToGroup(_GroupManagerDragData data, String targetGroupId) {
    if (data.type == _GroupManagerDragType.group) {
      return data.id != targetGroupId &&
          !_service.isDescendantGroup(data.id, targetGroupId);
    }
    return true;
  }

  Future<void> _moveDraggedItem(
    _GroupManagerDragData data,
    String targetGroupId,
  ) async {
    if (data.type == _GroupManagerDragType.group) {
      await _service.moveGroup(data.id, targetGroupId);
      return;
    }
    await _service.movePosition(data.id, targetGroupId);
  }

  String _formatLineSubtitle(cam_model.CameraPosition item) {
    final lines = item.lineMileages
        .where(
          (line) =>
              line.line.trim().isNotEmpty || line.mileage.trim().isNotEmpty,
        )
        .map(
          (line) =>
              "${line.line.isEmpty ? '未填线路' : line.line} / ${line.mileage.isEmpty ? '未填里程' : line.mileage}",
        )
        .join("；");
    return lines.isEmpty ? '线路里程：未设置' : lines;
  }

  Future<void> _openDetail(cam_model.CameraPosition item) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CameraPositionDetailPage(positionId: item.id),
      ),
    );
  }

  Future<void> _openEditor({cam_model.CameraPosition? position, String? groupId}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            CameraPositionEditorPage(position: position, groupId: groupId),
      ),
    );
  }

  /// 长按分组弹出右键菜单：添加机位 / 添加子组。
  Future<void> _showGroupContextMenu(
    BuildContext renderObjectContext,
    cam_model.CameraPositionGroup? group,
  ) async {
    final renderBox = renderObjectContext.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final offset = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    final groupName = group?.name ?? '根目录';
    final screenWidth = MediaQuery.of(context).size.width;

    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        offset.dx,
        offset.dy + size.height,
        screenWidth - offset.dx - size.width,
        0,
      ),
      items: [
        PopupMenuItem(
          value: 'add_position',
          child: Row(
            children: [
              const Icon(Icons.add_location_alt, size: 20),
              const SizedBox(width: 8),
              Text('在「$groupName」中添加机位'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'add_subgroup',
          child: Row(
            children: [
              const Icon(Icons.create_new_folder, size: 20),
              const SizedBox(width: 8),
              Text(group == null ? '添加根级地区组' : '在「$groupName」中添加子组'),
            ],
          ),
        ),
        if (group != null)
          PopupMenuItem(
            value: 'delete_group',
            child: Row(
              children: [
                const Icon(Icons.delete_outline, size: 20, color: Colors.red),
                const SizedBox(width: 8),
                Text('删除「$groupName」'),
              ],
            ),
          ),
      ],
    );
    if (!mounted || result == null) return;
    if (result == 'add_position') {
      await _openEditor(groupId: group?.id);
    } else if (result == 'add_subgroup') {
      await _showAddSubGroupDialog(group?.id ?? '');
    } else if (result == 'delete_group' && group != null) {
      await _confirmDeleteGroup(group);
    }
  }

  Future<void> _confirmDeleteGroup(cam_model.CameraPositionGroup group) async {
    final childCount = _service.childGroupsOf(group.id).length +
        _service.positionsInGroup(group.id).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${group.name}」'),
        content: Text(childCount > 0
            ? '该组包含 $childCount 个子项，删除后子项将移至根目录。确认删除？'
            : '确认删除该地区组？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _service.deleteGroup(group.id);
    }
  }

  /// 弹出对话框输入子组名称并创建。
  Future<void> _showAddSubGroupDialog(String parentGroupId) async {
    final nameController = TextEditingController();
    final parentName =
        parentGroupId.isEmpty ? '根目录' : _service.groupDisplayName(parentGroupId);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('在「$parentName」中添加子组'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            labelText: '子组名称',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          onSubmitted: (value) {
            final name = value.trim();
            if (name.isEmpty) return;
            Navigator.pop(dialogContext, name);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final name = nameController.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(dialogContext, name);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
    // 延迟 dispose，避免对话框退出动画期间 TextField 访问已释放的 controller
    WidgetsBinding.instance.addPostFrameCallback((_) {
      nameController.dispose();
    });
    if (result == null || result.isEmpty) return;

    final newGroupId = DateTime.now().millisecondsSinceEpoch.toString();
    try {
      await _service.saveGroup(
        cam_model.CameraPositionGroup(
          id: newGroupId,
          name: result,
          parentGroupId: parentGroupId,
        ),
      );
    } catch (e, st) {
      debugPrint('saveGroup error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('添加子组失败: $e')),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _expandedTreeGroupIds.add(newGroupId);
      if (parentGroupId.isNotEmpty) {
        _expandedTreeGroupIds.add(parentGroupId);
      }
    });
  }
}

enum _GroupManagerDragType { group, position }

class _GroupManagerDragData {
  final _GroupManagerDragType type;
  final String id;

  const _GroupManagerDragData._({required this.type, required this.id});

  factory _GroupManagerDragData.group(String id) {
    return _GroupManagerDragData._(type: _GroupManagerDragType.group, id: id);
  }

  factory _GroupManagerDragData.position(String id) {
    return _GroupManagerDragData._(
      type: _GroupManagerDragType.position,
      id: id,
    );
  }
}

/// Windows 风格的地区组浏览/选择页。
/// 返回选中的地区组 id；根目录（无上级 / 不分组）返回空字符串。
class GroupBrowserPage extends StatefulWidget {
  final String initialGroupId;

  const GroupBrowserPage({super.key, this.initialGroupId = ''});

  @override
  State<GroupBrowserPage> createState() => _GroupBrowserPageState();
}

class _GroupBrowserPageState extends State<GroupBrowserPage> {
  final CameraPositionService _service = CameraPositionService.instance;
  late String _selectedId;
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _selectedId = widget.initialGroupId;
    for (final group in _service.childGroupsOf('')) {
      _expanded.add(group.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.pop(context, _selectedId);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text("选择地区组"),
          leading: IconButton(
            tooltip: "返回",
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context, _selectedId),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, _selectedId),
              child: const Text("确定", style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(8),
          children: [
            _buildRootRow(),
            ..._service
                .childGroupsOf('')
                .map((group) => _buildGroupNode(group, 1)),
          ],
        ),
      ),
    );
  }

  Widget _buildRootRow() {
    final selected = _selectedId.isEmpty;
    return _browserTile(
      icon: Icons.folder_special,
      title: "根目录（不分组 / 无上级）",
      selected: selected,
          onTap: () {
            setState(() => _selectedId = '');
          },
      depth: 0,
      trailing: null,
    );
  }

  Widget _buildGroupNode(cam_model.CameraPositionGroup group, int depth) {
    final childGroups = _service.childGroupsOf(group.id);
    final selected = _selectedId == group.id;
    final expanded = _expanded.contains(group.id);
    final trailing = childGroups.isEmpty
        ? null
        : IconButton(
            tooltip: expanded ? "折叠" : "展开",
            icon: Icon(expanded ? Icons.expand_more : Icons.chevron_right),
            onPressed: () => setState(() {
              if (expanded) {
                _expanded.remove(group.id);
              } else {
                _expanded.add(group.id);
              }
            }),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _browserTile(
          icon: Icons.folder,
          title: group.name,
          selected: selected,
          onTap: () {
            setState(() => _selectedId = group.id);
          },
          depth: depth,
          trailing: trailing,
        ),
        if (expanded)
          ...childGroups.map((child) => _buildGroupNode(child, depth + 1)),
      ],
    );
  }

  Widget _browserTile({
    required IconData icon,
    required String title,
    required bool selected,
    required VoidCallback onTap,
    required int depth,
    Widget? trailing,
  }) {
    return Padding(
      padding: EdgeInsets.only(left: depth * 16.0),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        leading: Icon(
          icon,
          color: selected ? Theme.of(context).colorScheme.primary : null,
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        trailing: trailing,
        tileColor: selected
            ? Theme.of(context).colorScheme.primaryContainer
            : Colors.transparent,
        onTap: onTap,
      ),
    );
  }
}

class CameraPositionEditorPage extends StatefulWidget {
  final cam_model.CameraPosition? position;
  final String? groupId;

  const CameraPositionEditorPage({super.key, this.position, this.groupId});

  @override
  State<CameraPositionEditorPage> createState() =>
      _CameraPositionEditorPageState();
}

class _CameraPositionEditorPageState extends State<CameraPositionEditorPage> {
  final CameraPositionService _service = CameraPositionService.instance;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _latitudeController = TextEditingController();
  final TextEditingController _longitudeController = TextEditingController();
  final List<_LineMileageControllers> _lineControllers = [];
  String _groupId = '';
  List<String> _imagePaths = [];

  @override
  void initState() {
    super.initState();
    final position = widget.position;
    if (position != null) {
      _nameController.text = position.name;
      _groupId = position.groupId;
      _latitudeController.text = position.latitude.toStringAsFixed(6);
      _longitudeController.text = position.longitude.toStringAsFixed(6);
      _imagePaths = List<String>.from(position.imagePaths);
      for (final item in position.lineMileages) {
        _lineControllers.add(
          _LineMileageControllers(line: item.line, mileage: item.mileage),
        );
      }
    } else if (widget.groupId != null) {
      _groupId = widget.groupId!;
    }
    if (_lineControllers.isEmpty) {
      _lineControllers.add(_LineMileageControllers());
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _latitudeController.dispose();
    _longitudeController.dispose();
    for (final item in _lineControllers) {
      item.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.position == null ? "添加机位" : "编辑机位")),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: "机位名称（必填）",
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          InputDecorator(
            decoration: const InputDecoration(
              labelText: "所属地区组",
              border: OutlineInputBorder(),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _groupId.isEmpty
                        ? "不分组"
                        : _service.groupDisplayName(_groupId),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton.icon(
                  onPressed: _pickGroup,
                  icon: const Icon(Icons.folder_open),
                  label: const Text("浏览"),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _latitudeController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: "纬度（必填）",
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _longitudeController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: "经度（必填）",
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _useCurrentLocation,
                  icon: const Icon(Icons.my_location),
                  label: const Text("定位"),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickOnMap,
                  icon: const Icon(Icons.map),
                  label: const Text("地图选点"),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(
                child: Text(
                  "机位图片",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
              TextButton.icon(
                onPressed: _pickFromGallery,
                icon: const Icon(Icons.photo_library),
                label: const Text("相册"),
              ),
              TextButton.icon(
                onPressed: _takePhoto,
                icon: const Icon(Icons.camera_alt),
                label: const Text("拍摄"),
              ),
            ],
          ),
          if (_imagePaths.isEmpty)
            const Text("暂无图片，可从相册上传或拍摄后保存到应用数据中。")
          else
            SizedBox(
              height: 92,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _imagePaths.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final path = _imagePaths[index];
                  return Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: crossFileImage(
                          path,
                          width: 92,
                          height: 92,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            width: 92,
                            height: 92,
                            color: Colors.black12,
                            child: const Icon(Icons.broken_image),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        right: 0,
                        child: InkWell(
                          onTap: () {
                            setState(() => _imagePaths.removeAt(index));
                          },
                          child: Container(
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.close,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(
                child: Text(
                  "线路与里程",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
              TextButton.icon(
                onPressed: () {
                  setState(
                    () => _lineControllers.add(_LineMileageControllers()),
                  );
                },
                icon: const Icon(Icons.add),
                label: const Text("添加线路"),
              ),
            ],
          ),
          const Text("线路、里程可以为空；为空时不受预警距离约束。"),
          const SizedBox(height: 8),
          ..._lineControllers.asMap().entries.map((entry) {
            final index = entry.key;
            final item = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: item.lineController,
                      decoration: const InputDecoration(
                        labelText: "线路",
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: item.mileageController,
                      decoration: const InputDecoration(
                        labelText: "机位里程",
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _lineControllers.length == 1
                        ? null
                        : () {
                            setState(() {
                              final removed = _lineControllers.removeAt(index);
                              removed.dispose();
                            });
                          },
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 20),
          FilledButton(onPressed: _save, child: const Text("保存机位")),
        ],
      ),
    );
  }

  Future<void> _pickGroup() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => GroupBrowserPage(initialGroupId: _groupId),
      ),
    );
    if (!mounted || result == null) return;
    setState(() => _groupId = result);
  }

  Future<void> _useCurrentLocation() async {
    final location = await NativeLocationService.instance.getCurrentLocation();
    if (!mounted) return;
    if (location == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("定位失败，请确认定位权限和系统定位已开启")));
      return;
    }
    setState(() {
      _latitudeController.text = location.latitude.toStringAsFixed(6);
      _longitudeController.text = location.longitude.toStringAsFixed(6);
    });
  }

  Future<void> _pickOnMap() async {
    final initialLatitude =
        double.tryParse(_latitudeController.text) ?? 39.9042;
    final initialLongitude =
        double.tryParse(_longitudeController.text) ?? 116.4074;
    final result = await Navigator.push<NativeLocation>(
      context,
      MaterialPageRoute(
        builder: (_) => SimpleMapPickPage(
          initialLatitude: initialLatitude,
          initialLongitude: initialLongitude,
        ),
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      _latitudeController.text = result.latitude.toStringAsFixed(6);
      _longitudeController.text = result.longitude.toStringAsFixed(6);
    });
  }

  Future<void> _pickFromGallery() async {
    final path = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const NativeImagePickerPage()),
    );
    if (!mounted || path == null || path.isEmpty) return;
    setState(() => _imagePaths = [..._imagePaths, path]);
  }

  Future<void> _takePhoto() async {
    try {
      final granted = await NativeImageService.instance
          .requestCameraPermission();
      if (!mounted) return;
      if (!granted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("没有相机权限，请授权后重试")));
        return;
      }
      final path = await NativeImageService.instance.takePhotoToAppData();
      if (!mounted || path == null || path.isEmpty) return;
      setState(() => _imagePaths = [..._imagePaths, path]);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("拍摄失败：$error")));
    }
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final latitude = double.tryParse(_latitudeController.text.trim());
    final longitude = double.tryParse(_longitudeController.text.trim());
    if (name.isEmpty || latitude == null || longitude == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("名称和位置不能为空")));
      return;
    }

    final lineMileages = _lineControllers
        .map(
          (item) => cam_model.LineMileage(
            line: item.lineController.text.trim(),
            mileage: item.mileageController.text.trim(),
          ),
        )
        .where((item) => item.line.isNotEmpty || item.mileage.isNotEmpty)
        .toList();
    final id =
        widget.position?.id ?? DateTime.now().millisecondsSinceEpoch.toString();
    await _service.savePosition(
      cam_model.CameraPosition(
        id: id,
        name: name,
        groupId: _groupId,
        latitude: latitude,
        longitude: longitude,
        lineMileages: lineMileages,
        imagePaths: _imagePaths,
      ),
    );
    if (mounted) Navigator.pop(context);
  }
}

/// 地图选点页：全屏地图，点击选择一个坐标点。
///
/// 地图使用 GCJ-02 坐标系（高德栅格瓦片）。用户在地图上点击获得的坐标
/// 为 GCJ-02，返回时转回 WGS-84 以保持存储坐标的一致性。
class SimpleMapPickPage extends StatefulWidget {
  final double initialLatitude;
  final double initialLongitude;

  const SimpleMapPickPage({
    super.key,
    required this.initialLatitude,
    required this.initialLongitude,
  });

  @override
  State<SimpleMapPickPage> createState() => _SimpleMapPickPageState();
}

class _SimpleMapPickPageState extends State<SimpleMapPickPage> {
  final MapLibreController _mapController = MapLibreController();

  /// 选中的点（WGS-84），用于存储和返回。
  late LatLng _selectedPoint;

  @override
  void initState() {
    super.initState();
    _selectedPoint = LatLng(
      widget.initialLatitude,
      widget.initialLongitude,
    );

    // 地图就绪后将中心移动到初始选点。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _mapController.move(
        wgs84ToGcj02(_selectedPoint.latitude, _selectedPoint.longitude),
        15,
      );
    });
  }

  /// 构建选中点的标记列表（WGS-84 → GCJ-02）。
  List<MapMarker> get _markers => [
        MapMarker(
          point: wgs84ToGcj02(_selectedPoint.latitude, _selectedPoint.longitude),
          color: Colors.red,
          size: 32,
        ),
      ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("地图选点")),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: MapLibreMapWidget(
                    initialCenter: wgs84ToGcj02(39.9042, 116.4074),
                    initialZoom: 15,
                    markers: _markers,
                    controller: _mapController,
                    onMapTap: (point) {
                      setState(() => _selectedPoint = gcj02ToWgs84(
                            point.latitude,
                            point.longitude,
                          ));
                    },
                  ),
                ),
                Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Card(
                      color: const Color.fromARGB(255, 7, 151, 235),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          "点击地图选择机位\n纬度：${_selectedPoint.latitude.toStringAsFixed(6)}，经度：${_selectedPoint.longitude.toStringAsFixed(6)}",
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ),
                const MapAttribution(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final location = await NativeLocationService.instance
                          .getCurrentLocation();
                      if (location == null) return;
                      if (!mounted) return;
                      setState(() {
                        _selectedPoint = LatLng(
                          location.latitude,
                          location.longitude,
                        );
                      });
                      final gcj = wgs84ToGcj02(
                        location.latitude,
                        location.longitude,
                      );
                      final currentZoom = _mapController.zoom;
                      _mapController.move(
                        gcj,
                        currentZoom < 15 ? 15 : currentZoom,
                      );
                    },
                    icon: const Icon(Icons.my_location),
                    label: const Text("定位到当前位置"),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      Navigator.pop(
                        context,
                        NativeLocation(
                          latitude: _selectedPoint.latitude,
                          longitude: _selectedPoint.longitude,
                        ),
                      );
                    },
                    child: const Text("确认选点"),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 机位详情页：展示地图位置、图片，提供导航、编辑、删除、设为当前机位等操作。
class CameraPositionDetailPage extends StatefulWidget {
  final String positionId;

  const CameraPositionDetailPage({super.key, required this.positionId});

  @override
  State<CameraPositionDetailPage> createState() =>
      _CameraPositionDetailPageState();
}

class _CameraPositionDetailPageState extends State<CameraPositionDetailPage> {
  final CameraPositionService _service = CameraPositionService.instance;
  final MapLibreController _mapController = MapLibreController();

  @override
  void initState() {
    super.initState();
    _service.addListener(_refresh);

    // 地图就绪后将中心移动到机位坐标。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final pos = _position;
      if (pos == null) return;
      final gcj = wgs84ToGcj02(pos.latitude, pos.longitude);
      _mapController.move(gcj, 15);
    });
  }

  @override
  void dispose() {
    _service.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
    }
  }

  cam_model.CameraPosition? get _position {
    for (final item in _service.positions) {
      if (item.id == widget.positionId) return item;
    }
    return null;
  }

  // --------------------------------------------------------------------------
  // Build
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final position = _position;
    if (position == null) {
      return Scaffold(
        appBar: AppBar(title: const Text("机位详情")),
        body: const Center(child: Text("机位不存在或已被删除")),
      );
    }
    final isCurrent = position.id == _service.currentPositionId;
    final groupName = position.groupId.isEmpty
        ? null
        : _service.groupDisplayName(position.groupId);
    return Scaffold(
      appBar: AppBar(title: Text(position.name)),
      body: ListView(
        children: [
          _buildMap(position),
          if (position.imagePaths.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildImageGallery(position),
          ],
          const SizedBox(height: 12),
          _buildInfoCard(position, groupName),
          const SizedBox(height: 16),
          _buildActionButtons(position, isCurrent),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildMap(cam_model.CameraPosition position) {
    final gcjPoint = wgs84ToGcj02(position.latitude, position.longitude);
    return SizedBox(
      width: double.infinity,
      height: 220,
      child: Stack(
        children: [
          MapLibreMapWidget(
            initialCenter: wgs84ToGcj02(39.9042, 116.4074),
            initialZoom: 15,
            controller: _mapController,
            markers: [
              MapMarker(point: gcjPoint, color: Colors.red, size: 32),
            ],
          ),
          const MapAttribution(),
        ],
      ),
    );
  }

  Widget _buildImageGallery(cam_model.CameraPosition position) {
    return SizedBox(
      height: 100,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: position.imagePaths.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: crossFileImage(
              position.imagePaths[index],
              width: 100,
              height: 100,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                width: 100,
                height: 100,
                color: Colors.black12,
                child: const Icon(Icons.broken_image),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildInfoCard(cam_model.CameraPosition position, String? groupName) {
    final lineText = position.lineMileages
        .where(
          (l) => l.line.trim().isNotEmpty || l.mileage.trim().isNotEmpty,
        )
        .map(
          (l) =>
              "${l.line.isEmpty ? '未填线路' : l.line} / ${l.mileage.isEmpty ? '未填里程' : l.mileage}",
        )
        .join("；");
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (groupName != null)
              _infoRow(Icons.folder, "所属地区组", groupName),
            _infoRow(
              Icons.my_location,
              "坐标",
              "${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}",
            ),
            _infoRow(
              Icons.train,
              "线路里程",
              lineText.isEmpty ? "未设置，不受距离约束" : lineText,
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Colors.grey),
          const SizedBox(width: 8),
          Text("$label：", style: const TextStyle(fontWeight: FontWeight.bold)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _buildActionButtons(cam_model.CameraPosition position, bool isCurrent) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          if (!isCurrent)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () async {
                  final error = await _service.setCurrentPosition(position.id);
                  if (!mounted) return;
                  if (error != null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(error)),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("已设为当前机位")),
                    );
                  }
                },
                icon: const Icon(Icons.radio_button_checked),
                label: const Text("设为当前机位"),
              ),
            ),
          if (!isCurrent) const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _openNavigationOptions(position),
                  icon: const Icon(Icons.navigation),
                  label: const Text("导航"),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _openEditor(position),
                  icon: const Icon(Icons.edit),
                  label: const Text("编辑"),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _confirmDelete(position),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text("删除"),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openNavigationOptions(cam_model.CameraPosition position) async {
    final encodedName = Uri.encodeComponent(position.name);
    final wgsLat = position.latitude;
    final wgsLon = position.longitude;
    final gcj = CoordTransform.transformWGS84toGCJ02(wgsLon, wgsLat);
    final gcjLat = gcj.lat.toStringAsFixed(6);
    final gcjLon = gcj.lon.toStringAsFixed(6);
    final bd = CoordTransform.transformWGS84toBD09(wgsLon, wgsLat);
    final bdLat = bd.lat.toStringAsFixed(6);
    final bdLon = bd.lon.toStringAsFixed(6);
    final wgsLatStr = wgsLat.toStringAsFixed(6);
    final wgsLonStr = wgsLon.toStringAsFixed(6);

    final options = [
      _NavigationOption(
        name: "高德地图",
        uri: Uri.parse(
          "androidamap://route/plan/?dlat=$gcjLat&dlon=$gcjLon&dname=$encodedName&dev=0&t=1",
        ),
      ),
      _NavigationOption(
        name: "百度地图",
        uri: Uri.parse(
          "baidumap://map/direction?destination=latlng:$bdLat,$bdLon|name:$encodedName&mode=transit&coord_type=bd09ll",
        ),
      ),
      _NavigationOption(
        name: "腾讯地图",
        uri: Uri.parse(
          "qqmap://map/routeplan?type=bus&tocoord=$gcjLat,$gcjLon&to=$encodedName&coord_type=1",
        ),
      ),
      _NavigationOption(
        name: "系统地图",
        uri: Uri.parse(
          "geo:$wgsLatStr,$wgsLonStr?q=$wgsLatStr,$wgsLonStr($encodedName)",
        ),
      ),
    ];

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text("公共交通导航到：${position.name}"),
                subtitle: Text("WGS84: $wgsLatStr, $wgsLonStr"),
              ),
              ...options.map(
                (option) => ListTile(
                  leading: const Icon(Icons.navigation),
                  title: Text(option.name),
                  onTap: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    Navigator.pop(context);
                    final ok = await launchUrl(
                      option.uri,
                      mode: LaunchMode.externalApplication,
                    );
                    if (!ok) {
                      messenger
                          .showSnackBar(SnackBar(content: Text("无法打开${option.name}")));
                    }
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openEditor(cam_model.CameraPosition position) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CameraPositionEditorPage(position: position),
      ),
    );
  }

  Future<void> _confirmDelete(cam_model.CameraPosition position) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("删除机位"),
        content: Text("确定要删除「${position.name}」吗？"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("删除"),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _service.deletePosition(position.id);
    if (!mounted) return;
    Navigator.pop(context);
  }
}

class _LineMileageControllers {
  final TextEditingController lineController;
  final TextEditingController mileageController;

  _LineMileageControllers({String line = '', String mileage = ''})
    : lineController = TextEditingController(text: line),
      mileageController = TextEditingController(text: mileage);

  void dispose() {
    lineController.dispose();
    mileageController.dispose();
  }
}

class _NavigationOption {
  final String name;
  final Uri uri;

  const _NavigationOption({required this.name, required this.uri});
}
