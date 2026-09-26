// ============================================================================
// 列车查询页面（UI 入口）
//
// ⚠️ 本文件只放**页面**（StatefulWidget + State），业务代码已拆到同目录的
//    4 个 part 文件里，靠 part / part of 组成同一个库：
//      train_search_models.dart    数据模型 + 配置常量
//      train_search_api.dart       网络层（各数据源请求封装）
//      train_search_parsers.dart   解析与工具（HTML 硬解析 / 格式化）
//      train_search_widgets.dart   可复用 UI 组件（卡片 / 行 / 徽章）
//
//    用 part 而不是独立 import，是为了**不改名**：几百个下划线开头的私有符号
//    （_Station / _RailwayApi / _cleanErr …）全部原样保留，零重命名、零回归风险。
//    代价是这些符号在本库内互相可见——对单页面规模的代码是划算的。
//
//    新增代码时按职责放到对应 part 文件；只有「页面 / 页面级 State」才写这里。
//
// 使用前请在 pubspec.yaml 增加依赖：
//   dependencies:
//     http: ^1.2.2
//
// 四种查询方式：
//   1. 站-站   : 出发站 → 到达站，列出当日全部车次 + 余票
//   2. 车次    : G101 / Z155，列出该车次全程经停时刻表
//                每行含：电报码 / 到发时刻 / 正晚点 / 里程 / 停靠时长
//                顶部含：最近担当的动车组（动车，可有多组）或车型（普速）
//   3. 车组号  : CR400AF-2031 / CRH2A-2001 / G83，交路 + 配属档案
//                数据源：rail.re（api.rail.re）+ OpenCRHTracker（crh.lihugang.top）
//                ⚠️ 车次与车组号在 rail.re 上是两个不同接口：
//                   GET /emu/{车组号}   → 该车组担当过哪些车次
//                   GET /train/{车次}   → 该车次近期用过哪些车组
//                本文件按关键词自动选路（_classifyEmuKeyword）：
//                   G83 / 1461 这类 → 车次；CR/CRH 开头 → 车组号；
//                   判不出来就两条都打。车次路线拿到车组号后，
//                   再并发补 OpenCRHTracker 的历史与配属（最多 5 组）。
//   4. 车站    : 某站当日大屏（站台 / 到发时刻 / 参考车型）
//                数据源：OpenCRHTracker；点击车次直接进「车次」同款时刻表页
//   5. 普速    : 车厢配属（cr400bf.passearch.info）/ 机车配属（loco.passearch.info）
//                两个站都只有 HTML 表格、没有 JSON API，靠 _parseHtmlTable 硬解析
//                （按表头文字定位列索引，不写死列序）。
//                解析顺序：先按 <table> 把页面切成块，只认「含表头的那一块」，
//                再在块内取行——否则页脚那张友情链接表会被当成车厢数据渲染出来
//                （它整行都是超链接文字，不含任何可过滤的特征词）。
//                翻页：优先跟随服务端本页吐出的「下一页」链接（_pasNextPageUrl），
//                拿不到才按 _pasPageUri 自己拼 ?type=&keyword=&pagenum=N。
//                别自己赌参数名与顺序——拼错了服务端会静默返回第 1 页，
//                表现就是「翻页参数不生效 / 加载更多没变化」。
//                另外抓 HTML 必须走 _getHtml（Accept 带 text/html），
//                用 _getPlain 那套 JSON 的 Accept 会被内容协商挡掉。
//                翻页失败不再静默：原因会显示在列表底部并给「重试」。
//                翻页「打滑」（新页内容与已加载的完全重复）时不再直接认输：
//                  换 URL 写法重试（加时间戳穿透缓存 / 换参数顺序 / 换参数名），
//                  仍失败才停，并把「请求的 URL + 服务端标注页码 + 本页首末条」
//                  原样打出来，一眼看出是 URL 拼错还是命中了缓存。
//                另外 _getHtml 会保存并回传 Cookie——http.Client 默认不存 Cookie，
//                PHP 站的分页结果有可能挂在 session 上。
//                两者拆成两个独立分栏：关键字、查询维度、结果、翻页各管各的
//                ——车厢查的是车次（Z155），机车查的是型号（HXD3D），
//                  本来就不是一个关键字，不该共用一个输入框。
//                机车站没有车次维度，只能按型号或配属段查，
//                所以查不到「某趟车今天用什么机车」。
//                两个站每页固定 50 条，列表底部可「加载更多」。
//
// ── 里程数据源 ────────────────────────────────────────────────────────────
//   黄河铁路网（jprailfan.com）：社区站，无公开 JSON API，返回的是传统 HTML
//   页面。本文件用「先 JSON 后 HTML 表格」的双解析器抓取 站名→里程(km)，
//   路径常量 _kHuangheMileagePath 需按该站工具箱实际 URL 调整（见下方注释）。
//   抓不到时里程列显示「—」，不影响其余字段。
//
// ── 正晚点数据源 ──────────────────────────────────────────────────────────
//   12306 官方「正晚点查询」（zwdch）。该页面未提供公开 API，仅覆盖
//   过去 1 小时 ~ 未来 3 小时，且按「车次 + 车站」单次查询。
//   因此本文件：仅在查询日期 = 今天时，对经停站并发拉取（并发上限 4），
//   结果进内存缓存 2 分钟；其余情况显示「—」。
//
// ⚠️ 关于直连 12306：
//   12306 未对外开放公共 API，kyfw 域接口受瑞数动态防护 + 频控保护，
//   移动端/桌面端直连大概率返回 200 但 data 为空，或被要求滑块验证。
//   生产环境建议自建反代（同路径转发），然后把下面两个 Base 常量换成你的域名。
//
// ⚠️ 关于第三方数据源：
//   rail.re、OpenCRHTracker、黄河铁路网均为社区维护的公开接口/页面，
//   无 SLA、无 CORS 承诺，OpenCRHTracker 有匿名配额
//   （响应头 x-api-remain / x-api-cost / Retry-After），超限时返回 429。
//   请低频使用，勿用于商业场景。
// ============================================================================

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/app_settings_service.dart';

part '../services/train_search/train_search_models.dart';
part '../services/train_search/train_search_api.dart';
part '../services/train_search/train_search_parsers.dart';
part '../services/train_search/train_search_widgets.dart';

// ───────────────────────────────────────────────────────────────────────────
// 页面
// ───────────────────────────────────────────────────────────────────────────

class TrainSearchPage extends StatefulWidget {
  const TrainSearchPage({super.key});

  @override
  State<TrainSearchPage> createState() => _TrainSearchPageState();
}

class _TrainSearchPageState extends State<TrainSearchPage> {
  final AppSettingsService _settings = AppSettingsService.instance;
  final _RailwayApi _api = _RailwayApi.instance;

  _SearchMode _mode = _SearchMode.stationToStation;

  late DateTime _date;
  final TextEditingController _fromCtrl = TextEditingController();
  final TextEditingController _toCtrl = TextEditingController();
  final TextEditingController _trainNoCtrl = TextEditingController();
  final TextEditingController _emuCtrl = TextEditingController();


  bool _loading = false;
  String? _error;
  String _notice = '';

  /// 记录「已经成功查过一次」的查询项。
  ///
  /// ⚠️ 用来区分两种完全不同的状态——**没查过** 和 **查了但没结果**。
  ///    以前两者都用「结果为空」来判断，于是「北京南→上海虹桥 当天确实没车」
  ///    会显示成「选择出发/到达站后点击查询」，等于暗示用户还没点查询，
  ///    既误导又把真正的结论（没车）藏了起来。
  ///    普速模式车厢/机车是两个分栏，key 要带上分栏，否则会互相污染。
  final Set<String> _queried = <String>{};

  String get _queryKey =>
      _mode == _SearchMode.ordinary ? 'ordinary|${_psTab.name}' : _mode.name;

  List<_TrainRun> _runs = <_TrainRun>[];
  _TrainDetail? _detail;
  List<_StationTrain> _stationTrains = <_StationTrain>[];

  // 车组号查询结果
  _EmuResult? _emuResult;
  // 车站大屏查询结果
  _BoardResult? _boardResult;
  /// 大屏「加载更多」进行中
  bool _boardLoadingMore = false;
  /// 大屏时段筛选：0 = 全部，1~4 对应 _kBoardSlots
  int _boardSlot = 0;
  // 普速配属：车厢 / 机车是两个独立分栏，各有各的关键字、维度、结果
  _PsTab _psTab = _PsTab.car;
  final TextEditingController _psCarCtrl = TextEditingController();
  final TextEditingController _psLocoCtrl = TextEditingController();
  String _psCarType = 'train';
  String _psLocoType = 'model';
  _CarPart? _psCarResult;
  _LocoPart? _psLocoResult;
  /// 普速「加载更多」进行中
  bool _psLoadingMore = false;

  bool _stationsReady = false;

  // 站-站结果筛选 / 强制刷新
  bool _onlyHighSpeed = false;
  bool _onlyAvailable = false;
  bool _forceRefresh = false;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_refresh);
    _settings.load();
    _date = _today();
    _loadStations();
  }

  @override
  void dispose() {
    _settings.removeListener(_refresh);
    _fromCtrl.dispose();
    _toCtrl.dispose();
    _trainNoCtrl.dispose();
    _emuCtrl.dispose();
    _psCarCtrl.dispose();
    _psLocoCtrl.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _loadStations() async {
    try {
      await _api.loadStations();
      if (mounted) setState(() => _stationsReady = true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _notice = '车站字典加载失败，站名联想不可用：$e';
        });
      }
    }
  }

  // ── 查询 ────────────────────────────────────────────────────────────────

  Future<void> _pickDate() async {
    final first = _today();
    final picked = await showDatePicker(
      context: context,
      locale: const Locale('zh', 'CN'),
      initialDate: _date,
      firstDate: first,
      lastDate: first.add(const Duration(days: 14)), // 预售期 15 天
      helpText: '选择乘车日期',
    );
    if (picked != null) setState(() => _date = picked);
  }

  void _setDateOffset(int days) {
    setState(() => _date = _today().add(Duration(days: days)));
  }

  Future<void> _search() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _runs = <_TrainRun>[];
      _detail = null;
      _stationTrains = <_StationTrain>[];
      _emuResult = null;
      // 只清当前栏：切到另一栏时之前的结果还在，不需要重查
      if (_psTab == _PsTab.car) {
        _psCarResult = null;
      } else {
        _psLocoResult = null;
      }
      _psLoadingMore = false;
      _boardResult = null;
      _boardSlot = 0;
      _boardLoadingMore = false;
    });

    try {
      switch (_mode) {
        case _SearchMode.stationToStation:
          final from = _requireStation(_fromCtrl.text, '出发站');
          final to = _requireStation(_toCtrl.text, '到达站');
          if (from.code == to.code) throw Exception('出发站与到达站不能相同');
          final list = await _api.queryByStationPair(
            from.code,
            to.code,
            _date,
            forceRefresh: _forceRefresh,
          );
          if (mounted) setState(() => _runs = list);
          break;

        case _SearchMode.trainNo:
          final code = _trainNoCtrl.text.trim().toUpperCase();
          if (code.isEmpty) throw Exception('请输入车次，如 G101、Z155');
          final d = await _api.queryByTrainNo(
            code,
            _date,
            forceRefresh: _forceRefresh,
          );
          if (mounted) setState(() => _detail = d);
          break;

        case _SearchMode.emuNo:
          final kw = _emuCtrl.text.trim();
          if (kw.isEmpty) {
            throw Exception('请输入车组号，如 CR400AF-2031、CRH2A-2001');
          }
          final r = await _api.queryEmu(
            kw,
            forceRefresh: _forceRefresh,
          );
          if (mounted) setState(() => _emuResult = r);
          break;

        case _SearchMode.ordinary:
          // 车厢 / 机车是两个独立分栏，只查当前栏，各存各的结果
          if (_psTab == _PsTab.car) {
            final kw = _psCarCtrl.text.trim();
            if (kw.isEmpty) throw Exception('请输入查询关键字');
            final r = await _api.queryCarStock(
              kw,
              _psCarType,
              forceRefresh: _forceRefresh,
            );
            if (mounted) {
              setState(() {
                _psCarResult = r;
              });
            }
          } else {
            final kw = _psLocoCtrl.text.trim();
            if (kw.isEmpty) throw Exception('请输入查询关键字');
            final r = await _api.queryLocoStock(
              kw,
              _psLocoType,
              forceRefresh: _forceRefresh,
            );
            if (mounted) {
              setState(() {
                _psLocoResult = r;
              });
            }
          }
          break;

        case _SearchMode.station:
          // 车站大屏走 OpenCRHTracker，
          // 失败时回退 12306 原接口，保证功能不空。
          final kw = _fromCtrl.text.trim();
          if (kw.isEmpty) throw Exception('请输入车站名');
          try {
            final board = await _api.queryStationBoard(
              kw,
              forceRefresh: _forceRefresh,
            );
            if (mounted) setState(() => _boardResult = board);
          } catch (e) {
            final boardErr = _cleanErr(e);
            try {
              final st = _requireStation(kw, '车站');
              final list = await _api.queryByStation(
                st.code,
                _date,
                forceRefresh: _forceRefresh,
              );
              if (mounted) {
                setState(() => _stationTrains = list);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('大屏数据源不可用，已回退 12306：$boardErr'),
                    duration: const Duration(seconds: 4),
                  ),
                );
              }
            } catch (_) {
              throw Exception('$boardErr\n（12306 回退同样失败）');
            }
          }
          break;
      }
      // 能走到这里 = 查询成功，**包括「查到 0 条」**。
      // 标记一下，空态才能区分「还没查」和「查了但没结果」。
      // （抛异常的路径不会到这，那边由 _error 负责提示）
      if (mounted) setState(() => _queried.add(_queryKey));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _forceRefresh = false;
        });
      }
    }
  }

  _Station _requireStation(String text, String label) {
    final kw = text.trim();
    if (kw.isEmpty) throw Exception('请输入$label');
    final s = _api.findStation(kw);
    if (s == null) {
      throw Exception('未找到$label「$kw」，请从联想列表中选择');
    }
    return s;
  }

  // ── 车站大屏：翻页 / 时段筛选 ────────────────────────────────────────────

  /// 大屏「加载更多」：在现有结果上继续翻页，失败只提示不丢数据
  Future<void> _loadMoreBoard({bool auto = false}) async {
    final cur = _boardResult;
    if (cur == null || !cur.hasMore || _boardLoadingMore) return;
    if (mounted) setState(() => _boardLoadingMore = true);
    try {
      final more = await _api.queryStationBoard(
        cur.station,
        loadMore: true,
        // 滑到底自动续拉时一次只加一页，手动点按钮一次翻 _kBoardMorePages 页
        morePages: auto ? 1 : _kBoardMorePages,
        previous: cur,
      );
      if (mounted) setState(() => _boardResult = more);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('加载更多失败：${_cleanErr(e)}'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _boardLoadingMore = false);
    }
  }

  /// 大屏可见列表（按时段过滤，原始数据不变）
  List<_BoardItem> _visibleBoardItems(_BoardResult b) {
    if (_boardSlot <= 0) return b.items;
    final from = (_boardSlot - 1) * 6;
    final to = from + 6;
    return b.items.where((t) {
      final h = t.hourOfDay;
      return h >= from && h < to;
    }).toList();
  }

  /// 站-站结果的可见列表（按筛选条件过滤，原始数据不变）
  List<_TrainRun> get _visibleRuns {
    return _runs.where((r) {
      if (_onlyHighSpeed) {
        final c = r.trainCode.toUpperCase();
        if (!(c.startsWith('G') || c.startsWith('D') || c.startsWith('C'))) {
          return false;
        }
      }
      if (_onlyAvailable) {
        final any = r.seats.any((s) =>
            s.value != '无' &&
            s.value.isNotEmpty &&
            int.tryParse(s.value) != 0);
        if (!any) return false;
      }
      return true;
    }).toList();
  }

  /// 打开车次经停详情页；trainNo 非空时可省一次车次检索请求
  void _openTrainDetail(String trainCode, String? trainNo) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _TrainDetailPage(
        trainCode: trainCode,
        trainNo: trainNo,
        date: _date,
      ),
    ));
  }

  /// 从车次详情 / 车组号结果里点车组号：
  /// 进下一级页面查这个车组，当前页结果原样保留，返回即可回到来处
  void _openEmuSearch(String emuNo) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _EmuSearchPage(initialKeyword: emuNo),
      ),
    );
  }

  Widget _buildFilterRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
      child: Row(
        children: [
          FilterChip(
            label: const Text('只看高铁动车'),
            visualDensity: VisualDensity.compact,
            selected: _onlyHighSpeed,
            onSelected: (v) => setState(() => _onlyHighSpeed = v),
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('只看有票'),
            visualDensity: VisualDensity.compact,
            selected: _onlyAvailable,
            onSelected: (v) => setState(() => _onlyAvailable = v),
          ),
        ],
      ),
    );
  }

  // ── 构建 ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('列车数据查询'),
        actions: [],
      ),
      body: Column(
        children: [
          _buildModeSwitch(),
          // 车组号查的是历史担当记录、普速查的是配属档案，
          // 两者数据源都不接受日期，摆个日期选择器容易让人以为结果被按日期过滤了
          if (_mode != _SearchMode.emuNo && _mode != _SearchMode.ordinary)
            _buildDateRow(),
          _buildInputArea(),
          if (_mode == _SearchMode.stationToStation) _buildFilterRow(),
          _buildSearchButton(),
          const Divider(height: 1),
          Expanded(child: _buildResult()),
        ],
      ),
    );
  }

  Widget _buildModeSwitch() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: SegmentedButton<_SearchMode>(
        segments: const <ButtonSegment<_SearchMode>>[
          ButtonSegment(
            value: _SearchMode.stationToStation,
            icon: Icon(Icons.swap_horiz),
            label: Text('站-站'),
          ),
          ButtonSegment(
            value: _SearchMode.trainNo,
            icon: Icon(Icons.train),
            label: Text('车次'),
          ),
          ButtonSegment(
            value: _SearchMode.emuNo,
            icon: Icon(Icons.directions_railway),
            label: Text('车组号'),
          ),
          ButtonSegment(
            value: _SearchMode.station,
            icon: Icon(Icons.place),
            label: Text('车站'),
          ),
          ButtonSegment(
            value: _SearchMode.ordinary,
            icon: Icon(Icons.railway_alert),
            label: Text('普速'),
          ),
        ],
        selected: <_SearchMode>{_mode},
        onSelectionChanged: (s) => setState(() {
          _mode = s.first;
          _error = null;
          _notice = '';
          _runs = <_TrainRun>[];
          _detail = null;
          _stationTrains = <_StationTrain>[];
          _emuResult = null;
          _psCarResult = null;
          _psLocoResult = null;
          _boardResult = null;
          // 换了查询方式 = 回到「还没查」的状态，之前的标记不该留着
          _queried.clear();
        }),
      ),
    );
  }

  Widget _buildDateRow() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          OutlinedButton.icon(
            onPressed: _pickDate,
            icon: const Icon(Icons.calendar_month, size: 18),
            label: Text(_fmtCn(_date)),
          ),
          const SizedBox(width: 8),
          _quickChip('今天', 0),
          const SizedBox(width: 6),
          _quickChip('明天', 1),
          const SizedBox(width: 6),
          _quickChip('后天', 2),
        ],
      ),
    );
  }

  Widget _quickChip(String text, int offset) {
    final d = _today().add(Duration(days: offset));
    final selected =
        _date.year == d.year && _date.month == d.month && _date.day == d.day;
    return ActionChip(
      label: Text(text),
      visualDensity: VisualDensity.compact,
      backgroundColor: selected ? Theme.of(context).colorScheme.primaryContainer : null,
      onPressed: () => _setDateOffset(offset),
    );
  }

  Widget _buildInputArea() {
    switch (_mode) {
      case _SearchMode.stationToStation:
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _StationInput(
                  controller: _fromCtrl,
                  hint: '出发站',
                  stations: _api.stations,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: IconButton(
                  icon: const Icon(Icons.swap_horiz),
                  tooltip: '交换',
                  onPressed: () {
                    final t = _fromCtrl.text;
                    _fromCtrl.text = _toCtrl.text;
                    _toCtrl.text = t;
                  },
                ),
              ),
              Expanded(
                child: _StationInput(
                  controller: _toCtrl,
                  hint: '到达站',
                  stations: _api.stations,
                ),
              ),
            ],
          ),
        );

      case _SearchMode.trainNo:
        return _singleField(
          controller: _trainNoCtrl,
          hint: '车次，如 G101 / D3106 / Z155',
          icon: Icons.train,
        );

      case _SearchMode.emuNo:
        return _singleField(
          controller: _emuCtrl,
          hint: '车组号或车次，如 CR400AF-2031 / CRH2A-2001 / G83',
          icon: Icons.directions_railway,
        );

      case _SearchMode.station:
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: _StationInput(
            controller: _fromCtrl,
            hint: '车站，如 北京南 / 上海虹桥',
            stations: _api.stations,
          ),
        );

      case _SearchMode.ordinary:
        return _buildPasInputArea();
    }
    return const SizedBox.shrink();
  }

  /// 普速查询的输入区：车厢 / 机车两个分栏，
  /// 各自有关键字与「按什么维度查」，互不干扰
  Widget _buildPasInputArea() {
    final isCar = _psTab == _PsTab.car;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SegmentedButton<_PsTab>(
            segments: const <ButtonSegment<_PsTab>>[
              ButtonSegment(
                value: _PsTab.car,
                icon: Icon(Icons.airline_seat_recline_normal, size: 18),
                label: Text('车厢'),
              ),
              ButtonSegment(
                value: _PsTab.loco,
                icon: Icon(Icons.directions_railway, size: 18),
                label: Text('机车'),
              ),
            ],
            selected: <_PsTab>{_psTab},
            onSelectionChanged: (s) => setState(() {
              _psTab = s.first;
              _error = null;
            }),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              const Text('按', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 6),
              SizedBox(
                width: 124,
                height: 48,
                child: _psTypeDropdown(
                  value: isCar ? _psCarType : _psLocoType,
                  options: isCar ? _kPasCarTypes : _kPasLocoTypes,
                  onChanged: (v) => setState(() {
                    if (isCar) {
                      _psCarType = v;
                    } else {
                      _psLocoType = v;
                    }
                  }),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: isCar ? _psCarCtrl : _psLocoCtrl,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    prefixIcon: Icon(
                      isCar
                          ? Icons.airline_seat_recline_normal
                          : Icons.directions_railway,
                      size: 20,
                    ),
                    hintText: isCar
                        ? (_kPasCarHint[_psCarType] ?? '关键字')
                        : (_kPasLocoHint[_psLocoType] ?? '关键字'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 6, 2, 0),
            child: Text(
              isCar
                  ? '数据源 cr400bf.passearch.info　按「${_kPasCarTypes[_psCarType]}」查'
                  : '数据源 loco.passearch.info　按「${_kPasLocoTypes[_psLocoType]}」查'
                      '${_psLocoTypeNote(_psLocoType)}',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 查询维度下拉。
  ///
  /// ⚠️ 别给 TextStyle 硬编码而不写 color：DropdownButton 会用这个 style 覆盖主题色，
  ///    深色模式下就变成黑底黑字、一个字都看不见。颜色一律从 colorScheme 取。
  ///    同理 dropdownColor 也得给，否则弹出层是默认纸白、深色模式下看不清。
  Widget _psTypeDropdown({
    required String value,
    required Map<String, String> options,
    required void Function(String) onChanged,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          isDense: true,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          dropdownColor: cs.surface,
          icon: Icon(Icons.arrow_drop_down, color: cs.onSurfaceVariant),
          items: options.entries
              .map(
                (e) => DropdownMenuItem<String>(
                  value: e.key,
                  child: Text(
                    e.value,
                    style: TextStyle(fontSize: 13, color: cs.onSurface),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }

  Widget _singleField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool enabled = true,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: TextField(
        controller: controller,
        enabled: enabled,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _search(),
        decoration: InputDecoration(
          prefixIcon: Icon(icon),
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  Widget _buildSearchButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _loading ? null : _search,
              icon: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search),
              label: const Text('查询'),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: '忽略缓存重新查询',
            icon: const Icon(Icons.refresh),
            onPressed: _loading
                ? null
                : () {
                    _forceRefresh = true;
                    _search();
                  },
          ),
        ],
      ),
    );
  }

  Widget _buildResult() {
    final hasResult = _runs.isNotEmpty ||
        _detail != null ||
        _stationTrains.isNotEmpty ||
        _emuResult != null ||
        _boardResult != null;

    if (_notice.isNotEmpty && !hasResult) {
      return _center(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, size: 40, color: Colors.orange),
          const SizedBox(height: 8),
          Text(_notice, textAlign: TextAlign.center),
          TextButton(
            onPressed: () {
              setState(() => _notice = '');
              _loadStations();
            },
            child: const Text('重试'),
          ),
        ],
      ));
    }

    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return _center(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 40, color: Colors.redAccent),
          const SizedBox(height: 8),
          // SelectableText：错误信息里可能带排查用的细节，方便长按复制
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: SelectableText(_error!, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 8),
          const Text(
            '数据可能没有收录',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ));
    }

    switch (_mode) {
      case _SearchMode.emuNo:
        final r = _emuResult;
        if (r == null) {
          return _empty('输入车组号或车次后点击查询\n'
              '如 CR400AF-2031 / CRH2A-2001 / G83');
        }
        return _emuResultView(r);

      case _SearchMode.ordinary:
        if (_psTab == _PsTab.car) {
          final r = _psCarResult;
          if (r == null) {
            return _empty('输入车次或车型后点击查询\n如 Z155 / YW25T');
          }
          return _psCarListView(r);
        }
        final r = _psLocoResult;
        if (r == null) {
          return _empty('输入机车型号或配属段后点击查询\n如 HXD3D / 京局京段');
        }
        return _psLocoListView(r);

      case _SearchMode.stationToStation:
        final list = _visibleRuns;
        if (_runs.isEmpty) {
          // ⚠️ 「没查过」和「查了但没车」必须分开说。
          //    同一个 _runs.isEmpty 覆盖了两种状态，一律显示
          //    「选择出发/到达站后点击查询」会让人以为查询根本没生效。
          return _queried.contains('stationToStation')
              ? _stationPairEmpty()
              : _empty('选择出发/到达站后点击查询');
        }
        if (list.isEmpty) return _empty('当前筛选条件下没有车次');
        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: list.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (_, i) => _runCard(list[i]),
        );

      case _SearchMode.trainNo:
        if (_detail == null) return _empty('输入车次后点击查询');
        return _detailView(_detail!);

      case _SearchMode.station:
        final board = _boardResult;
        if (board != null) return _boardView(board);
        if (_stationTrains.isNotEmpty) {
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: _stationTrains.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (_, i) => _stationTrainCard(_stationTrains[i]),
          );
        }
        // 同理：查过了就别再说「输入车站后点击查询」，直接给结论
        return _queried.contains('station')
            ? _empty('「${_fromCtrl.text.trim()}」当日没有查到停靠车次')
            : _empty('输入车站后点击查询');
    }
    return const SizedBox.shrink();
  }

  Widget _center(Widget child) => Center(child: child);

  Widget _empty(String text) => Center(
        child: Text(text, style: const TextStyle(color: Colors.grey)),
      );

  /// 站-站「查过了，但当天确实没车」的空态。
  ///
  /// ⚠️ 不能复用那句「选择出发/到达站后点击查询」——用户明明已经查过了，
  ///    再让他去点查询，只会让人以为查询没生效，还把真正的结论藏了起来。
  ///    这里把三件事说清楚：**查了什么 → 结论是什么 → 还能怎么办**，
  ///    并直接给出换日期的入口（超出预售期是最常见的原因）。
  Widget _stationPairEmpty() {
    final cs = Theme.of(context).colorScheme;
    final from = _fromCtrl.text.trim();
    final to = _toCtrl.text.trim();
    final hasPair = from.isNotEmpty && to.isNotEmpty;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.train_outlined, size: 40, color: cs.onSurfaceVariant),
            const SizedBox(height: 10),
            if (hasPair)
              Text(
                '$from → $to',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600),
              ),
            const SizedBox(height: 4),
            Text(
              '${_fmtCn(_date)} 没有查到车次',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            Text(
              '· 该日期可能超出预售期（12306 通常预售 15 天）\n'
              '· 两站之间可能没有直达列车，试试分段中转\n'
              '· 也可以换个日期再查',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                OutlinedButton(
                  onPressed: _loading
                      ? null
                      : () {
                          _setDateOffset(-1);
                          _search();
                        },
                  child: const Text('前一天'),
                ),
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: _loading
                      ? null
                      : () {
                          _setDateOffset(1);
                          _search();
                        },
                  child: const Text('后一天'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── 结果卡片 ────────────────────────────────────────────────────────────

  Widget _runCard(_TrainRun r) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  r.trainCode,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    r.date,
                    style: TextStyle(fontSize: 11, color: cs.onSecondaryContainer),
                  ),
                ),
                const Spacer(),
                Text('历时 ${r.duration}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.departTime,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    SizedBox(
                      width: 90,
                      child: Text(r.fromStation,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                Expanded(
                  child: Column(
                    children: [
                      const Icon(Icons.arrow_right_alt, color: Colors.grey),
                      SizedBox(width: 70, child: const Divider(thickness: 1)),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(r.arriveTime,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    SizedBox(
                      width: 90,
                      child: Text(r.toStation,
                          textAlign: TextAlign.end,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ],
            ),
            if (r.seats.isNotEmpty) ...[
              const Divider(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: r.seats.map((s) {
                  final has = s.value != '无' && s.value.isNotEmpty;
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: has
                          ? cs.primaryContainer.withOpacity(0.6)
                          : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${s.label} ',
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          TextSpan(
                            text: s.value.isEmpty ? '--' : s.value,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: has ? cs.primary : Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _openTrainDetail(r.trainCode, r.trainNo),
                icon: const Icon(Icons.list_alt, size: 16),
                label: const Text('经停时刻表'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailView(_TrainDetail d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _buildTrainDetailBody(
            context,
            d,
            // 点车组号 → 跳到车组号查询，看它的完整交路
            onPickEmu: (emuNo) => _openEmuSearch(emuNo),
            // 普速车次才有车厢配属可查（动车组的车体不在这个数据源里）
            onPickCarStock: d.isEmu
                ? null
                : () => _openPsPage(context, d.trainCode),
          ),
        ),
        _trainDetailFooter(context, d),
      ],
    );
  }

  Widget _stationTrainCard(_StationTrain t) {
    return Card(
      child: ListTile(
        dense: true,
        leading: SizedBox(
          width: 66,
          child: Text(
            t.trainCode,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        title: Text(
          '${t.startStation} → ${t.endStation}',
          style: const TextStyle(fontSize: 13),
        ),
        subtitle: Text(
          [t.arriveTime, t.departTime]
              .where((e) => e.isNotEmpty)
              .join(' / '),
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        trailing: const Icon(Icons.chevron_right, color: Colors.grey),
        onTap: () => _openTrainDetail(t.trainCode, null),
      ),
    );
  }

  // ── 车组号结果 ──────────────────────────────────────────────────────────

  Widget _emuResultView(_EmuResult r) {
    final cs = Theme.of(context).colorScheme;
    final profiles = r.profiles;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
          child: Text(
            '${r.keyword.toUpperCase()}　担当明细 ${r.records.length} 条'
            '（社区数据源历史数据，不按日期过滤）',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
        ),
        ...profiles.map((p) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildEmuProfileCard(context, p),
            )),
        if (r.records.isEmpty && profiles.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('暂无担当记录', textAlign: TextAlign.center),
          ),
        ...r.records.map(_emuRecordCard),
        if (r.errors.isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              '部分数据源未返回：\n${r.errors.join('\n')}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
        ],
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text(
            '数据来源 rail.re（Arnie97/moerail）与 '
            'OpenCRHTracker（lihugang/OpenCRHTracker），'
            '均为社区维护，仅供参考。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ),
      ],
    );
  }

  Widget _emuProfileCard(_EmuProfile p) =>
      _buildEmuProfileCard(context, p);

  // ── 普速配属结果（车厢 / 机车各一个列表）────────────────────────────────

  /// 普速「加载更多」：只翻当前栏
  Future<void> _loadMorePs() async {
    if (_psLoadingMore) return;
    if (_psTab == _PsTab.car) {
      final cur = _psCarResult;
      if (cur == null || !cur.hasMore) return;
      if (mounted) setState(() => _psLoadingMore = true);
      try {
        final more = await _api.queryCarStock(
          _psCarCtrl.text.trim(),
          cur.type,
          loadMore: true,
          previous: cur,
        );
        if (mounted) setState(() => _psCarResult = more);
      } catch (e) {
        if (mounted) _psToast('加载更多失败：${_cleanErr(e)}');
      } finally {
        if (mounted) setState(() => _psLoadingMore = false);
      }
      return;
    }
    final cur = _psLocoResult;
    if (cur == null || !cur.hasMore) return;
    if (mounted) setState(() => _psLoadingMore = true);
    try {
      final more = await _api.queryLocoStock(
        _psLocoCtrl.text.trim(),
        cur.type,
        loadMore: true,
        previous: cur,
      );
      if (mounted) setState(() => _psLocoResult = more);
    } catch (e) {
      if (mounted) _psToast('加载更多失败：${_cleanErr(e)}');
    } finally {
      if (mounted) setState(() => _psLoadingMore = false);
    }
  }

  void _psToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  /// 列表共用的「加载更多 / 到底了 / 加载失败」尾部
  ///
  /// ⚠️ [moreError] 非空时必须把翻页失败的原因摆出来。以前失败被静默吞成
  ///    hasMore = false，界面直接显示「已全部加载」，用户只会以为「点了没反应」。
  /// [loaded] / [total] 用来显示进度：这两个站一页只有 50 条，
  ///    8879 条的车厢结果不标进度的话，用户根本不知道还要点多少次。
  Widget _psLoadMoreFooter(
    bool hasMore, {
    int loaded = 0,
    int? total,
    String? moreError,
  }) {
    final cs = Theme.of(context).colorScheme;
    final progress =
        total == null ? '已加载 $loaded 条' : '已加载 $loaded / 共 $total 条';

    if (moreError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          children: <Widget>[
            Text(
              moreError,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: cs.error),
            ),
            const SizedBox(height: 6),
            if (hasMore)
              OutlinedButton.icon(
                onPressed: _psLoadingMore ? null : _loadMorePs,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              )
            else
              Text(progress,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      );
    }

    if (!hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: Text('已全部加载　$progress',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: _psLoadingMore
          ? const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : Column(
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: _loadMorePs,
                  icon: const Icon(Icons.expand_more, size: 18),
                  label: const Text('加载更多'),
                ),
                const SizedBox(height: 4),
                Text(progress,
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
    );
  }

  Widget _psCarListView(_CarPart r) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 16),
      children: <Widget>[
        _psListHeader(
          count: r.items.length,
          total: r.total,
          dim: _kPasCarTypes[r.type] ?? r.type,
          error: r.error ?? r.moreError,
          color: cs.primary,
        ),
        if (r.items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text('无车厢配属记录',
                  style: TextStyle(fontSize: 13, color: Colors.grey)),
            ),
          ),
        ...List<Widget>.generate(
          r.items.length,
          (i) => _buildCarCard(context, r.items[i], index: i + 1),
        ),
        if (r.items.isNotEmpty)
          _psLoadMoreFooter(
            r.hasMore,
            loaded: r.items.length,
            total: r.total,
            moreError: r.moreError,
          ),
      ],
    );
  }

  Widget _psLocoListView(_LocoPart r) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 16),
      children: <Widget>[
        _psListHeader(
          count: r.items.length,
          total: r.total,
          dim: _kPasLocoTypes[r.type] ?? r.type,
          error: r.error ?? r.moreError,
          color: cs.tertiary,
        ),
        if (r.items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text('无机车配属记录',
                  style: TextStyle(fontSize: 13, color: Colors.grey)),
            ),
          ),
        ...List<Widget>.generate(
          r.items.length,
          (i) => _buildLocoCard(context, r.items[i], index: i + 1),
        ),
        if (r.items.isNotEmpty)
          _psLoadMoreFooter(
            r.hasMore,
            loaded: r.items.length,
            total: r.total,
            moreError: r.moreError,
          ),
      ],
    );
  }

  /// 列表顶部：条数 + 命中维度 + 错误
  Widget _psListHeader({
    required int count,
    required int? total,
    required String dim,
    required String? error,
    required Color color,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.filter_alt_outlined, size: 14, color: color),
              const SizedBox(width: 5),
              Text(
                '按「$dim」查',
                style:
                    TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                total != null && total > count
                    ? '共 $total 条 · 已加载 $count'
                    : '$count 条',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              // SelectableText：翻页诊断信息很长，得能长按复制出来看/发给别人
              child: SelectableText(error,
                  style: const TextStyle(fontSize: 11, color: Colors.orange)),
            ),
        ],
      ),
    );
  }

  Widget _emuRecordCard(_EmuRecord r) => _buildEmuRecordCard(
        context,
        r,
        (code) => _openTrainDetail(code, null),
        onPickEmu: _openEmuSearch,
      );

  // ── 车站大屏 ────────────────────────────────────────────────────────────

  Widget _boardView(_BoardResult b) {
    final items = _visibleBoardItems(b);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: <Widget>[
              const Icon(Icons.dashboard_outlined, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${b.station}　${b.countLabel}',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              Text(
                _fmtCn(_date),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
        // 时段筛选：数据拿不全时，用它把范围压回单次上限以内
        if (b.truncated || b.items.length >= _kBoardPageSize)
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _kBoardSlots.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) => ChoiceChip(
                label: Text(
                  _kBoardSlots[i],
                  style: const TextStyle(fontSize: 12),
                ),
                selected: _boardSlot == i,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onSelected: (_) => setState(() => _boardSlot = i),
              ),
            ),
          ),
        if (b.notes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              b.notes.join('；'),
              style: const TextStyle(fontSize: 11, color: Colors.orange),
            ),
          ),
        if (b.truncated)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Icon(Icons.info_outline, size: 14, color: Colors.orange),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    b.canLoadMore
                        ? '数据源单次最多返回 $_kBoardPageSize 条，已分 ${b.pages} 页'
                            '取到 ${b.items.length} 趟，可继续加载更多'
                        : '数据源单次最多返回 $_kBoardPageSize 条且未支持分页，'
                            '${b.items.length} 趟可能不完整，建议切换时段查看',
                    style: const TextStyle(fontSize: 11, color: Colors.orange),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: items.length + 1,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (_, i) =>
                i >= items.length ? _boardFooter(b) : _boardCard(items[i]),
          ),
        ),
      ],
    );
  }

  /// 大屏列表尾部：加载中 / 加载更多 / 到底了
  Widget _boardFooter(_BoardResult b) {
    if (_boardLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (b.canLoadMore) {
      // 滑到底自动续拉一页，避免用户手动点太多次
      if (_kBoardAutoLoadOnScrollEnd) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _loadMoreBoard(auto: true));
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: OutlinedButton.icon(
          onPressed: _loadMoreBoard,
          icon: const Icon(Icons.expand_more, size: 18),
          label: Text(
            '加载更多（已 ${b.items.length}'
            '${b.total != null ? ' / ${b.total}' : ''} 趟）',
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Text(
          b.truncated
              ? '已到数据源上限，切换时段可看其余车次'
              : '已显示全部 ${b.items.length} 趟',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ),
    );
  }

  Widget _boardCard(_BoardItem t) {
    final cs = Theme.of(context).colorScheme;
    final time = [t.arriveTime, t.departTime]
        .where((e) => e.isNotEmpty)
        .join(' / ');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // 点击车次 → 进与「车次查询」同款的经停时刻表页
        onTap: t.trainCode.isEmpty
            ? null
            : () => _openTrainDetail(t.trainCode, null),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 58,
                child: Text(
                  time.isEmpty ? '—' : time,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SizedBox(
                width: 66,
                child: Text(
                  t.trainCode,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '${t.startStation} → ${t.endStation}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    if (t.models.isNotEmpty)
                      Text(
                        t.models.join(' / '),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                  ],
                ),
              ),
              if (t.platform.isNotEmpty)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${t.platform}站台',
                    style: TextStyle(fontSize: 11, color: cs.onPrimaryContainer),
                  ),
                ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────────
// 车站联想输入框
// ───────────────────────────────────────────────────────────────────────────

class _StationInput extends StatefulWidget {
  final TextEditingController controller;
  final String hint;
  final List<_Station> stations;

  const _StationInput({
    required this.controller,
    required this.hint,
    required this.stations,
  });

  @override
  State<_StationInput> createState() => _StationInputState();
}

class _StationInputState extends State<_StationInput> {
  final FocusNode _focus = FocusNode();
  List<_Station> _suggestions = <_Station>[];
  bool _showPanel = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// 失焦 → 收起候选面板
  ///
  /// ⚠️ 这里**绝不能同步 setState**。点击候选项的那一瞬间 TextField 会先失焦，
  ///    如果此刻立刻把面板移出 widget 树，ListTile 的 GestureDetector 随即被
  ///    dispose，等手指抬起（pointer up）时已经没人接收这个 tap 了 ——
  ///    现象就是「点了候选项，面板消失了，输入框却没被补全」。
  ///
  ///    最伤的正是拼音简写（bjx → 北京西）和电报码（BXP）这两个场景：
  ///    用户没法用输入法直接打出中文站名，只能靠点候选项补全，
  ///    一点没反应，这功能就等于废了。
  ///
  ///    改成延后一小会儿再收：正常选中时 _pick() 已经立刻收掉了，
  ///    这段延时只在「点输入框外面的空白」时才真正起作用，肉眼无感。
  void _onFocusChange() {
    if (_focus.hasFocus || !mounted) return;
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      if (mounted && !_focus.hasFocus && _showPanel) {
        setState(() => _showPanel = false);
      }
    });
  }

  /// 打分：不管输中文、拼音、简写还是电报码，想要的站都排在最前面
  ///
  /// ⚠️ 旧版是四选一的 if 链，而且**先扫到谁就先列谁**（按车站字典原始顺序）。
  ///    于是输 bjx 时，前面压着一堆同样以 bj 开头的站，真正的「北京西」被挤到
  ///    下面要翻；输电报码 BX（不完整）更是直接匹配不到，候选列表是空的。
  ///    现在按匹配质量打分，越精准越靠前。
  int _scoreOf(_Station s, String q, String upper) {
    final name = s.name;
    final code = s.code.toUpperCase();
    final initials = s.initials.toLowerCase();
    final pinyin = s.pinyin.toLowerCase();
    // 完全命中：站名 / 电报码 / 全拼三者任一完全相同
    if (name == q || code == upper || pinyin == q) return 100;
    if (initials == q) return 95; // 简写全等（bjx → 北京西，bj → 北京）
    if (code.startsWith(upper)) return 90; // 电报码前缀（BX → BXP）
    if (name.startsWith(q)) return 85; // 站名前缀（北京 → 北京西）
    if (pinyin.startsWith(q)) return 80; // 全拼前缀（beijing → 北京西）
    if (initials.startsWith(q)) return 70; // 简写前缀（bj → 北京西…）
    if (name.contains(q)) return 50; // 站名包含
    if (code.contains(upper)) return 40; // 电报码包含
    if (pinyin.contains(q)) return 30; // 全拼包含
    // ⚠️ 为什么「简写全等」(95) 要压过「电报码前缀」(90)：
    //    输 bj 时，北京北(BJB)、北京(BJP) 的电报码都以 BJ 开头，
    //    按电报码优先就会把「北京北」顶到第一，而用户想打的其实是「北京」。
    //    简写是最常用的输入方式，精确命中时理应排在最前。
    return 0;
  }

  void _onChanged(String v) {
    final q = v.trim().toLowerCase();
    if (q.isEmpty) {
      setState(() {
        _suggestions = <_Station>[];
        _showPanel = false;
      });
      return;
    }
    final upper = q.toUpperCase();
    final scored = <MapEntry<_Station, int>>[];
    for (final s in widget.stations) {
      final score = _scoreOf(s, q, upper);
      if (score > 0) scored.add(MapEntry<_Station, int>(s, score));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    final res = scored.take(20).map((e) => e.key).toList();
    setState(() {
      _suggestions = res;
      _showPanel = res.isNotEmpty;
    });
  }

  /// 选中候选项 → 补全输入框
  ///
  /// ⚠️ 光设 controller.text 不够：selection 不同步的话光标还停在原处，
  ///    接着再输入就把刚补好的站名打乱了，所以连光标一起设到末尾。
  ///    另外必须同步清掉 _suggestions —— 程序改 text 不会触发 onChanged，
  ///    留着旧列表的话，下次聚焦会闪出一堆已经不相关的候选。
  void _pick(_Station s) {
    widget.controller.value = TextEditingValue(
      text: s.name,
      selection: TextSelection.collapsed(offset: s.name.length),
    );
    setState(() {
      _suggestions = <_Station>[];
      _showPanel = false;
    });
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: widget.controller,
          focusNode: _focus,
          textInputAction: TextInputAction.next,
          onChanged: _onChanged,
          onSubmitted: (_) => setState(() => _showPanel = false),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.location_on_outlined),
            hintText: widget.hint,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_showPanel)
          Material(
            elevation: 3,
            borderRadius: BorderRadius.circular(6),
            clipBehavior: Clip.antiAlias,
            child: Container(
              constraints: const BoxConstraints(maxHeight: 180),
              decoration: BoxDecoration(
                border: Border.all(color: cs.outlineVariant),
                borderRadius: BorderRadius.circular(6),
              ),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: _suggestions.length,
                itemBuilder: (_, i) {
                  final s = _suggestions[i];
                  return ListTile(
                    dense: true,
                    title: Text(s.name),
                    // 副标题标出是怎么匹配上的（输 BXP 时能看到就是电报码命中）
                    subtitle: s.initials.isEmpty
                        ? null
                        : Text(
                            s.initials.toUpperCase(),
                            style: const TextStyle(fontSize: 11),
                          ),
                    trailing: Text(
                      s.code,
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    onTap: () => _pick(s),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}

/// 车组号 / 车次担当查询页。
///
/// 注意：这里**不按日期过滤**——车组担当来自 rail.re / OpenCRHTracker 的
/// 历史记录，数据源本身也不接受日期参数，硬套日期只会让结果看起来是空的。
class _EmuSearchPage extends StatefulWidget {
  /// 进入即查询的关键词（外部点车组号跳转时带上）
  final String initialKeyword;

  const _EmuSearchPage({this.initialKeyword = ''});

  @override
  State<_EmuSearchPage> createState() => _EmuSearchPageState();
}

class _EmuSearchPageState extends State<_EmuSearchPage> {
  final _RailwayApi _api = _RailwayApi.instance;
  late final TextEditingController _ctrl;
  bool _loading = false;
  String? _error;
  _EmuResult? _result;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialKeyword);
    if (widget.initialKeyword.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    final kw = _ctrl.text.trim();
    if (kw.isEmpty) {
      setState(() => _error = '请输入车组号或车次');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await _api.queryEmu(kw, forceRefresh: force);
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _cleanErr(e);
          _result = null;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 点车组号 → 再进一层，返回键一层层往上退
  void _drillDown(String emuNo) => _openEmuPage(context, emuNo);

  /// 点车次 → 进经停时刻表页。
  /// 尽量用这条担当记录本身的日期；早于今天的话 12306 查不到，退回今天。
  void _openTrain(String trainCode) {
    var date = _today();
    final r = _result;
    if (r != null) {
      for (final x in r.records) {
        if (x.trainCode != trainCode || x.date.length < 10) continue;
        final d = DateTime.tryParse(x.date.substring(0, 10));
        if (d != null) {
          date = d;
          break;
        }
      }
    }
    if (date.isBefore(_today())) date = _today();
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _TrainDetailPage(
          trainCode: trainCode,
          trainNo: null,
          date: date,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('车组号查询'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '忽略缓存重新查询',
            onPressed: _loading ? null : () => _load(force: true),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: TextField(
              controller: _ctrl,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _load(),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.directions_railway),
                hintText: '车组号或车次，如 CR400AF-2031 / G83',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.search),
                        onPressed: _load,
                      ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: Text(
              '担当记录为社区数据源的历史数据，不按日期过滤；'
              '点车组号继续下钻，点车次看经停时刻表。',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final cs = Theme.of(context).colorScheme;
    final r = _result;

    if (_loading && r == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.error),
          ),
        ),
      );
    }
    if (r == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '输入车组号或车次开始查询',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
          child: Text(
            '${r.keyword.toUpperCase()}　担当明细 ${r.records.length} 条'
            '（按日期倒序）',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
        ),
        ...r.profiles.map(
          (p) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _buildEmuProfileCard(context, p),
          ),
        ),
        ...r.records.map(
          (x) => _buildEmuRecordCard(context, x, _openTrain,
              onPickEmu: _drillDown),
        ),
        if (r.records.isEmpty && r.profiles.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '暂无担当记录',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ),
        if (r.errors.isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              '部分数据源未返回：\n${r.errors.join('\n')}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
        ],
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text(
            '数据来源 rail.re（Arnie97/moerail）与 '
            'OpenCRHTracker（lihugang/OpenCRHTracker），'
            '均为社区维护，仅供参考。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ),
      ],
    );
  }
}

/// 普速配属查询页：车厢（cr400bf.passearch.info）+ 机车（loco.passearch.info）
///
/// 两个站都只有 HTML 表格，靠硬解析取数；每页固定 50 条。
/// 两栏各自独立：关键字、维度、结果、翻页都分开。
class _PsSearchPage extends StatefulWidget {
  /// 进入即查询的关键词（从车次详情跳转时带车次号）
  final String initialKeyword;

  const _PsSearchPage({this.initialKeyword = ''});

  @override
  State<_PsSearchPage> createState() => _PsSearchPageState();
}

class _PsSearchPageState extends State<_PsSearchPage> {
  final _RailwayApi _api = _RailwayApi.instance;
  late final TextEditingController _carCtrl;
  late final TextEditingController _locoCtrl;
  _PsTab _tab = _PsTab.car;
  String _carType = 'train';
  String _locoType = 'model';
  bool _loading = false;
  bool _loadingMore = false;
  String? _carError;
  String? _locoError;
  _CarPart? _carResult;
  _LocoPart? _locoResult;

  @override
  void initState() {
    super.initState();
    _carCtrl = TextEditingController(text: widget.initialKeyword);
    _locoCtrl = TextEditingController();
    if (widget.initialKeyword.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  @override
  void dispose() {
    _carCtrl.dispose();
    _locoCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    final isCar = _tab == _PsTab.car;
    final kw = (isCar ? _carCtrl.text : _locoCtrl.text).trim();
    if (kw.isEmpty) {
      setState(() {
        if (isCar) {
          _carError = '请输入查询关键字';
        } else {
          _locoError = '请输入查询关键字';
        }
      });
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      if (isCar) {
        _carError = null;
        _carResult = null;
      } else {
        _locoError = null;
        _locoResult = null;
      }
    });
    try {
      if (isCar) {
        final r =
            await _api.queryCarStock(kw, _carType, forceRefresh: force);
        if (mounted) setState(() => _carResult = r);
      } else {
        final r =
            await _api.queryLocoStock(kw, _locoType, forceRefresh: force);
        if (mounted) setState(() => _locoResult = r);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (isCar) {
            _carError = _cleanErr(e);
          } else {
            _locoError = _cleanErr(e);
          }
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    final isCar = _tab == _PsTab.car;
    if (isCar) {
      final cur = _carResult;
      if (cur == null || !cur.hasMore) return;
      if (mounted) setState(() => _loadingMore = true);
      try {
        final more = await _api.queryCarStock(
          _carCtrl.text.trim(),
          cur.type,
          loadMore: true,
          previous: cur,
        );
        if (mounted) setState(() => _carResult = more);
      } catch (e) {
        if (mounted) _toast('加载更多失败：${_cleanErr(e)}');
      } finally {
        if (mounted) setState(() => _loadingMore = false);
      }
      return;
    }
    final cur = _locoResult;
    if (cur == null || !cur.hasMore) return;
    if (mounted) setState(() => _loadingMore = true);
    try {
      final more = await _api.queryLocoStock(
        _locoCtrl.text.trim(),
        cur.type,
        loadMore: true,
        previous: cur,
      );
      if (mounted) setState(() => _locoResult = more);
    } catch (e) {
      if (mounted) _toast('加载更多失败：${_cleanErr(e)}');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isCar = _tab == _PsTab.car;
    return Scaffold(
      appBar: AppBar(
        title: const Text('普速配属查询'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '忽略缓存重新查询',
            onPressed: _loading ? null : () => _load(force: true),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: SegmentedButton<_PsTab>(
              segments: const <ButtonSegment<_PsTab>>[
                ButtonSegment(
                  value: _PsTab.car,
                  icon: Icon(Icons.airline_seat_recline_normal, size: 18),
                  label: Text('车厢'),
                ),
                ButtonSegment(
                  value: _PsTab.loco,
                  icon: Icon(Icons.directions_railway, size: 18),
                  label: Text('机车'),
                ),
              ],
              selected: <_PsTab>{_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            child: Row(
              children: <Widget>[
                const Text('按', style: TextStyle(fontSize: 13)),
                const SizedBox(width: 6),
                SizedBox(
                  width: 124,
                  height: 48,
                  child: _buildPsDropdown(
                    value: isCar ? _carType : _locoType,
                    options: isCar ? _kPasCarTypes : _kPasLocoTypes,
                    onChanged: (v) => setState(() {
                      if (isCar) {
                        _carType = v;
                      } else {
                        _locoType = v;
                      }
                    }),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: isCar ? _carCtrl : _locoCtrl,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _load(),
                    decoration: InputDecoration(
                      prefixIcon: Icon(
                        isCar
                            ? Icons.airline_seat_recline_normal
                            : Icons.directions_railway,
                        size: 20,
                      ),
                      hintText: isCar
                          ? (_kPasCarHint[_carType] ?? '关键字')
                          : (_kPasLocoHint[_locoType] ?? '关键字'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: _loading
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          : IconButton(
                              icon: const Icon(Icons.search),
                              onPressed: _load,
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: Text(
              isCar
                  ? '数据源 cr400bf.passearch.info　按「${_kPasCarTypes[_carType]}」查'
                  : '数据源 loco.passearch.info　按「${_kPasLocoTypes[_locoType]}」查'
                      '${_psLocoTypeNote(_locoType)}',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  /// 同主页面的 _psTypeDropdown：颜色必须从 colorScheme 取，
  /// 否则深色模式下是黑底黑字，什么都看不见。
  Widget _buildPsDropdown({
    required String value,
    required Map<String, String> options,
    required void Function(String) onChanged,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          isDense: true,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          dropdownColor: cs.surface,
          icon: Icon(Icons.arrow_drop_down, color: cs.onSurfaceVariant),
          items: options.entries
              .map(
                (e) => DropdownMenuItem<String>(
                  value: e.key,
                  child: Text(
                    e.value,
                    style: TextStyle(fontSize: 13, color: cs.onSurface),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }

  Widget _buildBody() {
    final cs = Theme.of(context).colorScheme;
    final isCar = _tab == _PsTab.car;
    final err = isCar ? _carError : _locoError;

    if (_loading && (isCar ? _carResult : _locoResult) == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (err != null) {
      // 错误信息里带了排查用的细节（HTTP 状态 / 服务端条数 / 扫到几个 <tr>），
      // 用 SelectableText 方便长按复制出来看
      return ListView(
        padding: const EdgeInsets.all(24),
        children: <Widget>[
          SelectableText(
            err,
            style: TextStyle(color: cs.error, fontSize: 13),
          ),
        ],
      );
    }

    if (isCar) {
      final r = _carResult;
      if (r == null) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '选好「按什么查」，输入关键字后点击查询\n如 Z155 / 683046 / YW25T',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ),
        );
      }
      return ListView(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 16),
        children: <Widget>[
          _buildPsListHeader(
            count: r.items.length,
            total: r.total,
            dim: _kPasCarTypes[r.type] ?? r.type,
            // 翻页诊断也放顶部：底部 footer 在 50 张卡片之后，滚不到底就看不见
            error: r.error ?? r.moreError,
            color: cs.primary,
          ),
          if (r.items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text('无车厢配属记录',
                    style: TextStyle(fontSize: 13, color: Colors.grey)),
              ),
            ),
          ...List<Widget>.generate(
            r.items.length,
            (i) => _buildCarCard(context, r.items[i], index: i + 1),
          ),
          if (r.items.isNotEmpty)
          _buildLoadMoreFooter(
            r.hasMore,
            loaded: r.items.length,
            total: r.total,
            moreError: r.moreError,
          ),
        ],
      );
    }

    final r = _locoResult;
    if (r == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '选好「按什么查」，输入关键字后点击查询\n'
            '机车：型号输 HXD3D　车号输编号 0047　配属段输 京局京段\n'
            '⚠️ 型号和车号都不要输完整车号（HXD3D0047）',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 16),
      children: <Widget>[
        _buildPsListHeader(
          count: r.items.length,
          total: r.total,
          dim: _kPasLocoTypes[r.type] ?? r.type,
          error: r.error ?? r.moreError,
          color: cs.tertiary,
        ),
        if (r.items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text('无机车配属记录',
                  style: TextStyle(fontSize: 13, color: Colors.grey)),
            ),
          ),
        ...List<Widget>.generate(
          r.items.length,
          (i) => _buildLocoCard(context, r.items[i], index: i + 1),
        ),
        if (r.items.isNotEmpty)
          _buildLoadMoreFooter(
            r.hasMore,
            loaded: r.items.length,
            total: r.total,
            moreError: r.moreError,
          ),
      ],
    );
  }

  Widget _buildPsListHeader({
    required int count,
    required int? total,
    required String dim,
    required String? error,
    required Color color,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.filter_alt_outlined, size: 14, color: color),
              const SizedBox(width: 5),
              Text(
                '按「$dim」查',
                style: TextStyle(
                    fontSize: 12, color: color, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                total != null && total > count
                    ? '共 $total 条 · 已加载 $count'
                    : '$count 条',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              // SelectableText：翻页诊断信息很长，得能长按复制出来看/发给别人
              child: SelectableText(error,
                  style: const TextStyle(fontSize: 11, color: Colors.orange)),
            ),
        ],
      ),
    );
  }

  /// 同主页面的 _psLoadMoreFooter：失败要看得见，进度也要看得见
  Widget _buildLoadMoreFooter(
    bool hasMore, {
    int loaded = 0,
    int? total,
    String? moreError,
  }) {
    final cs = Theme.of(context).colorScheme;
    final progress =
        total == null ? '已加载 $loaded 条' : '已加载 $loaded / 共 $total 条';

    if (moreError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          children: <Widget>[
            Text(
              moreError,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: cs.error),
            ),
            const SizedBox(height: 6),
            if (hasMore)
              OutlinedButton.icon(
                onPressed: _loadingMore ? null : _loadMore,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              )
            else
              Text(progress,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      );
    }

    if (!hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: Text('已全部加载　$progress',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: _loadingMore
          ? const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : Column(
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: _loadMore,
                  icon: const Icon(Icons.expand_more, size: 18),
                  label: const Text('加载更多'),
                ),
                const SizedBox(height: 4),
                Text(progress,
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────────
// 车次经停详情（独立页面，支持日期切换）
// ───────────────────────────────────────────────────────────────────────────

class _TrainDetailPage extends StatefulWidget {
  /// 车次号，如 G101
  final String trainCode;

  /// 内部车号（站-站结果里自带，传了可省一次检索请求）
  final String? trainNo;

  final DateTime date;

  const _TrainDetailPage({
    required this.trainCode,
    required this.date,
    this.trainNo,
  });

  @override
  State<_TrainDetailPage> createState() => _TrainDetailPageState();
}

class _TrainDetailPageState extends State<_TrainDetailPage> {
  final _RailwayApi _api = _RailwayApi.instance;

  late DateTime _date;
  bool _loading = true;
  String? _error;
  _TrainDetail? _detail;

  @override
  void initState() {
    super.initState();
    _date = widget.date;
    _load();
  }

  bool get _canPrev => _date.isAfter(_today());
  bool get _canNext => _date.isBefore(_today().add(const Duration(days: 14)));

  Future<void> _load({bool forceRefresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = (widget.trainNo != null && widget.trainNo!.isNotEmpty)
          ? await _api.queryDetailByTrainNo(
              trainNo: widget.trainNo!,
              trainCode: widget.trainCode,
              date: _date,
              forceRefresh: forceRefresh,
            )
          : await _api.queryByTrainNo(
              widget.trainCode,
              _date,
              forceRefresh: forceRefresh,
            );
      if (mounted) setState(() => _detail = d);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _shiftDay(int delta) {
    setState(() => _date = _date.add(Duration(days: delta)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.trainCode}　${_fmtCn(_date)}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: '前一天',
            onPressed: _canPrev ? () => _shiftDay(-1) : null,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: '后一天',
            onPressed: _canNext ? () => _shiftDay(1) : null,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '忽略缓存重新加载',
            onPressed: _loading ? null : () => _load(forceRefresh: true),
          ),
        ],
      ),
      body: Builder(
        builder: (context) {
          if (_loading && d == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (_error != null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline,
                        size: 40, color: Colors.redAccent),
                    const SizedBox(height: 8),
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: () => _load(forceRefresh: true),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            );
          }
          if (d == null) return const SizedBox.shrink();
          // 与「车次查询」内联结果共用同一套主体，结构完全对齐
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _buildTrainDetailBody(
                  context,
                  d,
                  compactHeader: true,
                  // 独立页里点车组号 → 弹窗看它的配属与近期交路
                  onPickEmu: (emuNo) => _openEmuPage(context, emuNo),
                  onPickCarStock:
                      d.isEmu ? null : () => _openPsPage(context, d.trainCode),
                ),
              ),
              _trainDetailFooter(context, d),
            ],
          );
        },
      ),
    );
  }
}
