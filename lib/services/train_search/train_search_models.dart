// 数据模型 + 配置常量（数据源地址、缓存时长、分页参数、查询维度）
part of '../../pages/train_search_page.dart';


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
//      机车站可用：model=型号 / depot=配属段 / number=车号
//      ⚠️ number（车号）一度被误判为「不通」，实测是**关键字写法不对**：
//         type=number 要输车号里的**编号部分**（0047），
//         实测 keyword=0047 → 23 条（HXD10047/HXD1C0047/HXD3D0047…）；
//         输完整车号 HXD3D0047 或型号 HXD3D 都是 0 条（不报错，静默返回首页模板）。
//         这条最容易踩，界面提示里单独点出来（见 _kPasLocoHint）。
//      机车站不通：no / loco（车号，报「参数错误」）、
//                  factory / manufacturer（厂家，报「参数错误」）、train（车次）
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
///
/// ⚠️ number 曾长期被当成「不可用」而剔除，实测是能用的，只是
///    关键字必须输车号里的编号部分（0047），输完整车号 HXD3D0047 反而 0 条。
///    现在放回来，顺序按常用度排：型号 → 车号 → 配属段。
const Map<String, String> _kPasLocoTypes = <String, String>{
  'model': '型号',
  'number': '车号',
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
  // ⚠️ 车号维度要输「编号」，不能输完整车号：
  //    实测 keyword=0047 → 23 条；keyword=HXD3D0047 → 0 条（静默无结果）。
  //    这是最容易踩的坑，提示里必须写死示例。
  'number': '如 0047（车号里的编号，不是 HXD3D0047）',
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
  /// 整行原始内容拼成的指纹。
  ///
  /// ⚠️ 这是去重键的主力。按型号查机车时（type=model），
  ///    服务端表格的第一列是**型号**（HXD3D），不是完整车号（HXD3D0001）——
  ///    50 条记录的 locoNo 全是同一个 "HXD3D"，拿它当 dedupKey 的话
  ///    第 2 页必然被判成「与已加载完全重复」，翻页就此卡死。
  ///    改用整行指纹，只要行内容不同就判为不同，不再依赖列定位猜得准不准。
  final String rawKey;

  const _LocoItem({
    this.locoNo = '',
    this.bureau = '',
    this.depot = '',
    this.factory = '',
    this.note = '',
    this.rawKey = '',
  });

  bool get isEmpty => locoNo.isEmpty && rawKey.isEmpty;

  String get title => locoNo;

  String get subtitle => <String>[
        '${bureau}${depot}'.trim(),
        factory,
        note,
      ].where((e) => e.isNotEmpty).join('　');

  /// 整行指纹优先，它缺失时才退回车号
  String get dedupKey => rawKey.isNotEmpty ? rawKey : locoNo;
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
  /// 「加载更多」过程中的失败原因。
  ///
  /// ⚠️ 以前翻页失败是静默吞掉的：直接 hasMore = false，界面秒变「已全部加载」，
  ///    用户看到的就是「点了加载更多什么都没发生」。现在失败原因必须带到界面上。
  final String? moreError;
  /// 服务端本页「下一页」链接的原样 URL。
  ///
  /// ⚠️ 这是翻页可靠性的关键：自己拼 URL 要赌参数名、赌顺序、赌编码，
  ///    而服务端自己吐出来的链接必然是对的。下一页直接请求这个 URL，
  ///    拼错参数这类问题就从根上消失了。
  final String? nextUrl;
  // ── 翻页排查用的现场证据 ──────────────────────────────────────────────
  // 「第二页返回 50 条但全部重复」这种事，光看代码看不出来：
  // 必须能看到「究竟请求了哪个 URL」「服务端自己说这是第几页」
  // 「本页首/末条是什么」，一眼才能分辨是 URL 拼错还是命中了缓存。
  final String? requestedUrl;
  final int? serverPage;
  final String? firstKey;
  final String? lastKey;

  const _CarPart({
    this.items = const <_CarStock>[],
    this.total,
    this.pages = 0,
    this.hasMore = false,
    this.type = '',
    this.error,
    this.moreError,
    this.nextUrl,
    this.requestedUrl,
    this.serverPage,
    this.firstKey,
    this.lastKey,
  });

  _CarPart copyWith({
    List<_CarStock>? items,
    int? total,
    int? pages,
    bool? hasMore,
    String? type,
    String? error,
    String? moreError,
    String? nextUrl,
    String? requestedUrl,
    int? serverPage,
    String? firstKey,
    String? lastKey,
    bool clearMoreError = false,
    bool clearNextUrl = false,
  }) =>
      _CarPart(
        items: items ?? this.items,
        total: total ?? this.total,
        pages: pages ?? this.pages,
        hasMore: hasMore ?? this.hasMore,
        type: type ?? this.type,
        error: error ?? this.error,
        moreError: clearMoreError ? null : (moreError ?? this.moreError),
        nextUrl: clearNextUrl ? null : (nextUrl ?? this.nextUrl),
        requestedUrl: requestedUrl ?? this.requestedUrl,
        serverPage: serverPage ?? this.serverPage,
        firstKey: firstKey ?? this.firstKey,
        lastKey: lastKey ?? this.lastKey,
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
  /// 「加载更多」过程中的失败原因（同 _CarPart.moreError）
  final String? moreError;
  /// 服务端本页「下一页」链接的原样 URL（同 _CarPart.nextUrl）
  final String? nextUrl;
  /// 排查用：实际请求的 URL / 服务端标注页码 / 本页首末条（同 _CarPart）
  final String? requestedUrl;
  final int? serverPage;
  final String? firstKey;
  final String? lastKey;

  const _LocoPart({
    this.items = const <_LocoItem>[],
    this.total,
    this.pages = 0,
    this.hasMore = false,
    this.type = '',
    this.error,
    this.moreError,
    this.nextUrl,
    this.requestedUrl,
    this.serverPage,
    this.firstKey,
    this.lastKey,
  });

  _LocoPart copyWith({
    List<_LocoItem>? items,
    int? total,
    int? pages,
    bool? hasMore,
    String? type,
    String? error,
    String? moreError,
    String? nextUrl,
    String? requestedUrl,
    int? serverPage,
    String? firstKey,
    String? lastKey,
    bool clearMoreError = false,
    bool clearNextUrl = false,
  }) =>
      _LocoPart(
        items: items ?? this.items,
        total: total ?? this.total,
        pages: pages ?? this.pages,
        hasMore: hasMore ?? this.hasMore,
        type: type ?? this.type,
        error: error ?? this.error,
        moreError: clearMoreError ? null : (moreError ?? this.moreError),
        nextUrl: clearNextUrl ? null : (nextUrl ?? this.nextUrl),
        requestedUrl: requestedUrl ?? this.requestedUrl,
        serverPage: serverPage ?? this.serverPage,
        firstKey: firstKey ?? this.firstKey,
        lastKey: lastKey ?? this.lastKey,
      );
}

/// 普速查询的两个分栏：车厢 / 机车
enum _PsTab { car, loco }

String _psTabLabel(_PsTab t) => t == _PsTab.car ? '车厢配属' : '机车配属';

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
