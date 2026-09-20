// ============================================================================
// 列车查询页面（单文件实现）
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

import '../models/ble_warning_message.dart';
import '../services/app_settings_service.dart';
import '../services/lock_screen_overlay.dart';
import '../services/tts_service.dart';

// ── 接口地址（如需自建反代，直接改这两个常量即可，路径保持一致）────────────
const String _kKyfwBase = 'https://kyfw.12306.cn';
const String _kSearchBase = 'https://search.12306.cn';
const String _kUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

// ── 车组号数据源 ───────────────────────────────────────────────────────────
// ① rail.re（Arnie97/moerail，静态站 + 公开 JSON，无鉴权）
//    GET /emu/{车组号}    → [{emu_no, train_no, date}, ...]
//    GET /train/{车次}    → 同上（仅收录 G/D/C 动车）
const String _kRailReBase = 'https://api.rail.re';

// ② OpenCRHTracker（lihugang/OpenCRHTracker，公开开发者 API，匿名可调用但有配额）
//    GET /api/v2/history/emu/{车组号}      → 该车组历史担当车次
//    GET /api/v2/allocation/emu/{车组号}   → 配属/车型/路局/动车所
//    GET /api/v2/timetable/station/{站名}  → 车站当日时刻表（大屏数据）
const String _kCrhBase = 'https://crh.lihugang.top/api/v2';

// ③ 黄河铁路网（jprailfan.com，铁路工具箱）：里程数据。
//    该站为传统 PHP 站，没有公开 JSON API；默认路径指向工具箱的里程查询页，
//    {train} 会被替换成车次。若你的入口地址不同，只改这一个常量即可。
//    返回 HTML 表格时用 _parseMileage 解析，返回 JSON 时走 JSON 分支。
const String _kHuangheBase = 'https://www.jprailfan.com';
const String _kHuangheMileagePath = '/tools/mileage.php?train={train}';
const bool _kHuangheEnabled = true;

const bool _kRailReEnabled = true;
const bool _kCrhEnabled = true;

// ── 正晚点数据源 ───────────────────────────────────────────────────────────
// 12306 官方「正晚点查询」（zwdch）。接口未公开，路径与参数按抓包结果填写；
// 只支持当天、且仅覆盖过去 1 小时 ~ 未来 3 小时的车次。
const String _kLateBase = 'https://www.12306.cn/index/otn/zwdch';
const String _kLatePath = '/query';
const bool _kLateEnabled = true;
/// 单次正晚点查询的并发上限（官方接口频控较严，别调大）
const int _kLateConcurrency = 4;
/// 单次最多查多少个站的正晚点（站多时只取当前时刻附近的站）
const int _kLateMaxStations = 12;

/// 余票字段在 result 字符串中的下标（12306 会不定期调整，改动只改这里）
const Map<int, String> _kSeatIndex = <int, String>{
  32: '商务座',
  31: '一等座',
  30: '二等座',
  25: '特等座',
  21: '高级软卧',
  23: '软卧',
  33: '动卧',
  28: '硬卧',
  29: '硬座',
  26: '无座',
};

// ── 缓存有效期（内存缓存，减少请求 = 降低被风控概率）──────────────────────
const Duration _kTtlStationDict = Duration(days: 30); // 车站字典，几乎不变
const Duration _kTtlLeftTicket = Duration(seconds: 60); // 余票，变化快
const Duration _kTtlTrainInfo = Duration(hours: 12); // 时刻表
const Duration _kTtlEmu = Duration(minutes: 30); // 车组交路，一天才变几次
const Duration _kTtlBoard = Duration(seconds: 60); // 车站大屏，实时
const Duration _kTtlMileage = Duration(days: 7); // 里程，基本不变
const Duration _kTtlLate = Duration(minutes: 2); // 正晚点，实时但频控严
const Duration _kTtlConsist = Duration(minutes: 30); // 担当车组，一天才变几次
const Duration _kTtlPas = Duration(minutes: 30); // 普速配属，一天才变几次
/// 车次详情页最多展示几组最近担当的动车组
const int _kConsistMax = 10;
/// 其中最多给几组补查车型（OpenCRHTracker 配额有限）
const int _kConsistProfileMax = 3;
/// 车次查询时，最多给几个车组号补查 OpenCRHTracker 历史/配属
const int _kEmuTrainExpandMax = 5;

// ── 普速配属数据源（车厢 / 机车）───────────────────────────────────────────
// ① 车厢（车辆）配属：https://cr400bf.passearch.info
//      GET /index.php?keyword={kw}&type={type}&pagenum=N
//      表头：型号 车号 现配属 定员 运用车次 制造厂 转向架
// ② 机车配属：https://loco.passearch.info
//      GET /index.php?keyword={kw}&type={type}&pagenum=N
//      表头：车号 配属 机务段 厂家 备注
//
// ⚠️ 查什么、按什么维度查，一律由用户在界面上选，代码不做任何自动猜测或回退。
//    下面的 type 值是逐个实测出来的，页面上列了但实际查不出东西的已剔除：
//      车厢站可用：number=车号 / model=型号 / train=运用车次 / depot=现配属 / bogie=转向架
//      车厢站不通：no / carno / car（车号）、factory / manufacturer（制造厂）
//      机车站可用：model=型号 / depot=配属段
//      机车站不通：no / loco（车号，报「参数错误」）、number（不报错但恒 0 条）、
//                  factory / manufacturer（厂家）、train（车次）
//    → 机车站没有车次维度，所以查不到「某趟车今天用什么机车」。
//    ⚠️ 机车站按型号查时，关键字必须是型号本身（HXD3D），
//       输完整车号 HXD3D0001 会返回「0 条」——不是报错，是查不到。
//    → 这是用户最容易踩的坑，界面上有提示。
//    哪天站点补上了，往这两个 Map 里加一项即可（UI 会自动多出一个选项）。
const String _kPasCarBase = 'https://cr400bf.passearch.info';
const String _kPasLocoBase = 'https://loco.passearch.info';
const bool _kPasCarEnabled = true;
const bool _kPasLocoEnabled = true;
/// 车厢站实测可用的查询维度（type → 中文名），按常用度排序
const Map<String, String> _kPasCarTypes = <String, String>{
  'train': '运用车次',
  'number': '车号',
  'model': '型号',
  'depot': '现配属',
  'bogie': '转向架',
};
/// 机车站实测可用的查询维度（type → 中文名）
const Map<String, String> _kPasLocoTypes = <String, String>{
  'model': '型号',
  'depot': '配属段',
};
/// 关键字示例，随维度变化，直接显示在输入框下面
const Map<String, String> _kPasCarHint = <String, String>{
  'train': '如 Z155',
  'number': '如 683046',
  'model': '如 YW25T',
  'depot': '如 上局合段',
  'bogie': '如 SW220K',
};
const Map<String, String> _kPasLocoHint = <String, String>{
  'model': '如 HXD3D（型号，不是 HXD3D0001）',
  'depot': '如 京局京段',
};
/// 服务端固定每页 50 条（实测：车厢 1360 条 / 28 页；机车 739 条 / 15 页）
const int _kPasPageSize = 50;
/// 「加载更多」一次翻几页
const int _kPasMorePages = 1;

// ── 车站大屏分页 ───────────────────────────────────────────────────────────
// 数据源 GET /api/v2/timetable/station/{站名} 单次最多返回 80 条，
// 超出部分会被静默截断（不报错、不告知），大站一天几百趟必然看不全。
// 因此这里做「翻页拉取 + 去重合并」：
//   · 首屏自动翻 _kBoardAutoPages 页（默认 3 页 = 240 趟）；
//   · 剩下的由用户点「加载更多」，每次再翻 _kBoardMorePages 页；
//   · 分页参数名各家不一，这里按候选顺序自动探测，命中后固定复用；
//   · 全部探测失败就停在 80 条，并在界面上明确标注「可能不完整」，
//     同时提供时段筛选，让用户自己把范围缩到 80 条以内。
// 若你已知该接口真实的分页参数，直接改 _kBoardOffsetKeys 等常量即可。
const int _kBoardPageSize = 80;
const int _kBoardAutoPages = 3;
const int _kBoardMorePages = 3;
/// 列表滑到底时自动续拉一页（大屏翻页场景更顺手，想省配额可关掉）
const bool _kBoardAutoLoadOnScrollEnd = true;
/// offset 风格：offset=已取条数
const String _kBoardOffsetKey = 'offset';
/// page 风格：page=第几页（从 1 开始）
const String _kBoardPageKey = 'page';
/// cursor 风格：cursor=服务端上页回传的游标
const String _kBoardCursorKey = 'cursor';
/// 时间戳切片兜底：after=上页最后一条的发车时间戳（秒）
const String _kBoardAfterTsKey = 'after';
/// 时段筛选（客户端过滤，用于把结果压回 80 条以内）
const List<String> _kBoardSlots = <String>[
  '全部',
  '0-6 时',
  '6-12 时',
  '12-18 时',
  '18-24 时',
];

class _CacheEntry {
  final Object data;
  final DateTime at;
  const _CacheEntry(this.data, this.at);
}

class _JsonCache {
  _JsonCache._();
  static final _JsonCache instance = _JsonCache._();

  final Map<String, _CacheEntry> _map = <String, _CacheEntry>{};

  Object? get(String key, Duration ttl) {
    final e = _map[key];
    if (e == null) return null;
    if (DateTime.now().difference(e.at) > ttl) {
      _map.remove(key);
      return null;
    }
    return e.data;
  }

  void set(String key, Object data) =>
      _map[key] = _CacheEntry(data, DateTime.now());

  void clear() => _map.clear();
}

enum _SearchMode { stationToStation, trainNo, emuNo, station, ordinary }



// ───────────────────────────────────────────────────────────────────────────
// 数据模型
// ───────────────────────────────────────────────────────────────────────────

class _Station {
  final String name;
  final String code;
  final String pinyin;
  final String initials;

  const _Station({
    required this.name,
    required this.code,
    required this.pinyin,
    required this.initials,
  });
}

class _Seat {
  final String label;
  final String value;
  const _Seat(this.label, this.value);
}

/// 站-站查询结果
class _TrainRun {
  final String trainCode;
  final String trainNo;
  final String fromStation;
  final String toStation;
  final String departTime;
  final String arriveTime;
  final String duration;
  final String date;
  final List<_Seat> seats;

  const _TrainRun({
    required this.trainCode,
    required this.trainNo,
    required this.fromStation,
    required this.toStation,
    required this.departTime,
    required this.arriveTime,
    required this.duration,
    required this.date,
    required this.seats,
  });
}

/// 单站正晚点
class _LateInfo {
  /// 晚点分钟数：>0 晚点，<0 早点，0 正点，null 未知
  final int? lateMin;
  /// 实际到/发时刻（HH:mm），官方不返回时为空
  final String realTime;
  final String note;

  const _LateInfo({
    this.lateMin,
    this.realTime = '',
    this.note = '',
  });

  bool get known => lateMin != null || realTime.isNotEmpty;

  String get label {
    final m = lateMin;
    if (m == null) return realTime.isNotEmpty ? '预计 $realTime' : '—';
    if (m == 0) return '正点';
    return m > 0 ? '晚点 $m 分' : '早点 ${-m} 分';
  }

  /// 0 正点 / 1 晚点 / -1 早点 / 2 未知
  int get state {
    final m = lateMin;
    if (m == null) return 2;
    if (m == 0) return 0;
    return m > 0 ? 1 : -1;
  }
}

/// 车次经停点
class _Stop {
  final int index;
  final String stationName;
  /// 车站电报码（如 BJP），字典反查不到时为空
  final String stationCode;
  final String arriveTime;
  final String departTime;
  final String stopover;
  /// 自始发站累计里程（km）
  final double? mileage;
  final _LateInfo? late;

  const _Stop({
    required this.index,
    required this.stationName,
    this.stationCode = '',
    required this.arriveTime,
    required this.departTime,
    required this.stopover,
    this.mileage,
    this.late,
  });

  _Stop copyWith({
    String? stationCode,
    double? mileage,
    _LateInfo? late,
  }) {
    return _Stop(
      index: index,
      stationName: stationName,
      stationCode: stationCode ?? this.stationCode,
      arriveTime: arriveTime,
      departTime: departTime,
      stopover: stopover,
      mileage: mileage ?? this.mileage,
      late: late ?? this.late,
    );
  }
}

/// 担当车组 / 车型
class _TrainConsist {
  /// 车组号（动车），如 CR400AF-2031
  final String emuNo;
  /// 车型（普速或动车配属车型），如 25T / CR400AF
  final String model;
  /// 配属等补充说明
  final String note;
  final String source;
  /// 担当日期（车组号来源带日期时）
  final String date;

  const _TrainConsist({
    this.emuNo = '',
    this.model = '',
    this.note = '',
    this.source = '',
    this.date = '',
  });

  bool get isEmpty => emuNo.isEmpty && model.isEmpty;

  /// 顶部一行展示：优先车组号，其次车型
  String get title => emuNo.isNotEmpty ? emuNo : model;

  /// 副标题：车型 + 担当日期
  String get subtitle {
    final parts = <String>[];
    if (model.isNotEmpty) parts.add(model);
    if (date.isNotEmpty) parts.add(date);
    return parts.join('　');
  }
}

/// 车次详情
class _TrainDetail {
  final String trainCode;
  final String trainNo;
  final DateTime date;
  final String startStation;
  final String endStation;
  final List<_Stop> stops;
  /// 最近担当的动车组列表（动车，按日期倒序，可能有多组）
  /// 普速时放的是车型（一般 0~1 条）
  final List<_TrainConsist> consists;
  /// 里程数据来源名，抓不到为空
  final String mileageSource;
  /// 是否有里程数据
  final bool hasMileage;

  const _TrainDetail({
    required this.trainCode,
    required this.trainNo,
    required this.date,
    required this.startStation,
    required this.endStation,
    required this.stops,
    this.consists = const <_TrainConsist>[],
    this.mileageSource = '',
    this.hasMileage = false,
  });

  bool get isEmu {
    final c = trainCode.toUpperCase();
    return c.startsWith('G') || c.startsWith('D') || c.startsWith('C');
  }

  /// 首要的一条（底部来源标注等场景用），没有则为 null
  _TrainConsist? get consist => consists.isEmpty ? null : consists.first;

  _TrainDetail copyWith({
    List<_Stop>? stops,
    List<_TrainConsist>? consists,
    String? mileageSource,
    bool? hasMileage,
  }) {
    return _TrainDetail(
      trainCode: trainCode,
      trainNo: trainNo,
      date: date,
      startStation: startStation,
      endStation: endStation,
      stops: stops ?? this.stops,
      consists: consists ?? this.consists,
      mileageSource: mileageSource ?? this.mileageSource,
      hasMileage: hasMileage ?? this.hasMileage,
    );
  }
}

/// 车站查询结果（某站当日停靠列车）
class _StationTrain {
  final String trainCode;
  final String startStation;
  final String endStation;
  final String arriveTime;
  final String departTime;

  const _StationTrain({
    required this.trainCode,
    required this.startStation,
    required this.endStation,
    required this.arriveTime,
    required this.departTime,
  });
}

// ───────────────────────────────────────────────────────────────────────────
// 车组号 / 车站大屏数据模型
// ───────────────────────────────────────────────────────────────────────────

/// 车组号来源
enum _EmuSource { railRe, crhTracker }

String _emuSourceLabel(_EmuSource s) {
  switch (s) {
    case _EmuSource.railRe:
      return 'rail.re';
    case _EmuSource.crhTracker:
      return 'OpenCRHTracker';
  }
}

/// 一条车组担当记录
class _EmuRecord {
  final String emuNo; // CR400AF-2031
  final String trainCode; // G83
  final String date; // 2025-10-19 / 2025-10-19 20:22
  final _EmuSource source;

  const _EmuRecord({
    required this.emuNo,
    required this.trainCode,
    required this.date,
    required this.source,
  });
}

/// 车组配属档案（OpenCRHTracker /allocation/emu 提供）
class _EmuProfile {
  final String emuNo;
  final String model; // CR400AF-C
  final String bureau; // 北京局集团
  final String trainDepot; // 北京动车段
  final String depot; // 雄安动车所
  final String manufacturer;
  final String manufactureMonth;
  final int? designMaxSpeed;
  final List<String> tags;

  const _EmuProfile({
    required this.emuNo,
    required this.model,
    required this.bureau,
    required this.trainDepot,
    required this.depot,
    required this.manufacturer,
    required this.manufactureMonth,
    required this.designMaxSpeed,
    required this.tags,
  });

  bool get isEmpty =>
      model.isEmpty &&
      bureau.isEmpty &&
      depot.isEmpty &&
      trainDepot.isEmpty &&
      designMaxSpeed == null;

  List<String> get lines {
    final out = <String>[];
    if (model.isNotEmpty) out.add('车型 $model');
    if (bureau.isNotEmpty) out.add('配属 $bureau');
    if (trainDepot.isNotEmpty) out.add(trainDepot);
    if (depot.isNotEmpty) out.add(depot);
    if (manufacturer.isNotEmpty) out.add(manufacturer);
    if (manufactureMonth.isNotEmpty) out.add('出厂 $manufactureMonth');
    if (designMaxSpeed != null) out.add('设计时速 $designMaxSpeed km/h');
    return out;
  }
}

/// 车站大屏一条车次
class _BoardItem {
  final String trainCode;
  final String startStation;
  final String endStation;
  final String arriveTime; // HH:mm
  final String departTime;
  final String platform; // 站台
  final List<String> models; // 参考车型
  final _EmuSource source;
  /// 原始时间戳（秒），非展示字段：翻页游标 / 跨页去重 / 时段筛选都靠它
  final int arriveAt;
  final int departAt;

  const _BoardItem({
    required this.trainCode,
    required this.startStation,
    required this.endStation,
    required this.arriveTime,
    required this.departTime,
    required this.platform,
    required this.models,
    required this.source,
    this.arriveAt = 0,
    this.departAt = 0,
  });

  /// 跨页去重键：车次 + 到发时间戳 + 站台
  String get dedupKey => '$trainCode|$arriveAt|$departAt|$platform';

  /// 时段筛选用的小时（发车优先，取不到用到站），无时间戳返回 -1
  int get hourOfDay {
    final s = departAt > 0 ? departAt : arriveAt;
    if (s <= 0) return -1;
    return _tsCst(s).hour;
  }
}

/// 大屏分页风格：数据源到底认哪种翻页参数，运行时探测
enum _BoardPageStyle { none, offset, page, cursor, timestamp }

/// 一次分页请求的原始结果
class _BoardPage {
  final List<_BoardItem> items;
  /// 数据源声称的总条数（读不到为 null）
  final int? total;
  /// 服务端自报「还有下一页」（读不到为 null）
  final bool? hasMore;
  /// 服务端回传的下一页游标（cursor 风格用）
  final String nextCursor;

  const _BoardPage({
    required this.items,
    this.total,
    this.hasMore,
    this.nextCursor = '',
  });
}

// ───────────────────────────────────────────────────────────────────────────
// 普速配属数据模型（车厢 / 机车）
// ───────────────────────────────────────────────────────────────────────────

/// 一节车厢（25T / 25G 等）的配属信息
class _CarStock {
  final String model; // YW25T
  final String carNo; // 683046
  final String depot; // 上局合段
  final String capacity; // 定员 66
  final String trainCode; // 运用车次 Z155
  final String factory; // 唐山
  final String bogie; // SW220K

  const _CarStock({
    this.model = '',
    this.carNo = '',
    this.depot = '',
    this.capacity = '',
    this.trainCode = '',
    this.factory = '',
    this.bogie = '',
  });

  bool get isEmpty => carNo.isEmpty && model.isEmpty;

  /// 一行标题：型号 + 车号
  String get title => [model, carNo]
      .where((e) => e.isNotEmpty)
      .join(' ')
      .trim();

  /// 副标题：现配属 + 制造厂 + 转向架 + 定员
  String get subtitle => <String>[
        depot,
        factory.isEmpty ? '' : '$factory 制造',
        bogie,
        capacity.isEmpty ? '' : '定员 $capacity',
      ].where((e) => e.isNotEmpty).join('　');

  /// 去重键
  String get dedupKey => '$model|$carNo|$depot';
}

/// 一台机车的配属信息
class _LocoItem {
  final String locoNo; // HXD3D0001
  final String bureau; // 沈局
  final String depot; // 沈段
  final String factory; // 厂家
  final String note; // 备注

  const _LocoItem({
    this.locoNo = '',
    this.bureau = '',
    this.depot = '',
    this.factory = '',
    this.note = '',
  });

  bool get isEmpty => locoNo.isEmpty;

  String get title => locoNo;

  String get subtitle => <String>[
        '${bureau}${depot}'.trim(),
        factory,
        note,
      ].where((e) => e.isNotEmpty).join('　');

  String get dedupKey => locoNo;
}

/// 车厢查询结果（含分页状态）
class _CarPart {
  final List<_CarStock> items;
  final int? total;
  final int pages; // 已翻页数
  final bool hasMore;
  /// 命中的查询维度：train=运用车次 / model=型号
  final String type;
  final String? error;

  const _CarPart({
    this.items = const <_CarStock>[],
    this.total,
    this.pages = 0,
    this.hasMore = false,
    this.type = '',
    this.error,
  });

  _CarPart copyWith({
    List<_CarStock>? items,
    int? total,
    int? pages,
    bool? hasMore,
    String? type,
    String? error,
  }) =>
      _CarPart(
        items: items ?? this.items,
        total: total ?? this.total,
        pages: pages ?? this.pages,
        hasMore: hasMore ?? this.hasMore,
        type: type ?? this.type,
        error: error ?? this.error,
      );
}

/// 机车查询结果（含分页状态）
class _LocoPart {
  final List<_LocoItem> items;
  final int? total;
  final int pages;
  final bool hasMore;
  /// 命中的查询维度：model=型号 / depot=配属段
  final String type;
  final String? error;

  const _LocoPart({
    this.items = const <_LocoItem>[],
    this.total,
    this.pages = 0,
    this.hasMore = false,
    this.type = '',
    this.error,
  });

  _LocoPart copyWith({
    List<_LocoItem>? items,
    int? total,
    int? pages,
    bool? hasMore,
    String? type,
    String? error,
  }) =>
      _LocoPart(
        items: items ?? this.items,
        total: total ?? this.total,
        pages: pages ?? this.pages,
        hasMore: hasMore ?? this.hasMore,
        type: type ?? this.type,
        error: error ?? this.error,
      );
}

/// 普速查询的两个分栏：车厢 / 机车
enum _PsTab { car, loco }

String _psTabLabel(_PsTab t) => t == _PsTab.car ? '车厢配属' : '机车配属';

// ───────────────────────────────────────────────────────────────────────────
// 12306 接口封装
// ───────────────────────────────────────────────────────────────────────────

class _RailwayApi {
  _RailwayApi._();
  static final _RailwayApi instance = _RailwayApi._();

  final http.Client _client = http.Client();
  final Map<String, String> _cookies = <String, String>{};
  bool _cookieLoading = false;

  List<_Station> _stations = <_Station>[];
  final Map<String, String> _codeToName = <String, String>{};
  final Map<String, String> _nameToCode = <String, String>{};
  bool _stationsLoaded = false;

  /// 大屏分页风格探测结果：探明一次后全局复用，避免每换一个站都重探一遍
  _BoardPageStyle? _boardStyleLocked;
  final Set<_BoardPageStyle> _boardStyleDead = <_BoardPageStyle>{};

  List<_Station> get stations => _stations;

  // ── 基础请求 ────────────────────────────────────────────────────────────

  Future<void> _ensureCookie() async {
    if (_cookies.isNotEmpty || _cookieLoading) return;
    _cookieLoading = true;
    try {
      final res = await _client
          .get(
            Uri.parse('$_kKyfwBase/otn/leftTicket/init'),
            headers: <String, String>{'User-Agent': _kUserAgent},
          )
          .timeout(const Duration(seconds: 15));
      final raw = res.headers['set-cookie'];
      if (raw != null) _mergeCookies(raw);
    } catch (_) {
      // 拿不到 cookie 也继续尝试，某些反代不需要
    }
    _cookieLoading = false;
  }

  void _mergeCookies(String raw) {
    for (final m in RegExp(r'([^=;\s]+)=([^;]*)').allMatches(raw)) {
      final k = m.group(1)?.trim() ?? '';
      final v = m.group(2)?.trim() ?? '';
      if (k.isEmpty) continue;
      final lk = k.toLowerCase();
      if (lk == 'path' ||
          lk == 'domain' ||
          lk == 'expires' ||
          lk == 'max-age' ||
          lk == 'secure' ||
          lk == 'httponly' ||
          lk == 'samesite') {
        continue;
      }
      _cookies[k] = v;
    }
  }

  String get _cookieHeader =>
      _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  Future<http.Response> _get(
    Uri uri, {
    String? referer,
    String? origin,
  }) async {
    await _ensureCookie();
    final headers = <String, String>{
      'User-Agent': _kUserAgent,
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      if (referer != null) 'Referer': referer,
      if (origin != null) 'Origin': origin,
      if (_cookies.isNotEmpty) 'Cookie': _cookieHeader,
    };
    final res = await _client
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 20));
    final raw = res.headers['set-cookie'];
    if (raw != null) _mergeCookies(raw);
    return res;
  }

  /// 第三方数据源专用：不领 12306 cookie、不带其凭证，避免多余请求
  Future<http.Response> _getPlain(
    Uri uri, {
    String? referer,
  }) {
    return _client
        .get(
          uri,
          headers: <String, String>{
            'User-Agent': _kUserAgent,
            'Accept': 'application/json, text/plain, */*',
            'Accept-Language': 'zh-CN,zh;q=0.9',
            if (referer != null) 'Referer': referer,
          },
        )
        .timeout(const Duration(seconds: 20));
  }

  // ── 车站字典 ────────────────────────────────────────────────────────────

  Future<List<_Station>> loadStations({bool force = false}) async {
    if (_stationsLoaded && !force) return _stations;

    final cached = force
        ? null
        : _JsonCache.instance.get('stationDict', _kTtlStationDict);
    if (cached is List<_Station>) {
      _stations = cached;
      for (final s in _stations) {
        _codeToName[s.code] = s.name;
        _nameToCode[s.name] = s.code;
      }
      _stationsLoaded = true;
      return _stations;
    }

    final res = await _get(
      Uri.parse('$_kKyfwBase/otn/resources/js/framework/station_name.js'),
      referer: '$_kKyfwBase/otn/leftTicket/init',
      origin: _kKyfwBase,
    );
    if (res.statusCode != 200) {
      throw Exception('车站字典加载失败：HTTP ${res.statusCode}');
    }
    final body = res.body;
    final m = RegExp(r"'([^']*)'", dotAll: true).firstMatch(body);
    final raw = m?.group(1) ?? body;

    final list = <_Station>[];
    for (final part in raw.split('@')) {
      final p = part.trim();
      if (p.isEmpty) continue;
      final f = p.split('|');
      if (f.length < 4) continue;
      final name = f[1].trim();
      final code = f[2].trim();
      if (name.isEmpty || code.isEmpty) continue;
      list.add(
        _Station(
          name: name,
          code: code,
          pinyin: f[3].trim(),
          initials: f[0].trim(),
        ),
      );
      _codeToName[code] = name;
      _nameToCode[name] = code;
    }
    if (list.isEmpty) throw Exception('车站字典为空，可能已被拦截');
    _JsonCache.instance.set('stationDict', list);
    _stations = list;
    _stationsLoaded = true;
    return list;
  }

  /// 站名 / 电报码 / 拼音 / 首字母 → 车站
  _Station? findStation(String keyword) {
    final q = keyword.trim();
    if (q.isEmpty) return null;
    final upper = q.toUpperCase();
    // 字典没加载成功时的兜底：允许直接填电报码
    if (_stations.isEmpty && RegExp(r'^[A-Z]{3}$').hasMatch(upper)) {
      return _Station(name: upper, code: upper, pinyin: '', initials: '');
    }
    for (final s in _stations) {
      if (s.name == q) return s;
    }
    for (final s in _stations) {
      if (s.code == upper) return s;
    }
    for (final s in _stations) {
      if (s.name.contains(q)) return s;
    }
    final lower = q.toLowerCase();
    for (final s in _stations) {
      if (s.initials.toLowerCase() == lower ||
          s.pinyin.toLowerCase() == lower) {
        return s;
      }
    }
    return null;
  }

  String nameOfCode(String code) => _codeToName[code] ?? code;

  /// 站名 → 电报码（经停表里补电报码用；字典未加载时返回空串）
  String codeOfName(String name) => _nameToCode[name.trim()] ?? '';

  // ── 1. 站-站查询 ────────────────────────────────────────────────────────

  Future<List<_TrainRun>> queryByStationPair(
    String fromCode,
    String toCode,
    DateTime date, {
    bool forceRefresh = false,
  }) async {
    final key = 'leftTicket|$fromCode|$toCode|${_fmtDash(date)}';
    final cached = forceRefresh
        ? null
        : _JsonCache.instance.get(key, _kTtlLeftTicket);
    if (cached is List<_TrainRun>) return cached;

    final uri = Uri.parse('$_kKyfwBase/otn/leftTicket/query').replace(
      queryParameters: <String, String>{
        'leftTicketDTO.train_date': _fmtDash(date),
        'leftTicketDTO.from_station': fromCode,
        'leftTicketDTO.to_station': toCode,
        'purpose_codes': 'ADULT',
      },
    );
    final res = await _get(
      uri,
      referer: '$_kKyfwBase/otn/leftTicket/init',
      origin: _kKyfwBase,
    );
    if (res.statusCode != 200) {
      throw Exception('查询失败：HTTP ${res.statusCode}');
    }
    final root = jsonDecode(res.body);
    if (root is! Map<String, dynamic>) throw Exception('返回格式异常');
    final data = root['data'];
    if (data is! Map<String, dynamic>) {
      final msg = root['messages'];
      throw Exception(
          (msg is List && msg.isNotEmpty) ? msg.first.toString() : '未查询到数据');
    }

    // map: {BJP: 北京南, SHH: 上海虹桥...}
    final map = <String, String>{};
    final rawMap = data['map'];
    if (rawMap is Map) {
      rawMap.forEach((k, v) => map[k.toString()] = v.toString());
    }
    final result = (data['result'] as List?)?.cast<String>() ?? <String>[];

    final runs = <_TrainRun>[];
    for (final row in result) {
      final f = row.split('|');
      if (f.length < 33) continue;
      final fCode = f[6];
      final tCode = f[7];
      final seats = <_Seat>[];
      for (final idx in _kSeatIndex.keys) {
        if (idx >= f.length) continue;
        final v = f[idx].trim();
        // 空串 / "--" 表示该车次不提供此席别
        if (v.isEmpty || v == '--') continue;
        seats.add(_Seat(_kSeatIndex[idx]!, v));
      }
      runs.add(
        _TrainRun(
          trainCode: f[3],
          trainNo: f[2],
          fromStation: map[fCode] ?? fCode,
          toStation: map[tCode] ?? tCode,
          departTime: f[8],
          arriveTime: f[9],
          duration: f[10],
          date: f[13],
          seats: seats,
        ),
      );
    }
    runs.sort((a, b) => a.departTime.compareTo(b.departTime));
    _JsonCache.instance.set(key, runs);
    return runs;
  }

  // ── 2. 车次查询 ─────────────────────────────────────────────────────────

  Future<_TrainDetail> queryByTrainNo(
    String trainCode,
    DateTime date, {
    bool forceRefresh = false,
  }) async {
    final key = 'trainInfo|$trainCode|${_fmtDash(date)}';
    final cached =
        forceRefresh ? null : _JsonCache.instance.get(key, _kTtlTrainInfo);
    if (cached is _TrainDetail) return cached;

    // 第一步：车次号 → 内部 train_no
    final sUri = Uri.parse('$_kSearchBase/search/v1/train/search').replace(
      queryParameters: <String, String>{
        'keyword': trainCode,
        'date': _fmtCompact(date),
      },
    );
    final sRes = await _get(sUri, referer: '$_kSearchBase/');
    if (sRes.statusCode != 200) {
      throw Exception('车次检索失败：HTTP ${sRes.statusCode}');
    }
    final sRoot = jsonDecode(sRes.body);
    final sList = (sRoot is Map<String, dynamic>)
        ? (sRoot['data'] as List?)?.cast<dynamic>() ?? <dynamic>[]
        : <dynamic>[];
    if (sList.isEmpty) {
      final err = (sRoot is Map) ? sRoot['errorMsg'] : null;
      throw Exception(err?.toString() ?? '未查询到该车次');
    }

    Map<String, dynamic>? hit;
    final target = trainCode.trim().toUpperCase();
    for (final e in sList) {
      if (e is Map) {
        final code = (e['station_train_code'] ?? '').toString().toUpperCase();
        if (code == target) {
          hit = e.cast<String, dynamic>();
          break;
        }
      }
    }
    hit ??= (sList.first as Map).cast<String, dynamic>();

    final realNo = (hit['train_no'] ?? '').toString();
    if (realNo.isEmpty) throw Exception('未获取到列车编号');
    final startName = (hit['from_station'] ?? hit['start_station'] ?? '')
        .toString();
    final endName =
        (hit['to_station'] ?? hit['end_station'] ?? '').toString();
    // 检索接口偶尔带车型字段（普速主要靠它）
    final searchModel = _pickTrainModel(hit);

    // 第二步：train_no → 经停时刻表
    final detail = await _fetchStops(
      trainNo: realNo,
      trainCode: trainCode,
      date: date,
      startStation: startName,
      endStation: endName,
      searchModel: searchModel,
    );
    // 第三步：补里程 / 担当车组 / 正晚点
    final full = await _enrichDetail(detail);
    _JsonCache.instance.set(key, full);
    return full;
  }

  /// 已知内部 train_no（站-站结果里自带），直接拉经停表，省一次检索请求
  Future<_TrainDetail> queryDetailByTrainNo({
    required String trainNo,
    required String trainCode,
    required DateTime date,
    bool forceRefresh = false,
  }) async {
    final key = 'trainInfo|$trainCode|${_fmtDash(date)}';
    final cached =
        forceRefresh ? null : _JsonCache.instance.get(key, _kTtlTrainInfo);
    if (cached is _TrainDetail) return cached;

    final detail = await _fetchStops(
      trainNo: trainNo,
      trainCode: trainCode,
      date: date,
    );
    final full = await _enrichDetail(detail);
    _JsonCache.instance.set(key, full);
    return full;
  }

  /// 纯网络请求：train_no → 经停时刻表
  Future<_TrainDetail> _fetchStops({
    required String trainNo,
    required String trainCode,
    required DateTime date,
    String startStation = '',
    String endStation = '',
    String searchModel = '',
  }) async {
    final uri = Uri.parse('$_kKyfwBase/otn/queryTrainInfo/query').replace(
      queryParameters: <String, String>{
        'leftTicketDTO.train_no': trainNo,
        'leftTicketDTO.train_date': _fmtDash(date),
        'rand_code': '',
      },
    );
    final res = await _get(
      uri,
      referer: '$_kKyfwBase/otn/queryTrainInfo/init',
      origin: _kKyfwBase,
    );
    if (res.statusCode != 200) {
      throw Exception('时刻表查询失败：HTTP ${res.statusCode}');
    }
    final root = jsonDecode(res.body);
    final dataList = (root is Map<String, dynamic>)
        ? ((root['data'] as Map?)?['data'] as List?)?.cast<dynamic>() ??
            <dynamic>[]
        : <dynamic>[];

    final stops = <_Stop>[];
    var i = 1;
    for (final e in dataList) {
      if (e is! Map) continue;
      final name = (e['station_name'] ?? '').toString();
      stops.add(
        _Stop(
          index: i++,
          stationName: name,
          // 电报码：接口带就直接用，否则用车站字典反查
          stationCode: _pickTelecode(e) ?? codeOfName(name),
          arriveTime: (e['arrive_time'] ?? '').toString(),
          departTime: (e['start_time'] ?? '').toString(),
          stopover: (e['stopover_time'] ?? '').toString(),
          // 少数版本的经停接口自带里程，能拿到就先用
          mileage: _toKm(
            (e['mileage'] ?? e['distance'] ?? e['licheng'])?.toString(),
          ),
        ),
      );
    }
    if (stops.isEmpty) {
      throw Exception('未获取到经停信息，可能已超出预售期或被风控拦截');
    }
    final hasMileage = stops.any((s) => s.mileage != null);
    return _TrainDetail(
      trainCode: trainCode,
      trainNo: trainNo,
      date: date,
      startStation:
          startStation.isNotEmpty ? startStation : stops.first.stationName,
      endStation: endStation.isNotEmpty ? endStation : stops.last.stationName,
      stops: stops,
      hasMileage: hasMileage,
      mileageSource: hasMileage ? '12306' : '',
      // 普速车型先填 12306 检索到的，动车会在 _enrichDetail 里换成车组号列表
      consists: searchModel.isEmpty
          ? const <_TrainConsist>[]
          : <_TrainConsist>[_TrainConsist(model: searchModel, source: '12306')],
    );
  }

  // ══ 车次增强数据：里程 / 担当车组 / 正晚点 ═══════════════════════════════

  /// 把里程、担当车组、正晚点并到时刻表上；任一项失败都不影响主流程
  Future<_TrainDetail> _enrichDetail(_TrainDetail d) async {
    final stops = d.stops;
    if (stops.isEmpty) return d;

    // ① 里程（黄河铁路网）
    var mileage = <String, double>{};
    var mileageSource = '';
    if (_kHuangheEnabled) {
      final m = await _mileageOf(d.trainCode);
      if (m.isNotEmpty) {
        mileage = m;
        mileageSource = '黄河铁路网';
      }
    }

    // ② 担当车组 / 车型（动车返回最近所有担当车组）
    final consists = await _consistsOf(d);

    // ③ 正晚点（仅当天）
    var lateMap = <String, _LateInfo>{};
    if (_kLateEnabled && _isSameDay(d.date, DateTime.now())) {
      lateMap = await _lateOf(d);
    }

    final newStops = <_Stop>[];
    for (final s in stops) {
      final km = mileage[_normStation(s.stationName)];
      newStops.add(
        s.copyWith(
          // 黄河铁路网拿不到时保留接口自带的里程
          mileage: km ?? s.mileage,
          late: lateMap[_normStation(s.stationName)],
        ),
      );
    }

    final hasMileage = mileage.isNotEmpty || d.hasMileage;
    return d.copyWith(
      stops: newStops,
      consists: consists.isEmpty ? d.consists : consists,
      mileageSource: mileage.isNotEmpty ? mileageSource : d.mileageSource,
      hasMileage: hasMileage,
    );
  }

  /// 里程：站名（归一化后）→ 累计公里
  Future<Map<String, double>> _mileageOf(String trainCode) async {
    final key = 'mileage|${trainCode.toUpperCase()}';
    final cached = _JsonCache.instance.get(key, _kTtlMileage);
    if (cached is Map) return Map<String, double>.from(cached);

    final res = await _mileageFromHuanghe(trainCode);
    if (res.isNotEmpty) _JsonCache.instance.set(key, res);
    return res;
  }

  /// 黄河铁路网里程页：JSON 优先，HTML 表格兜底
  Future<Map<String, double>> _mileageFromHuanghe(String trainCode) async {
    try {
      final path =
          _kHuangheMileagePath.replaceAll('{train}', Uri.encodeComponent(trainCode));
      final res = await _getPlain(
        Uri.parse('$_kHuangheBase$path'),
        referer: '$_kHuangheBase/',
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return <String, double>{};
      return _parseMileage(res.body);
    } catch (_) {
      return <String, double>{};
    }
  }

  /// 最近担当的动车组（动车走 rail.re /train/{车次}，返回近期全部车组），
  /// 普速只有车型时返回 12306 检索到的那一条；都没有则返回空列表。
  Future<List<_TrainConsist>> _consistsOf(_TrainDetail d) async {
    final key = 'consist|${d.trainCode.toUpperCase()}|${_fmtDash(d.date)}';
    final cached = _JsonCache.instance.get(key, _kTtlConsist);
    if (cached is List<_TrainConsist>) return cached;

    final out = <_TrainConsist>[];

    if (d.isEmu && _kRailReEnabled) {
      final recs = await _railReByTrain(d.trainCode);
      recs.sort((a, b) => b.date.compareTo(a.date)); // 最近担当排最前

      // 同一车组会被多天重复收录：按车组号去重，保留最近一次
      final seen = <String>{};
      final uniq = <_EmuRecord>[];
      for (final r in recs) {
        if (seen.add(r.emuNo)) uniq.add(r);
      }

      final top = uniq.take(_kConsistMax).toList();

      // 只给前几组补车型，避免把 OpenCRHTracker 配额打满
      final models = <String, String>{};
      if (_kCrhEnabled) {
        final jobs = top
            .take(_kConsistProfileMax)
            .map((r) => _emuProfileFromCrh(r.emuNo));
        final profiles = await Future.wait(jobs);
        for (var i = 0; i < profiles.length && i < top.length; i++) {
          final p = profiles[i];
          if (p != null && p.model.isNotEmpty) {
            models[top[i].emuNo] = p.model;
          }
        }
      }

      for (final r in top) {
        out.add(
          _TrainConsist(
            emuNo: r.emuNo,
            model: models[r.emuNo] ?? '',
            note: r.date.isEmpty ? 'rail.re' : '担当 ${r.date}',
            source: 'rail.re',
            date: r.date,
          ),
        );
      }
    }

    // 兜底：动车没查到车组 / 普速，用 12306 检索接口给的车型
    if (out.isEmpty) out.addAll(d.consists);

    if (out.isNotEmpty) _JsonCache.instance.set(key, out);
    return out;
  }

  /// rail.re：GET /train/{车次} → 该车次近期担当车组（供车次详情页用）
  Future<List<_EmuRecord>> _railReByTrain(String trainCode) async {
    final part = await _railRePartByTrain(trainCode);
    return part.records
        .where((r) => r.emuNo.isNotEmpty)
        .toList();
  }

  /// 正晚点：仅当天有效，按站并发（并发上限 _kLateConcurrency）
  /// 官方接口只覆盖过去 1 小时 ~ 未来 3 小时，站数多时只查当前时刻附近的站
  Future<Map<String, _LateInfo>> _lateOf(_TrainDetail d) async {
    final out = <String, _LateInfo>{};
    final names = _lateTargetStations(d);
    if (names.isEmpty) return out;
    for (var i = 0; i < names.length; i += _kLateConcurrency) {
      final end = (i + _kLateConcurrency) < names.length
          ? i + _kLateConcurrency
          : names.length;
      final batch = <Future<_LateInfo?>>[];
      for (var j = i; j < end; j++) {
        batch.add(_queryLate(d.trainCode, names[j], d.date));
      }
      final res = await Future.wait(batch);
      for (var k = 0; k < res.length; k++) {
        final info = res[k];
        if (info != null && info.known) {
          out[_normStation(names[i + k])] = info;
        }
      }
    }
    return out;
  }

  /// 需要查正晚点的站：站少就全查，站多就取当前时刻附近的 _kLateMaxStations 站
  List<String> _lateTargetStations(_TrainDetail d) {
    final all = d.stops.map((s) => s.stationName).toList();
    if (all.length <= _kLateMaxStations) return all;

    final now = DateTime.now();
    final nowMin = now.hour * 60 + now.minute;
    var idx = 0;
    var best = 1 << 30;
    for (var i = 0; i < d.stops.length; i++) {
      final s = d.stops[i];
      final min = _parseHm(
        s.departTime.isNotEmpty ? s.departTime : s.arriveTime,
      );
      if (min == null) continue;
      final diff = (min - nowMin).abs();
      if (diff < best) {
        best = diff;
        idx = i;
      }
    }
    final half = _kLateMaxStations ~/ 2;
    var start = (idx - half).clamp(0, d.stops.length).toInt();
    var end = (start + _kLateMaxStations).clamp(0, d.stops.length).toInt();
    start = (end - _kLateMaxStations).clamp(0, d.stops.length).toInt();
    return all.sublist(start, end);
  }

  /// 单站正晚点：12306 官方 zwdch（接口未公开，仅当天、前后 3 小时内有效）
  Future<_LateInfo?> _queryLate(
    String trainCode,
    String stationName,
    DateTime date,
  ) async {
    final key = 'late|${trainCode.toUpperCase()}|$stationName';
    final cached = _JsonCache.instance.get(key, _kTtlLate);
    if (cached is _LateInfo) return cached;

    try {
      final res = await _client
          .post(
            Uri.parse('$_kLateBase$_kLatePath'),
            headers: <String, String>{
              'User-Agent': _kUserAgent,
              'Accept': 'application/json, text/plain, */*',
              'Accept-Language': 'zh-CN,zh;q=0.9',
              'Referer': '$_kLateBase/init',
              'X-Requested-With': 'XMLHttpRequest',
            },
            body: <String, String>{
              'cz': stationName,
              'cc': trainCode,
              'cxlx': '0', // 0 到达 / 1 出发
              'rq': _fmtDash(date),
            },
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final info = _parseLate(res.body);
      if (info != null) _JsonCache.instance.set(key, info);
      return info;
    } catch (_) {
      return null;
    }
  }

  // ── 4. 车站查询 ─────────────────────────────────────────────────────────

  Future<List<_StationTrain>> queryByStation(
    String stationCode,
    DateTime date, {
    bool forceRefresh = false,
  }) async {
    final key = 'station|$stationCode|${_fmtDash(date)}';
    final cached = forceRefresh
        ? null
        : _JsonCache.instance.get(key, _kTtlLeftTicket);
    if (cached is List<_StationTrain>) return cached;

    final uri = Uri.parse('$_kKyfwBase/otn/czxx/query').replace(
      queryParameters: <String, String>{
        'train_start_date': _fmtDash(date),
        'train_station_code': stationCode,
      },
    );
    final res = await _get(
      uri,
      referer: '$_kKyfwBase/otn/czxx/init',
      origin: _kKyfwBase,
    );
    if (res.statusCode != 200) {
      throw Exception('车站查询失败：HTTP ${res.statusCode}');
    }
    final root = jsonDecode(res.body);
    final dataList = (root is Map<String, dynamic>)
        ? ((root['data'] as Map?)?['data'] as List?)?.cast<dynamic>() ??
            <dynamic>[]
        : <dynamic>[];

    final out = <_StationTrain>[];
    for (final e in dataList) {
      if (e is! Map) continue;
      out.add(
        _StationTrain(
          trainCode: (e['station_train_code'] ?? e['train_code'] ?? '')
              .toString(),
          startStation: (e['start_station_name'] ?? e['from_station'] ?? '')
              .toString(),
          endStation:
              (e['end_station_name'] ?? e['to_station'] ?? '').toString(),
          arriveTime: (e['arrive_time'] ?? '').toString(),
          departTime: (e['start_time'] ?? e['depart_time'] ?? '').toString(),
        ),
      );
    }
    if (out.isEmpty) throw Exception('该站当日无查询数据，可能被拦截或超出预售期');
    _JsonCache.instance.set(key, out);
    return out;
  }

  // ══ 3. 车组号 / 车次查询（多源聚合）══════════════════════════════════════

  /// 关键词既可以是车组号（CR400AF-2031 / CRH2A-2001），也可以是车次（G83）。
  ///
  /// ⚠️ rail.re 两个方向的接口是不同的路径：
  ///   GET /emu/{车组号}  → 该车组近期担当的车次
  ///   GET /train/{车次}  → 该车次近期使用过的车组
  /// 之前只打 /emu/，所以输入车次必然「未收录」。这里先判定关键词类型，
  /// 再选对应路径；判不出来就两条都打。
  ///
  /// 车次路线拿到车组号后，会再并发补 OpenCRHTracker 的历史与配属，
  /// 因此查一次 G83 能看到「近期用过的所有车组 + 各自的配属档案」。
  Future<_EmuResult> queryEmu(
    String keyword, {
    bool forceRefresh = false,
  }) async {
    final q = keyword.trim();
    final key = 'emu|${q.toUpperCase()}';
    final cached = forceRefresh
        ? null
        : _JsonCache.instance.get(key, _kTtlEmu);
    if (cached is _EmuResult) return cached;

    if (!_kRailReEnabled && !_kCrhEnabled) {
      throw Exception('未启用任何车组号数据源，请检查文件顶部开关');
    }

    final kind = _classifyEmuKeyword(q);

    // ① 先按类型打 rail.re
    final parts = <_EmuPart>[];
    final errors = <String>[];

    Future<_EmuPart> railReBy(_EmuQueryKind k) {
      switch (k) {
        case _EmuQueryKind.train:
          return _railRePartByTrain(q);
        case _EmuQueryKind.emu:
          return _emuFromRailRe(q);
        case _EmuQueryKind.unknown:
          return _railReByKeyword(q); // 内部两条都试，取先成功的
      }
    }

    if (_kRailReEnabled) parts.add(await railReBy(kind));

    // ② 车组号路线：直接打 OpenCRHTracker
    if (_kCrhEnabled && kind == _EmuQueryKind.emu) {
      parts.add(await _emuFromCrh(q));
    }

    // ③ 车次路线：把 rail.re 给的车组号展开，补 OpenCRHTracker
    if (_kCrhEnabled && kind == _EmuQueryKind.train) {
      final emuNos = <String>[];
      final seen = <String>{};
      for (final p in parts) {
        for (final r in p.records) {
          if (r.emuNo.isNotEmpty && seen.add(r.emuNo)) emuNos.add(r.emuNo);
        }
      }
      final expand = emuNos.take(_kEmuTrainExpandMax).toList();
      if (expand.isNotEmpty) {
        final expanded = await Future.wait(expand.map(_emuFromCrh));
        parts.addAll(expanded);
      } else {
        // 一个车组号都没拿到，退一步按车组号再试一次（比如关键词其实是车组号）
        parts.add(await _emuFromCrh(q));
      }
    }

    if (_kCrhEnabled && kind == _EmuQueryKind.unknown) {
      parts.add(await _emuFromCrh(q));
    }

    // ③-b 兜底：按车组号一路查下来 rail.re 一条都没有，
    // 再按车次路径试一次（仅此一次，常态不会多打请求）
    if (_kRailReEnabled &&
        kind == _EmuQueryKind.emu &&
        !parts.any((p) => p.records.isNotEmpty)) {
      final asTrain = await _railRePartByTrain(q);
      if (asTrain.records.isNotEmpty) parts.add(asTrain);
    }

    // ④ 汇总
    final records = <_EmuRecord>[];
    final recSeen = <String>{};
    final profiles = <_EmuProfile>[];
    final proSeen = <String>{};

    final errCount = <String, int>{};
    for (final p in parts) {
      if (p.error != null && p.sourceName.isNotEmpty) {
        final msg = '${p.sourceName}：${p.error}';
        errCount[msg] = (errCount[msg] ?? 0) + 1;
      }
      for (final r in p.records) {
        final sig = '${r.emuNo}|${r.trainCode}|${r.date}';
        if (recSeen.add(sig)) records.add(r);
      }
      for (final f in p.profiles) {
        if (proSeen.add(f.emuNo)) profiles.add(f);
      }
    }

    // 多个车组号展开查询时，同一类错误会重复出现，合并成「×N」
    for (final e in errCount.entries) {
      errors.add(e.value > 1 ? '${e.key}（×${e.value}）' : e.key);
    }

    // 按日期倒序：最近担当排最前
    records.sort((a, b) => b.date.compareTo(a.date));

    // 车次查询时把配属档案按「该车组最近担当日期」排序，方便对照
    if (kind == _EmuQueryKind.train && profiles.length > 1) {
      final rank = <String, int>{};
      for (var i = 0; i < records.length; i++) {
        rank.putIfAbsent(records[i].emuNo, () => i);
      }
      profiles.sort(
        (a, b) => (rank[a.emuNo] ?? 999).compareTo(rank[b.emuNo] ?? 999),
      );
    }

    if (records.isEmpty && profiles.isEmpty) {
      throw Exception(
        errors.isEmpty ? '各数据源均未收录「$q」' : '各数据源均无结果\n${errors.join('\n')}',
      );
    }

    final result = _EmuResult(
      keyword: q,
      kind: kind,
      records: records,
      profiles: profiles,
      errors: errors,
    );
    _JsonCache.instance.set(key, result);
    return result;
  }

  /// 判定关键词类型：车次（G83 / 1234）还是车组号（CR400AF-2031 / CRH2A-2001）
  _EmuQueryKind _classifyEmuKeyword(String q) {
    final s = q.trim().toUpperCase();
    if (s.isEmpty) return _EmuQueryKind.unknown;

    // 车组号特征：CR / CRH 前缀，或「字母+数字-数字」结构
    if (s.startsWith('CR')) return _EmuQueryKind.emu;
    if (RegExp(r'^[A-Z]+\d*[A-Z]*-\d{2,5}$').hasMatch(s)) {
      return _EmuQueryKind.emu;
    }
    // 车次特征：单个字母字头 + 纯数字，或纯数字
    if (RegExp(r'^[GDCZTKYLSPAY]\d{1,5}$').hasMatch(s)) {
      return _EmuQueryKind.train;
    }
    if (RegExp(r'^\d{1,5}$').hasMatch(s)) return _EmuQueryKind.train;
    return _EmuQueryKind.unknown;
  }

  /// 判不出类型时：/train/ 与 /emu/ 都打一遍，取先有数据的那个
  Future<_EmuPart> _railReByKeyword(String q) async {
    final trainPart = await _railRePartByTrain(q);
    if (trainPart.records.isNotEmpty) return trainPart;
    final emuPart = await _emuFromRailRe(q);
    if (emuPart.records.isNotEmpty) return emuPart;
    return trainPart.error == null ? trainPart : emuPart;
  }

  /// ①-a rail.re：GET /emu/{车组号} → [ {emu_no, train_no, date}, ... ]
  ///     只接受车组号，传车次会「未收录」
  ///
  /// ⚠️ 车组号写法不统一：库里存的是 CR400BF5033（无横杠），
  /// 但用户习惯输入 CR400BF-5033。带错写法请求会返回空数组（不是报错），
  /// 之前只试一种写法，遇到写法不一致就静默「未收录」。
  /// 这里按 _emuNoVariants 依次尝试，命中即用。
  Future<_EmuPart> _emuFromRailRe(String q) async {
    const name = 'rail.re';
    final tried = <String>[];
    String? lastErr;

    for (final v in _emuNoVariants(q)) {
      if (tried.contains(v)) continue;
      tried.add(v);
      try {
        final res = await _getPlain(
          Uri.parse('$_kRailReBase/emu/${Uri.encodeComponent(v)}'),
          referer: 'https://rail.re/',
        ).timeout(const Duration(seconds: 15));

        if (res.statusCode == 404) {
          lastErr = 'HTTP 404';
          continue; // 换下一种写法再试
        }
        if (res.statusCode != 200) {
          return _EmuPart.error(name, 'HTTP ${res.statusCode}');
        }
        final root = jsonDecode(res.body);
        if (root is! List) return _EmuPart.error(name, '返回格式异常');

        final out = _parseRailReList(root, fallbackEmu: q);
        if (out.isNotEmpty) return _EmuPart(records: out, sourceName: name);
        lastErr = '空结果';
      } catch (e) {
        lastErr = _cleanErr(e);
      }
    }
    return _EmuPart.error(
      name,
      '未收录（已试 ${tried.join(' / ')}）${lastErr == null ? '' : '：$lastErr'}',
    );
  }

  /// ①-b rail.re：GET /train/{车次} → 该车次近期使用过的所有车组
  ///     与 /emu/ 是两个不同的路径，查车次必须走这条
  Future<_EmuPart> _railRePartByTrain(String trainCode) async {
    const name = 'rail.re';
    final code = trainCode.trim().toUpperCase();
    try {
      final res = await _getPlain(
        Uri.parse('$_kRailReBase/train/${Uri.encodeComponent(code)}'),
        referer: 'https://rail.re/',
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        return _EmuPart.error(name, 'HTTP ${res.statusCode}');
      }
      final root = jsonDecode(res.body);
      if (root is! List) return _EmuPart.error(name, '返回格式异常');

      final out = _parseRailReList(root, fallbackTrain: code);
      if (out.isEmpty) return _EmuPart.error(name, '未收录该车次');
      return _EmuPart(records: out, sourceName: name);
    } catch (e) {
      return _EmuPart.error(name, _cleanErr(e));
    }
  }

  /// rail.re 两种接口返回结构一致，共用解析：
  /// [ {emu_no, train_no, date}, ... ] → [_EmuRecord]
  ///
  /// 字段名做多候选：接口改版 / 不同分支的字段命名不一致时（emuNo / train /
  /// serviceDay …），只认死一个名字就会整页解析成空、显示「未收录」。
  List<_EmuRecord> _parseRailReList(
    List root, {
    String fallbackEmu = '',
    String fallbackTrain = '',
  }) {
    String pick(Map e, List<String> keys) {
      for (final k in keys) {
        final v = e[k];
        if (v == null) continue;
        final s = v.toString().trim();
        if (s.isNotEmpty && s != 'null') return s;
      }
      return '';
    }

    final out = <_EmuRecord>[];
    for (final e in root) {
      if (e is! Map) continue;
      final emuNo = _prettyEmuNo(
        pick(e, const <String>['emu_no', 'emuNo', 'emu', 'trainset', 'trainset_no']),
      );
      // train_no 可能是 "G83/G86" 这类复合写法，只取首段
      final trainNo = pick(
        e,
        const <String>['train_no', 'trainNo', 'train_code', 'trainCode', 'train'],
      ).split('/').first.trim();
      final date = pick(
        e,
        const <String>['date', 'run_date', 'service_day', 'serviceDay', 'day'],
      );
      final short = date.length >= 16 ? date.substring(0, 16) : date;
      final emu = emuNo.isNotEmpty ? emuNo : fallbackEmu;
      final train = trainNo.isNotEmpty ? trainNo : fallbackTrain;
      if (emu.isEmpty && train.isEmpty) continue;
      out.add(_EmuRecord(
        emuNo: emu,
        trainCode: train,
        date: short.length >= 10 ? short.substring(0, 10) : short,
        source: _EmuSource.railRe,
      ));
    }
    return out;
  }

  /// ② OpenCRHTracker：历史担当 + 配属档案
  ///    车组号同样按 _emuNoVariants 逐个试，避免写法不一致导致空结果
  Future<_EmuPart> _emuFromCrh(String q) async {
    const name = 'OpenCRHTracker';
    try {
      final records = <_EmuRecord>[];
      String? histErr;
      String? hitVariant;

      for (final v in _emuNoVariants(q)) {
        final hist = await _getPlain(
          Uri.parse('$_kCrhBase/history/emu/${Uri.encodeComponent(v)}')
              .replace(queryParameters: <String, String>{'limit': '60'}),
          referer: 'https://crh.lihugang.top/',
        ).timeout(const Duration(seconds: 15));

        final parsed = <_EmuRecord>[];

        if (hist.statusCode == 200) {
          final root = jsonDecode(hist.body);
          final data = (root is Map) ? root['data'] : null;
          final items = (data is Map) ? (data['items'] as List?) : null;
          if (items != null) {
            for (final e in items) {
              if (e is! Map) continue;
              final code = _joinTrainCode(e['trainCode']);
              final day = e['serviceDay'];
              final date = (day is int)
                  ? _fmtDash(_serviceDayToDate(day))
                  : '';
              parsed.add(_EmuRecord(
                emuNo: _prettyEmuNo(q),
                trainCode: code,
                date: date,
                source: _EmuSource.crhTracker,
              ));
            }
          }
          if (root is Map && root['ok'] == false) {
            histErr = (root['error'] ?? '查询失败').toString();
          }
        } else if (hist.statusCode == 404) {
          histErr = '未收录';
        } else if (hist.statusCode == 429) {
          histErr = '触发限频，稍后再试';
          break; // 继续试只是浪费配额
        } else {
          histErr = 'HTTP ${hist.statusCode}';
        }

        if (parsed.isNotEmpty) {
          records.addAll(parsed);
          hitVariant = v;
          histErr = null;
          break;
        }
      }

      // 配属档案失败不影响交路展示；同样按变体逐个试
      final profile = await _emuProfileFromCrhAny(hitVariant ?? q);

      if (records.isEmpty && profile == null) {
        return _EmuPart.error(name, histErr ?? '未收录');
      }
      return _EmuPart(
        records: records,
        profiles: profile == null
            ? const <_EmuProfile>[]
            : <_EmuProfile>[profile],
        sourceName: name,
      );
    } catch (e) {
      return _EmuPart.error(name, _cleanErr(e));
    }
  }

  /// 配属档案按车组号写法逐个尝试，任一命中即返回
  Future<_EmuProfile?> _emuProfileFromCrhAny(String q) async {
    for (final v in _emuNoVariants(q)) {
      final p = await _emuProfileFromCrh(v);
      if (p != null) return p;
    }
    return null;
  }

  /// 配属档案：GET /api/v2/allocation/emu/{q}
  Future<_EmuProfile?> _emuProfileFromCrh(String q) async {
    try {
      final res = await _getPlain(
        Uri.parse('$_kCrhBase/allocation/emu/${Uri.encodeComponent(q)}'),
        referer: 'https://crh.lihugang.top/',
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final root = jsonDecode(res.body);
      final data = (root is Map) ? root['data'] : null;
      if (data is! Map) return null;

      final tags = <String>[];
      final rawTags = data['tags'];
      if (rawTags is List) {
        for (final t in rawTags) {
          final s = t.toString().trim();
          if (s.isNotEmpty) tags.add(s);
        }
      }

      final p = _EmuProfile(
        emuNo: _prettyEmuNo(q),
        model: (data['model'] ?? '').toString(),
        bureau: (data['bureau'] ?? '').toString(),
        trainDepot: (data['trainDepot'] ?? '').toString(),
        depot: (data['depot'] ?? '').toString(),
        manufacturer: (data['trainsetManufacturer'] ?? '').toString(),
        manufactureMonth: (data['manufactureMonth'] ?? '').toString(),
        designMaxSpeed: (data['designMaxSpeed'] is num)
            ? (data['designMaxSpeed'] as num).toInt()
            : null,
        tags: tags,
      );
      return p.isEmpty ? null : p;
    } catch (_) {
      return null;
    }
  }

  // ══ 4. 车站大屏 ═══════════════════════════════════════════════════════════

  /// 分页风格探测顺序：offset → page → cursor → 时间戳切片
  static const List<_BoardPageStyle> _styleOrder = <_BoardPageStyle>[
    _BoardPageStyle.offset,
    _BoardPageStyle.page,
    _BoardPageStyle.cursor,
    _BoardPageStyle.timestamp,
  ];

  /// 车站大屏：走 OpenCRHTracker 车站时刻表，失败则由上层回退 12306 原接口。
  ///
  /// 数据源单次上限 $_kBoardPageSize 条，大站必然截断，所以这里：
  ///   首屏自动翻满 _kBoardAutoPages 页，剩下的交给 loadMore 继续追加。
  Future<_BoardResult> queryStationBoard(
    String stationName, {
    bool forceRefresh = false,
    bool loadMore = false,
    int morePages = _kBoardMorePages,
    _BoardResult? previous,
  }) async {
    final name = stationName.trim();
    final key = 'board|$name';

    // ── 加载更多：在已有结果上继续翻页 ──
    if (loadMore) {
      final cached =
          forceRefresh ? null : _JsonCache.instance.get(key, _kTtlBoard);
      final base = previous ?? (cached is _BoardResult ? cached : null);
      if (base == null) throw Exception('请先查询「$name」的车站大屏');
      if (!base.hasMore) return base;

      final more = await _boardCollect(base, morePages);
      _JsonCache.instance.set(key, more);
      return more;
    }

    final cached =
        forceRefresh ? null : _JsonCache.instance.get(key, _kTtlBoard);
    if (cached is _BoardResult) return cached;

    if (!_kCrhEnabled) {
      throw Exception('大屏数据源已关闭（_kCrhEnabled = false）');
    }

    final first = await _boardFetchPage(name, null, _BoardPageStyle.none);
    if (first.items.isEmpty) throw Exception('该站当日无数据');

    var result = _BoardResult(
      station: name,
      items: first.items,
      notes: const <String>[],
      total: first.total,
      fetched: first.items.length,
      pages: 1,
      hasMore: first.hasMore ?? (first.items.length >= _kBoardPageSize),
      truncated: (first.total ?? first.items.length) > first.items.length,
      nextCursor: first.nextCursor,
    );

    if (result.hasMore) {
      result = await _boardCollect(result, _kBoardAutoPages - 1);
    }
    _JsonCache.instance.set(key, result);
    return result;
  }

  /// 从 [start] 继续翻页，最多再翻 [maxPages] 页。
  /// 探测失败 / 请求失败都不会丢掉已拿到的数据，只是把 hasMore 关掉。
  Future<_BoardResult> _boardCollect(_BoardResult start, int maxPages) async {
    var cur = start;
    if (maxPages <= 0) return cur;

    final seen = <String>{for (final e in cur.items) e.dedupKey};

    var loaded = 0; // 成功追加的页数
    var guard = 0; // 总请求次数（含探测失败），防止无效风格把预算耗光

    while (loaded < maxPages && cur.hasMore && guard < maxPages + 4) {
      guard++;
      var style = cur.style;
      final probing = style == _BoardPageStyle.none;

      if (probing) {
        final next = _nextBoardStyle(cur);
        if (next == null) {
          // 四种风格全试过都拿不到新东西：停在现有数据并如实标注
          return cur.copyWith(
            hasMore: false,
            truncated: true,
            notes: <String>[
              ...cur.notes,
              '数据源单次最多返回 $_kBoardPageSize 条且未支持分页，'
                  '仅取到前 ${cur.items.length} 趟；可切换时段查看其余车次',
            ],
          );
        }
        style = next;
      }

      _BoardPage page;
      try {
        page = await _boardFetchPage(cur.station, cur, style);
      } catch (e) {
        cur = cur.copyWith(
          tried: <_BoardPageStyle>[...cur.tried, style],
          notes: <String>[...cur.notes, '继续加载失败：${_cleanErr(e)}'],
        );
        if (!probing) return cur.copyWith(hasMore: false);
        _boardStyleDead.add(style);
        continue;
      }

      if (page.items.isEmpty) {
        cur = probing
            ? cur.copyWith(tried: <_BoardPageStyle>[...cur.tried, style])
            : cur.copyWith(hasMore: false);
        if (!probing) break;
        _boardStyleDead.add(style);
        continue;
      }

      final fresh = <_BoardItem>[];
      for (final it in page.items) {
        if (seen.add(it.dedupKey)) fresh.add(it);
      }

      if (fresh.isEmpty) {
        // 整页都与已有数据重复 → 服务端根本不认这个参数，换下一种
        cur = cur.copyWith(tried: <_BoardPageStyle>[...cur.tried, style]);
        if (!probing) return cur.copyWith(hasMore: false);
        _boardStyleDead.add(style);
        continue;
      }

      cur = cur.append(page, fresh).copyWith(style: style);
      _boardStyleLocked ??= style;
      loaded++;
      if (page.items.length < _kBoardPageSize) {
        cur = cur.copyWith(hasMore: false);
      }
    }
    return cur;
  }

  /// 下一个还没试过、且当前可用的分页风格
  _BoardPageStyle? _nextBoardStyle(_BoardResult cur) {
    // 同一数据源对所有车站行为一致：探明一次就全局复用，别每次换站都重试
    final locked = _boardStyleLocked;
    if (locked != null) {
      return _styleUsable(locked, cur) ? locked : null;
    }
    for (final s in _styleOrder) {
      if (cur.tried.contains(s) || _boardStyleDead.contains(s)) continue;
      if (!_styleUsable(s, cur)) continue;
      return s;
    }
    return null;
  }

  bool _styleUsable(_BoardPageStyle s, _BoardResult cur) {
    if (s == _BoardPageStyle.cursor) return cur.nextCursor.isNotEmpty;
    if (s == _BoardPageStyle.timestamp) return _lastBoardTs(cur) > 0;
    return true;
  }

  /// 时间戳切片用的游标：已取数据里最后一条的发车时间戳
  int _lastBoardTs(_BoardResult cur) {
    for (var i = cur.items.length - 1; i >= 0; i--) {
      final t = cur.items[i].departAt;
      if (t > 0) return t;
    }
    return 0;
  }

  /// OpenCRHTracker 车站时刻表：GET /api/v2/timetable/station/{站名}
  /// [style] 为 none 时表示首页，不带任何翻页参数。
  Future<_BoardPage> _boardFetchPage(
    String station,
    _BoardResult? cur,
    _BoardPageStyle style,
  ) async {
    final qp = <String, String>{'limit': '$_kBoardPageSize'};
    switch (style) {
      case _BoardPageStyle.none:
        break;
      case _BoardPageStyle.offset:
        qp[_kBoardOffsetKey] = '${cur?.fetched ?? 0}';
        break;
      case _BoardPageStyle.page:
        qp[_kBoardPageKey] = '${(cur?.pages ?? 0) + 1}';
        break;
      case _BoardPageStyle.cursor:
        qp[_kBoardCursorKey] = cur?.nextCursor ?? '';
        break;
      case _BoardPageStyle.timestamp:
        qp[_kBoardAfterTsKey] = cur == null ? '0' : '${_lastBoardTs(cur)}';
        break;
    }

    final res = await _getPlain(
      Uri.parse(
        '$_kCrhBase/timetable/station/${Uri.encodeComponent(station)}',
      ).replace(queryParameters: qp),
      referer: 'https://crh.lihugang.top/',
    ).timeout(const Duration(seconds: 15));

    if (res.statusCode == 404) throw Exception('未收录该站');
    if (res.statusCode == 429) throw Exception('触发限频，稍后再试');
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');

    final root = jsonDecode(res.body);
    if (root is Map && root['ok'] == false) {
      throw Exception((root['error'] ?? '查询失败').toString());
    }
    final data = (root is Map) ? root['data'] : null;
    final items = (data is Map) ? (data['items'] as List?) : null;
    if (items == null || items.isEmpty) {
      return const _BoardPage(items: <_BoardItem>[]);
    }

    final out = <_BoardItem>[];
    for (final e in items) {
      if (e is! Map) continue;

      // allCodes 里取主车次，兼容跨天/复用车次号
      String code = '';
      final all = e['allCodes'];
      if (all is List && all.isNotEmpty) {
        code = _joinTrainCode(all.first);
      }
      if (code.isEmpty) code = _joinTrainCode(e['trainCode']);

      final models = <String>[];
      final rm = e['referenceModels'];
      if (rm is List) {
        for (final m in rm) {
          if (m is Map) {
            final s = (m['model'] ?? '').toString().trim();
            if (s.isNotEmpty) models.add(s);
          } else {
            final s = m.toString().trim();
            if (s.isNotEmpty) models.add(s);
          }
        }
      }

      final plat = e['platformNo'];
      final aTs = (e['arriveAt'] is int) ? e['arriveAt'] as int : 0;
      final dTs = (e['departAt'] is int) ? e['departAt'] as int : 0;
      out.add(_BoardItem(
        trainCode: code,
        startStation: (e['startStation'] ?? '').toString(),
        endStation: (e['endStation'] ?? '').toString(),
        arriveTime: _hhmm(aTs > 0 ? aTs : null),
        departTime: _hhmm(dTs > 0 ? dTs : null),
        platform: (plat is int && plat > 0) ? '$plat' : '',
        models: models,
        source: _EmuSource.crhTracker,
        arriveAt: aTs,
        departAt: dTs,
      ));
    }

    return _BoardPage(
      items: out,
      total: _readBoardTotal(root, data),
      hasMore: _readBoardHasMore(root, data),
      nextCursor: _readBoardCursor(root, data),
    );
  }

  /// 服务端自报总条数（字段名各家不一，多试几个；读不到返回 null）
  int? _readBoardTotal(dynamic root, dynamic data) {
    for (final k in <String>['total', 'totalCount', 'count', 'total_count']) {
      final v = (data is Map ? data[k] : null) ?? (root is Map ? root[k] : null);
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) {
        final n = int.tryParse(v);
        if (n != null) return n;
      }
    }
    return null;
  }

  bool? _readBoardHasMore(dynamic root, dynamic data) {
    for (final k in <String>['hasMore', 'hasNext', 'has_next', 'more']) {
      final v = (data is Map ? data[k] : null) ?? (root is Map ? root[k] : null);
      if (v is bool) return v;
    }
    return null;
  }

  String _readBoardCursor(dynamic root, dynamic data) {
    for (final k in <String>['nextCursor', 'next_cursor', 'pageToken', 'next']) {
      final v = (data is Map ? data[k] : null) ?? (root is Map ? root[k] : null);
      if (v is String && v.isNotEmpty) return v;
      if (v is num) return v.toString();
    }
    return '';
  }

  // ══ 5. 普速配属查询（车厢 / 机车，两个完全独立的源）══════════════════════

  /// 车厢配属查询（cr400bf.passearch.info）
  ///
  /// 两个站都只有 HTML 表格，靠 _parseHtmlTable 硬解析。
  /// 按哪个维度（type）、查什么关键词，全部由用户在界面上选，代码不做猜测与回退。
  Future<_CarPart> queryCarStock(
    String keyword,
    String type, {
    bool forceRefresh = false,
    bool loadMore = false,
    _CarPart? previous,
  }) async {
    if (!_kPasCarEnabled) throw Exception('车厢数据源已关闭，检查文件顶部开关');
    final kw = keyword.trim();
    if (kw.isEmpty) throw Exception('请输入查询关键字');
    final key = _psCacheKey('car', kw, type);

    if (loadMore) {
      final base = previous ??
          (forceRefresh
              ? null
              : _JsonCache.instance.get(key, _kTtlPas) as _CarPart?);
      if (base == null) throw Exception('请先查询「$kw」');
      if (!base.hasMore) return base;
      final next =
          await _psCarMore(base, kw, base.type, _kPasMorePages);
      _JsonCache.instance.set(key, next);
      return next;
    }

    final cached =
        forceRefresh ? null : _JsonCache.instance.get(key, _kTtlPas);
    if (cached is _CarPart) return cached;

    final part = await _psFetchCars(kw, 1, type);
    if (part.items.isEmpty) {
      throw Exception(part.error ?? '没有查到「$kw」的车厢记录');
    }
    _JsonCache.instance.set(key, part);
    return part;
  }

  /// 机车配属查询（loco.passearch.info）
  Future<_LocoPart> queryLocoStock(
    String keyword,
    String type, {
    bool forceRefresh = false,
    bool loadMore = false,
    _LocoPart? previous,
  }) async {
    if (!_kPasLocoEnabled) throw Exception('机车数据源已关闭，检查文件顶部开关');
    final kw = keyword.trim();
    if (kw.isEmpty) throw Exception('请输入查询关键字');
    final key = _psCacheKey('loco', kw, type);

    if (loadMore) {
      final base = previous ??
          (forceRefresh
              ? null
              : _JsonCache.instance.get(key, _kTtlPas) as _LocoPart?);
      if (base == null) throw Exception('请先查询「$kw」');
      if (!base.hasMore) return base;
      final next =
          await _psLocoMore(base, kw, base.type, _kPasMorePages);
      _JsonCache.instance.set(key, next);
      return next;
    }

    final cached =
        forceRefresh ? null : _JsonCache.instance.get(key, _kTtlPas);
    if (cached is _LocoPart) return cached;

    final part = await _psFetchLocos(kw, 1, type);
    if (part.items.isEmpty) {
      throw Exception(part.error ?? '没有查到「$kw」的机车记录');
    }
    _JsonCache.instance.set(key, part);
    return part;
  }

  String _psCacheKey(String kind, String kw, String type) =>
      'ps|$kind|${kw.toUpperCase()}|$type';

  Future<_CarPart> _psCarMore(
    _CarPart cur,
    String kw,
    String type,
    int maxPages,
  ) async {
    var next = cur;
    final seen = <String>{for (final e in cur.items) e.dedupKey};
    for (var i = 0; i < maxPages && next.hasMore; i++) {
      final p = await _psFetchCars(kw, next.pages + 1, type);
      if (p.error != null) return next.copyWith(hasMore: false);
      final fresh = <_CarStock>[];
      for (final it in p.items) {
        if (seen.add(it.dedupKey)) fresh.add(it);
      }
      if (fresh.isEmpty) return next.copyWith(hasMore: false);
      next = next.copyWith(
        items: <_CarStock>[...next.items, ...fresh],
        total: p.total ?? next.total,
        pages: next.pages + 1,
        hasMore: _psHasMore(next.items.length + fresh.length, p.total,
            p.items.length),
      );
    }
    return next;
  }

  Future<_LocoPart> _psLocoMore(
    _LocoPart cur,
    String kw,
    String type,
    int maxPages,
  ) async {
    var next = cur;
    final seen = <String>{for (final e in cur.items) e.dedupKey};
    for (var i = 0; i < maxPages && next.hasMore; i++) {
      final p = await _psFetchLocos(kw, next.pages + 1, type);
      if (p.error != null) return next.copyWith(hasMore: false);
      final fresh = <_LocoItem>[];
      for (final it in p.items) {
        if (seen.add(it.dedupKey)) fresh.add(it);
      }
      if (fresh.isEmpty) return next.copyWith(hasMore: false);
      next = next.copyWith(
        items: <_LocoItem>[...next.items, ...fresh],
        total: p.total ?? next.total,
        pages: next.pages + 1,
        hasMore: _psHasMore(next.items.length + fresh.length, p.total,
            p.items.length),
      );
    }
    return next;
  }

  /// 车厢：GET {base}/index.php?keyword={kw}&type={type}&pagenum={page}
  Future<_CarPart> _psFetchCars(String kw, int page, String type) async {
    final uri = Uri.parse('$_kPasCarBase/index.php').replace(
      queryParameters: <String, String>{
        'keyword': kw,
        'type': type,
        'pagenum': '$page',
      },
    );
    String body;
    try {
      final res = await _getPlain(uri, referer: '$_kPasCarBase/')
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        return _CarPart(type: type, error: 'HTTP ${res.statusCode}');
      }
      body = utf8.decode(res.bodyBytes, allowMalformed: true);
    } catch (e) {
      return _CarPart(type: type, error: _cleanErr(e));
    }
    if (body.contains('参数错误')) {
      return _CarPart(type: type, error: '参数错误（该维度不被支持）');
    }

    final total = _pasTotal(body);
    // 先把服务端声明的条数传进解析器：它说有 N>0 条时放宽行过滤
    final table = _parseHtmlTable(body, declared: total);
    if (table.rows.isEmpty) {
      return _CarPart(
        type: type,
        total: total,
        error: _psEmptyReason(body, total, '车厢', type),
      );
    }

    final items = <_CarStock>[];
    for (final row in table.rows) {
      final s = _CarStock(
        model: _pasCell(row, table.header, const <String>['型号'], 0),
        carNo: _pasCell(row, table.header, const <String>['车号'], 1),
        depot: _pasCell(row, table.header, const <String>['现配属', '配属'], 2),
        capacity: _pasCell(row, table.header, const <String>['定员'], 3),
        trainCode: _pasCell(
          row,
          table.header,
          const <String>['运用车次', '运用车次(仅供参考)', '车次'],
          4,
        ),
        factory: _pasCell(row, table.header, const <String>['制造厂', '厂家'], 5),
        bogie: _pasCell(row, table.header, const <String>['转向架'], 6),
      );
      if (s.isEmpty) continue;
      items.add(s);
    }
    final kept = items.where((e) => !e.isEmpty).toList();
    return _CarPart(
      items: kept,
      total: total,
      pages: page,
      hasMore: _psHasMore(kept.length, total, table.rows.length),
      type: type,
    );
  }

  /// 机车：GET {base}/index.php?keyword={kw}&type={type}&pagenum={page}
  Future<_LocoPart> _psFetchLocos(String kw, int page, String type) async {
    final uri = Uri.parse('$_kPasLocoBase/index.php').replace(
      queryParameters: <String, String>{
        'keyword': kw,
        'type': type,
        'pagenum': '$page',
      },
    );
    String body;
    try {
      final res = await _getPlain(uri, referer: '$_kPasLocoBase/')
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        return _LocoPart(type: type, error: 'HTTP ${res.statusCode}');
      }
      body = utf8.decode(res.bodyBytes, allowMalformed: true);
    } catch (e) {
      return _LocoPart(type: type, error: _cleanErr(e));
    }
    if (body.contains('参数错误')) {
      return _LocoPart(type: type, error: '参数错误（该维度不被支持）');
    }

    final total = _pasTotal(body);
    final table = _parseHtmlTable(body, declared: total);
    if (table.rows.isEmpty) {
      return _LocoPart(
        type: type,
        total: total,
        error: _psEmptyReason(body, total, '机车', type),
      );
    }

    final items = <_LocoItem>[];
    for (final row in table.rows) {
      // ⚠️ 机车页表头实测是 4 格「车号 | 配属机务段 | 厂家 | 备注」，
      //    「配属」和「机务段」是同一格。两个字段都按包含匹配取到同一列时，
      //    只保留一个，否则副标题会显示成「沈局沈段沈局沈段」。
      final bureau = _pasCell(row, table.header, const <String>['配属'], 1);
      var depot = _pasCell(row, table.header, const <String>['机务段'], 2);
      if (depot == bureau) depot = '';
      items.add(
        _LocoItem(
          locoNo: _pasCell(row, table.header, const <String>['车号'], 0),
          bureau: bureau,
          depot: depot,
          factory:
              _pasCell(row, table.header, const <String>['厂家', '制造厂'], 3),
          note: _pasCell(row, table.header, const <String>['备注'], 4),
        ),
      );
    }
    final kept = items.where((e) => !e.isEmpty).toList();
    return _LocoPart(
      items: kept,
      total: total,
      pages: page,
      hasMore: _psHasMore(kept.length, total, table.rows.length),
      type: type,
    );
  }

  /// 还能不能翻：优先看服务端给的总数，读不到就看本页是否拿满
  bool _psHasMore(int loaded, int? total, int rowsThisPage) {
    if (total != null) return loaded < total;
    return rowsThisPage >= _kPasPageSize;
  }
}

/// 「共有符合条件的记录 1360 条」
int? _pasTotal(String body) {
  final m = RegExp(r'共有符合条件的记录\s*(\d+)\s*条').firstMatch(body);
  if (m != null) return int.tryParse(m.group(1) ?? '');
  return null;
}

/// 查不到东西时，把原因说清楚——别只丢一句「无记录」
///
/// 这两个站在「查不到」和「不支持」上的表现完全不同，混在一起根本没法排查：
///   · 参数不对  → 页面出现「参数错误」
///   · 参数对但没数据 → 返回首页模板，没有「共有符合条件的记录」这行
///   · 真有数据但解析不出来 → 有「共有符合条件的记录 N 条」却没解析到行
/// 另外机车站按型号查时输完整车号（HXD3D0001）会静默返回 0 条，
/// 这里单独点出来，否则用户只会看到「无记录」干瞪眼。
String _psEmptyReason(String body, int? declared, String what, String type) {
  final trCount = RegExp(r'<tr', caseSensitive: false).allMatches(body).length;

  if (declared == 0) {
    final tip = what == '机车' && type == 'model'
        ? '　按型号查请输型号本身（HXD3D），不要输完整车号 HXD3D0001'
        : '';
    return '服务端返回 0 条：换个关键字或换个维度试试。$tip';
  }
  if (declared != null) {
    return '页面写着「共有 $declared 条」，但表格没解析出数据行'
        '（共扫到 $trCount 个 <tr>）。\n'
        '请确认实际 URL：…/index.php?keyword=…&type=$type&pagenum=1\n'
        '前几行实际内容：\n${_psTableDebug(body)}';
  }
  final noResult = body.contains('共有符合条件的记录');
  if (noResult) {
    return '页面有结果统计但解析为空（共扫到 $trCount 个 <tr>）。\n'
        '前几行实际内容：\n${_psTableDebug(body)}';
  }
  final gb = body.contains(RegExp(r'charset=["'']?gb', caseSensitive: false));
  return '没查到「$what」记录：服务端既没报错也没给结果'
      '（扫到 $trCount 个 <tr>）。'
      '${gb ? '⚠️ 该页声明为 GBK 编码，中文可能乱码。' : ''}'
      '常见原因：关键字写法不对，或该维度此刻无数据。';
}

/// 按表头名取单元格；表头识别失败时退回列序 fallback
String _pasCell(
  List<String> row,
  Map<String, int> header,
  List<String> names,
  int fallback,
) {
  // ① 精确匹配
  for (final n in names) {
    final idx = header[n];
    if (idx != null && idx < row.length) return row[idx];
  }
  // ② 包含匹配：机车页实测表头是「配属机务段」这种合并格，
  //    精确找「配属」「机务段」都找不到，只能靠包含关系认出来。
  for (final n in names) {
    for (final e in header.entries) {
      if (e.key.contains(n) || n.contains(e.key)) {
        if (e.value < row.length) return row[e.value];
      }
    }
  }
  return fallback < row.length ? row[fallback] : '';
}

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
  final accent = _bureauColor(context, l.bureau.isNotEmpty ? l.bureau : l.locoNo);

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
                      if (l.bureau.isNotEmpty)
                        _psChip(context, text: l.bureau, color: accent),
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

/// 非数据行的特征词。
///
/// ⚠️ 这两个站的表格之外还有一堆行会被 <tr> 扫进来：页脚的
/// 「友情链接: 日本列岛列车大行进 2022 火车wiki在线客里表」、
/// 分页栏「首页 上一页 下一页 尾页 (2/15)」、统计行「共有符合条件的记录 N 条」、
/// 顶部导航「查询方式: 车号 型号 …」、版本行「p@ssearch 3.5 Build 37276」。
/// 不加这道过滤，页脚那串日文友情链接会被当成一条车厢数据渲染出来。
bool _isPaSSearchJunkRow(String t) {
  const junk = <String>[
    '共有符合条件的记录',
    '首页',
    '尾页',
    '上一页',
    '下一页',
    '友情链接',
    '查询方式',
    '查询关键字',
    'Contact us',
    'Build',
    '主页面',
    '动车组配属查询',
    '数据反馈',
    '备用站',
    '返回',
    '提交',
  ];
  for (final k in junk) {
    if (t.contains(k)) return true;
  }
  return false;
}

/// 数据行至少要有一个「像车号/型号」的单元格：字母开头、混着数字
/// （YW25T / 683046 / HXD3D0001 / RZ25B110389 都符合，纯中文的页脚不符合）
bool _looksLikeStockRow(List<String> cells) {
  for (final t in cells) {
    if (RegExp(r'^[A-Za-z]{1,}[A-Za-z0-9\-]*\d{2,}').hasMatch(t)) return true;
    if (RegExp(r'^\d{4,}').hasMatch(t)) return true; // 纯数字车号（6 位）
  }
  return false;
}

/// 极简 HTML 表格解析：表头列名 → 列索引 + 数据行（保留空单元格）
class _HtmlTable {
  final Map<String, int> header;
  final List<List<String>> rows;

  const _HtmlTable({this.header = const <String, int>{}, this.rows = const []});
}

/// 一行是否够格当数据行。
/// [strict] = false 时放宽「必须长得像车号」这道过滤（只留 junk 过滤）。
///
/// ⚠️ 为什么要放宽：机车页实测表头是 4 格「车号 | 配属机务段 | 厂家 | 备注」，
///    数据行形如「HXD3D0001 | 沈局沈段 | 大连 | …」，
///    一旦车号列的写法超出 _looksLikeStockRow 的正则（比如带空格、纯中文局段在前），
///    整页 200 多条会被一刀切光，页面却仍写着「共有 210 条」。
///    所以服务端声明了 N>0 条时，宁可信它，放宽过滤。
/// 把 HTML 里的表格切成「行 → 单元格」。
///
/// ⚠️ 关键：这两个站的数据行**没有写 `</tr>`**（实测页面 `<tr` 出现 53 次、
///    带 `</tr>` 的只有 3 个）。浏览器容错能正常渲染，但
///    `<tr[^>]*>(.*?)</tr>` 这种成对正则只会匹配到 3 行 —— 结果就是
///    「页面写着 210 条，却解析出 0 行」，而且报错信息看着像页面结构变了。
///
/// 所以这里改成**按位置切分**，完全不依赖闭合标签：
///   1. 扫出所有 `<tr`、`<td`/`<th`、`</table` 的起始下标；
///   2. 第 i 行的区间 = [第 i 个 `<tr`, 第 i+1 个 `<tr`)，遇到 `</table` 提前截断；
///   3. 落在该区间内的 `<td`/`<th` 就是这一行的单元格，
///      每个单元格的文本 = 从它的 `<td` 到下一个 `<td`（或区间末尾），去标签。
/// 这样闭合与否都能正确解析，列也不会错位。
///
/// 注意 `<t[dh](?![a-z])` 的负向预查：否则 `<thead>` 会被当成 `<th`。
List<List<String>> _htmlRows(String body) {
  final rowStarts = <int>[];
  final cellStarts = <int>[];
  final tableEnds = <int>[];
  for (final m in RegExp(r'<tr(?![a-z])', caseSensitive: false)
      .allMatches(body)) {
    rowStarts.add(m.start);
  }
  for (final m in RegExp(r'<t[dh](?![a-z])', caseSensitive: false)
      .allMatches(body)) {
    cellStarts.add(m.start);
  }
  for (final m in RegExp(r'</table', caseSensitive: false).allMatches(body)) {
    tableEnds.add(m.start);
  }

  final out = <List<String>>[];
  for (var i = 0; i < rowStarts.length; i++) {
    final rs = rowStarts[i];
    var end = i + 1 < rowStarts.length ? rowStarts[i + 1] : body.length;
    for (final te in tableEnds) {
      if (te > rs && te < end) {
        end = te;
        break;
      }
    }
    final mine = <int>[];
    for (final cs in cellStarts) {
      if (cs >= rs && cs < end) mine.add(cs);
    }
    if (mine.isEmpty) continue;
    final cells = <String>[];
    for (var j = 0; j < mine.length; j++) {
      final ce = j + 1 < mine.length ? mine[j + 1] : end;
      cells.add(_htmlText(body.substring(mine[j], ce > body.length ? body.length : ce)));
    }
    out.add(cells);
  }
  return out;
}

bool _psIsDataRow(List<String> cells, {bool strict = true}) {
  if (cells.where((t) => t.isNotEmpty).length < 2) return false;
  if (cells.any(_isPaSSearchJunkRow)) return false;
  return strict ? _looksLikeStockRow(cells) : true;
}

_HtmlTable _parseHtmlTable(String body, {int? declared}) {
  // 按位置切分，不依赖 </tr> / </td> 闭合标签（见 _htmlRows 注释）
  final all = _htmlRows(body);

  // ── 找表头 ──────────────────────────────────────────────────────────────
  // ⚠️ 这里踩过坑：页面顶部的「查询方式：车号 配属段 厂家」同样满足
  //    「含车号 + 含业务列名」，所以它也是表头候选。
  //    早期版本取**最后一个**候选，结果当页面靠后还有一处类似行时，
  //    headIdx 就落在数据之后 → 解析出 0 行（页面却写着 739 条）。
  //    现在改成：给每个候选打分 = 它后面连续像数据行的行数，取分最高的那个。
  const headKeys = <String>['配属', '转向架', '定员', '机务段', '备注', '厂家'];
  var headIdx = -1;
  var bestScore = -1;
  for (var i = 0; i < all.length; i++) {
    final c = all[i];
    if (!c.any((t) => t.contains('车号'))) continue;
    if (!c.any((t) => headKeys.any((k) => t.contains(k)))) continue;
    if (c.any(_isPaSSearchJunkRow)) continue; // 查询表单行也算 junk
    var score = 0;
    for (var j = i + 1; j < all.length; j++) {
      if (_psIsDataRow(all[j], strict: false)) {
        score++;
      } else if (score > 0 && all[j].any((t) => t.contains('车号'))) {
        break; // 撞上下一个表头就停
      }
    }
    if (score > bestScore) {
      bestScore = score;
      headIdx = i;
    }
  }

  final header = <String, int>{};
  if (headIdx >= 0) {
    final hc = all[headIdx];
    for (var i = 0; i < hc.length; i++) {
      if (hc[i].isEmpty) continue;
      header.putIfAbsent(hc[i], () => i);
    }
  }

  // 服务端声明了 N>0 条时放宽过滤：它说有数据，我们就别把数据筛没了
  final strict = declared == null || declared <= 0;

  final rows = <List<String>>[];
  if (headIdx >= 0) {
    for (var i = headIdx + 1; i < all.length; i++) {
      if (_psIsDataRow(all[i], strict: strict)) rows.add(all[i]);
    }
  }

  // ── 兜底：表头定位失败（或定位错了）时，全表扫一遍 ──────────────────────
  // 宁可多扫几行，也不要在「页面明明写着 N 条」时返回 0 行。
  if (rows.isEmpty) {
    for (var i = 0; i < all.length; i++) {
      if (i == headIdx) continue;
      if (_psIsDataRow(all[i], strict: false)) rows.add(all[i]);
    }
  }
  return _HtmlTable(header: header, rows: rows);
}

/// 解析失败时给用户的现场证据：前若干行 + 最后几行的单元格内容
/// （用同一套 _htmlRows 切分，保证打出来的就是解析器实际看到的东西）
String _psTableDebug(String body) {
  final all = _htmlRows(body);
  final sb = StringBuffer();
  for (var i = 0; i < all.length && i < 8; i++) {
    sb.writeln('第${i + 1}行[${all[i].length}格]: ${all[i].join(' | ')}');
  }
  if (all.length > 8) {
    sb.writeln('（共 ${all.length} 行，以下为最后 2 行）');
    for (var i = all.length - 2; i < all.length; i++) {
      if (i < 8) continue;
      sb.writeln('第${i + 1}行[${all[i].length}格]: ${all[i].join(' | ')}');
    }
  }
  return sb.toString();
}

/// 单元格纯文本：去标签、去实体
String _htmlText(String raw) {
  var s = raw.replaceAll(RegExp(r'<[^>]*>'), '');
  s = s
      .replaceAll(RegExp(r'&nbsp;?|&#160;?'), ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"');
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

// ───────────────────────────────────────────────────────────────────────────
// 车组号 / 车站大屏查询返回体
// ───────────────────────────────────────────────────────────────────────────

/// 单个数据源的结果（失败时 error 非空）
class _EmuPart {
  final List<_EmuRecord> records;
  final List<_EmuProfile> profiles;
  final String? error;
  final String sourceName;

  const _EmuPart({
    this.records = const <_EmuRecord>[],
    this.profiles = const <_EmuProfile>[],
    this.error,
    this.sourceName = '',
  });

  _EmuPart.error(this.sourceName, this.error)
      : records = const <_EmuRecord>[],
        profiles = const <_EmuProfile>[];
}

/// 查询关键词的类型：车组号 / 车次 / 无法判定
enum _EmuQueryKind { emu, train, unknown }

class _EmuResult {
  final String keyword;
  final _EmuQueryKind kind;
  final List<_EmuRecord> records;
  final List<_EmuProfile> profiles;
  final List<String> errors;

  const _EmuResult({
    required this.keyword,
    required this.records,
    required this.profiles,
    required this.errors,
    this.kind = _EmuQueryKind.emu,
  });

  /// 首个配属档案（单组查询时用）
  _EmuProfile? get profile => profiles.isEmpty ? null : profiles.first;

  /// 是否由「车次」反查出来的多组结果
  bool get isTrainQuery => kind == _EmuQueryKind.train;

  /// 结果里出现过的车组号，按最近担当排序（去重）
  List<String> get emuNos {
    final out = <String>[];
    final seen = <String>{};
    for (final r in records) {
      if (r.emuNo.isNotEmpty && seen.add(r.emuNo)) out.add(r.emuNo);
    }
    return out;
  }
}

class _BoardResult {
  final String station;
  final List<_BoardItem> items;
  final List<String> notes;

  /// 数据源声称的当日总趟数（读不到为 null）
  final int? total;
  /// 是否还能继续翻页
  final bool hasMore;
  /// 已被数据源单次上限截断（即使翻到头也未必是全天完整数据）
  final bool truncated;
  /// 当前生效的分页风格
  final _BoardPageStyle style;
  /// 已尝试过但无效的分页风格（避免重复探测浪费配额）
  final List<_BoardPageStyle> tried;
  /// 已翻页数（首页为 1）
  final int pages;
  /// 服务端累计返回条数（可能多于去重后的 items.length，offset 分页要用它）
  final int fetched;
  /// cursor 风格下服务端回传的下一页游标
  final String nextCursor;

  const _BoardResult({
    required this.station,
    required this.items,
    required this.notes,
    this.total,
    this.hasMore = false,
    this.truncated = false,
    this.style = _BoardPageStyle.none,
    this.tried = const <_BoardPageStyle>[],
    this.pages = 1,
    this.fetched = 0,
    this.nextCursor = '',
  });

  _BoardResult copyWith({
    List<_BoardItem>? items,
    List<String>? notes,
    int? total,
    bool? hasMore,
    bool? truncated,
    _BoardPageStyle? style,
    List<_BoardPageStyle>? tried,
    int? pages,
    int? fetched,
    String? nextCursor,
  }) {
    return _BoardResult(
      station: station,
      items: items ?? this.items,
      notes: notes ?? this.notes,
      total: total ?? this.total,
      hasMore: hasMore ?? this.hasMore,
      truncated: truncated ?? this.truncated,
      style: style ?? this.style,
      tried: tried ?? this.tried,
      pages: pages ?? this.pages,
      fetched: fetched ?? this.fetched,
      nextCursor: nextCursor ?? this.nextCursor,
    );
  }

  /// 追加一页（[fresh] 为去重后的新增部分）
  _BoardResult append(_BoardPage page, List<_BoardItem> fresh) {
    final t = page.total ?? total;
    return copyWith(
      items: <_BoardItem>[...items, ...fresh],
      total: t,
      pages: pages + 1,
      fetched: fetched + page.items.length,
      nextCursor: page.nextCursor,
      // 自报 hasMore 优先；否则按「本页是否拿满」推断
      hasMore: page.hasMore ?? (page.items.length >= _kBoardPageSize),
      truncated: t != null && items.length + fresh.length < t,
    );
  }

  /// 头部文案，如「共 312 趟 · 已加载 240」
  String get countLabel {
    final t = total;
    if (t != null && t > items.length) {
      return '共 $t 趟 · 已加载 ${items.length}';
    }
    if (t != null) return '共 $t 趟';
    return '当日 ${items.length} 趟';
  }

  /// 是否值得显示「加载更多」按钮
  bool get canLoadMore => hasMore;
}

String _cleanErr(Object e) =>
    e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');

String _fmtDash(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _fmtCompact(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}'
    '${d.month.toString().padLeft(2, '0')}'
    '${d.day.toString().padLeft(2, '0')}';

String _fmtCn(DateTime d) =>
    '${d.month}月${d.day}日 ${_weekdayCn(d.weekday)}';

String _weekdayCn(int w) {
  const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  return names[((w - 1).clamp(0, 6)).toInt()];
}

/// 今天的零点（日期比较/预售期边界统一用它）
DateTime _today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

/// 秒级 Unix 时间戳 → 上海时间（数据源一律按 UTC+8 出）
DateTime _tsCst(int? sec) {
  if (sec == null || sec <= 0) {
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
  return DateTime.fromMillisecondsSinceEpoch(sec * 1000, isUtc: true)
      .add(const Duration(hours: 8));
}

/// 秒级 Unix 时间戳 → HH:mm，非法值返回空串
String _hhmm(int? sec) {
  if (sec == null || sec <= 0) return '';
  final t = _tsCst(sec);
  return '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}

/// OpenCRHTracker 的 serviceDay：按上海时间自 1970-01-01 起的天数
/// （文档示例：2026-08-14 → 20679，已验证一致）
DateTime _serviceDayToDate(int day) =>
    DateTime.fromMillisecondsSinceEpoch(day * 86400000, isUtc: true)
        .add(const Duration(hours: 8));

/// {prefix: 'G', number: 9418} → G9418
String _joinTrainCode(dynamic tc) {
  if (tc is Map) {
    final p = (tc['prefix'] ?? '').toString();
    final n = (tc['number'] ?? '').toString();
    final code = '$p$n';
    if (code.trim().isNotEmpty && code != p) return code;
  }
  return tc?.toString() ?? '';
}

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 站名归一化（去空格、去“站”字，用于里程/正晚点的站名配对）
String _normStation(String name) {
  var s = name.trim().replaceAll(RegExp(r'\s+'), '');
  if (s.length > 1 && s.endsWith('站')) s = s.substring(0, s.length - 1);
  return s;
}

/// 从 12306 经停记录里挖电报码（不同版本字段名不一致，多做几个候选）
String? _pickTelecode(Map e) {
  for (final k in <String>[
    'station_telecode',
    'station_tele_code',
    'telecode',
    'station_code',
    'stationCode',
    'stationTelecode',
  ]) {
    final v = e[k];
    if (v == null) continue;
    final s = v.toString().trim().toUpperCase();
    if (RegExp(r'^[A-Z]{3}$').hasMatch(s)) return s;
  }
  return null;
}

/// 从 12306 检索结果里挖车型（普速主要靠它，字段同样不稳定）
String _pickTrainModel(Map e) {
  for (final k in <String>[
    'train_type',
    'trainType',
    'train_type_name',
    'crh_type',
    'emu_type',
    'model',
    'type',
  ]) {
    final v = e[k];
    if (v == null) continue;
    final s = v.toString().trim();
    if (s.isEmpty || s == 'null') continue;
    // 排除明显不是车型的枚举值
    if (RegExp(r'^\d+$').hasMatch(s)) continue;
    return s;
  }
  return '';
}

/// 里程解析：先按 JSON 找「站名 + 里程」字段，失败再按 HTML 表格抓
Map<String, double> _parseMileage(String body) {
  final out = <String, double>{};
  if (body.trim().isEmpty) return out;

  // ── JSON 分支 ────────────────────────────────────────────────────────────
  try {
    final root = jsonDecode(body);
    final list = (root is List)
        ? root
        : (root is Map
            ? ((root['data'] is List)
                ? root['data'] as List
                : ((root['data'] is Map)
                    ? ((root['data']['list'] ?? root['data']['items']) as List?)
                    : null))
            : null);
    if (list != null) {
      for (final e in list) {
        if (e is! Map) continue;
        final name = (e['station'] ?? e['station_name'] ?? e['name'] ?? '')
            .toString()
            .trim();
        final raw = (e['mileage'] ?? e['km'] ?? e['distance'] ?? e['licheng'])
            ?.toString();
        final km = _toKm(raw);
        if (name.isNotEmpty && km != null) out[_normStation(name)] = km;
      }
      if (out.isNotEmpty) return out;
    }
  } catch (_) {
    // 不是 JSON，走 HTML 分支
  }

  // ── HTML 表格分支 ────────────────────────────────────────────────────────
  final rows = RegExp(
    r'<tr[^>]*>(.*?)</tr>',
    caseSensitive: false,
    dotAll: true,
  ).allMatches(body);

  int? mileCol; // 表头里「里程」所在列
  int? nameCol; // 表头里「站名」所在列

  for (final row in rows) {
    final cells = RegExp(
      r'<t[dh][^>]*>(.*?)</t[dh]>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(row.group(1) ?? '');

    final texts = cells
        .map(
          (m) => (m.group(1) ?? '')
              .replaceAll(RegExp(r'<[^>]*>'), '')
              .replaceAll(RegExp(r'&nbsp;?'), ' ')
              .trim(),
        )
        .where((t) => t.isNotEmpty)
        .toList();
    if (texts.length < 2) continue;

    // 表头行：记住列位置，不产出数据
    final headIdx = texts.indexWhere((t) => t.contains('里程'));
    if (headIdx >= 0) {
      mileCol = headIdx;
      final nIdx = texts.indexWhere(
        (t) => t.contains('站名') || t.contains('车站'),
      );
      nameCol = nIdx >= 0 ? nIdx : null;
      continue;
    }

    // 站名：优先用表头定位的列，否则取第一个含中文、非纯数字的单元格
    var nameIdx = nameCol ?? -1;
    if (nameIdx < 0 || nameIdx >= texts.length) {
      nameIdx = texts.indexWhere(
        (t) => RegExp(r'[\u4e00-\u9fa5]').hasMatch(t) &&
            !RegExp(r'^\d+(\.\d+)?$').hasMatch(t),
      );
    }
    if (nameIdx < 0 || nameIdx >= texts.length) continue;

    // 里程：优先按表头列取，否则取站名之后第一个形如 123 / 123.4 / 123km 的格
    double? km;
    if (mileCol != null && mileCol < texts.length) {
      km = _toKm(texts[mileCol]);
    }
    if (km == null) {
      for (var i = nameIdx + 1; i < texts.length; i++) {
        km = _toKm(texts[i]);
        if (km != null) break;
      }
    }
    if (km == null) continue;
    out[_normStation(texts[nameIdx])] = km;
  }
  return out;
}

/// HH:mm → 当日分钟数，解析失败返回 null
int? _parseHm(String v) {
  final m = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(v.trim());
  if (m == null) return null;
  final h = int.tryParse(m.group(1)!);
  final mm = int.tryParse(m.group(2)!);
  if (h == null || mm == null) return null;
  return h * 60 + mm;
}

double? _toKm(String? raw) {
  if (raw == null) return null;
  final s = raw.trim().toLowerCase().replaceAll(RegExp(r'[,，\s]'), '');
  final m = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(s.replaceAll('km', ''));
  if (m == null) return null;
  return double.tryParse(m.group(1)!);
}

/// 正晚点解析：JSON 取 data/message 文本，HTML 去标签，再抓「晚点 X 分 / 正点」
_LateInfo? _parseLate(String body) {
  if (body.trim().isEmpty) return null;

  String text;
  try {
    final root = jsonDecode(body);
    if (root is Map) {
      var buf = '';
      for (final k in <String>['data', 'message', 'msg', 'result']) {
        final v = root[k];
        if (v is String) {
          buf += ' $v';
        } else if (v is Map) {
          for (final kk in <String>['msg', 'message', 'text', 'status']) {
            final vv = v[kk];
            if (vv is String) buf += ' $vv';
          }
        }
      }
      text = buf.isNotEmpty ? buf : root.toString();
    } else {
      text = root.toString();
    }
  } catch (_) {
    text = body.replaceAll(RegExp(r'<[^>]*>', dotAll: true), ' ');
  }

  final t = text.replaceAll(RegExp(r'\s+'), ' ');

  final late = RegExp(r'晚点\s*(\d+)\s*分').firstMatch(t);
  if (late != null) {
    return _LateInfo(lateMin: int.tryParse(late.group(1)!) ?? 0);
  }
  final early = RegExp(r'早点\s*(\d+)\s*分').firstMatch(t);
  if (early != null) {
    return _LateInfo(lateMin: -(int.tryParse(early.group(1)!) ?? 0));
  }
  if (t.contains('正点')) return const _LateInfo(lateMin: 0);

  final tm = RegExp(r'(\d{1,2}:\d{2})').firstMatch(t);
  if (tm != null) return _LateInfo(realTime: tm.group(1)!);

  return null;
}

/// 车组号写法的候选列表，按命中概率排序：
///   CR400BF-5033 → [CR400BF-5033, CR400BF5033]
///   CR400BF5033  → [CR400BF5033, CR400BF-5033]
/// 两个数据源对横杠的容忍度不一致，两边都拿候选列表去试最稳。
List<String> _emuNoVariants(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return const <String>[];
  final out = <String>[s];
  if (s.contains('-')) {
    final noDash = s.replaceAll('-', '');
    if (noDash.isNotEmpty) out.add(noDash);
  } else {
    final dashed = _prettyEmuNo(s);
    if (dashed != s) out.add(dashed);
  }
  return out;
}

/// rail.re 的车组号是 CR400AF2031（无横杠），补成 CR400AF-2031
String _prettyEmuNo(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return s;
  if (s.contains('-')) return s;
  final m = RegExp(r'^([A-Za-z]+[A-Za-z0-9]*?)(\d{3,5})$').firstMatch(s);
  if (m != null) return '${m.group(1)}-${m.group(2)}';
  return s;
}

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
                      '　⚠️ 型号维度请输 HXD3D，输完整车号 HXD3D0001 会返回 0 条',
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
            '提示：12306 未开放公共 API，直连可能被风控拦截。'
            '建议自建反代后修改文件顶部 _kKyfwBase / _kSearchBase。',
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
        if (_runs.isEmpty) return _empty('选择出发/到达站后点击查询');
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
        return _empty('输入车站后点击查询');
    }
    return const SizedBox.shrink();
  }

  Widget _center(Widget child) => Center(child: child);

  Widget _empty(String text) => Center(
        child: Text(text, style: const TextStyle(color: Colors.grey)),
      );

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

  /// 列表共用的「加载更多 / 到底了」尾部
  Widget _psLoadMoreFooter(bool hasMore) {
    if (!hasMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: Text('已全部加载',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
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
          : OutlinedButton.icon(
              onPressed: _loadMorePs,
              icon: const Icon(Icons.expand_more, size: 18),
              label: const Text('加载更多'),
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
          error: r.error,
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
        if (r.items.isNotEmpty) _psLoadMoreFooter(r.hasMore),
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
          error: r.error,
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
        if (r.items.isNotEmpty) _psLoadMoreFooter(r.hasMore),
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
              child: Text(error,
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
    _focus.addListener(() {
      if (!_focus.hasFocus && mounted) setState(() => _showPanel = false);
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
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
    final res = <_Station>[];
    // 精确/前缀优先
    for (final s in widget.stations) {
      if (s.name.startsWith(q) || s.code == upper) res.add(s);
      if (res.length >= 20) break;
    }
    if (res.length < 20) {
      for (final s in widget.stations) {
        if (res.any((e) => e.code == s.code)) continue;
        if (s.name.contains(q) ||
            s.initials.toLowerCase().startsWith(q) ||
            s.pinyin.toLowerCase().startsWith(q)) {
          res.add(s);
        }
        if (res.length >= 20) break;
      }
    }
    setState(() {
      _suggestions = res;
      _showPanel = res.isNotEmpty;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
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
          Container(
            constraints: const BoxConstraints(maxHeight: 180),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border.all(
                color: Theme.of(context).dividerColor,
              ),
              borderRadius: BorderRadius.circular(6),
              boxShadow: const [
                BoxShadow(blurRadius: 4, color: Colors.black26),
              ],
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
                  trailing: Text(
                    s.code,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  onTap: () {
                    widget.controller.text = s.name;
                    setState(() => _showPanel = false);
                    _focus.unfocus();
                  },
                );
              },
            ),
          ),
      ],
    );
  }
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
                      '　⚠️ 型号维度请输 HXD3D，输完整车号 HXD3D0001 会返回 0 条',
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
            error: r.error,
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
          if (r.items.isNotEmpty) _buildLoadMoreFooter(r.hasMore),
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
            '机车请输型号 HXD3D（不是 HXD3D0001）或配属段 京局京段',
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
          error: r.error,
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
        if (r.items.isNotEmpty) _buildLoadMoreFooter(r.hasMore),
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
              child: Text(error,
                  style: const TextStyle(fontSize: 11, color: Colors.orange)),
            ),
        ],
      ),
    );
  }

  Widget _buildLoadMoreFooter(bool hasMore) {
    if (!hasMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: Text('已全部加载',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
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
          : OutlinedButton.icon(
              onPressed: _loadMore,
              icon: const Icon(Icons.expand_more, size: 18),
              label: const Text('加载更多'),
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
