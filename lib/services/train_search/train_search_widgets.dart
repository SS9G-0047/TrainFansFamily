// 可复用 UI 组件：结果卡片、经停行、徽章、详情页主体
part of '../../pages/train_search_page.dart';


// ── 普速卡片配色 ─────────────────────────────────────────────────────────
// 查询结果动辄上百条，全是白卡片根本没法扫。
// 车厢按车种上色（YW 硬卧 / YZ 硬座 / CA 餐车 …），机车按配属局上色，
// 一眼就能看出这趟车的编组构成或这批机车都归哪个局。

/// 车种前缀 → 色板（MaterialColor，深浅两种色阶各取一支）
MaterialColor _carModelSwatch(String model) {
  final m = model.toUpperCase();
  if (m.startsWith('YW')) return Colors.indigo; // 硬卧
  if (m.startsWith('RW')) return Colors.purple; // 软卧
  if (m.startsWith('YZ')) return Colors.green; // 硬座
  if (m.startsWith('RZ')) return Colors.teal; // 软座
  if (m.startsWith('CA')) return Colors.orange; // 餐车
  if (m.startsWith('XL')) return Colors.brown; // 行李车
  if (m.startsWith('KD')) return Colors.blueGrey; // 空调发电车
  if (m.startsWith('UZ')) return Colors.grey; // 邮政车
  if (m.startsWith('WX') || m.startsWith('SY') || m.startsWith('TZ')) {
    return Colors.blueGrey; // 试验 / 维修 / 回送
  }
  return Colors.blue;
}

/// 车种中文名（用于卡片副标题，比 YW25T 好认）
String _carModelName(String model) {
  final m = model.toUpperCase();
  const names = <String, String>{
    'YW': '硬卧车',
    'RW': '软卧车',
    'YZ': '硬座车',
    'RZ': '软座车',
    'CA': '餐车',
    'XL': '行李车',
    'KD': '空调发电车',
    'UZ': '邮政车',
    'WX': '维修车',
    'SY': '试验车',
    'TZ': '回送车',
  };
  for (final e in names.entries) {
    if (m.startsWith(e.key)) return e.value;
  }
  return '';
}

/// 按明暗主题取色阶：深色模式下 700 太暗，改取 300
Color _swatchOf(BuildContext context, MaterialColor swatch) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark ? swatch.shade300 : swatch.shade700;
}

/// 配属局 → 稳定色（同一局始终同色，用字符串 hash 取）
Color _bureauColor(BuildContext context, String bureau) {
  const pool = <MaterialColor>[
    Colors.red,
    Colors.orange,
    Colors.amber,
    Colors.green,
    Colors.teal,
    Colors.cyan,
    Colors.blue,
    Colors.indigo,
    Colors.purple,
    Colors.pink,
  ];
  final s = bureau.trim();
  final h = s.isEmpty ? 0 : s.codeUnits.fold<int>(0, (a, b) => a * 31 + b);
  return _swatchOf(context, pool[h.abs() % pool.length]);
}

/// 小标签：有底色的小圆角块，用于车种 / 定员 / 厂家这些次要字段
Widget _psChip(
  BuildContext context, {
  required String text,
  required Color color,
}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withOpacity(0.14),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: color.withOpacity(0.35), width: 0.5),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500),
    ),
  );
}

/// 一节车厢的卡片：左侧车种色条 + 车号 + 车型/配属/定员/车次
Widget _buildCarCard(BuildContext context, _CarStock c, {int? index}) {
  final cs = Theme.of(context).colorScheme;
  final swatch = _carModelSwatch(c.model);
  final accent = _swatchOf(context, swatch);
  final modelName = _carModelName(c.model);

  return Card(
    margin: const EdgeInsets.only(bottom: 8),
    clipBehavior: Clip.antiAlias,
    child: IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(width: 4, color: accent),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      if (index != null) ...<Widget>[
                        SizedBox(
                          width: 26,
                          child: Text(
                            '$index',
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurfaceVariant.withOpacity(0.7),
                            ),
                          ),
                        ),
                      ],
                      Text(
                        c.model.isEmpty ? '—' : c.model,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: accent,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          c.carNo.isEmpty ? '' : c.carNo,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'monospace',
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (c.trainCode.isNotEmpty)
                        _psChip(context,
                            text: c.trainCode, color: cs.primary),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: <Widget>[
                      if (c.depot.isNotEmpty)
                        _psChip(context, text: c.depot, color: cs.secondary),
                      if (modelName.isNotEmpty)
                        _psChip(context, text: modelName, color: accent),
                      if (c.capacity.isNotEmpty)
                        _psChip(context,
                            text: '定员 ${c.capacity}', color: cs.onSurfaceVariant),
                      if (c.factory.isNotEmpty)
                        _psChip(context, text: c.factory, color: cs.onSurfaceVariant),
                      if (c.bogie.isNotEmpty)
                        _psChip(context, text: c.bogie, color: cs.onSurfaceVariant),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// 一台机车的卡片：左侧配属局色条 + 车号 + 局段/厂家/备注
Widget _buildLocoCard(BuildContext context, _LocoItem l, {int? index}) {
  final cs = Theme.of(context).colorScheme;
  // 配属统一走 depot：bureau 已不再单独填（机车页合并格，拆不出「局」「段」）
  final accent = _bureauColor(context, l.depot.isNotEmpty ? l.depot : l.locoNo);

  return Card(
    margin: const EdgeInsets.only(bottom: 8),
    clipBehavior: Clip.antiAlias,
    child: IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(width: 4, color: accent),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      if (index != null) ...<Widget>[
                        SizedBox(
                          width: 26,
                          child: Text(
                            '$index',
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurfaceVariant.withOpacity(0.7),
                            ),
                          ),
                        ),
                      ],
                      Expanded(
                        child: Text(
                          l.locoNo.isEmpty ? '—' : l.locoNo,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'monospace',
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: <Widget>[
                      if (l.depot.isNotEmpty)
                        _psChip(context, text: l.depot, color: accent),
                      if (l.depot.isNotEmpty)
                        _psChip(context, text: l.depot, color: cs.secondary),
                      if (l.factory.isNotEmpty)
                        _psChip(context, text: l.factory, color: cs.onSurfaceVariant),
                      if (l.note.isNotEmpty)
                        _psChip(context, text: l.note, color: cs.onSurfaceVariant),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

// ───────────────────────────────────────────────────────────────────────────
// 车组号卡片（顶层函数：主页结果、速查弹窗共用）
// ───────────────────────────────────────────────────────────────────────────

Widget _buildEmuProfileCard(BuildContext context, _EmuProfile p) {
  final cs = Theme.of(context).colorScheme;
  return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.directions_railway, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    p.emuNo,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: p.lines.map((t) {
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(t, style: const TextStyle(fontSize: 12)),
                );
              }).toList(),
            ),
            if (p.tags.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: p.tags.map((t) {
                  return Chip(
                    label: Text(t, style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
}

Widget _buildEmuRecordCard(
  BuildContext context,
  _EmuRecord r,
  void Function(String trainCode)? onPickTrain, {
  // 车组号可点：不额外加控件，直接让这行文字可点，跳下一级查这台车
  void Function(String emuNo)? onPickEmu,
}) {
  final cs = Theme.of(context).colorScheme;
  final isCrh = r.source == _EmuSource.crhTracker;
  final canPickEmu = onPickEmu != null && r.emuNo.isNotEmpty;
  return Card(
      child: ListTile(
        dense: true,
        leading: SizedBox(
          width: 62,
          child: Text(
            r.trainCode.isEmpty ? '—' : r.trainCode,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        title: canPickEmu
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onPickEmu(r.emuNo),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        r.emuNo,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.primary,
                          decoration: TextDecoration.underline,
                          decorationColor: cs.primary.withOpacity(0.4),
                        ),
                      ),
                    ),
                  ],
                ),
              )
            : Text(r.emuNo, style: const TextStyle(fontSize: 13)),
        subtitle: Text(
          r.date.isEmpty ? '日期未知' : r.date,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: isCrh ? cs.tertiaryContainer : cs.secondaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _emuSourceLabel(r.source),
                style: TextStyle(
                  fontSize: 10,
                  color: isCrh ? cs.onTertiaryContainer : cs.onSecondaryContainer,
                ),
              ),
            ),
            if (r.trainCode.isNotEmpty && onPickTrain != null) ...<Widget>[
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.list_alt, size: 18),
                tooltip: '查看经停',
                onPressed: () => onPickTrain(r.trainCode),
              ),
            ],
          ],
        ),
        onTap: (r.trainCode.isEmpty || onPickTrain == null)
            ? null
            : () => onPickTrain(r.trainCode),
      ),
    );
}

// ───────────────────────────────────────────────────────────────────────────
// 经停行（列表页与详情页共用）
// ───────────────────────────────────────────────────────────────────────────

/// 经停行：序号 / 站名 / 电报码 + 到发时刻 / 正晚点 / 里程 / 停靠时长
/// 列表页（车次查询）与详情页（独立页、车站大屏点入）共用，保证两处结构一致
Widget _stopRow(BuildContext context, _Stop s, bool first, bool last) {
  final cs = Theme.of(context).colorScheme;
  final arr = s.arriveTime.isEmpty ? '--' : s.arriveTime;
  final dep = s.departTime.isEmpty ? '--' : s.departTime;
  final timeText = first ? '发 $dep' : last ? '到 $arr' : '$arr → $dep';
  final stop = s.stopover.trim();

  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 40,
        child: Column(
          children: [
            Container(
              width: 10,
              height: 10,
              margin: const EdgeInsets.only(top: 14),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (first || last) ? cs.primary : Colors.grey,
              ),
            ),
            if (!last)
              Container(
                width: 1,
                height: 46,
                color: Colors.grey.withOpacity(0.45),
              ),
          ],
        ),
      ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 22,
                    child: Text(
                      '${s.index}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      s.stationName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (s.stationCode.isNotEmpty) _telecodeChip(context, s.stationCode),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 10,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    timeText,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  _lateBadge(context, s.late),
                  Text(
                    s.mileage == null ? '里程 —' : '${_fmtKm(s.mileage!)} km',
                    style: TextStyle(
                      fontSize: 11,
                      color: s.mileage == null ? Colors.grey : cs.onSurfaceVariant,
                    ),
                  ),
                  if (!first && !last && stop.isNotEmpty && stop != '--')
                    Text(
                      '停 $stop',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

String _fmtKm(double v) =>
    v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(1);

/// 电报码小标签
Widget _telecodeChip(BuildContext context, String code) {
  final cs = Theme.of(context).colorScheme;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      code,
      style: TextStyle(
        fontSize: 11,
        letterSpacing: 0.5,
        color: cs.onSurfaceVariant,
      ),
    ),
  );
}

/// 正晚点徽章：正点绿 / 晚点红 / 早点蓝 / 未知灰
Widget _lateBadge(BuildContext context, _LateInfo? late) {
  final cs = Theme.of(context).colorScheme;
  Color bg;
  Color fg;
  switch (late?.state ?? 2) {
    case 0:
      bg = Colors.green.withOpacity(0.16);
      fg = Colors.green.shade700;
      break;
    case 1:
      bg = cs.errorContainer;
      fg = cs.onErrorContainer;
      break;
    case -1:
      bg = cs.tertiaryContainer;
      fg = cs.onTertiaryContainer;
      break;
    default:
      bg = cs.surfaceContainerHighest;
      fg = cs.onSurfaceVariant;
      break;
  }
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      late?.label ?? '正晚点 —',
      style: TextStyle(fontSize: 11, color: fg),
    ),
  );
}

/// 详情页脚注：说明里程 / 担当 / 正晚点各自的数据来源（两个详情页共用）
Widget _trainDetailFooter(BuildContext context, _TrainDetail d) {
  final c = d.consist;
  final n = d.consists.length;
  final parts = <String>[
    d.hasMileage ? '里程 ${d.mileageSource}' : '里程 暂无数据',
    (c == null || c.title.isEmpty)
        ? (d.isEmu ? '担当车组 暂无数据' : '车型 暂无数据')
        : (d.isEmu
            ? '担当车组 ${c.source.isEmpty ? '第三方数据源' : c.source}'
                '（近 $n 组）'
            : '车型 ${c.source.isEmpty ? '12306' : c.source}'),
    _kLateEnabled ? '正晚点 12306（仅当天附近）' : '正晚点 未启用',
  ];
  return Container(
    width: double.infinity,
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: Text(
      parts.join('　·　'),
      style: const TextStyle(fontSize: 11, color: Colors.grey),
    ),
  );
}

/// 车次详情主体（头部 + 经停列表）：
/// 「车次查询」内联结果与「经停详情独立页」共用，保证两处结构完全对齐
Widget _buildTrainDetailBody(
  BuildContext context,
  _TrainDetail d, {
  bool compactHeader = false,
  /// 点击车组号时回调（车次查询页可用来跳转到车组号查询）
  void Function(String emuNo)? onPickEmu,
  /// 点「车厢配属」时回调（普速车次才有意义，调用方决定要不要给）
  VoidCallback? onPickCarStock,
}) {
  final cs = Theme.of(context).colorScheme;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        color: cs.surfaceContainerHighest,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Text(
              d.trainCode,
              style: TextStyle(
                fontSize: compactHeader ? 18 : 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              _fmtDash(d.date),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const Spacer(),
            Text(
              '共 ${d.stops.length} 站',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            if (onPickCarStock != null) ...<Widget>[
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: onPickCarStock,
                icon: const Icon(Icons.railway_alert, size: 16),
                label: const Text('车厢配属'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ],
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${d.startStation} → ${d.endStation}',
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 4),
            _ConsistSection(detail: d, onPickEmu: onPickEmu),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: d.stops.length,
          itemBuilder: (_, i) => _stopRow(
            context,
            d.stops[i],
            i == 0,
            i == d.stops.length - 1,
          ),
        ),
      ),
    ],
  );
}

// ───────────────────────────────────────────────────────────────────────────
// 担当车组 / 车型区块（横向滑动查看最近所有担当的动车组）
// ───────────────────────────────────────────────────────────────────────────

/// 滑动条的行高（车组号一行 + 车型/日期一行）
const double _kConsistChipHeight = 52;

/// 少于这个数量时不显示「滑动查看」提示
const int _kConsistHintMin = 3;

class _ConsistSection extends StatelessWidget {
  final _TrainDetail detail;
  final void Function(String emuNo)? onPickEmu;

  const _ConsistSection({
    required this.detail,
    this.onPickEmu,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final list = detail.consists;
    final isEmu = detail.isEmu;
    final label = isEmu ? '担当车组' : '车型';

    if (list.isEmpty) {
      return Row(
        children: <Widget>[
          Icon(
            isEmu ? Icons.directions_railway : Icons.train,
            size: 16,
            color: cs.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          const Text(
            '暂无数据',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(
              isEmu ? Icons.directions_railway : Icons.train,
              size: 16,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(width: 6),
            Text(
              isEmu ? '近 ${list.length} 组' : '${list.length} 项',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const Spacer(),
            if (list.length > _kConsistHintMin)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.chevron_right,
                    size: 14,
                    color: cs.onSurfaceVariant.withOpacity(0.7),
                  ),
                  const SizedBox(width: 2),
                  Text(
                    '滑动查看全部',
                    style: TextStyle(
                      fontSize: 10,
                      color: cs.onSurfaceVariant.withOpacity(0.7),
                    ),
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 6),
        // 横向滑动：一次看不全就左右拖，不做展开/收起
        SizedBox(
          height: _kConsistChipHeight,
          child: ScrollConfiguration(
            // 去掉移动端滑动到边缘的水波纹，视觉更干净
            behavior: _NoGlowScrollBehavior(),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) => _consistChip(
                context,
                list[i],
                isEmu && list[i].emuNo.isNotEmpty ? onPickEmu : null,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _consistChip(
    BuildContext context,
    _TrainConsist c,
    void Function(String emuNo)? onTap,
  ) {
    final cs = Theme.of(context).colorScheme;
    final sub = c.subtitle;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap == null ? null : () => onTap(c.emuNo),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: cs.primaryContainer.withOpacity(0.6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.primary.withOpacity(0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              c.title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.primary,
              ),
            ),
            if (sub.isNotEmpty)
              Text(
                sub,
                style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

/// 横向滑动条去水波纹（Android 默认会有一圈发光）
class _NoGlowScrollBehavior extends ScrollBehavior {
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

// ───────────────────────────────────────────────────────────────────────────
// 车组号 / 车次担当查询（独立页面，作为下一级界面 push 进来）
// ───────────────────────────────────────────────────────────────────────────

/// 从车次经停详情里点车组号：进下一级页面，按返回回到原来的详情页
Future<void> _openEmuPage(BuildContext context, String emuNo) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => _EmuSearchPage(initialKeyword: emuNo),
    ),
  );
}

// ───────────────────────────────────────────────────────────────────────────
// 普速配属查询（独立页面，作为下一级界面 push 进来）
// ───────────────────────────────────────────────────────────────────────────

/// 从车次详情里点「车厢配属」：进下一级页面，按返回回到原来的详情页。
/// 默认停在「车厢」栏并带上车次号，进来后可以切到机车或改维度。
Future<void> _openPsPage(BuildContext context, String keyword) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => _PsSearchPage(initialKeyword: keyword),
    ),
  );
}
